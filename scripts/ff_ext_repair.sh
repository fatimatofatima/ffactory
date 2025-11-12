#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; STACK=$FF/stack; APPS=$FF/apps; ENVF=$FF/.env; NET=ffactory_ffactory_net
[ -f "$ENVF" ] || die ".env مفقود. شغّل الأساس أولًا."
docker network inspect "$NET" >/dev/null 2>&1 || die "الشبكة $NET غير موجودة."

install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service" "$STACK" "$FF/data/hashsets"

# اختيار منفذ شاغر
pick_free_port(){ p="$1"; while ss -lnt 2>/dev/null | awk '{print $4}' | sed 's/.*://g' | grep -qx "$p"; do p=$((p+1)); done; echo "$p"; }

VP=$(pick_free_port "${VISION_PORT:-8081}")
MP=$(pick_free_port "${MEDIA_PORT:-8082}")
HP=$(pick_free_port "${HASHSET_PORT:-8083}")

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ========== vision-engine (YOLOv8) ==========
cat >"$APPS/vision-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
pillow==10.3.0
opencv-python-headless==4.10.0.84
ultralytics==8.2.103
requests==2.31.0
R
cat >"$APPS/vision-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, requests, cv2
from PIL import Image
from ultralytics import YOLO
import os
api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt")
ERR=None
try:
    yolo=YOLO(MODEL); READY=True
except Exception as e:
    READY=False; ERR=str(e)
class ImgReq(BaseModel): image_url:str; conf:float|None=0.25
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":ERR}
@api.post("/detect")
def detect(inp:ImgReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    r=requests.get(inp.image_url,timeout=30); r.raise_for_status()
    im=Image.open(io.BytesIO(r.content)).convert("RGB")
    res=yolo.predict(im, conf=inp.conf or 0.25, verbose=False)[0]
    out=[]; names=res.names
    for b in res.boxes:
        cid=int(b.cls[0]); out.append({"cls_id":cid,"cls":names.get(cid,str(cid)),"conf":float(b.conf[0])})
    return {"detections":out}
PY
cat >"$APPS/vision-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/vision-engine/Dockerfile"

# ========== media-forensics (ELA/EXIF/PRNU بسيط) ==========
cat >"$APPS/media-forensics/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
pillow==10.3.0
opencv-python-headless==4.10.0.84
numpy==1.26.4
imagehash==4.3.1
exifread==3.0.0
requests==2.31.0
R
cat >"$APPS/media-forensics/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, base64, requests, numpy as np, cv2
from PIL import Image, ImageChops
import imagehash, exifread
api=FastAPI()
class ImgReq(BaseModel): image_url:str; ela_quality:int|None=90; heatmap:bool|None=False
@api.get("/health")
def health(): return {"status":"ok"}
def _fetch(url): r=requests.get(url,timeout=30); r.raise_for_status(); return r.content
def _pil(b): return Image.open(io.BytesIO(b)).convert('RGB')
def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q); comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff,dtype=np.int16); return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr),95))
def prnu_residual(img):
    g=np.array(img.convert('L'),dtype=np.float32)/255.0
    den=cv2.fastNlMeansDenoising((g*255).astype(np.uint8),None,h=7,templateWindowSize=7,searchWindowSize=21).astype(np.float32)/255.0
    r=g-den; r=r-r.mean(); r/= (r.std()+1e-8); return r
