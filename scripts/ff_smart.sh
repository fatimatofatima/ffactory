#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/ffactory
STACK="$ROOT/stack"
LOGD="$ROOT/logs"
ENVF="$ROOT/.env"
NET="ffactory_ffactory_net"

mkdir -p "$STACK" "$LOGD"
LOG="$LOGD/ff_smart.$(date +%F_%H%M%S).log"

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG"; }
ok(){ log "✅ $*"; }
warn(){ log "⚠️ $*"; }
die(){ log "❌ $*"; exit 1; }

# 0) فحوصات
for b in docker curl nc; do
  command -v "$b" >/dev/null 2>&1 || die "الأمر $b غير موجود"
done

# 1) شبكة خارجية ثابتة
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  docker network create "$NET" >/dev/null
  ok "أنشأنا الشبكة: $NET"
else
  ok "الشبكة جاهزة: $NET"
fi

# 2) .env
if [ ! -f "$ENVF" ]; then
  PW="$(openssl rand -hex 12 2>/dev/null || uuidgen | tr -d '-')"
  cat > "$ENVF" <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$PW
POSTGRES_DB=ffactory
REDIS_PASSWORD=$PW
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=$PW
NEO4J_PASSWORD=$PW
EOF
  ok "أنشأنا $ENVF"
fi
set -a; . "$ENVF"; set +a

# 3) core compose
cat > "$STACK/docker-compose.core.yml" <<EOF
services:
  db:
    image: postgres:15-alpine
    container_name: ffactory_db
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    networks:
      - ffnet
    ports:
      - "127.0.0.1:5433:5432"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${POSTGRES_USER} -h 127.0.0.1 || exit 1"]
      interval: 5s
      retries: 30

  redis:
    image: redis:7-alpine
    container_name: ffactory_redis
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    networks:
      - ffnet
    ports:
      - "127.0.0.1:6379:6379"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","redis-cli -a ${REDIS_PASSWORD} ping | grep -q PONG"]
      interval: 5s
      retries: 30

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    command: ["server","/data","--console-address",":9001"]
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    networks:
      - ffnet
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","curl -fs http://127.0.0.1:9000/minio/health/live >/dev/null"]
      interval: 10s
      retries: 30

  neo4j:
    image: neo4j:5
    container_name: ffactory_neo4j
    environment:
      NEO4J_AUTH: "neo4j/${NEO4J_PASSWORD}"
      NEO4J_PLUGINS: '["apoc"]'
    networks:
      - ffnet
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","curl -fs http://127.0.0.1:7474/ >/dev/null"]
      interval: 10s
      retries: 30

networks:
  ffnet:
    external: true
    name: ${NET}
EOF
ok "كتبنا core"

# 4) apps compose (نسخ وهمية عشان الصحة)
cat > "$STACK/docker-compose.apps.yml" <<EOF
services:
  vision:
    image: ealen/echo-server
    container_name: ffactory_vision
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8081:8080"]
    restart: unless-stopped

  media:
    image: ealen/echo-server
    container_name: ffactory_media_forensics
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8082:8080"]
    restart: unless-stopped

  hashset:
    image: ealen/echo-server
    container_name: ffactory_hashset
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8083:8080"]
    restart: unless-stopped

  asr:
    image: ealen/echo-server
    container_name: ffactory_asr
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8086:8080"]
    restart: unless-stopped

  nlp:
    image: ealen/echo-server
    container_name: ffactory_nlp
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8000:8080"]
    restart: unless-stopped

  correlation:
    image: ealen/echo-server
    container_name: ffactory_correlation
    environment:
      PORT: 8080
    networks: [ffnet]
    ports: ["127.0.0.1:8170:8080"]
    restart: unless-stopped

networks:
  ffnet:
    external: true
    name: ${NET}
EOF
ok "كتبنا apps"

# 5) تشغيل
log "تشغيل CORE…"
docker compose -f "$STACK/docker-compose.core.yml" up -d --remove-orphans

log "تشغيل APPS…"
docker compose -f "$STACK/docker-compose.apps.yml" up -d --remove-orphans

# 6) تقرير
log "===== الحالة النهائية ====="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true
log "ملف اللوج: $LOG"
