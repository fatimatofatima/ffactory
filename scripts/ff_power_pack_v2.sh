#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; ENVF=$FF/.env; NET=ffactory_ffactory_net
[ -f "$ENVF" ] || die ".env مفقود. شغّل الأساس أولاً."
docker network inspect "$NET" >/dev/null 2>&1 || die "شبكة $NET غير موجودة. شغّل الأساس أولاً."
install -d -m 755 "$APPS/ocr-engine" "$APPS/face-engine" "$APPS/embed-search" "$STACK"

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ===== OCR (Tesseract + عربي) =====
cat >"$APPS/ocr-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
pillow==10.3.0
pytesseract==0.3.10
requests==2.31.0
R
cat >"$APPS/ocr-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests
from PIL import Image
import pytesseract

api=FastAPI()
LANG=os.getenv("OCR_LANGS","ara+eng")
TESS_BIN=os.getenv("TESSERACT_BIN","/usr/bin/tesseract")
pytesseract.pytesseract.tesseract_cmd=TESS_BIN

class Inp(BaseModel):
    image_url:str
    psm:int|None=None
    oem:int|None=None
    langs:str|None=None

@api.get("/health")
def health(): 
    return {"status":"ok","langs":LANG,"tesseract":TESS_BIN}

@api.post("/ocr")
def ocr(inp:Inp):
    try:
        r=requests.get(inp.image_url,timeout=30); r.raise_for_status()
        img=Image.open(io.BytesIO(r.content))
        cfg=[]
        if inp.psm is not None: cfg+=["--psm",str(inp.psm)]
        if inp.oem is not None: cfg+=["--oem",str(inp.oem)]
        text=pytesseract.image_to_string(img, lang=(inp.langs or LANG), config=" ".join(cfg))
        return {"text":text.strip()}
    except Exception as e:
        raise HTTPException(500,str(e))
PY
cat >"$APPS/ocr-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-eng tesseract-ocr-ara \
    libarchive13 ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8084
ENV OCR_LANGS=ara+eng
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8084"]
D
sanitize "$APPS/ocr-engine/Dockerfile"

# ===== Face (InsightFace + ONNXRuntime CPU) =====
cat >"$APPS/face-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
numpy==1.26.4
pillow==10.3.0
opencv-python-headless==4.10.0.84
insightface==0.7.3
onnxruntime==1.19.2
requests==2.31.0
scikit-learn==1.5.2
R
cat >"$APPS/face-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, json, requests, numpy as np
from PIL import Image
import insightface
from insightface.app import FaceAnalysis
from numpy.linalg import norm

api=FastAPI()
PROVIDERS=["CPUExecutionProvider"]
MODEL=os.getenv("FACE_MODEL","buffalo_l")
try:
    app=FaceAnalysis(name=MODEL, providers=PROVIDERS)
    app.prepare(ctx_id=0, det_size=(640,640)); READY=True; ERR=""
except Exception as e:
    READY=False; ERR=str(e)

class ImgReq(BaseModel): image_url:str
class CmpReq(BaseModel): image_url_a:str; image_url_b:str

def _load_img(url):
    r=requests.get(url,timeout=30); r.raise_for_status()
    return np.array(Image.open(io.BytesIO(r.content)).convert("RGB"))

@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"err":(ERR or None)}

