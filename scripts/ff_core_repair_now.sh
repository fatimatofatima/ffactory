#!/usr/bin/env bash
set -uo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
ROOT=/opt/ffactory
ENVF=$ROOT/.env
STACK=$ROOT/stack/docker-compose.core.yml
LOG=$ROOT/logs/ff_core_repair.$(date +%F_%H%M%S).log
pw="Aa100200"
log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG"; }
safe(){ "$@" || { log "WARN: $*"; return 0; }; }

# 1) .env موحّد
install -d -m 755 "$ROOT/logs"
[ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
up(){ grep -qE "^$1=" "$ENVF" && sed -i -E "s|^($1)=.*|\1=$2|" "$ENVF" || echo "$1=$2" >>"$ENVF"; }
up POSTGRES_USER ffactory
up POSTGRES_DB   ffactory
up POSTGRES_PASSWORD "$pw"
up NEO4J_PASSWORD     "$pw"
up MINIO_ROOT_USER    ffroot
up MINIO_ROOT_PASSWORD "$pw"
up REDIS_PASSWORD     "$pw"

# 2) compose أساسي بصحة كاملة
if [ ! -s "$STACK" ]; then install -d -m 755 "$(dirname "$STACK")"; fi
cat >"$STACK" <<YML
name: ffactory
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      TZ: Asia/Riyadh
    ports: ["127.0.0.1:5433:5432"]
    volumes: [ "db_data:/var/lib/postgresql/data" ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 3s
      timeout: 3s
      retries: 30

  redis:
    image: redis:7
    command: ["redis-server","--appendonly","yes","--requirepass","\${REDIS_PASSWORD}"]
    environment: { LANG: C.UTF-8 }
    ports: ["127.0.0.1:6379:6379"]
    restart: unless-stopped
    healthcheck:
      test: ["CMD","redis-cli","-a","\${REDIS_PASSWORD}","ping"]
      interval: 3s
      timeout: 3s
      retries: 30

  neo4j:
    image: neo4j:5
    environment:
      NEO4J_AUTH: neo4j/\${NEO4J_PASSWORD}
      NEO4J_server_memory_heap_initial__size: 512m
      NEO4J_server_memory_heap_max__size: 1g
    ports: ["127.0.0.1:7474:7474","127.0.0.1:7687:7687"]
    volumes: [ "neo4j_data:/data" ]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","cypher-shell -u neo4j -p \${NEO4J_PASSWORD} 'RETURN 1' || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 36

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    ports: ["127.0.0.1:9000:9000","127.0.0.1:9001:9001"]
    volumes: [ "minio_data:/data" ]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL","wget -qO- http://127.0.0.1:9000/minio/health/ready >/dev/null"]
      interval: 3s
      timeout: 3s
      retries: 40
volumes:
  db_data: {}
  neo4j_data: {}
  minio_data: {}
YML

# 3) تنزيل نظيف ثم تشغيل وانتظار
log "down old"
safe docker compose -f "$STACK" down
log "up --wait"
if ! docker compose -f "$STACK" --env-file "$ENVF" up -d --quiet-pull --wait; then
  log "compose reported failure"
fi

# 4) فحص الحالة
log "ps"
docker compose -f "$STACK" ps | tee -a "$LOG"

# 5) إن تعطل neo4j أو minio اطبع اللوج
for s in neo4j minio; do
  st=$(docker compose -f "$STACK" ps --status running -q $s || true)
  [ -n "$st" ] || { log "logs <$s>"; safe docker compose -f "$STACK" logs --no-color --tail=200 $s | tee -a "$LOG"; }
done

# 6) صحّة نهائية
log "health checks"
DB=$(docker compose -f "$STACK" ps -q db || true)
RD=$(docker compose -f "$STACK" ps -q redis || true)
NJ=$(docker compose -f "$STACK" ps -q neo4j || true)
MN=$(docker compose -f "$STACK" ps -q minio || true)
[ -n "$DB" ] && docker exec "$DB" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" | tee -a "$LOG" || true
[ -n "$RD" ] && docker exec "$RD" redis-cli -a "$pw" ping | tee -a "$LOG" || true
[ -n "$NJ" ] && docker exec "$NJ" cypher-shell -u neo4j -p "$pw" 'RETURN 1;' | tail -1 | tee -a "$LOG" || true
[ -n "$MN" ] && curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null && echo "minio: ready" | tee -a "$LOG" || echo "minio: not ready" | tee -a "$LOG"

log "done -> $LOG"
exit 0
