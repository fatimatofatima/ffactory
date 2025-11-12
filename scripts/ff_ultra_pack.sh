#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; ENVF=$FF/.env; NET=ffactory_ffactory_net
[ -f "$ENVF" ] || die ".env مفقود"
docker network inspect "$NET" >/dev/null 2>&1 || die "شبكة $NET غير موجودة"

install -d -m 755 "$APPS/ocr-engine" "$APPS/face-engine" "$APPS/embed-search" "$FF/data/embeds" "$STACK"

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ========= OCR (Tesseract) =========
cat >"$APPS/ocr-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
pillow==10.3.0
pytesseract==0.3.10
requests==2.31.0
opencv-python-headless==4.10.0.84
R
cat >"$APPS/ocr-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests
from PIL import Image
import pytesseract
api=FastAPI()
LANGS=os.getenv("OCR_LANGS","ara+eng")
class Req(BaseModel): image_url:str; lang:str|None=None
@api.get("/health")
def health(): return {"status":"ok","langs":LANGS}
@api.post("/ocr")
def ocr(inp:Req):
    try:
        r=requests.get(inp.image_url,timeout=60); r.raise_for_status()
        im=Image.open(io.BytesIO(r.content))
        txt=pytesseract.image_to_string(im, lang=inp.lang or LANGS)
        return {"text":txt.strip()}
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/ocr-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-eng tesseract-ocr-ara libglib2.0-0 libgl1 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8091
ENV OCR_LANGS=ara+eng
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8091"]
D
sanitize "$APPS/ocr-engine/Dockerfile"

# ========= Face (InsightFace/ONNXRuntime) =========
cat >"$APPS/face-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
insightface==0.7.3
onnxruntime==1.18.0
opencv-python-headless==4.10.0.84
pillow==10.3.0
numpy==1.26.4
requests==2.31.0
R
cat >"$APPS/face-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests, numpy as np
from PIL import Image
from insightface.app import FaceAnalysis
api=FastAPI()
MODEL=os.getenv("FACE_MODEL","buffalo_l")
try:
    fa=FaceAnalysis(name=MODEL); fa.prepare(ctx_id=0, det_size=(640,640)); READY=True; ERR=""
except Exception as e:
    READY=False; ERR=str(e)
class Req(BaseModel): image_url:str
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":(ERR or None)}
@api.post("/detect")
def detect(inp:Req):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    r=requests.get(inp.image_url,timeout=60); r.raise_for_status()
    im=np.array(Image.open(io.BytesIO(r.content)).convert("RGB"))
    faces=fa.get(im)
    out=[]
    for f in faces:
        out.append({
          "bbox":[float(x) for x in f.bbox.tolist()],
          "det_score": float(getattr(f, "det_score", 0.0)),
          "embedding": [float(x) for x in (f.normed_embedding if hasattr(f,"normed_embedding") else f.embedding)[:128]]
        })
    return {"count":len(out),"faces":out}
PY
cat >"$APPS/face-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libglib2.0-0 libgl1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8092
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8092"]
D
sanitize "$APPS/face-engine/Dockerfile"

# ========= Embed-Search (FAISS + ST) =========
cat >"$APPS/embed-search/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
faiss-cpu==1.7.4
sentence-transformers==3.0.1
torch==2.4.1
pydantic==2.9.2
R
cat >"$APPS/embed-search/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, sqlite3, faiss, numpy as np, threading
from sentence_transformers import SentenceTransformer
DB=os.getenv("EMBED_DB","/data/embeds/index.sqlite")
MODEL_ID=os.getenv("EMBED_MODEL","sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
api=FastAPI()
os.makedirs(os.path.dirname(DB), exist_ok=True)
m=SentenceTransformer(MODEL_ID)
D=m.get_sentence_embedding_dimension()
lock=threading.Lock()
def db(): 
    con=sqlite3.connect(DB); con.execute("CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, text TEXT, vec BLOB)"); return con
def to_vec(text): 
    v=m.encode([text], normalize_embeddings=True)[0].astype("float32"); return v
def load_index():
    con=db(); rows=con.execute("SELECT vec FROM docs").fetchall(); con.close()
    xb=np.vstack([np.frombuffer(r[0], dtype="float32") for r in rows]) if rows else np.empty((0,D),dtype="float32")
    index=faiss.IndexFlatIP(D)
    if xb.shape[0]>0: index.add(xb)
    return index
index=load_index()
@api.get("/health")
def health():
    con=db(); n=con.execute("SELECT COUNT(*) FROM docs").fetchone()[0]; con.close()
    return {"status":"ok","model":MODEL_ID,"dim":D,"docs":int(n)}
class AddReq(BaseModel): id:str; text:str
@api.post("/index/add")
def add(r:AddReq):
    v=to_vec(r.text)
    with lock:
        con=db(); con.execute("INSERT OR REPLACE INTO docs(id,text,vec) VALUES(?,?,?)",(r.id,r.text,v.tobytes())); con.commit(); con.close()
        index.add(v.reshape(1,-1))
    return {"ok":True}
class SearchReq(BaseModel): q:str; k:int|None=5
@api.post("/search")
def search(r:SearchReq):
    v=to_vec(r.q).reshape(1,-1)
    with lock:
        D_,I=index.search(v, r.k or 5)
    con=db()
    ids=[]; rows=con.execute("SELECT rowid,id,text FROM docs").fetchall(); con.close()
    # Map FAISS order to DB rows
    id_by_row=[r[1] for r in rows]; text_by_row=[r[2] for r in rows]
    out=[]
    for pos,score in zip(I[0],D_[0]):
        if pos<0 or pos>=len(id_by_row): continue
        out.append({"id":id_by_row[pos], "score":float(score), "text":text_by_row[pos]})
    return {"hits":out}
PY
cat >"$APPS/embed-search/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/embeds"]
EXPOSE 8093
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8093"]
D
sanitize "$APPS/embed-search/Dockerfile"

# ========= Compose ext4 =========
EXT="$STACK/docker-compose.apps.ext4.yml"
cat >"$EXT"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { embeds_data: {} }

services:
  ocr-engine:
    build: { context: ../apps/ocr-engine, dockerfile: Dockerfile }
    container_name: ffactory_ocr
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8091:8091" ]
    healthcheck: { test: ["CMD","curl","-fsS","http://127.0.0.1:8091/health"], interval: 10s, timeout: 5s, retries: 40 }

  face-engine:
    build: { context: ../apps/face-engine, dockerfile: Dockerfile }
    container_name: ffactory_face
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8092:8092" ]
    healthcheck: { test: ["CMD","curl","-fsS","http://127.0.0.1:8092/health"], interval: 10s, timeout: 5s, retries: 40 }

  embed-search:
    build: { context: ../apps/embed-search, dockerfile: Dockerfile }
    container_name: ffactory_embed
    networks: [ ffactory_ffactory_net ]
    volumes: [ "/opt/ffactory/data/embeds:/data/embeds" ]
    ports: [ "127.0.0.1:8093:8093" ]
    healthcheck: { test: ["CMD","curl","-fsS","http://127.0.0.1:8093/health"], interval: 10s, timeout: 5s, retries: 40 }
YML

log "build+up ultra pack"
docker compose --env-file "$ENVF" -f "$EXT" up -d --build

echo "---- ps (subset) ----"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_(ocr|face|embed)' | head -n 2 || true
echo "---- health ----"
for p in 8091 8092 8093; do curl -fsS "http://127.0.0.1:$p/health" >/dev/null || echo "FAIL /health :$p"; done
log "done"
