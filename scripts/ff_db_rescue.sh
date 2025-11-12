#!/usr/bin/env bash
set -Eeuo pipefail
log(){ echo "[+] $*"; } ; warn(){ echo "[!] $*" >&2; } ; die(){ echo "[x] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مثبت"

FF=/opt/ffactory
STACK=$FF/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
install -d -m 755 "$STACK"

# 0) كشف ازدحام المنافذ
is_busy(){ ss -ltnH "( sport = :$1 )" | grep -q . ; }
PG_HOST_PORT="${PG_HOST_PORT:-5433}"
PORTS_FLAG=1
if is_busy "$PG_HOST_PORT"; then
  warn "المنفذ $PG_HOST_PORT مشغول. سأعطّل النشر على المضيف مؤقتاً."
  PORTS_FLAG=0
fi

# 1) ملف override لـ db مع صحة pg_isready. ربط المنفذ اختياري.
DBFIX="$STACK/docker-compose.db-fix.yml"
{
cat <<'YAML'
services:
  db:
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-ffadmin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-ffadmin123}
      POSTGRES_DB: ${POSTGRES_DB:-ffactory}
      POSTGRES_HOST_AUTH_METHOD: ${POSTGRES_HOST_AUTH_METHOD:-trust}
      TZ: ${TZ:-Asia/Kuwait}
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U ${POSTGRES_USER:-ffadmin} -d ${POSTGRES_DB:-ffactory} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    command: ["postgres","-c","max_connections=200","-c","shared_buffers=256MB"]
YAML
if [[ $PORTS_FLAG -eq 1 ]]; then
  echo '    ports:'
  echo "      - \"127.0.0.1:${PG_HOST_PORT}:5432\""
fi
} >"$DBFIX"

# 2) تجميع كل ملفات compose كصفيف
declare -a ARGS=()
while IFS= read -r -d '' f; do ARGS+=(-f "$f"); done < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' ! -name 'docker-compose.db-fix.yml' -print0 | sort -z)
ARGS+=(-f "$DBFIX")
((${#ARGS[@]})) || die "لا توجد ملفات compose في $STACK"

export COMPOSE_IGNORE_ORPHANS=1

# 3) إزالة وإنشاء db فقط
log "إعادة إنشاء db مع override."
docker compose -p "$PROJECT" "${ARGS[@]}" rm -fs db >/dev/null 2>&1 || true
docker compose -p "$PROJECT" "${ARGS[@]}" up -d db

# 4) انتظار الصحة
CID="$(docker compose -p "$PROJECT" "${ARGS[@]}" ps -q db)"
[[ -n "$CID" ]] || die "لم تُنشأ حاوية db"
for i in {1..60}; do
  st="$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo none)"
  [[ "$st" == "healthy" ]] && break
  sleep 2
done
st="$(docker inspect -f '{{.State.Health.Status}}' "$CID" 2>/dev/null || echo none)"
if [[ "$st" != "healthy" ]]; then
  echo "== db logs =="; docker logs --tail=200 "$CID" || true
  echo "== inspect =="; docker inspect -f '{{json .State.Health}}' "$CID" || true
  die "db لم يصل إلى healthy"
fi
log "db healthy."

# 5) تشغيل الخدمات التابعة التي كانت Created
log "تشغيل frontend-dashboard و api-gateway."
docker compose -p "$PROJECT" "${ARGS[@]}" up -d frontend-dashboard api-gateway || true

# 6) ملخص سريع
sleep 6
log "حالة الحاويات:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

# 7) فحوص أساسية
if command -v curl >/dev/null; then
  curl -sf http://127.0.0.1:9090/-/ready >/dev/null && log "Prometheus READY" || warn "Prometheus NOT ready"
  for p in 3001 3000; do
    if curl -sf "http://127.0.0.1:$p/health" >/dev/null; then log "Frontend OK on :$p"; break; fi
  done
fi

log "انتهى ff_db_rescue."
