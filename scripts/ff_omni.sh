#!/usr/bin/env bash
set -Eeuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ========= إعدادات عامة =========
FF=/opt/ffactory
CORE="$FF/stack/docker-compose.core.yml"
APPS="$FF/stack/docker-compose.apps.ext.yml"
ENVF="$FF/.env"
LOGD="$FF/logs"
PW="${FF_PW:-Aa100200}"            # غيّرها بتصدير FF_PW قبل التشغيل
NET1=ffactory_default
NET2=ffactory_ffactory_net
BUCKETS=("raw" "decoded" "reports")

mkdir -p "$LOGD"
LOG="$LOGD/ff_omni.$(date +%F_%H%M%S).log"

# ========= أدوات مساعدة =========
ts()  { date '+%F %T'; }
log() { printf "[%s] %s\n" "$(ts)" "$*" | tee -a "$LOG"; }
ok()  { log "✅ $*"; }
warn(){ log "⚠️  $*"; }
die() { log "❌ $*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

# لفّافة docker/compose مع تنظيف تحذير كلمات المرور
dc_core() { docker compose -f "$CORE" "$@" 2>&1 | sed 's/Warning: Using a password.*//'; }
dc_apps() { docker compose -f "$APPS" "$@" 2>&1 | sed 's/Warning: Using a password.*//'; }
dex()     { docker exec "$@"; }

# قراءة .env إلى البيئة (لو موجود)
env_load(){ set +u; [ -f "$ENVF" ] && set -a && . "$ENVF" && set +a; set -u; }

# كتابة/تحديث متغير في .env حتى لو كان موجود
env_upsert(){
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENVF" 2>/dev/null; then
    sed -i -E "s|^(${k})=.*|\1=${v}|" "$ENVF" || true
  else
    printf "%s=%s\n" "$k" "$v" >>"$ENVF"
  fi
}

# إزالة "عدم القابلية للتعديل" إن كانت مفعّلة على .env
env_unlock(){
  if lsattr "$ENVF" 2>/dev/null | grep -q 'i-'; then
    chattr -i "$ENVF" 2>/dev/null || warn "لا أستطيع إزالة خاصية immutability من $ENVF — نفّذ: sudo chattr -i $ENVF"
  fi
}

# ========= وظائف أساسية =========
ensure_networks(){
  docker network inspect "$NET1" >/dev/null 2>&1 || docker network create "$NET1" >/dev/null
  docker network inspect "$NET2" >/dev/null 2>&1 || docker network create "$NET2" >/dev/null
  ok "الشبكات جاهزة: $NET1, $NET2"
}

ensure_env(){
  install -d -m 755 "$(dirname "$ENVF")"
  [ -f "$ENVF" ] || install -m 600 /dev/null "$ENVF"
  env_unlock
  env_upsert POSTGRES_USER        ffactory
  env_upsert POSTGRES_DB          ffactory
  env_upsert POSTGRES_PASSWORD    "$PW"
  env_upsert REDIS_PASSWORD       "$PW"
  env_upsert NEO4J_PASSWORD       "$PW"
  env_upsert MINIO_ROOT_USER      ffroot
  env_upsert MINIO_ROOT_PASSWORD  "$PW"
  ok ".env جاهز ومتوحد"
  env_load
}

# ======== تشغيل الأساسيات وانتظار الجاهزية ========
up_core(){
  # نشغّل بدون --wait لتجنّب مشاكل صحة الحاويات ثم ننتظر يدويًا
  dc_core up -d >/dev/null || die "فشل تشغيل CORE"
  # اطبع حالة مختصرة
  docker ps --format ' Container {{.Names}}  {{.Status}}' --filter "name=ffactory" | tee -a "$LOG"
  ok "CORE up"
}

wait_for(){
  local desc="$1"; shift
  local tries=90
  until "$@" >/dev/null 2>&1; do
    ((tries--)) || { warn "$desc لم يصبح جاهزًا في الوقت المتوقّع"; return 1; }
    sleep 2
  done
  ok "$desc جاهز"
}

# محسّنات معرفة الحاويات
cid_db()    { dc_core ps -q db    || true; }
cid_redis() { dc_core ps -q redis || true; }
cid_neo4j() { dc_core ps -q neo4j || true; }
cid_minio() { dc_core ps -q minio || true; }

wait_postgres(){
  local id; id="$(cid_db)"; [ -n "$id" ] || return 1
  wait_for "PostgreSQL" dex "$id" pg_isready -U "${POSTGRES_USER:-ffactory}" -d "${POSTGRES_DB:-ffactory}"
}

wait_redis(){
  local id; id="$(cid_redis)"; [ -n "$id" ] || return 1
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    wait_for "Redis" dex "$id" redis-cli -a "$REDIS_PASSWORD" ping
  else
    wait_for "Redis" dex "$id" redis-cli ping
  fi
}

wait_neo4j(){
  local id; id="$(cid_neo4j)"; [ -n "$id" ] || return 1
  # جرب cypher-shell بكلمة السر
  wait_for "Neo4j" dex "$id" cypher-shell -u neo4j -p "${NEO4J_PASSWORD:-$PW}" 'RETURN 1;'
}

wait_minio(){
  # نفحص من المضيف
  wait_for "MinIO HTTP (9000)" curl -fsS http://127.0.0.1:9000/minio/health/ready
  # والكونسول
  wait_for "MinIO Console (9001)" curl -fsS http://127.0.0.1:9001/
}

# ======== إعداد MinIO (mc) ========
minio_mc(){
  local net="$NET1"
  docker run --rm --network="$net" -e MC_COLOR=never minio/mc sh -c "
    mc alias set local http://minio:9000 ${MINIO_ROOT_USER:-ffroot} ${MINIO_ROOT_PASSWORD:-$PW} >/dev/null &&
    (mc mb -p local/${BUCKETS[0]}    2>/dev/null || true) &&
    (mc mb -p local/${BUCKETS[1]}    2>/dev/null || true) &&
    (mc mb -p local/${BUCKETS[2]}    2>/dev/null || true) &&
    mc ls local >/dev/null
  " >/dev/null 2>&1 || warn "mc فشل — تحقق من بيانات MinIO أو الشبكة"
}

# ======== إصلاح مصادقة Neo4j ========
fix_neo4j_auth(){
  local id; id="$(cid_neo4j)"; [ -n "$id" ] || { warn "لا يوجد neo4j قيد التشغيل"; return 0; }
  if dex "$id" cypher-shell -u neo4j -p "${NEO4J_PASSWORD:-$PW}" 'RETURN 1;' >/dev/null 2>&1; then
    ok "Neo4j مصادقة ناجحة"
    return 0
  fi
  warn "Neo4j فشل مصادقة — سنحاول reset للبيانات إن طُلِب"
  return 1
}

force_reset_neo4j(){
  local id vol
  id="$(cid_neo4j || true)"
  dc_core stop neo4j >/dev/null 2>&1 || true
  # اسم الحجم غالبًا ffactory_neo4j_data
  vol="$(docker volume ls --format '{{.Name}}' | grep -E '^ffactory_neo4j_data$' || true)"
  if [ -n "$vol" ]; then
    docker volume rm -f "$vol" >/dev/null 2>&1 || warn "تعذّر حذف الحجم $vol (قيد الاستخدام؟)"
  fi
  dc_core up -d neo4j >/dev/null
  sleep 3
  wait_neo4j || die "Neo4j لم يعد بعد التصفير"
  ok "Neo4j تم تصفيره وضبط كلمة السر"
}

# ======== ملخص وتشخيص ========
ps_brief(){
  log "===== FFactory ps ====="
  docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

health_quick(){
  log "===== Health quick ====="
  curl -fsS http://127.0.0.1:8081/health >/dev/null && echo "Vision ✅" || echo "Vision ❌"
  curl -fsS http://127.0.0.1:8082/health >/dev/null && echo "Media  ✅" || echo "Media  ❌"
  curl -fsS http://127.0.0.1:8083/health >/dev/null && echo "Hashset✅" || echo "Hashset❌"
  curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null && echo "MinIO  ✅" || echo "MinIO  ❌"
  # نحكم على Neo4j بسرعة عبر cypher-shell
  if cid_neo4j >/dev/null; then
    dex "$(cid_neo4j)" cypher-shell -u neo4j -p "${NEO4J_PASSWORD:-$PW}" 'RETURN 1;' >/dev/null 2>&1 && \
      echo "Neo4j  ✅" || echo "Neo4j  ❌"
  fi
}

# ======== الأوامر ========
cmd_status(){
  ps_brief
  echo
  echo "[*] health:"
  health_quick
}

cmd_fix_neo4j(){
  env_load
  if ! fix_neo4j_auth; then
    warn "لو أردت إعادة تهيئة Neo4j كليًا: $0 --force-neo4j-reset"
  fi
}

cmd_force_neo4j_reset(){
  env_load
  force_reset_neo4j
}

# ======== التشغيل الكامل ========
cmd_run_all(){
  ensure_networks
  ensure_env
  up_core

  # انتظار الخدمات الأساسية
  wait_postgres || warn "PostgreSQL لم يصبح جاهزًا بالوقت القياسي"
  wait_redis    || warn "Redis لم يصبح جاهزًا بالوقت القياسي"

  # نحاول neo4j
  if ! wait_neo4j; then
    warn "Neo4j لم يُكمل المصادقة — محاولة إصلاح"
    fix_neo4j_auth || warn "ما زالت المصادقة تفشل — جرّب: $0 --force-neo4j-reset"
  fi

  # MinIO HTTP + buckets
  wait_minio || warn "MinIO healthcheck لا يزال غير مستقر — سنحاول mc لاحقًا"
  minio_mc   || warn "إعداد mc لم يكتمل (تحقّق يدويًا)"

  # تشغيل تطبيقات التحليل (لو ملف APPS موجود)
  if [ -f "$APPS" ]; then
    dc_apps up -d --build >/dev/null || warn "APPS up واجه مشاكل"
  fi

  ps_brief
  health_quick

  log "ملف اللوج: $LOG"
}

# ======== مفسّر الأوامر ========
case "${1:-run}" in
  run|"")              cmd_run_all ;;
  status)              cmd_status  ;;
  fix-neo4j)           cmd_fix_neo4j ;;
  --force-neo4j-reset) cmd_force_neo4j_reset ;;
  *)
    cat <<USAGE
استعمال:
  $0            # تشغيل شامل (يفحص/يصلّح/يشغّل/تقرير)
  $0 status     # تقرير حالة سريع
  $0 fix-neo4j  # محاولة إصلاح مصادقة Neo4j
  $0 --force-neo4j-reset  # تصفير بيانات Neo4j (خطر)
متغيرات مفيدة:
  FF_PW   لتوحيد كلمات السر (افتراضي Aa100200)
USAGE
  ;;
esac
