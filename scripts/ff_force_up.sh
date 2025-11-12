#!/usr/bin/env bash
set -Eeuo pipefail

FF=/opt/ffactory
STACK_CORE="$FF/stack/docker-compose.core.yml"
STACK_APPS="$FF/stack/docker-compose.apps.yml"
NET=ffactory_ffactory_net

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }

log "🚧 FFactory FORCE UP (تنظيف + تشغيل)"

# 0) شبكة
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  log "🔧 إنشاء الشبكة $NET ..."
  docker network create "$NET" >/dev/null
else
  log "✅ الشبكة موجودة: $NET"
fi

# 1) لمّ كل الحاويات اللي عاملة تعارض
log "🧹 إيقاف الحاويات القديمة اللي عاملة اسم متكرر..."
OLD_CONTAINERS=$(docker ps -a --format '{{.Names}}' | grep '^ffactory_' || true)
if [ -n "$OLD_CONTAINERS" ]; then
  echo "$OLD_CONTAINERS" | xargs -r docker stop >/dev/null 2>&1 || true
  echo "$OLD_CONTAINERS" | xargs -r docker rm   >/dev/null 2>&1 || true
  log "✅ تم إيقاف/حذف الحاويات القديمة:"
  echo "$OLD_CONTAINERS" | sed 's/^/   - /'
else
  log "ℹ️ مفيش حاويات قديمة باسم ffactory_"
fi

# 2) تشغيل الـ CORE من compose
if [ -f "$STACK_CORE" ]; then
  log "🚀 تشغيل CORE من $STACK_CORE ..."
  docker compose -f "$STACK_CORE" up -d
  log "✅ CORE اشتغل (أو هيشتغل خلال ثواني)"
else
  log "❌ مفيش ملف CORE في $STACK_CORE"
fi

# 3) تشغيل الـ APPS لو موجود
if [ -f "$STACK_APPS" ]; then
  log "🚀 تشغيل APPS من $STACK_APPS ..."
  docker compose -f "$STACK_APPS" up -d
  log "✅ APPS اشتغلت"
else
  log "ℹ️ مفيش ملف APPS في $STACK_APPS"
fi

# 4) عرض الحالة
log "📋 الحالة النهائية:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true

log "🎉 خلصنا FORCE UP بنجاح."
