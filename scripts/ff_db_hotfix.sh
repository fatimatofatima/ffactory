#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مثبت"

FF=/opt/ffactory
STACK=$FF/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
install -d -m 755 "$STACK"

# 1) Override آمن لخدمة db
# - مصادقة trust للاختبار السريع
# - healthcheck بـ pg_isready
# - نشر 5433:5432 للمضيف. داخل الشبكة استخدم db:5432
DBFIX="$STACK/docker-compose.db-fix.yml"
cat >"$DBFIX" <<'YAML'
services:
  db:
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-ffadmin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-ffadmin123}
      POSTGRES_DB: ${POSTGRES_DB:-ffactory}
      POSTGRES_HOST_AUTH_METHOD: ${POSTGRES_HOST_AUTH_METHOD:-trust}
      TZ: ${TZ:-Asia/Kuwait}
    # لا تغيّر المنفذ الداخلي 5432. عدّل ربط المضيف فقط إذا لزم.
    ports:
      - "${PG_HOST_PORT:-5433}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-ffadmin} -d ${POSTGRES_DB:-ffactory} -h 127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    command: ["postgres","-c","max_connections=200","-c","shared_buffers=256MB"]
YAML

# 2) تجميع ملفات Compose كصفيف لتفادي خطأ open /root/-f
declare -a ARGS=()
while IFS= read -r -d '' f; do
  ARGS+=(-f "$f")
done < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' -print0 | sort -z)
# أضف db-fix أخيراً
ARGS+=(-f "$DBFIX")
((${#ARGS[@]})) || die "لا توجد ملفات compose في $STACK"

export COMPOSE_IGNORE_ORPHANS=1

# 3) إعادة نشر db فقط أولاً
log "إعادة إنشاء db فقط."
docker compose -p "$PROJECT" "${ARGS[@]}" rm -fs db >/dev/null 2>&1 || true
# اختياري لمسح البيانات نهائياً: NUKE_DB=1 ./ff_db_hotfix.sh
if [[ "${NUKE_DB:-0}" = "1" ]]; then
  warn "سيتم حذف بيانات Postgres نهائياً."
  docker compose -p "$PROJECT" "${ARGS[@]}" down -v db || true
  # حاول حذف مجلد bind إن وُجد
  VPATH=$(docker volume inspect "${PROJECT}_postgres_data" -f '{{.Mountpoint}}' 2>/dev/null || true)
  [[ -n "$VPATH" ]] && rm -rf "$VPATH" || true
fi

log "تشغيل db."
docker compose -p "$PROJECT" "${ARGS[@]}" up -d db

# 4) انتظار صحة db
cid=$(docker compose -p "$PROJECT" "${ARGS[@]}" ps -q db)
[[ -n "$cid" ]] || die "لم يتم إيجاد حاوية db."
for i in {1..60}; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "none")
  if [[ "$st" == "healthy" ]]; then
    log "db healthy."
    break
  fi
  sleep 2
done
st_now=$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "none")
if [[ "$st_now" != "healthy" ]]; then
  warn "db لم يصل لحالة healthy."
  echo "== db logs =="
  docker logs --tail=200 "$cid" || true
  echo "== inspect health =="
  docker inspect -f '{{json .State.Health}}' "$cid" || true
  exit 1
fi

# 5) تشغيل الخدمات التي كانت موقوفة بسبب db
log "تشغيل الخدمات التابعة: frontend-dashboard و api-gateway وغيرها."
docker compose -p "$PROJECT" "${ARGS[@]}" up -d frontend-dashboard api-gateway || true

# 6) ملخص سريع
sleep 8
log "حالة الحاويات ضمن المشروع:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

# فحص أساسي
if command -v curl >/dev/null; then
  curl -sf http://127.0.0.1:9090/-/ready >/dev/null && log "Prometheus READY" || warn "Prometheus NOT ready"
  for p in 3001 3000; do
    if curl -sf "http://127.0.0.1:$p/health" >/dev/null; then log "Frontend OK on :$p"; break; fi
  done
fi

log "انتهى ff_db_hotfix."
