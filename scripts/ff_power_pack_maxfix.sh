#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; NET=ffactory_ffactory_net; ENVF=$FF/.env
[ -f "$ENVF" ] || die ".env مفقود. شغّل الأساس أولًا."
docker network inspect "$NET" >/dev/null 2>&1 || die "شبكة $NET غير موجودة."

install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service" \
                   "$APPS/video-prober" "$APPS/evidence-uploader" "$STACK"

sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ===== Vision (YOLOv8) =====
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
import io, requests
from PIL import Image
from ultralytics import YOLO
import os
api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt")
try: yolo=YOLO(MODEL); READY=True; ERR=""
except Exception as e: READY=False; ERR=str(e)
class ImgReq(BaseModel): image_url:str; conf:float|None=0.25
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":(ERR or None)}
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
EXPOSE 8081
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081"]
D
sanitize "$APPS/vision-engine/Dockerfile"

# ===== Media-Forensics (ELA/EXIF/Hashes) =====
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
import io, requests, numpy as np
from PIL import Image, ImageChops
import imagehash, exifread
api=FastAPI()
class ImgReq(BaseModel): image_url:str; ela_quality:int|None=90
def _fetch(url)->bytes:
    r=requests.get(url, timeout=30); r.raise_for_status(); return r.content
@api.get("/health")
def health(): return {"status":"ok"}
@api.post("/analyze")
def analyze(inp:ImgReq):
    try:
        raw=_fetch(inp.image_url); img=Image.open(io.BytesIO(raw)).convert('RGB')
        buf=io.BytesIO(); img.save(buf,'JPEG',quality=inp.ela_quality or 90)
        comp=Image.open(io.BytesIO(buf.getvalue()))
        diff=ImageChops.difference(img, comp)
        ela_mean=float(np.mean(np.abs(np.asarray(diff,dtype=np.int16))))
        ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        try:
            tags=exifread.process_file(io.BytesIO(raw), details=False)
            keep=("EXIF DateTimeOriginal","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
            exif={k:str(v) for k,v in tags.items() if k in keep}
        except: exif={}
        return {"ela_mean":ela_mean,"ahash":ah,"phash":ph,"exif":exif}
    except Exception as e:
        raise HTTPException(500,str(e))
PY
cat >"$APPS/media-forensics/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082"]
D
sanitize "$APPS/media-forensics/Dockerfile"

# ===== Hashset (fix ssdeep build) =====
cat >"$APPS/hashset-service/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
ssdeep==3.4
R
cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, tempfile, hashlib, requests, sqlite3, ssdeep
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db(): return sqlite3.connect(DB)
def init():
    con=db(); cur=con.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS nsrl (sha1 TEXT PRIMARY KEY)")
    con.commit(); con.close()
init()
class FileReq(BaseModel): file_url:str
@api.get("/health")
def health():
    con=db(); n=con.execute("SELECT COUNT(*) FROM nsrl").fetchone()[0]; con.close()
    return {"status":"ok","nsrl_rows":n}
def _download(url)->str:
    r=requests.get(url,timeout=60); r.raise_for_status()
    f=tempfile.NamedTemporaryFile(delete=False); f.write(r.content); f.close(); return f.name
@api.post("/hash")
def do_hash(inp:FileReq):
    p=_download(inp.file_url)
    sha256=hashlib.sha256(open(p,'rb').read()).hexdigest()
    sha1=hashlib.sha1(open(p,'rb').read()).hexdigest()
    md5=hashlib.md5(open(p,'rb').read()).hexdigest()
    fuzzy=ssdeep.hash_from_file(p)
    os.unlink(p)
    return {"md5":md5,"sha1":sha1,"sha256":sha256,"ssdeep":fuzzy}
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    con=db(); r=con.execute("SELECT 1 FROM nsrl WHERE sha1=?",(sha1,)).fetchone(); con.close()
    return {"sha1":sha1,"known":bool(r)}
@api.post("/nsrl/add")
def nsrl_add(sha1:str):
    con=db(); con.execute("INSERT OR IGNORE INTO nsrl(sha1) VALUES(?)",(sha1,)); con.commit(); con.close()
    return {"added":sha1}
PY
cat >"$APPS/hashset-service/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends build-essential gcc python3-dev libffi-dev libfuzzy-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8083
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083"]
D
sanitize "$APPS/hashset-service/Dockerfile"

# ===== Video-Prober (ffprobe JSON) =====
cat >"$APPS/video-prober/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
R
cat >"$APPS/video-prober/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, json
api=FastAPI()
class Req(BaseModel): video_url:str
@api.get("/health")
def health(): return {"status":"ok","ffprobe":"cli"}
@api.post("/probe")
def probe(r:Req):
    try:
        p=subprocess.run(["ffprobe","-v","quiet","-print_format","json","-show_format","-show_streams",r.video_url],
                         capture_output=True, text=True, timeout=120)
        if p.returncode!=0: raise Exception(p.stderr)
        return json.loads(p.stdout)
    except Exception as e:
        raise HTTPException(400, str(e))
