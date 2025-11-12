#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; STACK=$FF/stack; APPS=$FF/apps; NET=ffactory_ffactory_net
ENVF=$FF/.env; EXTY=$STACK/docker-compose.apps.ext.yml
[ -f "$ENVF" ] || die ".env مفقود. شغّل سكربت الإعداد الأساسي أولاً."
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service" "$STACK"

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# -------- Vision (YOLOv8) --------
cat >"$APPS/vision-engine/requirements.txt"<<'REQ'
fastapi==0.110.0
uvicorn[standard]==0.30.0
pillow==10.3.0
opencv-python-headless==4.10.0.84
ultralytics==8.2.103
REQ
cat >"$APPS/vision-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests
from PIL import Image
from ultralytics import YOLO
api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt"); READY=False; ERR=""
try: yolo=YOLO(MODEL); READY=True
except Exception as e: ERR=str(e)
class Inp(BaseModel): image_url:str; conf:float|None=0.25
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":(ERR or None)}
@api.post("/warmup")
def warm(): 
    global READY,ERR
    try: YOLO(MODEL); READY=True; return {"ok":True}
    except Exception as e: ERR=str(e); raise HTTPException(503, ERR)
@api.post("/detect")
def detect(inp:Inp):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        im=Image.open(io.BytesIO(r.content)).convert("RGB")
        res=yolo.predict(im, conf=inp.conf or 0.25, verbose=False)[0]
        out=[{"cls_id":int(b.cls[0]),
              "cls":res.names.get(int(b.cls[0]), str(int(b.cls[0]))),
              "conf":float(b.conf[0]),
              "xywh":[float(x) for x in b.xywh[0].tolist()]} for b in res.boxes]
        return {"detections":out}
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/vision-engine/Dockerfile"<<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 torchvision==0.19.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
ENV UVICORN_WORKERS=2
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081","--workers","2"]
DOCKER
sanitize "$APPS/vision-engine/Dockerfile"

# -------- Media-Forensics (ELA/EXIF/pHash) --------
cat >"$APPS/media-forensics/requirements.txt"<<'REQ'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
pillow==10.3.0
imagehash==4.3.1
exifread==3.0.0
opencv-python-headless==4.10.0.84
numpy>=1.26,<2.0
REQ
cat >"$APPS/media-forensics/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, base64, requests, numpy as np, cv2
from PIL import Image, ImageChops
import imagehash, exifread
api=FastAPI()
class Inp(BaseModel): image_url:str; ela_quality:int|None=90; heatmap:bool|None=False
@api.get("/health") 
def health(): return {"status":"ok"}
def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q)
    comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff, dtype=np.int16)
    return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr),95))
def noise_energy(img):
    g=np.array(img.convert('L'), dtype=np.float32)/255.0
    resid=g-cv2.GaussianBlur(g,(0,0),1.0); return float(np.mean(resid**2))
