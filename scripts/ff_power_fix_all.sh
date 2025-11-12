#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مُثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مُثبت"

FF=/opt/ffactory
APPS=$FF/apps
STACK=$FF/stack
ENVF=$FF/.env
NET=ffactory_ffactory_net
EXTY=$STACK/docker-compose.apps.ext.yml

[ -f "$ENVF" ] || die ".env مفقود. شغّل الأساس أولاً"
install -d -m 755 "$APPS/vision-engine" "$APPS/media-forensics" "$APPS/hashset-service" "$APPS/social-correlator" "$FF/data/hashsets" "$STACK"

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# ---------- إصلاح MinIO: إزالة underscore من الـHost عبر alias ----------
# بعض إصدارات MinIO ترفض Hostnames تحتوي underscore. نضيف alias "minio".
{ docker network disconnect "$NET" ffactory_minio >/dev/null 2>&1 || true; } || true
docker network connect --alias minio "$NET" ffactory_minio 2>/dev/null || true

# ---------- تعيين منافذ خالية ----------
in_use(){ ss -ltn 2>/dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | grep -qx "$1" && return 0 || \
           netstat -ltn 2>/dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | grep -qx "$1"; }
pick(){ p="$1"; while in_use "$p"; do p=$((p+1)); done; echo "$p"; }

VISION_PORT=${VISION_PORT:-$(pick 8081)}
MEDIA_PORT=${MEDIA_PORT:-$(pick 8082)}
HASH_PORT=${HASH_PORT:-$(pick 8083)}
SOCIAL_PORT=${SOCIAL_PORT:-$(pick 8088)}   # عالجنا تعارض 8088

# ---------- Vision (YOLOv8) ----------
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
MODEL=os.getenv("VISION_MODEL","yolov8n.pt"); ERR=None
try:
    yolo=YOLO(MODEL); READY=True
except Exception as e:
    READY=False; ERR=str(e)
class ImgReq(BaseModel): image_url:str; conf:float|None=0.25
@api.get("/health")
def health(): return {"ready": READY, "model": MODEL, "error": ERR}
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
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8081/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8081"]
D

# ---------- Media-Forensics (ELA/PRNU/EXIF) ----------
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
def _fetch(url)->bytes: r=requests.get(url, timeout=30); r.raise_for_status(); return r.content
def _pil(b): return Image.open(io.BytesIO(b)).convert('RGB')
def ela(img,q=90):
    buf=io.BytesIO(); img.save(buf,'JPEG',quality=q)
    comp=Image.open(io.BytesIO(buf.getvalue()))
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
        except Exception:
            exif={}
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
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8082
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8082/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8082"]
D

# ---------- Hashset (SHA*/MD5 + ssdeep عبر CLI + NSRL SQLite) ----------
cat >"$APPS/hashset-service/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
requests==2.31.0
R

cat >"$APPS/hashset-service/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, tempfile, hashlib, subprocess, sqlite3, requests
api=FastAPI()
DB=os.getenv("NSRL_DB_PATH","/data/hashsets/nsrl.sqlite")
def ssdeep_hash(path:str)->str:
    try:
        out=subprocess.check_output(["ssdeep","-b",path], text=True).strip().splitlines()
        return out[-1].split(',',1)[0] if len(out)>=2 else ""
    except Exception:
        return ""
@api.get("/health")
def health():
    return {"status":"ok","nsrl_db_exists": os.path.isfile(DB)}
class Inp(BaseModel):
    file_url: str
@api.post("/hash")
def do(inp:Inp):
    try:
        with tempfile.NamedTemporaryFile(delete=True) as f:
            r=requests.get(inp.file_url, timeout=60); r.raise_for_status()
            f.write(r.content); f.flush()
            data=r.content
            sha1=hashlib.sha1(data).hexdigest()
            sha256=hashlib.sha256(data).hexdigest()
            md5=hashlib.md5(data).hexdigest()
            ssd=ssdeep_hash(f.name)
            verdict=None
            if os.path.isfile(DB):
                con=sqlite3.connect(DB); cur=con.cursor()
                cur.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;", (sha1,))
                verdict="known" if cur.fetchone() else "unknown"
                con.close()
            return {"sha1":sha1,"sha256":sha256,"md5":md5,"ssdeep":ssd,"nsrl":verdict}
    except Exception as e:
        raise HTTPException(500, str(e))
@api.get("/nsrl/check")
def nsrl_check(sha1:str):
    if not os.path.isfile(DB): return {"nsrl":"db_missing"}
    con=sqlite3.connect(DB); cur=con.cursor()
    cur.execute("SELECT 1 FROM nsrl WHERE sha1=? LIMIT 1;", (sha1,))
    x=cur.fetchone(); con.close()
    return {"nsrl": "known" if x else "unknown"}
PY

cat >"$APPS/hashset-service/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ssdeep sqlite3 wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data/hashsets"]
EXPOSE 8083
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8083/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8083"]
D

