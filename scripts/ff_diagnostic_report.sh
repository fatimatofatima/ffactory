#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
warn(){ echo "🟡 $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
die(){ echo "🔴 $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; exit 1; }

FF="/opt/ffactory"
STACK="$FF/stack"
PROJECT="ffactory"
NET="${PROJECT}_ffactory_net"

# --- 0. تجميع ملفات Compose ---
COMPOSE_FILES=$(find "$STACK" -name 'docker-compose*.yml' | sort -u | awk '{printf "-f %s ",$0}')

# --- 1. إيقاف وتنظيف شامل ---
log "1/5. إيقاف وتنظيف النظام لضمان عدم وجود تضارب..."
docker compose $COMPOSE_FILES -p $PROJECT down -v --remove-orphans || true

# --- 2. بناء الصور الأخيرة (لتطبيق Build-Essential) ---
log "2/5. بناء الصور الأخيرة (لتطبيق Build-Essential/Torch)..."
docker compose $COMPOSE_FILES -p $PROJECT build --no-cache || die "🔴 فشل البناء. تحقق من متطلبات التجميع (build-essential)."

# --- 3. تشغيل النظام الأساسي ---
log "3/5. تشغيل البنية الأساسية والتطبيقات..."
docker compose $COMPOSE_FILES -p $PROJECT up -d || die "🔴 فشل تشغيل up -d."
sleep 15 # انتظار إقلاع DBs

# --- 4. تشخيص الأخطاء الداخلية (Runtime Crash) ---
log "4/5. تشخيص الانهيار (Crash) في محركات الذكاء الاصطناعي (Logs Dump)..."
AI_SERVICES="ffactory_asr ffactory_nlp ffactory_correlation"

for service in $AI_SERVICES; do
  echo "--- سجل أخطاء الخدمة: $service ---"
  # تفريغ آخر 30 سطر من السجلات
  docker logs --tail 30 "$service" 2>/dev/null || warn "$service غير قيد التشغيل أو لا يوجد سجل."
done

# --- 5. فحص المصادقة (Authentication Check) ---
log "5/5. فحص الاتصال بقاعدة البيانات (Auth Check)."
PG_PASS=$(grep POSTGRES_PASSWORD "$FF/.env" | cut -d= -f2)

docker run --rm --network "$NET" -e PGPASSWORD="$PG_PASS" postgres:16 \
  psql -h db -U ffadmin -d ffactory -c "SELECT current_user, current_database();" >/dev/null 2>&1

if [ $? -eq 0 ]; then
  log "✅ Postgres Auth OK. الأدوار ffadmin/ffactory جاهزة."
else
  warn "🔴 Postgres Auth FAILED. يجب تشغيل ff_pg_rescue.sh مجدداً أو التحقق من كلمة السر في .env."
fi

# --- 6. ملخص الصحة ---
log "--- ملخص الصحة النهائية ---"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Health}}' | grep ffactory