def exif_map(raw):
    try:
        tags=exifread.process_file(io.BytesIO(raw), details=False)
        keep=("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
        return {k:str(v) for k,v in tags.items() if k in keep}
    except: return {}
@api.post("/analyze")
def analyze(inp:Inp):
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        img=Image.open(io.BytesIO(r.content)).convert('RGB'); w,h=img.size
        diff, m, p95 = ela(img, inp.ela_quality or 90)
        nrg=noise_energy(img); ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        exif=exif_map(r.content)
        out={"width":w,"height":h,"ela_mean":m,"ela_p95":p95,"noise_energy":nrg,"ahash":ah,"phash":ph,"exif":exif}
        if inp.heatmap:
            b=io.BytesIO(); diff.save(b, format='PNG'); out["ela_heatmap_png_b64"]=base64.b64encode(b.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/media-forensics/Dockerfile"<<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
ENV UVICORN_WORKERS=2
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082","--workers","2"]
DOCKER
sanitize "$APPS/media-forensics/Dockerfile"

# -------- Hashset (MD5/SHA*/ssdeep + NSRL loader) --------
cat >"$APPS/hashset-service/requirements.txt"<<'REQ'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
ssdeep==3.4
REQ
cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, ssdeep, csv, gzip, bz2
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db_init():
    con=sqlite3.connect(DB); cur=con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY)")
    cur.execute("PRAGMA journal_mode=WAL"); con.commit(); con.close()
db_init()
class FileReq(BaseModel): file_url:str
class LoadReq(BaseModel): nsrl_url:str
@api.get("/health") 
def health(): return {"status":"ok","nsrl_db":os.path.exists(DB)}
def fetch(url)->bytes:
    r=requests.get(url, timeout=600); r.raise_for_status(); return r.content
@api.post("/hash")
def do_hash(req:FileReq):
    b=fetch(req.file_url)
    return {"md5":hashlib.md5(b).hexdigest(),"sha1":hashlib.sha1(b).hexdigest(),
            "sha256":hashlib.sha256(b).hexdigest(),"ssdeep":ssdeep.hash(b)}
@api.post("/nsrl/load")
def nsrl_load(req:LoadReq):
    raw=fetch(req.nsrl_url)
    if req.nsrl_url.endswith(".gz"): raw=gzip.decompress(raw)
    if req.nsrl_url.endswith(".bz2"): raw=bz2.decompress(raw)
    con=sqlite3.connect(DB); cur=con.cursor(); cur.execute("BEGIN")
    ins=0
    try:
        for row in csv.DictReader(io.StringIO(raw.decode(errors="ignore"))):
            sha=(row.get("SHA-1") or row.get("sha1") or row.get("SHA1") or "").strip().upper()
            if len(sha)==40:
                try: cur.execute("INSERT OR IGNORE INTO nsrl(sha1) VALUES(?)",(sha,)); ins+=1
                except Exception: pass
        con.commit()
    finally: con.close()
    return {"inserted":ins}
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    con=sqlite3.connect(DB); cur=con.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;",(sha1.upper(),))
    ok = cur.fetchone() is not None; con.close(); return {"present":ok}
PY
cat >"$APPS/hashset-service/Dockerfile"<<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends gcc libfuzzy-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8083
ENV UVICORN_WORKERS=2
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083","--workers","2"]
DOCKER
sanitize "$APPS/hashset-service/Dockerfile"

# -------- Compose (ext pack) --------
cat >"$EXTY"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { nvision_cache: {}, nforensics_cache: {}, hashsets_data: {} }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    networks: [ ffactory_ffactory_net ]
    volumes: [ "nvision_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8081:8081" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:8081/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    networks: [ ffactory_ffactory_net ]
    volumes: [ "nforensics_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8082:8082" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:8082/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    networks: [ ffactory_ffactory_net ]
    volumes: [ "hashsets_data:/data/hashsets" ]
    ports: [ "127.0.0.1:8083:8083" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:8083/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# -------- Build+Up --------
log "build+up ext pack"
docker compose --env-file "$ENVF" -f "$EXTY" up -d --build

# -------- WORM (MinIO) --------
log "enable WORM on MinIO bucket"
set +e
. "$ENVF"
MC="docker run --rm --network $NET -e MC_HOST_ffminio=http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@ffactory_minio:9000 minio/mc"
$MC mb --with-lock ffminio/forensic-evidence >/dev/null 2>&1 || true
$MC version enable ffminio/forensic-evidence >/dev/null 2>&1 || true
$MC retention set ffminio/forensic-evidence --default compliance 365d >/dev/null 2>&1 || true
set -e

# -------- Smoke --------
log "docker ps (first 2 ffactory_*)"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep '^ffactory_' | head -n 2 || true
log "health checks"
for p in 8081 8082 8083; do curl -fsS "http://127.0.0.1:${p}/health" >/dev/null || echo "FAIL /health :${p}"; done
log "done."
