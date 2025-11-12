#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مُثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مُثبت"

FF=/opt/ffactory; APPS=$FF/apps; STACK=$FF/stack; ENVF=$FF/.env; NET=ffactory_ffactory_net
EXTY=$STACK/docker-compose.apps.pack2.yml
[ -f "$ENVF" ] || die ".env مفقود"
install -d -m 755 "$APPS/ocr-engine" "$APPS/face-engine" "$APPS/embed-search" "$APPS/audit-logger" "$APPS/evidence-tracker" "$STACK"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

in_use(){ ss -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1" || netstat -ltn 2>/dev/null|awk '{print $4}'|sed -n 's/.*:\([0-9]\+\)$/\1/p'|grep -qx "$1"; }
pick(){ p="$1"; while in_use "$p"; do p=$((p+1)); done; echo "$p"; }

OCR_PORT=${OCR_PORT:-$(pick 8090)}
FACE_PORT=${FACE_PORT:-$(pick 8092)}
EMBED_PORT=${EMBED_PORT:-$(pick 8093)}
GATEWAY_PORT=${GATEWAY_PORT:-$(pick 8880)}
PROM_PORT=${PROM_PORT:-$(pick 9090)}
GRAFANA_PORT=${GRAFANA_PORT:-$(pick 3000)}
CADV_PORT=${CADV_PORT:-$(pick 8089)}
NODEX_PORT=${NODEX_PORT:-$(pick 9100)}

# ===== OCR: Tesseract =====
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
import io, requests
from PIL import Image
import pytesseract, os
api=FastAPI()
LANG=os.getenv("OCR_LANG","ara+eng")
class Inp(BaseModel): image_url:str; lang:str|None=None
@api.get("/health")
def health(): return {"status":"ok","lang":LANG}
@api.post("/ocr")
def ocr(inp:Inp):
    try:
        r=requests.get(inp.image_url,timeout=30); r.raise_for_status()
        im=Image.open(io.BytesIO(r.content))
        txt=pytesseract.image_to_string(im, lang=inp.lang or LANG)
        return {"text":txt}
    except Exception as e:
        raise HTTPException(500, str(e))
PY
cat >"$APPS/ocr-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-ara libgl1 libglib2.0-0 wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8090
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8090/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8090"]
D

# ===== Face: YuNet + SFace (ONNXRuntime) =====
cat >"$APPS/face-engine/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
opencv-python-headless==4.10.0.84
onnxruntime==1.18.0
numpy==1.26.4
pillow==10.3.0
requests==2.31.0
R
cat >"$APPS/face-engine/app.py"<<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os, io, requests, numpy as np, cv2
from PIL import Image
api=FastAPI()
# OpenCV Zoo models
YU=os.getenv("YUNET_URL","https://raw.githubusercontent.com/opencv/opencv_zoo/master/models/face_detection_yunet/face_detection_yunet_2023mar.onnx")
SF=os.getenv("SFACE_URL","https://raw.githubusercontent.com/opencv/opencv_zoo/master/models/face_recognition_sface/face_recognition_sface_2021dec.onnx")
os.makedirs("/models", exist_ok=True)
def _dl(url, path):
    if not os.path.isfile(path):
        import urllib.request; urllib.request.urlretrieve(url, path)
_dl(YU, "/models/yunet.onnx"); _dl(SF, "/models/sface.onnx")
det=cv2.FaceDetectorYN.create(model="/models/yunet.onnx", config="", input_size=(320,320), score_threshold=0.6, nms_threshold=0.3, top_k=500, backend_id=3, target_id=0)
rec=cv2.FaceRecognizerSF.create("/models/sface.onnx","")
class Img(BaseModel): image_url:str
class Pair(BaseModel): image_url_a:str; image_url_b:str
@api.get("/health")
def health(): return {"status":"ok","models":"yunet+sface"}
def _im(url):
    r=requests.get(url,timeout=30); r.raise_for_status()
    im=Image.open(io.BytesIO(r.content)).convert("RGB")
    return cv2.cvtColor(np.array(im), cv2.COLOR_RGB2BGR)
@api.post("/detect")
def detect(inp:Img):
    try:
        img=_im(inp.image_url); h,w=img.shape[:2]
        det.setInputSize((w,h))
        _, faces = det.detect(img)
        faces = [] if faces is None else faces
        out=[{"bbox": [float(x) for x in f[:4]], "score": float(f[14])} for f in faces]
        return {"faces": out}
    except Exception as e:
        raise HTTPException(500, str(e))
@api.post("/embed")
def embed(inp:Img):
    try:
        img=_im(inp.image_url); h,w=img.shape[:2]
        det.setInputSize((w,h)); _, faces = det.detect(img)
        faces = [] if faces is None else faces
        if not len(faces): return {"vec": None}
        x,y,w0,h0 = faces[0][:4].astype(int)
        crop=img[max(0,y):y+h0, max(0,x):x+w0]
        feat=rec.feature(crop)
        return {"vec": feat.flatten().tolist()}
    except Exception as e:
        raise HTTPException(500, str(e))
@api.post("/match")
def match(p:Pair):
    a=_im(p.image_url_a); b=_im(p.image_url_b)
    def vec(img):
        h,w=img.shape[:2]; det.setInputSize((w,h)); _, faces=det.detect(img); faces=[] if faces is None else faces
        if not faces: return None
        x,y,w0,h0=faces[0][:4].astype(int); crop=img[max(0,y):y+h0, max(0,x):x+w0]; return rec.feature(crop).flatten()
    va, vb = vec(a), vec(b)
    if va is None or vb is None: return {"similarity": None}
    sim=float(np.dot(va, vb)/ (np.linalg.norm(va)*np.linalg.norm(vb)+1e-9))
    return {"similarity": sim}
PY
cat >"$APPS/face-engine/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 wget && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8092
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8092/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8092"]
D

# ===== Embed-Search: Sentence-Transformers CPU =====
cat >"$APPS/embed-search/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
sentence-transformers==2.2.2
torch==2.4.1
requests==2.31.0
R
cat >"$APPS/embed-search/app.py"<<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from sentence_transformers import SentenceTransformer
import numpy as np, sqlite3, os, json
api=FastAPI()
os.makedirs("/data", exist_ok=True)
DB="/data/emb.db"
m=SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
con=sqlite3.connect(DB); con.execute("CREATE TABLE IF NOT EXISTS emb(id TEXT PRIMARY KEY, vec TEXT)"); con.commit()
class Add(BaseModel): id:str; text:str
class Q(BaseModel): query:str; k:int|None=5
@api.get("/health")
def h(): return {"status":"ok","model":"all-MiniLM-L6-v2"}
@api.post("/index")
def idx(a:Add):
    v=m.encode([a.text])[0].astype(float).tolist()
    con.execute("INSERT OR REPLACE INTO emb(id, vec) VALUES(?,?)",(a.id, json.dumps(v))); con.commit()
    return {"indexed":a.id}
@api.post("/search")
def sr(q:Q):
    v=m.encode([q.query])[0].astype(float)
    rows=list(con.execute("SELECT id, vec FROM emb"))
    if not rows: return {"results":[]}
    vecs=np.array([np.array(json.loads(r[1]), dtype=float) for r in rows])
    v=v/(np.linalg.norm(v)+1e-9); vv=vecs/(np.linalg.norm(vecs,axis=1,keepdims=True)+1e-9)
    sims=(vv@v).tolist()
    paired=sorted(zip([r[0] for r in rows], sims), key=lambda x: x[1], reverse=True)[:q.k or 5]
    return {"results":[{"id":i,"score":float(s)} for i,s in paired]}
PY
cat >"$APPS/embed-search/Dockerfile"<<'D'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends wget && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
VOLUME ["/data"]
EXPOSE 8093
HEALTHCHECK --interval=20s --timeout=5s --retries=30 CMD wget -qO- http://127.0.0.1:8093/health >/dev/null || exit 1
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8093"]
D

# ===== Audit-Logger =====
cat >"$APPS/audit-logger/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
psycopg[binary,pool]==3.2.1
R
cat >"$APPS/audit-logger/app.py"<<'PY'
from fastapi import FastAPI, Request
import os, psycopg, datetime as dt
api=FastAPI()
DB=os.getenv("DB_NAME","ffactory"); U=os.getenv("DB_USER","ffadmin"); P=os.getenv("DB_PASSWORD"); H=os.getenv("DB_HOST","db"); PORT=int(os.getenv("DB_PORT","5432"))
@api.on_event("startup")
def boot():
    with psycopg.connect(host=H, port=PORT, dbname=DB, user=U, password=P, autocommit=True) as c:
        c.execute("CREATE TABLE IF NOT EXISTS audit(ts timestamptz, actor text, action text, target text, meta jsonb)")
@api.get("/health")
def h(): return {"status":"ok"}
@api.post("/log")
async def log(req:Request):
    j=await req.json()
    with psycopg.connect(host=H, port=PORT, dbname=DB, user=U, password=P, autocommit=True) as c:
        c.execute("INSERT INTO audit VALUES(%s,%s,%s,%s,%s)", (dt.datetime.utcnow(), j.get("actor"), j.get("action"), j.get("target"), j))
    return {"ok":True}
PY
cat >"$APPS/audit-logger/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8094
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8094"]
D

# ===== Evidence-Tracker =====
cat >"$APPS/evidence-tracker/requirements.txt"<<'R'
fastapi==0.110.0
uvicorn[standard]==0.30.0
psycopg[binary,pool]==3.2.1
R
cat >"$APPS/evidence-tracker/app.py"<<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
import os, psycopg
api=FastAPI()
DB=os.getenv("DB_NAME","ffactory"); U=os.getenv("DB_USER","ffadmin"); P=os.getenv("DB_PASSWORD"); H=os.getenv("DB_HOST","db"); PORT=int(os.getenv("DB_PORT","5432"))
@api.on_event("startup")
def boot():
    with psycopg.connect(host=H, port=PORT, dbname=DB, user=U, password=P, autocommit=True) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS evidence(
            id SERIAL PRIMARY KEY, case_id text, path text, sha256 text, bucket text, object text, notes text)""")
class Ev(BaseModel):
    case_id:str; path:str; sha256:str; bucket:str; object:str; notes:str|None=None
@api.get("/health")
def h(): return {"status":"ok"}
@api.post("/add")
def add(e:Ev):
    with psycopg.connect(host=H, port=PORT, dbname=DB, user=U, password=P, autocommit=True) as c:
        c.execute("INSERT INTO evidence(case_id,path,sha256,bucket,object,notes) VALUES(%s,%s,%s,%s,%s,%s)",
                  (e.case_id,e.path,e.sha256,e.bucket,e.object,e.notes))
    return {"stored":True}
PY
cat >"$APPS/evidence-tracker/Dockerfile"<<'D'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8095
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8095"]
D

# ===== API Gateway: Nginx =====
cat >"$STACK/nginx.gateway.conf"<<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen 80;

    location /asr/ { proxy_pass http://host.docker.internal:8086/; proxy_set_header Host \$host; }
    location /nlp/ { proxy_pass http://host.docker.internal:8000/; }
    location /vision/ { proxy_pass http://host.docker.internal:${FACE_PORT}/; }
    location /ocr/ { proxy_pass http://host.docker.internal:${OCR_PORT}/; }
    location /media/ { proxy_pass http://host.docker.internal:8082/; }
    location /hash/ { proxy_pass http://host.docker.internal:8083/; }
    location /social/ { proxy_pass http://host.docker.internal:8088/; }
    location /embed/ { proxy_pass http://host.docker.internal:${EMBED_PORT}/; }
    location /evidence/ { proxy_pass http://host.docker.internal:8095/; }
    location /audit/ { proxy_pass http://host.docker.internal:8094/; }
  }
}
EOF

# ===== Compose (Pack 2) =====
cat >"$EXTY"<<YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { emb_data: {} }

services:
  ocr-engine:
    build: { context: ../apps/ocr-engine, dockerfile: Dockerfile }
    container_name: ffactory_ocr
    networks: [ ffactory_ffactory_net ]
    environment: [ OCR_LANG=ara+eng ]
    ports: [ "127.0.0.1:${OCR_PORT}:8090" ]

  face-engine:
    build: { context: ../apps/face-engine, dockerfile: Dockerfile }
    container_name: ffactory_face
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${FACE_PORT}:8092" ]

  embed-search:
    build: { context: ../apps/embed-search, dockerfile: Dockerfile }
    container_name: ffactory_embed
    networks: [ ffactory_ffactory_net ]
    volumes: [ "emb_data:/data" ]
    ports: [ "127.0.0.1:${EMBED_PORT}:8093" ]

  audit-logger:
    build: { context: ../apps/audit-logger, dockerfile: Dockerfile }
    container_name: ffactory_audit
    env_file: [ ../.env ]
    environment:
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER}
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8094:8094" ]

  evidence-tracker:
    build: { context: ../apps/evidence-tracker, dockerfile: Dockerfile }
    container_name: ffactory_evidence
    env_file: [ ../.env ]
    environment:
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER}
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8095:8095" ]

  api-gateway:
    image: nginx:1.27-alpine
    container_name: ffactory_api_gateway
    networks: [ ffactory_ffactory_net ]
    volumes: [ "../stack/nginx.gateway.conf:/etc/nginx/nginx.conf:ro" ]
    ports: [ "127.0.0.1:${GATEWAY_PORT}:80" ]

  prometheus:
    image: prom/prometheus:v2.55.1
    container_name: ffactory-prometheus
    networks: [ ffactory_ffactory_net ]
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
    volumes:
      - "../stack/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
    ports: [ "127.0.0.1:${PROM_PORT}:9090" ]

  grafana:
    image: grafana/grafana:11.2.2
    container_name: ffactory-grafana
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${GRAFANA_PORT}:3000" ]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.2
    container_name: ffactory-cadvisor
    networks: [ ffactory_ffactory_net ]
    privileged: true
    ports: [ "127.0.0.1:${CADV_PORT}:8080" ]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:rw
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.8.2
    container_name: ffactory-node-exporter
    networks: [ ffactory_ffactory_net ]
    pid: host
    ports: [ "127.0.0.1:${NODEX_PORT}:9100" ]
    volumes:
      - /:/host:ro,rslave
    command:
      - '--path.rootfs=/host'
YML

# ===== Prometheus config =====
cat >"$STACK/prometheus.yml"<<PROM
global: { scrape_interval: 15s }
scrape_configs:
  - job_name: 'cadvisor'
    static_configs: [ { targets: ['cadvisor:8080'] } ]
  - job_name: 'node'
    static_configs: [ { targets: ['node-exporter:9100'] } ]
PROM

log "[*] build+up pack2"
docker compose --env-file "$ENVF" -f "$EXTY" up -d --build

echo "---- docker ps | grep ffactory_ | head -n 2 ----"
docker ps | grep ffactory_ | head -n 2 || true

echo "---- health checks ----"
for p in "$OCR_PORT" "$FACE_PORT" "$EMBED_PORT" "$GATEWAY_PORT" "$PROM_PORT" "$GRAFANA_PORT" "$CADV_PORT" "$NODEX_PORT"; do
  curl -fsS "http://127.0.0.1:$p/health" >/dev/null 2>&1 && echo "OK:$p" || echo "SKIP_OR_EXT:$p"
done

echo "Gateway:  http://127.0.0.1:${GATEWAY_PORT}/"
echo "Grafana:  http://127.0.0.1:${GRAFANA_PORT}/"
echo "Prom:     http://127.0.0.1:${PROM_PORT}/"
