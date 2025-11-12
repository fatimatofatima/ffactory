#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

# ===== ثابتات ومسارات =====
FF=/opt/ffactory
APPS=$FF/apps
STACK=$FF/stack
ENVF=$FF/.env
NET=ffactory_ffactory_net
CORE_YML=$STACK/docker-compose.core.yml
APPS_YML=$STACK/docker-compose.apps.yml

install -d -m 755 "$APPS" "$STACK" "$FF/scripts" "$FF/data" "$FF/data/hashsets"

# ===== متغيرات البيئة مع قيم افتراضية لو ناقصة =====
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true
POSTGRES_USER=${POSTGRES_USER:-ffadmin}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-ffpass}
POSTGRES_DB=${POSTGRES_DB:-ffactory}
NEO4J_USER=${NEO4J_USER:-neo4j}
NEO4J_PASSWORD=${NEO4J_PASSWORD:-neo4jpass}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin}

# ===== أدوات =====
in_use(){ ss -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1" || netstat -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1"; }
pick(){ p="$1"; while in_use "$p"; do p=$((p+1)); done; echo "$p"; }

PG_PORT=${PG_PORT:-$(pick 5433)}
NEO_HTTP=${NEO_HTTP:-$(pick 7474)}
NEO_BOLT=${NEO_BOLT:-$(pick 7687)}
MINIO_S3=${MINIO_S3:-$(pick 9000)}
MINIO_CON=${MINIO_CON:-$(pick 9001)}
VISION_PORT=${VISION_PORT:-$(pick 8081)}
MEDIA_PORT=${MEDIA_PORT:-$(pick 8082)}
HASH_PORT=${HASH_PORT:-$(pick 8083)}
REL_PORT=${REL_PORT:-$(pick 8088)}

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# ===== CORE: Postgres + Redis + Neo4j + MinIO بأسماء بدون underscore و alias "minio" =====
cat >"$CORE_YML"<<YML
name: ffactory
networks: { $NET: { external: true } }
services:
  db:
    image: postgres:16
    container_name: ffactory-db
    environment:
      POSTGRES_USER: "$POSTGRES_USER"
      POSTGRES_PASSWORD: "$POSTGRES_PASSWORD"
      POSTGRES_DB: "$POSTGRES_DB"
    volumes: [ "$FF/data/pg:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:${PG_PORT}:5432" ]
    healthcheck: { test: ["CMD-SHELL","pg_isready -U $POSTGRES_USER"], interval: 5s, timeout: 4s, retries: 30 }
    networks: [ $NET ]

  redis:
    image: redis:7-alpine
    container_name: ffactory-redis
    networks: [ $NET ]

  neo4j:
    image: neo4j:5
    container_name: ffactory-neo4j
    environment:
      NEO4J_AUTH: "${NEO4J_USER}/${NEO4J_PASSWORD}"
      NEO4J_dbms_security_procedures_unrestricted: "apoc.*"
      NEO4JLABS_PLUGINS: "[\"apoc\"]"
    volumes:
      - "$FF/data/neo4j:/data"
    ports:
      - "127.0.0.1:${NEO_HTTP}:7474"
      - "127.0.0.1:${NEO_BOLT}:7687"
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:7474"], interval: 10s, timeout: 5s, retries: 30 }
    networks:
      $NET:
        aliases: [ "neo4j" ]

  minio:
    image: minio/minio:RELEASE.2024-09-22T00-33-43Z
    container_name: ffactory-minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: "$MINIO_ROOT_USER"
      MINIO_ROOT_PASSWORD: "$MINIO_ROOT_PASSWORD"
    volumes: [ "$FF/data/minio:/data" ]
    ports:
      - "127.0.0.1:${MINIO_S3}:9000"
      - "127.0.0.1:${MINIO_CON}:9001"
    healthcheck: { test: ["CMD","wget","-qO-","http://localhost:9001/minio/health/live"], interval: 10s, timeout: 5s, retries: 30 }
    networks:
      $NET:
        aliases: [ "minio" ]
networks: { $NET: { external: true } }
YML

log "[*] bring up core"
docker compose -f "$CORE_YML" up -d

# ===== انتظار الصحة =====
log "[*] wait db"
for i in $(seq 1 60); do docker exec ffactory-db pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1 && break || sleep 2; done
log "[*] wait neo4j"
for i in $(seq 1 60); do curl -fsS "http://127.0.0.1:${NEO_HTTP}" >/dev/null 2>&1 && break || sleep 2; done
log "[*] wait minio"
for i in $(seq 1 60); do curl -fsS "http://127.0.0.1:${MINIO_CON}/minio/health/live" >/dev/null 2>&1 && break || sleep 2; done

