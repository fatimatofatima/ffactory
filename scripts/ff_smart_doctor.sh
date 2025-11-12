#!/usr/bin/env bash
# ff_smart_doctor.sh  — فحص + تهيئة + تشغيل + تقرير
# يعمل بلا توقف؛ كل خطوة تُبلِّغ حالتها وتكمل حتى مع الإخفاقات.

set -uo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
ROOT=/opt/ffactory
STACK_DIR=$ROOT/stack
COMPOSE_FILE=$STACK_DIR/docker-compose.core.yml
ENVF=$ROOT/.env
NET=ffactory_default
BACK=$ROOT/backups
LOG=$ROOT/logs/ff_smart_doctor.$(date +%F).log

log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG"; }
has(){ command -v "$1" >/dev/null 2>&1; }
gen_secret(){ has openssl && openssl rand -hex 16 || date +%s%N; }
add_env(){ grep -qE "^$1=" "$ENVF" 2>/dev/null || { echo "$1=$2" >>"$ENVF"; log "ENV add: $1"; }; }
read_env(){ set -a; [ -f "$ENVF" ] && . "$ENVF"; set +a; }

safe(){ "$@" || log "WARN: failed: $*"; }

section(){ echo; log "==== $* ===="; }

# 0) أساسيات النظام
section "bootstrap"
safe install -d -m 755 "$STACK_DIR" "$ROOT/apps" "$ROOT/data" "$ROOT/logs" "$ROOT/audit" "$ROOT/volumes" "$ROOT/reports"
if ! has docker; then log "ERROR: docker مطلوب"; exit 1; fi
if ! docker compose version >/dev/null 2>&1; then log "ERROR: docker compose مطلوب"; exit 1; fi

# 1) ملف البيئة
section ".env"
[ -f "$ENVF" ] || safe install -m 600 /dev/null "$ENVF"
add_env TZ "Asia/Riyadh"
add_env POSTGRES_USER "ffactory"
add_env POSTGRES_PASSWORD "PG_$(gen_secret)"
add_env POSTGRES_DB "ffactory"
add_env NEO4J_PASSWORD "NEO_$(gen_secret)"
add_env MINIO_ROOT_USER "ffroot"
add_env MINIO_ROOT_PASSWORD "MINIO_$(gen_secret)"
read_env
log "ENV ready"

# 2) docker-compose.core.yml إذا كان مفقودًا نكتبه بصحة كاملة
if [ ! -s "$COMPOSE_FILE" ]; then
  section "write compose (core)"
  cat >"$COMPOSE_FILE" <<YML
name: ffactory
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      TZ: \${TZ}
    volumes: [ "db_data:/var/lib/postgresql/data" ]
    ports: [ "127.0.0.1:5433:5432" ]
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 3s
      timeout: 3s
      retries: 20

  redis:
    image: redis:7-alpine
    command: ["redis-server","--appendonly","yes"]
    environment: { LANG: C.UTF-8 }
    ports: [ "127.0.0.1:6379:6379" ]
    restart: unless-stopped
    healthcheck:
      test: ["CMD","redis-cli","ping"]
      interval: 3s
      timeout: 3s
      retries: 20

  neo4j:
    image: neo4j:5
    environment:
      NEO4J_AUTH: neo4j/\${NEO4J_PASSWORD}
      NEO4J_server_memory_heap_initial__size: 512m
      NEO4J_server_memory_heap_max__size: 1g
    volumes: [ "neo4j_data:/data" ]
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
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
    volumes: [ "minio_data:/data" ]
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
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
  log "compose written"
fi

# 3) تشغيل الـ core مع انتظار صحي
section "compose up --wait"
safe docker compose -f "$COMPOSE_FILE" --env-file "$ENVF" up -d --quiet-pull --wait
safe docker compose -f "$COMPOSE_FILE" ps

# 4) معرّفات الحاويات
DB_CID=$(docker compose -f "$COMPOSE_FILE" ps -q db || true)
RD_CID=$(docker compose -f "$COMPOSE_FILE" ps -q redis || true)
NJ_CID=$(docker compose -f "$COMPOSE_FILE" ps -q neo4j || true)
MN_CID=$(docker compose -f "$COMPOSE_FILE" ps -q minio || true)

# 5) استعادة قاعدة البيانات تلقائيًا إذا كانت فارغة ووجدنا أحدث نسخة
section "postgres check + optional restore"
DB_TABLES=$(safe docker exec "$DB_CID" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SELECT count(*) FROM pg_tables WHERE schemaname='public';" | tr -d '\r' || echo 0)
LATEST_SQL=$(ls -1t "$BACK"/db_*.sql.gz 2>/dev/null | head -1 || true)
if [ "${DB_TABLES:-0}" = "0" ] && [ -n "$LATEST_SQL" ]; then
  log "restore from $LATEST_SQL"
  safe sh -c "zcat \"$LATEST_SQL\" | docker exec -i \"$DB_CID\" psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""
else
  log "restore skipped (tables=$DB_TABLES, file=${LATEST_SQL:-none})"
fi

# 6) قيود neo4j + فهارس
section "neo4j constraints"
safe docker exec -i "$NJ_CID" cypher-shell -u neo4j -p "$NEO4J_PASSWORD" <<'CYPH'
CREATE CONSTRAINT person_id IF NOT EXISTS FOR (p:Person) REQUIRE p.id IS UNIQUE;
CREATE CONSTRAINT file_sha IF NOT EXISTS FOR (f:File) REQUIRE f.sha256 IS UNIQUE;
CREATE INDEX event_ts IF NOT EXISTS FOR (e:Event) ON (e.ts);
CYPH

# 7) buckets أساسية في MinIO
section "minio buckets"
safe docker run --rm --network="$NET" minio/mc sh -c "
  mc alias set local http://minio:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} &&
  mc mb -p local/raw || true &&
  mc mb -p local/decoded || true &&
  mc mb -p local/reports || true &&
  mc ls local >/dev/null
"

# 8) تقرير الحالة
section "health report"
safe docker exec "$DB_CID"    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
safe docker exec "$RD_CID"    redis-cli ping
safe docker exec "$NJ_CID"    cypher-shell -u neo4j -p "$NEO4J_PASSWORD" 'RETURN 1;'
safe wget -qO- http://127.0.0.1:9000/minio/health/ready >/dev/null && log "minio: ready" || log "minio: not ready"

# إحصاءات سريعة
section "quick stats"
safe docker exec -i "$DB_CID" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" | awk '{print "pg_tables:",$1}' | xargs -I{} bash -c 'log "{}"'
safe docker exec -i "$NJ_CID" cypher-shell -u neo4j -p "$NEO4J_PASSWORD" 'MATCH (n) RETURN count(n);' | tail -1 | awk '{print "neo4j_nodes:",$1}' | xargs -I{} bash -c 'log "{}"'

section "done"
log "log file: $LOG"
exit 0
