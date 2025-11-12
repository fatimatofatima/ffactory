#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

APPS_YML="$FF_STACK/docker-compose.apps.yml"

log "🚀 تشغيل APPS (لو موجودة) ..."
if [ -f "$APPS_YML" ]; then
  docker compose -f "$APPS_YML" up -d
  log "✅ APPS شغالة"
else
  log "ℹ️ مفيش $APPS_YML - نتخطى"
fi
