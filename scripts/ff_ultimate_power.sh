#!/usr/bin/env bash
set -Eeuo pipefail
log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }
die(){ echo "[err] $*" >&2; exit 1; }

FF=/opt/ffactory
STACK=$FF/stack
APPS=$FF/apps
SCRIPTS=$FF/scripts
NET=ffactory_ffactory_net

# ---------- 0) بنية المجلدات ----------
install -d -m 755 "$FF" "$STACK" "$APPS" "$SCRIPTS" "$FF/data" "$FF/logs" "$FF/backups"

# ---------- 1) أسرار وآمن ----------
# لا تُضمّن أي مفاتيح حساسة داخل السكربت. عدّل القيم الفارغة يدويًا لاحقًا.
PG_PASS="$(openssl rand -base64 32)"
NEO4J_PASS="$(openssl rand -base64 32)"
JWT_SECRET="$(openssl rand -base64 64)"
ENC_KEY="$(openssl rand -base64 32)"
HFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"   # متروك فارغًا افتراضيًا
OPENAI_KEY="${OPENAI_API_KEY:-}"       # متروك فارغًا افتراضيًا

cat >"$FF/.env" <<EOF
TZ=Asia/Kuwait
LANG=ar_EG.UTF-8

# Postgres
POSTGRES_DB=ffactory
POSTGRES_USER=ffadmin
POSTGRES_PASSWORD=$PG_PASS
# حافظ على منفذ الحاوية 5432، وانشره على 5433 على المضيف
PGPORT=5432

# Neo4j
NEO4J_AUTH=neo4j/$NEO4J_PASS

# MinIO
MINIO_ROOT_USER=ffminioadmin
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)

# اختياري
HUGGINGFACE_TOKEN=$HFACE_TOKEN
OPENAI_API_KEY=$OPENAI_KEY

JWT_SECRET=$JWT_SECRET
ENCRYPTION_KEY=$ENC_KEY

COMPOSE_PROJECT_NAME=ffactory
EOF
chmod 600 "$FF/.env"

# ---------- 2) شبكة موحّدة ----------
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# ---------- 3) Compose: البنية الأساسية ----------
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
    environment:
      - TZ=${TZ}
    command: [ "postgres", "-p", "${PGPORT}" ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "postgres_data:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:5433:5432" ]   # المضيف 5433 -> داخل الحاوية 5432
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

# ---------- 4) Compose: محركات الذكاء ----------
# ملاحظات:
# - ألغيت deploy:devices لتجنّب سلوك غير مدعوم خارج Swarm.
# - المنافذ مميّزة لتجنّب التعارض.
cat >"$STACK/docker-compose.ai.yml" <<'YML'
version: "3.9"
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { asr_cache: {}, nlp_cache: {}, vision_cache: {} }

services:
  asr-engine:
    build: { context: ../apps/asr-engine, dockerfile: Dockerfile }
    container_name: ffactory_asr
    env_file: [ ../.env ]
    environment:
      - MODEL_SIZE=medium
      - LANGUAGE=ar
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
    volumes: [ "nlp_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8000:8000" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 30

  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ "vision_cache:/root/.cache" ]
    ports: [ "127.0.0.1:8081:8081" ]
    healthcheck:
      test: ["CMD","curl","-fsS","http://127.0.0.1:8081/health"]
      interval: 10s
      timeout: 5s
      retries: 30
YML

# ---------- 5) Compose: المراقبة ----------
install -d -m 755 "$STACK/monitoring"
cat >"$STACK/monitoring/prometheus.yml" <<'PROM'
global: { scrape_interval: 15s }
scrape_configs:
  - job_name: 'prometheus'
    static_configs: [ { targets: ['prometheus:9090'] } ]
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
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=200h'
      - '--web.enable-lifecycle'
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
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    volumes: [ grafana_data:/var/lib/grafana ]
    ports: [ "127.0.0.1:3003:3000" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://127.0.0.1:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 30
YML

# ---------- 6) سكربت انتظار داخل الشبكة ----------
cat >"$SCRIPTS/wait-for-core.sh" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
NET=ffactory_ffactory_net
docker run --rm --network "$NET" curlimages/curl:8.10.1 sh -lc '
  set -e
  # Postgres TCP
  python - <<PY
import socket,sys
for host,port in [("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]:
    s=socket.socket(); s.settimeout(5)
    try: s.connect((host,port)); print(f"{host}:{port}=OK")
    except Exception as e: print(f"{host}:{port}=FAIL:{e}"); sys.exit(1)
PY
  # MinIO HTTP
  curl -fsS http://ffactory_minio:9000/minio/health/live >/dev/null
'
BASH
chmod +x "$SCRIPTS/wait-for-core.sh"

# ---------- 7) قوالب Dockerfile للتطبيقات (مختصرة) ----------
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
# ملاحظة: وفّر app.py بنفس هيكل FastAPI السابق لديك.

# NLP
install -d -m 755 "$APPS/neural-core"
cat >"$APPS/neural-core/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python","main.py"]
DOCKER

# Vision
install -d -m 755 "$APPS/vision-engine"
cat >"$APPS/vision-engine/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8081
CMD ["python","main.py"]
DOCKER

# ---------- 8) تشغيل ----------
log "bring up core"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.core.yml" up -d --build
log "wait core readiness (inside docker network)"
bash "$SCRIPTS/wait-for-core.sh"

log "bring up AI engines"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.ai.yml" up -d --build || true

log "bring up monitoring"
docker compose --env-file "$FF/.env" -f "$STACK/docker-compose.monitoring.yml" up -d --build || true

# ---------- 9) صحة نهائية ----------
log "final health snapshot"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '^ffactory_|^ff_asr' || true
echo "--- checks ---"
docker exec -i ffactory_neo4j cypher-shell -u neo4j -p "${NEO4J_PASS}" 'RETURN 1;' || echo "neo4j: check failed"
docker run --rm --network "$NET" -e PGPASSWORD="$PG_PASS" postgres:16 psql -h db -U ffadmin -d ffactory -c "SELECT 1;" || echo "db: check failed"
echo "ok."
