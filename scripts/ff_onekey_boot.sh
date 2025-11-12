#!/usr/bin/env bash
# FFactory One-Key Boot: infra + DB rescue + AI engines + health
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

FF=/opt/ffactory
STACK=$FF/stack
APPS=$FF/apps
SCRIPTS=$FF/scripts
NET=ffactory_ffactory_net

install -d -m 755 "$FF" "$STACK" "$APPS" "$SCRIPTS" "$FF/data" "$FF/logs" "$FF/backups"

# -------- 0) .env آمن (قابِل للتعديل) --------
PG_PASS="${POSTGRES_PASSWORD:-$(openssl rand -base64 24)}"
NEO_PASS="${NEO4J_PASSWORD:-$(openssl rand -base64 24)}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -base64 48)}"
ENC_KEY="${ENCRYPTION_KEY:-$(openssl rand -base64 32)}"

cat >"$FF/.env" <<EOF
TZ=Asia/Kuwait
LANG=ar_EG.UTF-8

# Postgres
POSTGRES_DB=ffactory
POSTGRES_USER=ffadmin
POSTGRES_PASSWORD=$PG_PASS
PGPORT=5432

# Neo4j
NEO4J_AUTH=neo4j/$NEO_PASS

# MinIO
MINIO_ROOT_USER=ffminioadmin
MINIO_ROOT_PASSWORD=$MINIO_PASS

# اختياري
HUGGINGFACE_TOKEN=${HUGGINGFACE_TOKEN:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}

JWT_SECRET=$JWT_SECRET
ENCRYPTION_KEY=$ENC_KEY
COMPOSE_PROJECT_NAME=ffactory
EOF
chmod 600 "$FF/.env"

