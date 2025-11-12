#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
warn(){ printf "[warn] %s\n" "$*" >&2; }
die(){ printf "[err] %s\n" "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مُثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مُثبت"

FF=/opt/ffactory
STACK=$FF/stack
APPS=$FF/apps
SCRIPTS=$FF/scripts
NET=ffactory_ffactory_net
install -d -m 755 "$FF" "$STACK" "$APPS" "$SCRIPTS" "$FF/backups" "$FF/logs"

backup(){
  local f="$1"; [ -f "$f" ] || return 0
  cp -a "$f" "$FF/backups/$(basename "$f").bak.$(date +%s)"
}

sanitize_file(){
  # يحذف NBSP وأي CRLF
  [ -f "$1" ] || return 0
  tr '\240' ' ' <"$1" | tr -d '\r' >"$1.__clean__" && mv -f "$1.__clean__" "$1"
}

# 0) بيئة موحّدة نظيفة
log "تحضير .env نظيف"
backup "$FF/.env"
PG_PASS="${POSTGRES_PASSWORD:-$(openssl rand -base64 24)}"
NEO_PASS="${NEO4J_PASSWORD:-$(openssl rand -base64 24)}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
JWT_SECRET_VAL="${JWT_SECRET:-$(openssl rand -base64 48)}"
ENC_KEY_VAL="${ENCRYPTION_KEY:-$(openssl rand -base64 32)}"

cat >"$FF/.env" <<EOF
TZ=Asia/Kuwait
LANG=ar_EG.UTF-8

# Postgres
POSTGRES_DB=ffactory
POSTGRES_USER=ffadmin
POSTGRES_PASSWORD=${PG_PASS}
PGPORT=5432

# Neo4j (نفصل user/password لتجنّب interpolation)
NEO4J_USER=neo4j
NEO4J_PASSWORD=${NEO_PASS}
NEO4J_AUTH=neo4j/${NEO_PASS}

# MinIO
MINIO_ROOT_USER=ffminioadmin
MINIO_ROOT_PASSWORD=${MINIO_PASS}

# اختيارية
HUGGINGFACE_TOKEN=
OPENAI_API_KEY=

JWT_SECRET=${JWT_SECRET_VAL}
ENCRYPTION_KEY=${ENC_KEY_VAL}
COMPOSE_PROJECT_NAME=ffactory
EOF
chmod 600 "$FF/.env"

# 1) شبكة موحّدة
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# 2) Compose الأساسي نظيف (بدون version)
CORE="$STACK/docker-compose.core.yml"
log "كتابة compose الأساسي -> $CORE"
backup "$CORE"
cat >"$CORE" <<'YML'
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
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER -h 127.0.0.1 -p 5432"]
      interval: 10s
      timeout: 5s
      retries: 40

  neo4j:
    image: neo4j:5.22
    container_name: ffactory_neo4j
    env_file: [ ../.env ]
    environment:
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=1g
      - TZ=$${TZ}
    networks: [ ffactory_ffactory_net ]
    volumes: [ "neo4j_data:/data", "neo4j_logs:/logs" ]
    ports: [ "127.0.0.1:7474:7474", "127.0.0.1:7687:7687" ]
    healthcheck:
      test: ["CMD-SHELL","cypher-shell -u $$NEO4J_USER -p $$NEO4J_PASSWORD 'RETURN 1;' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 40

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
      retries: 40

  redis:
    image: redis:7
    container_name: ffactory_redis
    networks: [ ffactory_ffactory_net ]
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# 3) انتظار صحة من داخل الشبكة
WAIT_CORE="$SCRIPTS/wait-core.sh"
cat >"$WAIT_CORE" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
docker run --rm --network ffactory_ffactory_net python:3.11-alpine python - <<'PY'
import socket,sys
targets=[("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]
for h,p in targets:
    s=socket.socket(); s.settimeout(6)
    try: s.connect((h,p)); print(f"{h}:{p}=OK")
    except Exception as e: print(f"{h}:{p}=FAIL:{e}"); sys.exit(1)
PY
BASH
chmod +x "$WAIT_CORE"

# 4) مُنقذ Postgres حقيقي (single-user، بدون DO $$)
PG_RESC="$SCRIPTS/ff_pg_rescue.sh"
cat >"$PG_RESC" <<'RESC'
#!/usr/bin/env bash
set -Eeuo pipefail
PW="${PW:-Aa100200@@}"
CN="${CN:-ffactory_db}"
VOL="${VOL:-ffactory_postgres_data}"
IMG="${IMG:-postgres:16}"
VOL_DET="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null || true)"
[ -n "$VOL_DET" ] && VOL="$VOL_DET"
docker rm -f "$CN" >/dev/null 2>&1 || true
run(){ docker run --rm -u postgres -v "$VOL":/var/lib/postgresql/data "$IMG" \
  bash -lc "postgres --single -D \${PGDATA:-/var/lib/postgresql/data} template1 <<< \"$1\" >/dev/null 2>&1 || true"; }
run "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "CREATE ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "ALTER ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "CREATE DATABASE ffactory WITH OWNER ffadmin;"
RESC
chmod +x "$PG_RESC"

# 5) تشغيل الأساس
log "تشغيل الأساس (db/neo4j/minio/redis)"
docker compose --env-file "$FF/.env" -f "$CORE" up -d --build
log "انتظار الاستعداد من داخل الشبكة"
if ! bash "$WAIT_CORE"; then
  warn "فشل فحص الشبكة — إنقاذ Postgres وإعادة التشغيل"
  PW_REC=$(grep '^POSTGRES_PASSWORD=' "$FF/.env" | cut -d= -f2-)
  PW="${PW_REC}" bash "$PG_RESC"
  docker compose --env-file "$FF/.env" -f "$CORE" up -d
  bash "$WAIT_CORE"
fi

# 6) توليد تطبيقات وإعداد بنية نظيفة (ASR/NER/Correlation)
install -d -m 755 "$APPS/asr-engine" "$APPS/neural-core" "$APPS/correlation-engine"

# ASR
cat >"$APPS/asr-engine/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
requests>=2.31
numpy<2.0
soundfile
librosa>=0.10.1
ctranslate2>=4.3
faster-whisper>=1.0
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
_model=WhisperModel(ASR_MODEL, device="cpu", compute_type="int8")
@api.get("/health")
def health(): return {"status":"ok","model":ASR_MODEL}
class Inp(BaseModel):
    audio_url: str
    language: Optional[str]=None
@api.post("/transcribe")
def transcribe(inp: Inp):
    try:
        r=requests.get(inp.audio_url,timeout=30); r.raise_for_status()
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            f.write(r.content); f.flush()
            segs,_=_model.transcribe(f.name, language=inp.language or LANG)
            return {"text":"".join(s.text for s in segs).strip()}
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
sanitize_file "$APPS/asr-engine/Dockerfile"

# NER (Neural Core) — نموذج خفيف قابل للتشغيل
cat >"$APPS/neural-core/requirements.txt" <<'REQ'
fastapi>=0.110
uvicorn[standard]>=0.30
transformers>=4.44.0
torch>=2.4.1
REQ
cat >"$APPS/neural-core/app.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from transformers import pipeline
import os
api=FastAPI()
MODEL=os.getenv("NER_MODEL","dslim/bert-base-NER")  # خفيف كبداية
try:
    ner=pipeline("token-classification", model=MODEL, aggregation_strategy="simple")
    READY=True; ERR=""
except Exception as e:
    READY=False; ERR=str(e)
class Inp(BaseModel): text:str
@api.get("/health")
def health(): return {"ready":READY,"model":MODEL,"error":ERR or None}
@api.post("/ner")
def do(inp:Inp):
    if not READY: return {"error":"model not ready"}
    return {"entities": ner(inp.text)}
PY
cat >"$APPS/neural-core/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8000"]
DOCKER
sanitize_file "$APPS/neural-core/Dockerfile"

# Correlation Engine
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
@api.post("/etl")
def etl():
    with bolt() as drv, drv.session() as s:
        s.run("CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;")
    rows=[]
    try:
        with psycopg.connect(host=DBH, port=DBPORT, dbname=DB, user=DBU, password=DBP) as c:
            try: rows=c.execute("SELECT id, name FROM people LIMIT 100;").fetchall()
            except Exception: rows=[]
        if rows:
            with bolt() as drv, drv.session() as s:
                s.run("UNWIND $b AS r MERGE (p:Person {id:r.id}) SET p.name=r.name", b=[{"id":x[0],"name":x[1]} for x in rows])
        return {"loaded":len(rows)}
    except Exception as e:
        return {"error":str(e)}
PY
cat >"$APPS/correlation-engine/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python","-m","uvicorn","app:api","--host","0.0.0.0","--port","8080"]
DOCKER
sanitize_file "$APPS/correlation-engine/Dockerfile"

# 7) Compose للتطبيقات
APPS_YML="$STACK/docker-compose.apps.yml"
backup "$APPS_YML"
cat >"$APPS_YML" <<'YML'
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
      retries: 40

  neural-core:
    build: { context: ../apps/neural-core, dockerfile: Dockerfile }
    container_name: ffactory_nlp
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "nlp_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8000:8000" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  correlation-engine:
    build: { context: ../apps/correlation-engine, dockerfile: Dockerfile }
    container_name: ffactory_correlation
    env_file: [ ../.env ]
    environment:
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=$${POSTGRES_USER}
      - DB_PASSWORD=$${POSTGRES_PASSWORD}
      - DB_NAME=$${POSTGRES_DB}
      - NEO4J_URI=bolt://neo4j:7687
      - NEO4J_USER=$${NEO4J_USER}
      - NEO4J_PASSWORD=$${NEO4J_PASSWORD}
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:8170:8080" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# 8) تشغيل التطبيقات
log "بناء/تشغيل التطبيقات (ASR/NER/Correlation)"
docker compose --env-file "$FF/.env" -f "$APPS_YML" up -d --build || die "فشل بناء/تشغيل التطبيقات"

# 9) تلخيص الحالة
log "ملخص الحاويات:"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_' || true
log "فحص سريع:"
docker run --rm --network "$NET" -e PGPASSWORD="$(grep '^POSTGRES_PASSWORD=' "$FF/.env" | cut -d= -f2-)" postgres:16 \
  psql -h db -U ffadmin -d ffactory -c "SELECT 1;" >/dev/null 2>&1 && echo "DB OK" || echo "DB FAIL"
docker exec -i ffactory_neo4j cypher-shell -u "$(grep '^NEO4J_USER=' "$FF/.env" | cut -d= -f2-)" -p "$(grep '^NEO4J_PASSWORD=' "$FF/.env" | cut -d= -f2-)" 'RETURN 1;' >/dev/null 2>&1 && echo "NEO4J OK" || echo "NEO4J FAIL"
echo "ASR:  http://127.0.0.1:8086/health"
echo "NER:  http://127.0.0.1:8000/health"
echo "ETL:  curl -X POST http://127.0.0.1:8170/etl"