# ---------- Social-Correlator (ربط حسابات ↔ أشخاص) ----------
cat >"$APPS/social-correlator/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
psycopg[binary,pool]==3.2.1
neo4j==5.21.0
python-dateutil==2.9.0.post0
rapidfuzz==3.9.6
R

cat >"$APPS/social-correlator/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, psycopg, json
from neo4j import GraphDatabase

api=FastAPI()
DB=os.getenv("DB_NAME","ffactory")
DBU=os.getenv("DB_USER","ffadmin")
DBP=os.getenv("DB_PASSWORD")
DBH=os.getenv("DB_HOST","db")
DBPORT=int(os.getenv("DB_PORT","5432"))
NEO_URI=os.getenv("NEO4J_URI","bolt://neo4j:7687")
NEO_USER=os.getenv("NEO4J_USER","neo4j")
NEO_PASS=os.getenv("NEO4J_PASSWORD")

def bolt(): return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))

@api.get("/health")
def health():
    try:
        with psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP) as c:
            c.execute("SELECT 1;").fetchone()
        with bolt() as d: d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e:
        return {"status":"bad","error":str(e)}

class Account(BaseModel):
    platform:str
    handle:str
    uid:str|None=None
    phone:str|None=None
    email:str|None=None
class LinkIn(BaseModel):
    person_name:str
    accounts:list[Account]

@api.post("/link")
def link(inp:LinkIn):
    try:
        with psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP, autocommit=True) as c:
            c.execute("""CREATE TABLE IF NOT EXISTS accounts(
                id SERIAL PRIMARY KEY, platform TEXT, handle TEXT, uid TEXT, phone TEXT, email TEXT, person TEXT)""")
            for acc in inp.accounts:
                c.execute("INSERT INTO accounts(platform,handle,uid,phone,email,person) VALUES(%s,%s,%s,%s,%s,%s)",
                          (acc.platform, acc.handle, acc.uid, acc.phone, acc.email, inp.person_name))
        with bolt() as drv, drv.session() as s:
            s.run("MERGE (p:Person {name:$n})", n=inp.person_name)
            for acc in inp.accounts:
                s.run("""MERGE (a:Account {platform:$pl, handle:$h})
                         MERGE (p:Person {name:$n})
                         MERGE (p)-[:USES]->(a)""", pl=acc.platform, h=acc.handle, n=inp.person_name)
        return {"linked": len(inp.accounts)}
    except Exception as e:
        raise HTTPException(500, str(e))
PY

cat >"$APPS/social-correlator/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8088
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8088/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8088"]
D

# ---------- Compose (امتداد التطبيقات مع منافذ نهائية) ----------
cat >"$EXTY"<<YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { hashsets_data: {} }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${VISION_PORT}:8081" ]
    healthcheck: { test: ["CMD","wget","-qO-","http://127.0.0.1:8081/health"], interval: 20s, timeout: 5s, retries: 30 }

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${MEDIA_PORT}:8082" ]
    healthcheck: { test: ["CMD","wget","-qO-","http://127.0.0.1:8082/health"], interval: 20s, timeout: 5s, retries: 30 }

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    networks: [ ffactory_ffactory_net ]
    environment:
      - NSRL_DB_PATH=/data/hashsets/nsrl.sqlite
    volumes: [ "hashsets_data:/data/hashsets" ]
    ports: [ "127.0.0.1:${HASH_PORT}:8083" ]
    healthcheck: { test: ["CMD","wget","-qO-","http://127.0.0.1:8083/health"], interval: 20s, timeout: 5s, retries: 30 }

  social-correlator:
    build: { context: ../apps/social-correlator, dockerfile: Dockerfile }
    container_name: ffactory_social_correlator
    env_file: [ ../.env ]
    environment:
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER}
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB}
      - NEO4J_URI=bolt://neo4j:7687
      - NEO4J_USER=${NEO4J_USER}
      - NEO4J_PASSWORD=${NEO4J_PASSWORD}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${SOCIAL_PORT}:8088" ]
    healthcheck: { test: ["CMD","wget","-qO-","http://127.0.0.1:8088/health"], interval: 20s, timeout: 5s, retries: 30 }
YML

# ---------- تمكين WORM على MinIO عبر alias "minio" ----------
. "$ENVF"
MC="docker run --rm --network $NET -e MC_HOST_ff=http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@minio:9000 minio/mc"
$MC mb --with-lock ff/forensic-evidence || true
$MC version enable ff/forensic-evidence || true
$MC retention set ff/forensic-evidence --default compliance 365d || true

# ---------- بناء وتشغيل ----------
log "[*] build+up apps-ext"
docker compose --env-file "$ENVF" -f "$EXTY" up -d --build

# ---------- ملخص واختبارات صحة ----------
echo "---- docker ps (أول سطرين) ----"
docker ps | grep ffactory_ | head -n 2 || true

echo "---- فحص /health ----"
fail=0
for p in "$VISION_PORT" "$MEDIA_PORT" "$HASH_PORT" "$SOCIAL_PORT"; do
  curl -fsS "http://127.0.0.1:$p/health" >/dev/null || { echo "FAIL:$p"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "ALL_OK"
