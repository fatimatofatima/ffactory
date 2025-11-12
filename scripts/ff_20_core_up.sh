#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

CORE_YML="$FF_STACK/docker-compose.core.yml"

log "🚀 تشغيل CORE ..."
if [ -f "$CORE_YML" ]; then
  docker compose -f "$CORE_YML" up -d
  log "⏳ انتظار الخدمات الأساسية 5 ثواني..."
  sleep 5
  log "✅ CORE شغال"
else
  log "❌ ملف $CORE_YML غير موجود"
  exit 1
fi
