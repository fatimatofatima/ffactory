#!/usr/bin/env bash
set -Eeuo pipefail

FF=/opt/ffactory
STACK_CORE="$FF/stack/docker-compose.core.yml"
STACK_APPS="$FF/stack/docker-compose.apps.yml"
NET=ffactory_ffactory_net
LOG="$FF/logs/ff_full_power.$(date +%F_%H%M%S).log"
mkdir -p "$FF/logs"

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG"; }

log "⚡ FFactory FULL POWER - one button"

# 0) الشبكة
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  log "🔧 إنشاء الشبكة $NET ..."
  docker network create "$NET" >/dev/null
else
  log "✅ الشبكة موجودة: $NET"
fi

# 1) الحاويات اللي بتتخانق مع compose
CORE_NAMES="ffactory_db ffactory_redis ffactory_minio ffactory_neo4j"
log "🧹 تنظيف الحاويات الأساسية القديمة..."
for c in $CORE_NAMES; do
  docker stop "$c" >/dev/null 2>&1 || true
  docker rm   "$c" >/dev/null 2>&1 || true
done
log "✅ تم التنظيف"

# 2) تشغيل CORE
if [ -f "$STACK_CORE" ]; then
  log "🚀 تشغيل CORE..."
  docker compose -f "$STACK_CORE" up -d
else
  log "❌ مفيش $STACK_CORE"
fi

# 3) تشغيل APPS (اختياري)
if [ -f "$STACK_APPS" ]; then
  log "🚀 تشغيل APPS..."
  docker compose -f "$STACK_APPS" up -d
fi

# 4) إعادة خدمات AI الوهمية
log "🤖 تشغيل خدمات AI (echo-server):"
for svc in asr:8086 nlp:8000 correlation:8170 social:8088; do
  name="ffactory_${svc%%:*}"
  port="${svc##*:}"
  docker stop "$name" >/dev/null 2>&1 || true
  docker rm   "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -p 127.0.0.1:$port:8080 --network "$NET" ealen/echo-server:latest >/dev/null
  log "   ✅ $name على البورت $port"
done

# 5) فحص البورتات
log "🩺 فحص البورتات:"
for p in 8081 8082 8083 8086 8000 8170 8088 5433 6379 7474 9000 9001; do
  if nc -z 127.0.0.1 "$p" >/dev/null 2>&1; then
    log "   ✅ $p مفتوح"
  else
    log "   ❌ $p مقفول"
  fi
done

# 6) عرض الحاويات
log "📋 الحاويات اللي شغالة:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ | tee -a "$LOG" || true

log "🎉 FULL POWER DONE"
log "📄 اللوج: $LOG"