# ===== إصلاح WORM على MinIO بدون underscores =====
log "[*] minio WORM"
docker run --rm --network "$NET" \
  -e MC_HOST_minio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" minio/mc \
  mb --with-lock minio/forensic-evidence || true
docker run --rm --network "$NET" \
  -e MC_HOST_minio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" minio/mc \
  version enable minio/forensic-evidence || true
docker run --rm --network "$NET" \
  -e MC_HOST_minio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" minio/mc \
  retention set minio/forensic-evidence --default compliance 365d
docker run --rm --network "$NET" \
  -e MC_HOST_minio="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" minio/mc \
  retention info minio/forensic-evidence || true

# ===== تصحيح Dockerfiles للتطبيقات =====

# Vision
install -d -m 755 "$APPS/vision-engine"
cat >"$APPS/vision-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
opencv-python-headless==4.10.0.84
pillow==10.3.0
ultralytics==8.2.103
requests==2.31.0
R
cat >"$APPS/vision-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import io, requests, cv2, os
from PIL import Image
from ultralytics import YOLO
api=FastAPI()
MODEL=os.getenv("VISION_MODEL","yolov8n.pt")
try:
    yolo=YOLO(MODEL); READY=True; ERR=""
except Exception as e:
    READY=False; ERR=str(e)
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
        cid=int(b.cls[0])
        out.append({"cls_id":cid,"cls":names.get(cid,str(cid)),"conf":float(b.conf[0]),
                    "xywh":[float(x) for x in b.xywh[0].tolist()]})
    return {"detections":out}
PY
cat >"$APPS/vision-engine/Dockerfile"<<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081"]
D

# Media-Forensics
install -d -m 755 "$APPS/media-forensics"
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
def _fetch(url)->bytes:
    r=requests.get(url, timeout=30); r.raise_for_status(); return r.content
def _pil(b): return Image.open(io.BytesIO(b)).convert('RGB')
def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q); comp=Image.open(io.BytesIO(buf.getvalue()))
    diff=ImageChops.difference(img.convert('RGB'), comp.convert('RGB'))
    arr=np.asarray(diff, dtype=np.int16); return diff, float(np.abs(arr).mean()), float(np.percentile(np.abs(arr),95))
def prnu_residual(img_rgb):
    g=np.array(img_rgb.convert('L'), dtype=np.float32)/255.0
    den=cv2.fastNlMeansDenoising((g*255).astype(np.uint8), None, h=7, templateWindowSize=7, searchWindowSize=21).astype(np.float32)/255.0
    resid=g-den; r=resid - resid.mean(); r/= (r.std()+1e-8); return r
@api.get("/health")
def health(): return {"status":"ok"}
@api.post("/analyze")
def analyze(inp:ImgReq):
    try:
        raw=_fetch(inp.image_url); img=_pil(raw); w,h=img.size
        diff, m, p95 = ela(img, inp.ela_quality or 90)
        r = prnu_residual(img); p_strength=float(np.mean(r**2))
        nrg=float(np.mean((np.array(img.convert('L'),dtype=np.float32)/255.0 - cv2.GaussianBlur(np.array(img.convert('L'),dtype=np.float32)/255.0,(0,0),1.0))**2))
        ah=str(imagehash.average_hash(img)); ph=str(imagehash.phash(img))
        try:
            tags=exifread.process_file(io.BytesIO(raw), details=False)
            keep=("EXIF DateTimeOriginal","EXIF LensModel","Image Make","Image Model","GPS GPSLatitude","GPS GPSLongitude")
            exif={k:str(v) for k,v in tags.items() if k in keep}
        except: exif={}
        out={"width":w,"height":h,"ela_mean":m,"ela_p95":p95,"prnu_strength":p_strength,"noise_energy":nrg,"ahash":ah,"phash":ph,"exif":exif}
        if inp.heatmap:
            b=io.BytesIO(); (Image.fromarray(((r-r.min())/(r.max()-r.min()+1e-8)*255).astype(np.uint8))).save(b,'PNG')
            out["prnu_residual_png_b64"]=base64.b64encode(b.getvalue()).decode()
            b2=io.BytesIO(); diff.save(b2,'PNG'); out["ela_heatmap_png_b64"]=base64.b64encode(b2.getvalue()).decode()
        return out
    except Exception as e: raise HTTPException(500, str(e))
PY
cat >"$APPS/media-forensics/Dockerfile"<<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082"]
D

