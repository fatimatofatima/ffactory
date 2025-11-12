#!/usr/bin/env bash
set -Eeuo pipefail
echo "👑 FFactory KING CONTROL - System Under Your Command 👑"

FF=/opt/ffactory
CORE="$FF/stack/docker-compose.core.yml"
APPS="$FF/stack/docker-compose.apps.ext.yml"
ENVF="$FF/.env"

# كلمة السر الافتراضية للاختبار (يمكن تمرير PW_OVERRIDE لتعديلها)
PW="${PW_OVERRIDE:-Aa100200}"

log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }
ok(){ log "✅ $*"; }
warn(){ log "⚠️  $*"; }
die(){ log "❌ $*"; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "أمر مفقود: $1"; }

dockerx(){ docker "$@" 2>&1 | sed 's/Warning: Using a password.*//'; }

ensure_env(){
  [ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
  up(){ grep -qE "^$1=" "$ENVF" && sed -i -E "s|^($1)=.*|\1=$2|" "$ENVF" || echo "$1=$2" >>"$ENVF"; }
  up TZ Asia/Riyadh
  up POSTGRES_USER ffactory
  up POSTGRES_DB ffactory
  up POSTGRES_PASSWORD "$PW"
  up REDIS_PASSWORD "$PW"
  up MINIO_ROOT_USER ffroot
  up MINIO_ROOT_PASSWORD "$PW"
  up NEO4J_PASSWORD "$PW"
}

hc_core(){
  local DB RD NJ MN
  DB=$(docker compose -f "$CORE" ps -q db || true)
  RD=$(docker compose -f "$CORE" ps -q redis || true)
  NJ=$(docker compose -f "$CORE" ps -q neo4j || true)
  MN=$(docker compose -f "$CORE" ps -q minio || true)

  echo "=== HEALTH CHECK ==="
  [ -n "$DB" ] && docker exec "$DB" pg_isready -U ffactory -d ffactory || true
  [ -n "$RD" ] && docker exec "$RD" redis-cli -a "$PW" ping || true
  [ -n "$NJ" ] && docker exec "$NJ" cypher-shell -u neo4j -p "$PW" 'RETURN 1;' || true

  # MinIO: نفحص من الـhost لأن healthcheck داخل الصورة قد يكون مضروب
  if curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null; then
    echo "minio: ready"
  else
    echo "minio: not ready"
  fi

  echo
  echo "=== UNHEALTHY LOGS (neo4j/minio) ==="
  for s in neo4j minio; do
    id=$(docker compose -f "$CORE" ps -q $s || true)
    [ -n "$id" ] || continue
    st=$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo none)
    if [ "$st" != "healthy" ]; then
      echo "--- $s ---"
      docker compose -f "$CORE" logs --tail=200 $s || true
    fi
  done
}

fix_minio(){
  log "🔧 MinIO: restart + probe"
  docker compose -f "$CORE" restart minio || true
  sleep 5

  # استعلم مباشرة من السيرفر
  if curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null; then
    ok "MinIO HTTP ready على 9000"
  else
    warn "MinIO لم يرد على /minio/health/ready — راجع اللوج"
    docker compose -f "$CORE" logs --tail=120 minio || true
  fi

  # تهيئة مستخدم/سلال عبر minio/mc بدون 'sh -c'
  NET=$(docker network ls --format '{{.Name}}' | awk '/ffactory/{print;exit}')
  [ -z "$NET" ] && NET=ffactory_default
  export MC_HOST_local="http://$(grep -E '^MINIO_ROOT_USER=' "$ENVF" | cut -d= -f2):$(grep -E '^MINIO_ROOT_PASSWORD=' "$ENVF" | cut -d= -f2)@minio:9000"

  docker run --rm --network "$NET" -e MC_HOST_local="$MC_HOST_local" minio/mc ls local >/dev/null 2>&1 && ok "mc: اتصال ناجح" || warn "mc: فشل اتصال"

  # إنشاء سلال إن لم توجد
  for b in raw decoded reports; do
    docker run --rm --network "$NET" -e MC_HOST_local="$MC_HOST_local" minio/mc mb -p "local/$b" >/dev/null 2>&1 || true
  done

  docker run --rm --network "$NET" -e MC_HOST_local="$MC_HOST_local" minio/mc admin info local || true
}

do_start(){
  ensure_env
  log "🚀 Starting Core"
  docker compose -f "$CORE" up -d --wait || warn "compose لم ينتظر كل الخدمات"
  log "🚀 Starting Apps (إن وُجدت)"
  [ -f "$APPS" ] && docker compose -f "$APPS" up -d --build || warn "ملف التطبيقات غير موجود: $APPS"
  hc_core
}

do_stop(){
  log "🛑 Stopping Apps"
  [ -f "$APPS" ] && docker compose -f "$APPS" down || true
  log "🛑 Stopping Core"
  docker compose -f "$CORE" down || true
}

do_status(){
  log "📊 FFactory Status Report"
  echo "=== CORE SERVICES ==="
  docker compose -f "$CORE" ps 2>/dev/null || echo "Core not running"
  echo -e "\n=== ANALYSIS APPS ==="
  [ -f "$APPS" ] && docker compose -f "$APPS" ps 2>/dev/null || echo "Apps not running"
  echo
  hc_core
}

do_logs(){
  svc="${1:-minio}"
  log "📋 Logs: $svc"
  docker compose -f "$CORE" logs --tail=50 "$svc" 2>/dev/null ||
  ([ -f "$APPS" ] && docker compose -f "$APPS" logs --tail=50 "$svc") ||
  echo "Service '$svc' not found"
}

set_pw(){
  ensure_env
  ok "تم توحيد كلمات السر في $ENVF"
  do_stop
  do_start
}

case "${1:-status}" in
  start)    do_start ;;
  stop)     do_stop ;;
  restart)  do_stop; sleep 2; do_start ;;
  status)   do_status ;;
  logs)     shift; do_logs "$1" ;;
  fix-minio) fix_minio ;;
  setpw)    set_pw ;;
  doctor)   hc_core ;;
  *)
    cat <<USAGE
Usage: $0 {start|stop|restart|status|logs <svc>|fix-minio|setpw|doctor}

Examples:
  $0 start          # تشغيل الكور + التطبيقات
  $0 status         # تقرير حالة شامل + فحوص صحّة
  $0 logs minio     # آخر لوج لـ MinIO
  $0 fix-minio      # إصلاح MinIO وتهيئة السلال
  PW_OVERRIDE=NewP@ss $0 setpw   # تدوير باسورد الاختبار وإعادة التشغيل
USAGE
    ;;
esac
