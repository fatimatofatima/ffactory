#!/usr/bin/env bash
set -Eeuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
PW="Aa100200"

ROOT=/opt/ffactory
ENVF=$ROOT/.env
COMPOSE=$ROOT/stack/docker-compose.core.yml
NET=ffactory_default
LOG=$ROOT/logs/ff_set_test_pw.$(date +%F_%H%M%S).log
log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG"; }
upsert(){ grep -qE "^$1=" "$ENVF" 2>/dev/null && sed -i -E "s|^($1)=.*|\1=$2|" "$ENVF" || echo "$1=$2" >>"$ENVF"; }

[ -f "$ENVF" ] || { log "ERROR: $ENVF غير موجود"; exit 1; }
set -a; . "$ENVF"; set +a

# 1) عدّل .env إلى كلمة السر الموحدة
log "update .env"
upsert POSTGRES_PASSWORD "$PW"
upsert NEO4J_PASSWORD     "$PW"
upsert MINIO_ROOT_PASSWORD "$PW"
upsert REDIS_PASSWORD     "$PW"
# لتسهيل استخدام MinIO كمستخدم غير الجذر في التطبيقات:
upsert MINIO_ACCESS_KEY   "ffactory"
upsert MINIO_SECRET_KEY   "$PW"

# 2) أعِد كتابة redis في compose ليستخدم requirepass + صحح healthcheck
log "patch compose for redis auth"
awk '
  {print_line=1}
  /redis:/ { inredis=1 }
  inredis && /command:/ { print "    command: [\"redis-server\",\"--appendonly\",\"yes\",\"--requirepass\",\"${REDIS_PASSWORD}\"]"; getline; print_line=0 }
  inredis && /healthcheck:/ { print; getline; print "      test: [\"CMD\",\"redis-cli\",\"-a\",\"${REDIS_PASSWORD}\",\"ping\"]"; inredis=0; next }
  { if(print_line) print }
' "$COMPOSE" > "$COMPOSE.tmp" && mv "$COMPOSE.tmp" "$COMPOSE"

# 3) أعِد تشغيل الـ core مع الانتظار
log "compose up --wait"
docker compose -f "$COMPOSE" --env-file "$ENVF" up -d --quiet-pull --wait

# 4) احصل على IDs
DB=$(docker compose -f "$COMPOSE" ps -q db)
NJ=$(docker compose -f "$COMPOSE" ps -q neo4j)
RD=$(docker compose -f "$COMPOSE" ps -q redis)
MN=$(docker compose -f "$COMPOSE" ps -q minio)

# 5) غيّر كلمة مرور Postgres داخل القاعدة إن أمكن
log "postgres: ALTER USER to new password"
if [ -n "${POSTGRES_USER:-}" ] && [ -n "${POSTGRES_DB:-}" ]; then
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -c "ALTER USER \"$POSTGRES_USER\" WITH PASSWORD '$PW';" || log "WARN: ALTER USER قد يكون مطبقًا مسبقًا"
fi

# 6) غيّر كلمة مرور neo4j للمستخدم neo4j
log "neo4j: ALTER CURRENT USER password"
docker exec "$NJ" cypher-shell -u neo4j -p "$PW" 'RETURN 1;' >/dev/null 2>&1 || \
docker exec "$NJ" cypher-shell -u neo4j -p "${NEO4J_PASSWORD:-$PW}" "ALTER CURRENT USER SET PASSWORD FROM '${NEO4J_PASSWORD:-$PW}' TO '$PW';" || \
log "WARN: تغيير كلمة سر neo4j فشل أو غير مطلوب"

# 7) أنشئ مستخدم MinIO للاختبار بكلمة السر الموحدة وأعطه readwrite
log "minio: create test user ffactory"
docker run --rm --network="$NET" minio/mc sh -c "
  mc alias set local http://minio:9000 ${MINIO_ROOT_USER:-ffroot} ${MINIO_ROOT_PASSWORD:-$PW} &&
  mc admin user add local ${MINIO_ACCESS_KEY:-ffactory} ${MINIO_SECRET_KEY:-$PW} || true &&
  mc admin policy attach local readwrite --user ${MINIO_ACCESS_KEY:-ffactory} || true
" || log "WARN: إعداد MinIO فشل"

# 8) اختبارات صحة باستخدام كلمة السر الموحدة
log "health checks"
docker exec "$DB" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" | tee -a "$LOG" || true
docker exec "$RD" redis-cli -a "$PW" ping | tee -a "$LOG" || true
docker exec "$NJ" cypher-shell -u neo4j -p "$PW" 'RETURN 1;' | tail -1 | tee -a "$LOG" || true
docker run --rm --network="$NET" minio/mc sh -c "
  mc alias set local http://minio:9000 ${MINIO_ACCESS_KEY:-ffactory} ${MINIO_SECRET_KEY:-$PW} &&
  mc ls local >/dev/null && echo MINIO:OK
" | tee -a "$LOG" || true

log "done. unified password set to: $PW"
log "log file: $LOG"