# -------- 1) شبكة موحّدة --------
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# -------- 2) Compose للبنية --------
cat >"$STACK/docker-compose.core.yml" <<'YML'
version: "3.9"
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { postgres_data: {}, neo4j_data: {}, neo4j_logs: {}, minio_data: {} }

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    env_file: [ ../.env ]
    command: [ "postgres", "-p", "${PGPORT}" ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "postgres_data:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:5433:5432" ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${POSTGRES_USER} -h 127.0.0.1 -p 5432"]
      interval: 10s
      timeout: 5s
      retries: 30

  neo4j:
    image: neo4j:5.22
    container_name: ffactory_neo4j
    env_file: [ ../.env ]
    environment:
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=1g
      - TZ=${TZ}
    networks: [ ffactory_ffactory_net ]
    volumes: [ "neo4j_data:/data", "neo4j_logs:/logs" ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    healthcheck:
      test: ["CMD-SHELL","cypher-shell -u neo4j -p \"${NEO4J_AUTH#neo4j/}\" 'RETURN 1;' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    env_file: [ ../.env ]
    command: server /data --console-address ":9001"
    networks: [ ffactory_ffactory_net ]
    volumes: [ "minio_data:/data" ]
    ports: [ "127.0.0.1:9000:9000", "127.0.0.1:9001:9001" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 30

  redis:
    image: redis:7
    container_name: ffactory_redis
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 10s
      timeout: 5s
      retries: 30
YML

# -------- 3) انتظار صحة البنية من داخل الشبكة --------
cat >"$SCRIPTS/wait-core.sh" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
docker run --rm --network ffactory_ffactory_net python:3.11-alpine python - <<'PY'
import socket,sys
for host,port in [("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]:
    s=socket.socket(); s.settimeout(5)
    try:
        s.connect((host,port)); print(f"{host}:{port}=OK")
    except Exception as e:
        print(f"{host}:{port}=FAIL:{e}"); sys.exit(1)
PY
BASH
chmod +x "$SCRIPTS/wait-core.sh"

# -------- 4) wait-entrypoint موحّد للخدمات Python --------
cat >"$SCRIPTS/wait-entrypoint.sh" <<'W'
#!/usr/bin/env bash
set -Eeuo pipefail
host_port_ok(){ python - "$@" <<'PY'
import socket,sys
pairs=[(sys.argv[i],int(sys.argv[i+1])) for i in range(0,len(sys.argv),2)]
for h,p in pairs:
    s=socket.socket(); s.settimeout(5)
    s.connect((h,p)); s.close()
PY
}
host_port_ok db 5432 neo4j 7687 || { echo "deps down"; exit 1; }
exec "$@"
W
chmod +x "$SCRIPTS/wait-entrypoint.sh"

# -------- 5) محركات التطبيق (ASR / NER / Correlation) --------
# ASR
install -d -m 755 "$APPS/asr-engine"
cat >"$APPS/asr-engine/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
numpy<2.0
soundfile
librosa>=0.10.1
ctranslate2>=4.3
faster-whisper>=1.0
pyannote.audio==3.1.1
REQ
cat >"$APPS/asr-engine/app.py" <<'PY'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
import os, requests, tempfile
from faster_whisper import WhisperModel

api=FastAPI()
ASR_MODEL=os.getenv("MODEL_SIZE","medium")
LANG=os.getenv("LANGUAGE")
HF=os.getenv("HUGGINGFACE_TOKEN","")
diar_ok=bool(HF)
_model=WhisperModel(ASR_MODEL, device="cpu", compute_type="int8")

@api.get("/health")
def health(): return {"status":"ok","model":ASR_MODEL,"diarization":diar_ok}

class Inp(BaseModel):
    audio_url:str
    language: Optional[str]=None

@api.post("/transcribe")
def transcribe(inp:Inp):
    try:
        r=requests.get(inp.audio_url, timeout=30); r.raise_for_status()
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(r.content); f.flush()
            segs,_=_model.transcribe(f.name, language=inp.language or LANG)
            text="".join(s.text for s in segs).strip()
        return {"text":text}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
PY
cat >"$APPS/asr-engine/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git libsndfile1 curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.4.1 torchaudio==2.4.1 && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
DOCKER

# Neural Core (NER)
install -d -m 755 "$APPS/neural-core"
cat >"$APPS/neural-core/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
transformers>=4.44.0
torch>=2.4.1
REQ
cat >"$APPS/neural-core/app.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from typing import List
import os
from transformers import pipeline

api=FastAPI()
MODEL=os.getenv("NER_MODEL","akhooli/bert-base-arabic-camelbert-ner")
try:
    nlp=pipeline("token-classification", model=MODEL, aggregation_strategy="simple")
    READY=True
except Exception as e:
    READY=False; ERR=str(e)

class Inp(BaseModel):
    text:str

@api.get("/health")
def health():
    return {"ready":READY,"model":MODEL,"error":(None if READY else ERR)}

@api.post("/ner")
def ner(inp:Inp):
    if not READY: return {"error":"model not ready"}
    return {"entities": nlp(inp.text)}
PY
cat >"$APPS/neural-core/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
ENTRYPOINT ["/bin/sh","-lc","/opt/wait-entrypoint.sh python -m uvicorn app:api --host 0.0.0.0 --port 8000"]
DOCKER

# Correlation Engine: ETL (Postgres -> Neo4j) + صحة
install -d -m 755 "$APPS/correlation-engine"
cat >"$APPS/correlation-engine/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
psycopg[binary,pool]>=3.2
neo4j>=5.21
REQ
cat >"$APPS/correlation-engine/app.py" <<'PY'
import os
from fastapi import FastAPI
import psycopg
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

def bolt_session():
    return GraphDatabase.driver(NEO_URI, auth=(NEO_USER, NEO_PASS))

@api.get("/health")
def health():
    try:
        with psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP) as c:
            c.execute("SELECT 1;").fetchone()
        with bolt_session() as d:
            d.verify_connectivity()
        return {"status":"ok"}
    except Exception as e:
        return {"status":"bad","error":str(e)}

@api.post("/etl")
def etl():
    # مثال ETL مبسّط: ينشئ قيودًا ويدمج بعض السجلات من جدول people (إن وُجد)
    with bolt_session() as drv, drv.session() as s:
        s.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;")
    try:
        rows=[]
        with psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP) as c:
            try:
                rows=c.execute("SELECT id, name FROM people LIMIT 100;").fetchall()
            except Exception:
                rows=[]
        if rows:
            with bolt_session() as drv, drv.session() as s:
                s.run("""
                UNWIND $batch AS row
                MERGE (p:Person {id: row.id})
                SET p.name = row.name
                """, batch=[{"id":r[0], "name":r[1]} for r in rows])
        return {"loaded": len(rows)}
    except Exception as e:
        return {"error": str(e)}
PY
cat >"$APPS/correlation-engine/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
ENTRYPOINT ["/bin/sh","-lc","/opt/wait-entrypoint.sh python -m uvicorn app:api --host 0.0.0.0 --port 8080"]
DOCKER

# -------- 6) Compose للتطبيقات + مراقبة --------
cat >"$STACK/docker-compose.apps.yml" <<'YML'
version: "3.9"
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { asr_cache: {}, nlp_cache: {} }

services:
  asr-engine:
    build: { context: ../apps/asr-engine, dockerfile: Dockerfile }
    container_name: ffactory_asr
    env_file: [ ../.env ]
    environment: [ MODEL_SIZE=medium, LANGUAGE=ar ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "asr_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8086:8080" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 30

  neural-core:
    build: { context: ../apps/neural-core, dockerfile: Dockerfile }
    container_name: ffactory_nlp
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes:
      - "nlp_cache:/root/.cache"
      - "/opt/ffactory/scripts/wait-entrypoint.sh:/opt/wait-entrypoint.sh:ro"
    ports: [ "127.0.0.1:8000:8000" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 30

  correlation-engine:
    build: { context: ../apps/correlation-engine, dockerfile: Dockerfile }
    container_name: ffactory_correlation
    env_file: [ ../.env ]
    environment:
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=${POSTGRES_USER}
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB}
      - NEO4J_URI=bolt://neo4j:7687
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=${NEO4J_AUTH#neo4j/}
    networks: [ ffactory_ffactory_net ]
    volumes:
      - "/opt/ffactory/scripts/wait-entrypoint.sh:/opt/wait-entrypoint.sh:ro"
    ports: [ "127.0.0.1:8170:8080" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 30
YML

install -d -m 755 "$STACK/monitoring"
cat >"$STACK/monitoring/prometheus.yml" <<'PROM'
global: { scrape_interval: 15s }
scrape_configs:
  - job_name: prometheus
    static_configs: [ { targets: [ 'prometheus:9090' ] } ]
PROM
cat >"$STACK/docker-compose.monitoring.yml" <<'YML'
version: "3.9"
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { prometheus_data: {}, grafana_data: {} }

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: ffactory_prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
    networks: [ ffactory_ffactory_net ]
    volumes:
      - prometheus_data:/prometheus
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports: [ "127.0.0.1:9090:9090" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://127.0.0.1:9090/-/ready"]
      interval: 10s
      timeout: 5s
      retries: 30

  grafana:
    image: grafana/grafana:latest
    container_name: ffactory_grafana
    networks: [ ffactory_ffactory_net ]
    volumes: [ grafana_data:/var/lib/grafana ]
    ports: [ "127.0.0.1:3003:3000" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://127.0.0.1:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 30
YML

# -------- 7) إنقاذ Postgres عند فساد الأدوار --------
pg_rescue(){
  log "DB rescue (single-user) إن لزم"
  VOL="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' ffactory_db 2>/dev/null || true)"
  [ -n "$VOL" ] || VOL="ffactory_postgres_data"
  docker rm -f ffactory_db >/dev/null 2>&1 || true
  run_single(){ docker run --rm -u postgres -v "$VOL":/var/lib/postgresql/data postgres:16 \
    bash -lc "postgres --single -D \${PGDATA:-/var/lib/postgresql/data} template1 <<< \"$1\" >/dev/null 2>&1 || true"; }
  run_single "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PG_PASS';"
  run_single "ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PG_PASS';"
  run_single "CREATE ROLE ffadmin  WITH LOGIN SUPERUSER PASSWORD '$PG_PASS';"
  run_single "ALTER ROLE ffadmin  WITH LOGIN SUPERUSER PASSWORD '$PG_PASS';"
  run_single "CREATE DATABASE ffactory WITH OWNER ffadmin;"
}

# -------- 8) تشغيل وترتيب --------
log "bring up core"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.core.yml" up -d --build

log "wait core inside network"
bash "$SCRIPTS/wait-core.sh" || { pg_rescue; docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.core.yml" up -d; bash "$SCRIPTS/wait-core.sh"; }

log "bring up apps"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.apps.yml" up -d --build || true

log "bring up monitoring"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.monitoring.yml" up -d --build || true

# -------- 9) ملخّص --------
log "docker ps snapshot (ffactory*)"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep '^ffactory_' || true
log "neo4j ping"
docker exec -i ffactory_neo4j cypher-shell -u neo4j -p "${NEO_PASS}" 'RETURN 1;' || echo "neo4j: check failed"
log "db ping"
docker run --rm --network "$NET" -e PGPASSWORD="$PG_PASS" postgres:16 psql -h db -U ffadmin -d ffactory -c "SELECT 1;" || echo "db: check failed"
log "done."