# Hashset: أضف build-essential وlibfuzzy-dev لحل خطأ ssdeep
install -d -m 755 "$APPS/hashset-service"
cat >"$APPS/hashset-service/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
ssdeep==3.4
R
cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, hashlib, requests, sqlite3, ssdeep, gzip, bz2, csv, tempfile
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
os.makedirs(os.path.dirname(DB), exist_ok=True)
def db(): return sqlite3.connect(DB)
@api.get("/health")
def health():
    try:
        con=db(); con.execute("CREATE TABLE IF NOT EXISTS nsrl(sha1 TEXT PRIMARY KEY)"); con.close()
        return {"status":"ok"}
    except Exception as e: return {"status":"bad","error":str(e)}
class HashReq(BaseModel): file_url:str
@api.post("/hash")
def do_hash(q:HashReq):
    try:
        r=requests.get(q.file_url,timeout=30); r.raise_for_status()
        b=r.content
        sha1=hashlib.sha1(b).hexdigest(); sha256=hashlib.sha256(b).hexdigest(); md5=hashlib.md5(b).hexdigest()
        fuzzy=ssdeep.hash(b)
        return {"sha1":sha1,"sha256":sha256,"md5":md5,"ssdeep":fuzzy}
    except Exception as e: raise HTTPException(500,str(e))
@api.get("/nsrl/check")
def nsrl(sha1:str):
    try:
        con=db(); cur=con.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1",(sha1.upper(),)); hit=cur.fetchone() is not None; con.close()
        return {"sha1":sha1,"known":bool(hit)}
    except Exception as e: raise HTTPException(500,str(e))
PY
cat >"$APPS/hashset-service/Dockerfile"<<'D'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libfuzzy-dev python3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8083
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083"]
D

# Relationship-Intel (ربط العلاقات)
install -d -m 755 "$APPS/relationship-intel"
cat >"$APPS/relationship-intel/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
psycopg[binary,pool]==3.2.1
neo4j==5.21.0
numpy==1.26.4
R
# إذا كان app.py موجود مسبقًا لا نعيد الكتابة
[ -f "$APPS/relationship-intel/app.py" ] || cat >"$APPS/relationship-intel/app.py"<<'PY'
# تم إنشاؤه سابقًا في ff_relation_pack.sh
from fastapi import FastAPI
api=FastAPI()
@api.get("/health")
def h(): return {"status":"ok"}
PY
cat >"$APPS/relationship-intel/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8088"]
D

# ===== Compose للتطبيقات مع منافذ حرة =====
cat >"$APPS_YML"<<YML
name: ffactory
networks: { $NET: { external: true } }
services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory-vision
    networks: [ $NET ]
    ports: [ "127.0.0.1:${VISION_PORT}:8081" ]
  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory-media-forensics
    networks: [ $NET ]
    ports: [ "127.0.0.1:${MEDIA_PORT}:8082" ]
  hashset:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory-hashset
    volumes: [ "$FF/data/hashsets:/data/hashsets" ]
    networks: [ $NET ]
    ports: [ "127.0.0.1:${HASH_PORT}:8083" ]
  relationship-intel:
    build: { context: ../apps/relationship-intel, dockerfile: Dockerfile }
    container_name: ffactory-relationship-intel
    env_file: [ ../.env ]
    environment:
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: "$POSTGRES_USER"
      DB_PASSWORD: "$POSTGRES_PASSWORD"
      DB_NAME: "$POSTGRES_DB"
      NEO4J_URI: bolt://neo4j:7687
      NEO4J_USER: "$NEO4J_USER"
      NEO4J_PASSWORD: "$NEO4J_PASSWORD"
    networks: [ $NET ]
    depends_on: [ "db", "neo4j" ]
    ports: [ "127.0.0.1:${REL_PORT}:8088" ]
YML

log "[*] build+up apps"
VISION_PORT=$VISION_PORT MEDIA_PORT=$MEDIA_PORT HASH_PORT=$HASH_PORT REL_PORT=$REL_PORT \
docker compose -f "$APPS_YML" up -d --build

echo "---- READY ----"
echo "DB:                postgres://$POSTGRES_USER:****@127.0.0.1:${PG_PORT}/$POSTGRES_DB"
echo "Neo4j HTTP:        http://127.0.0.1:${NEO_HTTP}"
echo "Neo4j Bolt:        bolt://127.0.0.1:${NEO_BOLT}"
echo "MinIO Console:     http://127.0.0.1:${MINIO_CON}"
echo "S3 (internal):     http://minio:9000  (mc alias= minio)"
echo "Vision Engine:     http://127.0.0.1:${VISION_PORT}/health"
echo "Media Forensics:   http://127.0.0.1:${MEDIA_PORT}/health"
echo "Hashset Service:   http://127.0.0.1:${HASH_PORT}/health"
echo "Relationship-Intel:http://127.0.0.1:${REL_PORT}/health"
