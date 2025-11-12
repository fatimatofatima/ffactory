#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory
APPS=$FF/apps
STACK=$FF/stack
ENVF=$FF/.env
NET=ffactory_ffactory_net

[ -f "$ENVF" ] || die ".env غير موجود"
install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service" "$STACK"

# تنظيف أي NBSP/CRLF
sanitize(){ [ -f "$1" ] || return 0; tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__c" && mv -f "$1.__c" "$1"; }

# ===== Vision (YOLOv8) =====
cat >"$APPS/vision-engine/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
opencv-python>=4.10.0
pillow>=10.3.0
ultralytics==8.2.103
requests>=2.31.0
R

cat >"$APPS/vision-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, requests, cv2, os
from PIL import Image
from ultralytics import YOLO

api = FastAPI()
MODEL = os.getenv("VISION_MODEL", "yolov8n.pt")
try:
    yolo = YOLO(MODEL)
    READY, ERR = True, ""
except Exception as e:
    READY, ERR = False, str(e)

class ImgReq(BaseModel):
    image_url: str
    conf: float | None = 0.25

class VidReq(BaseModel):
    video_url: str
    conf: float | None = 0.25
    stride_sec: float | None = 0.5
    max_frames: int | None = 200

@api.get("/health")
def health(): return {"ready": READY, "model": MODEL, "error": (ERR or None)}

@api.post("/detect")
def detect(inp: ImgReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    r = requests.get(inp.image_url, timeout=30); r.raise_for_status()
    im = Image.open(io.BytesIO(r.content)).convert("RGB")
    res = yolo.predict(im, conf=inp.conf or 0.25, verbose=False)[0]
    out, names = [], res.names
    for b in res.boxes:
        cid = int(b.cls[0])
        out.append({
            "cls_id": cid,
            "cls": names.get(cid, str(cid)),
            "conf": float(b.conf[0]),
            "xywh": [float(x) for x in res.boxes.xywh[0].tolist()]
        })
    return {"detections": out}

@api.post("/detect_video")
def detect_video(inp: VidReq):
    if not READY: raise HTTPException(503, ERR or "model not ready")
    cap = cv2.VideoCapture(inp.video_url)
    if not cap.isOpened(): raise HTTPException(400, "cannot open video")
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    step = max(int((inp.stride_sec or 0.5) * fps), 1)
    conf = inp.conf or 0.25
    frames = dets = 0
    classes = {}
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok: break
        if idx % step == 0:
            res = yolo.predict(frame, conf=conf, verbose=False)[0]
            dets += len(res.boxes); frames += 1
            for b in res.boxes:
                cid = int(b.cls[0]); classes[cid] = classes.get(cid, 0) + 1
            if frames >= (inp.max_frames or 200): break
        idx += 1
    cap.release()
    return {"frames_processed": frames, "detections": dets, "classes": classes}
PY

cat >"$APPS/vision-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081"]
D
sanitize "$APPS/vision-engine/Dockerfile"

# ===== Media-Forensics (ELA/PRNU/EXIF) =====
cat >"$APPS/media-forensics/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
pillow>=10.3.0
opencv-python>=4.10.0
numpy>=1.26
imagehash>=4.3.1
exifread>=3.0.0
requests>=2.31.0
R

cat >"$APPS/media-forensics/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, base64, requests, numpy as np, cv2
from PIL import Image, ImageChops
import imagehash, exifread

api = FastAPI()

class ImgReq(BaseModel):
    image_url: str
    ela_quality: int | None = 90
    heatmap: bool | None = False

def _fetch(url) -> bytes:
    r = requests.get(url, timeout=30); r.raise_for_status(); return r.content

def _pil(b): return Image.open(io.BytesIO(b)).convert("RGB")

def ela(img, q=90):
    buf = io.BytesIO(); img.save(buf, "JPEG", quality=q)
    comp = Image.open(io.BytesIO(buf.getvalue()))
    diff = ImageChops.difference(img.convert("RGB"), comp.convert("RGB"))
    arr = np.asarray(diff, dtype=np.int16)
    return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr), 95))

