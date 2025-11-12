#!/usr/bin/env bash
set -Eeuo pipefail

export FF_HOME="/opt/ffactory"
export FF_SCRIPTS="$FF_HOME/scripts"
export FF_STACK="$FF_HOME/stack"
export FF_LOGS="$FF_HOME/logs"
export FF_NET="ffactory_ffactory_net"

mkdir -p "$FF_SCRIPTS" "$FF_STACK" "$FF_LOGS"

ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; }

# شبكة docker
if ! docker network inspect "$FF_NET" >/dev/null 2>&1; then
  log "🔧 إنشاء الشبكة $FF_NET ..."
  docker network create "$FF_NET" >/dev/null
else
  log "✅ الشبكة موجودة: $FF_NET"
fi

log "✅ البيئة جاهزة"
