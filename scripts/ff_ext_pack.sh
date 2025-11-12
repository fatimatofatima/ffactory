#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory
STACK=$FF/stack
APPS=$FF/apps
NET=ffactory_ffactory_net
APPS_YML_EXT="$STACK/docker-compose.apps.ext.yml"

[ -f "$FF/.env" ] || die ".env مفقود. شغّل الأساس أولاً."
docker network inspect "$NET" >/dev/null 2>&1 || die "شبكة $NET غير موجودة. شغّل الأساس أولاً."

install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service"

# ---------- Vision Engine (YOLOv8 افتراضيًا) ----------
cat >"$APPS/vision-engine/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
pillow>=10.3
opencv-python-headless>=4.10
ultralytics>=8.2
torch==2.4.1
REQ
cat >"$APPS/vision-engine/app.py" <<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests
from PIL import Image
from ultralytics import YOLO

api=FastAPI()
MODEL_NAME=os.getenv("VISION_MODEL","yolov8n.pt")
try:
    yolo=YOLO(MODEL_NAME)  # CPU
    READY=True; ERR=""
except Exception as e:
    READY=False; ERR=str(e)

class Inp(BaseModel):
    image_url: str
    conf: float | None = 0.25

@api.get("/health")
def health():
    return {"ready":READY,"model":MODEL_NAME,"error":ERR or None}

@api.post("/detect")
def detect(inp: Inp):
    if not READY: raise HTTPException(status_code=503, detail=ERR or "model not ready")
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        im=Image.open(io.BytesIO(r.content)).convert("RGB")
        res=yolo.predict(im, conf=inp.conf or 0.25, verbose=False)
        det=[]
        for b in res[0].boxes:
            cls=int(b.cls[0])
            det.append({
                "cls_id": cls,
                "cls": res[0].names.get(cls,str(cls)),
                "conf": float(b.conf[0]),
                "xywh": [float(x) for x in b.xywh[0].tolist()]
            })
        return {"detections": det}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
PY
cat >"$APPS/vision-engine/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
# Torch CPU أولاً لتفادي CUDA
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 torchvision==0.19.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081"]
DOCKER

# ---------- Media Forensics (ELA/EXIF/PRNU البسيط + pHash) ----------
cat >"$APPS/media-forensics/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
pillow>=10.3
imagehash>=4.3
exifread>=3.0
opencv-python-headless>=4.10
numpy>=1.26,<2.0
REQ
cat >"$APPS/media-forensics/app.py" <<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, requests, numpy as np, cv2, json
from PIL import Image, ImageChops
import imagehash, exifread

api=FastAPI()

class Inp(BaseModel):
    image_url: str
    ela_quality: int | None = 90

@api.get("/health")
def health(): return {"status":"ok"}

def ela_score(img: Image.Image, q: int=90):
    buf=io.BytesIO(); img.save(buf, 'JPEG', quality=q)
    comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff, dtype=np.int16)
    mean=float(np.abs(arr).mean())
    p95=float(np.percentile(np.abs(arr),95))
    return mean, p95

def noise_energy(img: Image.Image):
    g=np.array(img.convert('L'), dtype=np.float32)/255.0
    blur=cv2.GaussianBlur(g,(0,0),1.0)
    resid=g-blur
    return float(np.mean(resid**2))

def read_exif(raw: bytes):
    try:
        tags=exifread.process_file(io.BytesIO(raw), details=False)
        keep={k:str(v) for k,v in tags.items() if k in ("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")}
        return keep
    except Exception:
        return {}

@api.post("/analyze")
def analyze(inp: Inp):
    try:
        r=requests.get(inp.image_url, timeout=30); r.raise_for_status()
        img=Image.open(io.BytesIO(r.content)).convert('RGB')
        ela_m, ela_p95=ela_score(img, inp.ela_quality or 90)
        nrg=noise_energy(img)
        ah=str(imagehash.average_hash(img))
        ph=str(imagehash.phash(img))
        exif=read_exif(r.content)
        w,h=img.size
        return {"width":w,"height":h,"ela_mean":ela_m,"ela_p95":ela_p95,"noise_energy":nrg,"ahash":ah,"phash":ph,"exif":exif}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
PY
cat >"$APPS/media-forensics/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082"]
DOCKER

# ---------- Hashset Service (MD5/SHA*/ssdeep + NSRL اختياري) ----------
cat >"$APPS/hashset-service/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
ssdeep>=3.4
REQ
cat >"$APPS/hashset-service/app.py" <<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, ssdeep

api=FastAPI()
NSRL_DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")  # جدول nsrl(sha1 TEXT PRIMARY KEY)

class FileReq(BaseModel):
    file_url: str

@api.get("/health")
def health():
    has_db = os.path.exists(NSRL_DB)
    return {"status":"ok","nsrl_db":has_db}

def _fetch(url:str)->bytes:
    r=requests.get(url, timeout=60); r.raise_for_status()
    return r.content

@api.post("/hash")
def do_hash(req: FileReq):
    try:
        b=_fetch(req.file_url)
        return {
            "md5": hashlib.md5(b).hexdigest(),
            "sha1": hashlib.sha1(b).hexdigest(),
            "sha256": hashlib.sha256(b).hexdigest(),
            "ssdeep": ssdeep.hash(b)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@api.get("/nsrl/check")
def nsrl_check(sha1: str):
    if not os.path.exists(NSRL_DB):
        return {"present": False, "reason": "nsrl db missing"}
    try:
        con=sqlite3.connect(NSRL_DB)
        cur=con.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;", (sha1.upper(),))
        ok = cur.fetchone() is not None
        con.close()
        return {"present": ok}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
PY
cat >"$APPS/hashset-service/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends gcc ssdeep libfuzzy-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8083
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083"]
DOCKER

# ---------- Compose إضافي للخدمات الجديدة ----------
cat >"$APPS_YML_EXT" <<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { nvision_cache: {}, nforensics_cache: {}, hashsets_data: {} }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "nvision_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8081:8081" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8081/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "nforensics_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8082:8082" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8082/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    env_file: [ ../.env ]
    environment:
      - NSRL_DB_PATH=/data/hashsets/nsrl.sqlite
    networks: [ ffactory_ffactory_net ]
    volumes: [ "hashsets_data:/data/hashsets" ]
    ports: [ "127.0.0.1:8083:8083" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8083/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# ---------- بناء وتشغيل ----------
log "build+up ext pack"
docker compose --env-file "$FF/.env" -f "$APPS_YML_EXT" up -d --build

log "endpoints:"
echo "Vision:          http://127.0.0.1:8081/health"
echo "Media-Forensics: http://127.0.0.1:8082/health"
echo "Hashset:         http://127.0.0.1:8083/health"