@api.post("/analyze")
def analyze(inp:ImgReq):
    try:
        raw=_fetch(inp.image_url); img=_pil(raw); w,h=img.size
        diff,m,p95=ela(img, inp.ela_quality or 90)
        r=prnu_residual(img); p_strength=float(np.mean(r**2))
        ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        try:
            tags=exifread.process_file(io.BytesIO(raw), details=False)
            keep=("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
            exif={k:str(v) for k,v in tags.items() if k in keep}
        except: exif={}
        out={"w":w,"h":h,"ela_mean":m,"ela_p95":p95,"prnu_strength":p_strength,"ahash":ah,"phash":ph,"exif":exif}
        if inp.heatmap:
            b1=io.BytesIO(); (Image.fromarray(((r-r.min())/(r.max()-r.min()+1e-8)*255).astype(np.uint8))).save(b1,'PNG')
            b2=io.BytesIO(); diff.save(b2,'PNG')
            out["prnu_png_b64"]=base64.b64encode(b1.getvalue()).decode()
            out["ela_png_b64"]=base64.b64encode(b2.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/media-forensics/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/media-forensics/Dockerfile"

# ========== hashset-service (SHA*, ssdeep عبر binary, NSRL sqlite) ==========
cat >"$APPS/hashset-service/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
R
cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, sqlite3, hashlib, requests, subprocess, tempfile, shlex
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db(): return sqlite3.connect(DB)
@api.get("/health")
def health():
    try:
        con=db(); con.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY);"); con.close()
        out=subprocess.run(["ssdeep","-h"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return {"status":"ok","nsrl_db":DB,"ssdeep":(out.returncode in (0,1))}
    except Exception as e:
        return {"status":"bad","error":str(e)}
class FileReq(BaseModel): file_url:str
@api.post("/hash")
def do_hash(req:FileReq):
    try:
        r=requests.get(req.file_url, timeout=60); r.raise_for_status()
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(r.content); f.flush(); path=f.name
        sha256=hashlib.sha256(r.content).hexdigest()
        sha1=hashlib.sha1(r.content).hexdigest()
        md5=hashlib.md5(r.content).hexdigest()
        try:
            out=subprocess.check_output(["ssdeep","-b",path]).decode(errors="ignore").strip().splitlines()[-1]
            ss=out.split(",")[0].strip()
        except Exception:
            ss=None
        os.unlink(path)
        return {"sha256":sha256,"sha1":sha1,"md5":md5,"ssdeep":ss}
    except Exception as e:
        raise HTTPException(500, str(e))
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    try:
        con=db(); cur=con.cursor()
        cur.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY);")
        cur.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;", (sha1.upper(),))
        hit=cur.fetchone() is not None
        con.close()
        return {"sha1":sha1, "in_nsrl":hit}
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/hashset-service/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends build-essential python3-dev libffi-dev ssdeep sqlite3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
D
sanitize "$APPS/hashset-service/Dockerfile"

# ========== compose (ext) ==========
EXT="$STACK/docker-compose.apps.ext.yml"
cat >"$EXT"<<YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { hashsets_data: {} }
services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${VP}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${MP}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    env_file: [ ../.env ]
    environment:
      - NSRL_DB_PATH=/data/hashsets/nsrl.sqlite
    volumes: [ "hashsets_data:/data/hashsets" ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${HP}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# ========== build+up ==========
log "build+up apps-ext (vision/media/hashset)"
docker compose --env-file "$ENVF" -f "$EXT" up -d --build --remove-orphans

# ========== MinIO WORM: alias set بدل MC_HOST_* ==========
worm(){
  . "$ENVF"
  MC="docker run --rm --network $NET minio/mc"
  $MC alias set ffminio "http://ffactory_minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  $MC mb --with-lock ffminio/forensic-evidence >/dev/null 2>&1 || true
  $MC version enable ffminio/forensic-evidence >/dev/null
  $MC retention set ffminio/forensic-evidence --default compliance 365d >/dev/null
  $MC retention info ffminio/forensic-evidence || true
}
log "configure MinIO WORM"
worm || true

# ========== health & المطلوب منك ==========
log "health checks"
curl -fsS "http://127.0.0.1:${VP}/health" || echo "vision FAIL (:${VP})"
curl -fsS "http://127.0.0.1:${MP}/health" || echo "media FAIL (:${MP})"
curl -fsS "http://127.0.0.1:${HP}/health" || echo "hashset FAIL (:${HP})"

log "two docker ps lines"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_' | head -n 2