def prnu_residual(img_rgb):
    g = np.array(img_rgb.convert("L"), dtype=np.float32) / 255.0
    den = cv2.fastNlMeansDenoising((g*255).astype(np.uint8), None, h=7, templateWindowSize=7, searchWindowSize=21).astype(np.float32)/255.0
    resid = g - den
    r = resid - resid.mean(); r /= (r.std() + 1e-8)
    return r

@api.get("/health")
def health(): return {"status": "ok"}

@api.post("/analyze")
def analyze(inp: ImgReq):
    try:
        raw = _fetch(inp.image_url); img = _pil(raw); w, h = img.size
        diff, m, p95 = ela(img, inp.ela_quality or 90)
        r = prnu_residual(img); p_strength = float(np.mean(r**2))
        nrg = float(np.mean((np.array(img.convert("L"), dtype=np.float32)/255.0 - cv2.GaussianBlur(np.array(img.convert("L"), dtype=np.float32)/255.0, (0,0), 1.0))**2))
        ah = str(imagehash.average_hash(img)); ph = str(imagehash.phash(img))
        try:
            tags = exifread.process_file(io.BytesIO(raw), details=False)
            keep = ("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
            exif = {k: str(v) for k,v in tags.items() if k in keep}
        except Exception:
            exif = {}
        out = {"width": w, "height": h, "ela_mean": m, "ela_p95": p95, "prnu_strength": p_strength, "noise_energy": nrg, "ahash": ah, "phash": ph, "exif": exif}
        if inp.heatmap:
            b = io.BytesIO(); (Image.fromarray(((r-r.min())/(r.max()-r.min()+1e-8)*255).astype(np.uint8))).save(b,'PNG')
            out["prnu_residual_png_b64"] = base64.b64encode(b.getvalue()).decode()
            b2 = io.BytesIO(); diff.save(b2,'PNG')
            out["ela_heatmap_png_b64"] = base64.b64encode(b2.getvalue()).decode()
        return out
    except Exception as e:
        raise HTTPException(500, str(e))
PY

cat >"$APPS/media-forensics/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082"]
D
sanitize "$APPS/media-forensics/Dockerfile"

# ===== Hashset (SHA*/ssdeep/NSRL SQLite) =====
cat >"$APPS/hashset-service/requirements.txt"<<'R'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31.0
ssdeep>=3.4
R

cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, csv, gzip, bz2

api = FastAPI()
try:
    import ssdeep as _ssdeep
    HAS_SSDEEP = True
except Exception:
    HAS_SSDEEP = False