@api.post("/detect")
def detect(inp:ImgReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    img=_load_img(inp.image_url)
    faces=app.get(img)
    out=[]
    for f in faces:
        b=f.bbox.astype(float).tolist()
        k=f.kps.astype(float).tolist()
        out.append({"bbox":b,"kps":k,"det_score":float(f.det_score)})
    return {"faces":out}

@api.post("/embed")
def embed(inp:ImgReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    img=_load_img(inp.image_url)
    faces=app.get(img)
    embs=[(f.normed_embedding if hasattr(f,'normed_embedding') else f.embedding/ (norm(f.embedding)+1e-9)).astype(float).tolist() for f in faces]
    return {"count":len(embs),"embeddings":embs}

@api.post("/compare")
def compare(inp:CmpReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    A=_load_img(inp.image_url_a); B=_load_img(inp.image_url_b)
    fa=app.get(A); fb=app.get(B)
    if not fa or not fb: raise HTTPException(400,"face not found in one of images")
    ea=fa[0].normed_embedding if hasattr(fa[0],'normed_embedding') else fa[0].embedding/(norm(fa[0].embedding)+1e-9)
    eb=fb[0].normed_embedding if hasattr(fb[0],'normed_embedding') else fb[0].embedding/(norm(fb[0].embedding)+1e-9)
    sim=float((ea*eb).sum())
    return {"similarity":sim}
PY
cat >"$APPS/face-engine/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8085
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8085"]
D
sanitize "$APPS/face-engine/Dockerfile"

# ===== Embed-Search (Sentence-Transformers + FAISS) =====
cat >"$APPS/embed-search/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
sentence-transformers==2.2.2
faiss-cpu==1.8.0.post1
numpy==1.26.4
torch==2.4.1
requests==2.31.0
R
cat >"$APPS/embed-search/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, json, threading
import numpy as np, faiss
from sentence_transformers import SentenceTransformer

api=FastAPI()
MODEL=os.getenv("EMBED_MODEL","sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
DIM=384
idx_path="/data/index.faiss"; meta_path="/data/meta.json"
os.makedirs("/data", exist_ok=True)

_lock=threading.Lock()
model=SentenceTransformer(MODEL, device="cpu")
if os.path.exists(idx_path):
    index=faiss.read_index(idx_path)
    if not isinstance(index, faiss.IndexFlatIP): 
        index=faiss.IndexFlatIP(DIM)
else:
    index=faiss.IndexFlatIP(DIM)
meta={}
if os.path.exists(meta_path):
    try: meta=json.load(open(meta_path,"r"))
    except: meta={}

def _save():
    faiss.write_index(index, idx_path)
    json.dump(meta, open(meta_path,"w"), ensure_ascii=False)

def _embed(texts):
    v=model.encode(texts, normalize_embeddings=True, convert_to_numpy=True)
    if v.ndim==1: v=v[None,:]
    return v.astype("float32")

class UpItem(BaseModel): id:str; text:str
class UpReq(BaseModel): items:list[UpItem]
class SearchReq(BaseModel): q:str; k:int|None=5

@api.get("/health")
def health(): 
    return {"status":"ok","model":MODEL,"dim":DIM,"count":index.ntotal}

@api.post("/upsert")
def upsert(req:UpReq):
    with _lock:
        vecs=_embed([i.text for i in req.items])
        index.add(vecs)
        for i in req.items: meta[str(index.ntotal - len(req.items) + req.items.index(i))]= {"id":i.id,"text":i.text}
        _save()
    return {"added":len(req.items),"total":int(index.ntotal)}

@api.post("/search")
def search(req:SearchReq):
    if index.ntotal==0: return {"hits":[]}
    v=_embed([req.q])
    D,I=index.search(v, req.k or 5)
    hits=[]
    for rank,(d,i) in enumerate(zip(D[0], I[0])):
        if i<0: continue
        m=meta.get(str(i),{})
        hits.append({"rank":rank+1,"score":float(d),"id":m.get("id"),"text":m.get("text")})
    return {"hits":hits}

@api.post("/reset")
def reset():
    global index, meta
    with _lock:
        index=faiss.IndexFlatIP(DIM); meta={}; _save()
    return {"status":"cleared"}
PY
cat >"$APPS/embed-search/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
# استخدم عجلات CPU لبايثورتش
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data"]
EXPOSE 8087
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8087"]
D
sanitize "$APPS/embed-search/Dockerfile"

# ===== Compose (حزمة V2) =====
EXT2="$STACK/docker-compose.apps.ext2.yml"
cat >"$EXT2"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { embed_data: {} }

services:
  ocr-engine:
    build: { context: ../apps/ocr-engine, dockerfile: Dockerfile }
    container_name: ffactory_ocr
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8084:8084" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8084/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  face-engine:
    build: { context: ../apps/face-engine, dockerfile: Dockerfile }
    container_name: ffactory_face
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8085:8085" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8085/health"]
      interval: 10s
      timeout: 5s
      retries: 60

  embed-search:
    build: { context: ../apps/embed-search, dockerfile: Dockerfile }
    container_name: ffactory_embed
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "embed_data:/data" ]
    ports: [ "127.0.0.1:8087:8087" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8087/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# ===== تشغيل مرحلي =====
log "build+up ocr/face"
docker compose --env-file "$ENVF" -f "$EXT2" up -d --build ocr-engine face-engine
log "build+up embed"
docker compose --env-file "$ENVF" -f "$EXT2" up -d --build embed-search

# ===== ملخص وصحة =====
echo "---- docker ps (subset) ----"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_(ocr|face|embed)' || true
echo "---- health ----"
for p in 8084 8085 8087; do curl -fsS "http://127.0.0.1:$p/health" >/dev/null || echo "FAIL /health :$p"; done