PY
cat >"$APPS/video-prober/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8088"]
D
sanitize "$APPS/video-prober/Dockerfile"

# ===== Evidence-Uploader (MinIO + Object Lock) =====
cat >"$APPS/evidence-uploader/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
minio==7.2.9
requests==2.31.0
R
cat >"$APPS/evidence-uploader/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from datetime import datetime, timedelta, timezone
from minio import Minio
from minio.commonconfig import ENABLED, GOVERNANCE, COMPLIANCE, LegalHold
from minio.retention import Retention
import os, requests, io
api=FastAPI()
S3=os.getenv("S3_ENDPOINT","ffactory_minio:9000")
AK=os.getenv("MINIO_ROOT_USER"); SK=os.getenv("MINIO_ROOT_PASSWORD")
SECURE=bool(int(os.getenv("S3_SECURE","0")))
cli=Minio(S3, access_key=AK, secret_key=SK, secure=SECURE)
class PutReq(BaseModel):
    bucket:str="forensic-evidence"; object_name:str; url:str
    retention_days:int|None=365; mode:str|None="COMPLIANCE"; legal_hold:bool|None=True
@api.get("/health")
def health(): return {"status":"ok","endpoint":S3}
@api.post("/ensure_bucket")
def ensure_bucket(bucket:str="forensic-evidence"):
    if not cli.bucket_exists(bucket):
        cli.make_bucket(bucket, object_lock=True)
    return {"bucket":bucket,"object_lock":True}
@api.post("/put_from_url")
def put_from_url(req:PutReq):
    if not cli.bucket_exists(req.bucket):
        cli.make_bucket(req.bucket, object_lock=True)
    r=requests.get(req.url, timeout=120); r.raise_for_status()
    data=io.BytesIO(r.content); data.seek(0)
    until=datetime.now(timezone.utc)+timedelta(days=req.retention_days or 365)
    mode=COMPLIANCE if (req.mode or "COMPLIANCE").upper()=="COMPLIANCE" else GOVERNANCE
    ret=Retention(mode, until)
    cli.put_object(req.bucket, req.object_name, data, length=len(r.content),
                   retention=ret, legal_hold=LegalHold(ENABLED) if req.legal_hold else None)
    stat=cli.stat_object(req.bucket, req.object_name)
    return {"bucket":req.bucket,"object":req.object_name,"version_id":stat.version_id,"retain_until":until.isoformat()}
PY
cat >"$APPS/evidence-uploader/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8089
ENV S3_ENDPOINT=ffactory_minio:9000 S3_SECURE=0
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8089"]
D
sanitize "$APPS/evidence-uploader/Dockerfile"

# ===== Compose (EXT3) =====
EXT3="$STACK/docker-compose.apps.ext3.yml"
cat >"$EXT3"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8081:8081" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8081/health"]
      interval: 10s; timeout: 5s; retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8082:8082" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8082/health"]
      interval: 10s; timeout: 5s; retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    networks: [ ffactory_ffactory_net ]
    volumes: [ "/opt/ffactory/data/hashsets:/data/hashsets" ]
    ports: [ "127.0.0.1:8083:8083" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8083/health"]
      interval: 10s; timeout: 5s; retries: 40

  video-prober:
    build: { context: ../apps/video-prober, dockerfile: Dockerfile }
    container_name: ffactory_vprobe
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8088:8088" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8088/health"]
      interval: 10s; timeout: 5s; retries: 40

  evidence-uploader:
    build: { context: ../apps/evidence-uploader, dockerfile: Dockerfile }
    container_name: ffactory_evidence_uploader
    env_file: [ ../.env ]
    environment:
      - S3_ENDPOINT=ffactory_minio:9000
      - S3_SECURE=0
      - MINIO_ROOT_USER=$${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=$${MINIO_ROOT_PASSWORD}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8089:8089" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8089/health"]
      interval: 10s; timeout: 5s; retries: 40
YML

# ===== Build/Up =====
log "build+up maxfix pack"
docker compose --env-file "$ENVF" -f "$EXT3" up -d --build

# ===== Quick health =====
echo "---- ps (subset) ----"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_(vision|media_forensics|hashset|vprobe|evidence)' | head -n 2 || true
echo "---- health ----"
for p in 8081 8082 8083 8088 8089; do curl -fsS "http://127.0.0.1:$p/health" >/dev/null || echo "FAIL /health :$p"; done

# ===== MinIO WORM harden via mc (idempotent) =====
. "$ENVF"
MC="docker run --rm --network $NET minio/mc"
$MC alias set ffminio http://ffactory_minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true
$MC mb --with-lock ffminio/forensic-evidence >/dev/null 2>&1 || true
$MC version enable ffminio/forensic-evidence >/dev/null 2>&1 || true
$MC retention set ffminio/forensic-evidence --default compliance 365d >/dev/null 2>&1 || true
$MC retention info ffminio/forensic-evidence || true

log "done"