DB = os.getenv("NSRL_DB_PATH", "/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)

def db():
    return sqlite3.connect(DB)

def db_init():
    con = db(); cur = con.cursor()
    cur.execute("""CREATE TABLE IF NOT EXISTS nsrl(
        sha1 TEXT PRIMARY KEY,
        md5 TEXT,
        sha256 TEXT,
        name TEXT,
        size INTEGER
    );""")
    con.commit(); con.close()
db_init()

class HashReq(BaseModel):
    file_url: str

@api.get("/health")
def health():
    return {"status":"ok","db":DB,"ssdeep":HAS_SSDEEP}

@api.post("/hash")
def do_hash(inp: HashReq):
    r = requests.get(inp.file_url, timeout=60); r.raise_for_status()
    b = r.content
    out = {
        "md5": hashlib.md5(b).hexdigest(),
        "sha1": hashlib.sha1(b).hexdigest(),
        "sha256": hashlib.sha256(b).hexdigest(),
        "size": len(b)
    }
    if HAS_SSDEEP:
        out["ssdeep"] = _ssdeep.hash(b)
    return out

@api.get("/nsrl/check")
def nsrl_check(sha1: str):
    con = db(); cur = con.cursor()
    cur.execute("SELECT sha1,md5,sha256,name,size FROM nsrl WHERE sha1=?", (sha1.upper(),))
    row = cur.fetchone(); con.close()
    if not row: return {"found": False}
    return {"found": True, "record": {"sha1":row[0],"md5":row[1],"sha256":row[2],"name":row[3],"size":row[4]}}

class LoadReq(BaseModel):
    csv_url: str

@api.post("/nsrl/load")
def nsrl_load(inp: LoadReq):
    url = inp.csv_url
    r = requests.get(url, timeout=300); r.raise_for_status()
    raw = r.content
    if url.endswith(".gz"): f = io.TextIOWrapper(gzip.GzipFile(fileobj=io.BytesIO(raw)), encoding="utf-8", errors="ignore")
    elif url.endswith(".bz2"): f = io.TextIOWrapper(bz2.BZ2File(io.BytesIO(raw)), encoding="utf-8", errors="ignore")
    else: f = io.StringIO(raw.decode("utf-8", "ignore"))
    reader = csv.DictReader(f)
    con = db(); cur = con.cursor()
    batch = []
    n = 0
    for row in reader:
        sha1 = (row.get("SHA-1") or row.get("sha1") or "").upper()
        md5  = (row.get("MD5") or row.get("md5") or "")
        name = row.get("FileName") or row.get("name") or ""
        size = int(row.get("FileSize") or row.get("size") or 0)
        if not sha1: continue
        batch.append((sha1, md5, None, name, size))
        if len(batch) >= 1000:
            cur.executemany("INSERT OR IGNORE INTO nsrl(sha1,md5,sha256,name,size) VALUES(?,?,?,?,?)", batch); con.commit(); n += len(batch); batch = []
    if batch:
        cur.executemany("INSERT OR IGNORE INTO nsrl(sha1,md5,sha256,name,size) VALUES(?,?,?,?,?)", batch); con.commit(); n += len(batch)
    con.close()
    return {"inserted": n}
PY

cat >"$APPS/hashset-service/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libfuzzy-dev gcc make curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data"]
EXPOSE 8083
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083"]
D
sanitize "$APPS/hashset-service/Dockerfile"

# ===== Compose (apps-ext) =====
cat >"$STACK/docker-compose.apps-ext.yml"<<'YML'
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { hash_data: {} }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8081:8081" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8081/health"]
      interval: 15s
      timeout: 5s
      retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8082:8082" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8082/health"]
      interval: 15s
      timeout: 5s
      retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "hash_data:/data" ]
    ports: [ "127.0.0.1:8083:8083" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8083/health"]
      interval: 15s
      timeout: 5s
      retries: 40
YML

# ===== MinIO WORM (idempotent) =====
set -a; . "$ENVF"; set +a
worm(){
  docker run --rm --network "$NET" \
    -e MC_HOST_ffminio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@ffactory_minio:9000" \
    minio/mc mb --with-lock ffminio/forensic-evidence 2>/dev/null || true
  docker run --rm --network "$NET" \
    -e MC_HOST_ffminio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@ffactory_minio:9000" \
    minio/mc version enable ffminio/forensic-evidence || true
  docker run --rm --network "$NET" \
    -e MC_HOST_ffminio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@ffactory_minio:9000" \
    minio/mc retention set ffminio/forensic-evidence --default compliance 365d || true
}

# ===== Build/Up =====
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
log "build+up apps-ext"
docker compose --env-file "$ENVF" -f "$STACK/docker-compose.apps-ext.yml" up -d --build

log "apply WORM (MinIO)"
worm

log "snapshot"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_(vision|media_forensics|hashset)' || true

# Smoke health: اطبع الأسطر الفاشلة فقط
for p in 8081 8082 8083; do
  curl -fsS "http://127.0.0.1:$p/health" >/dev/null || echo "FAIL /health :$p"
done
