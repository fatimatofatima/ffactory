#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
STACK=$FF/stack

detect_compose_files() {
  local f
  for f in \
    "$STACK/docker-compose.ultimate.yml" \
    "$STACK/docker-compose.complete.yml" \
    "$STACK/docker-compose.obsv.yml" \
    "$STACK/docker-compose.prod.yml" \
    "$STACK/docker-compose.dev.yml" \
    "$STACK/docker-compose.yml"
  do [[ -f "$f" ]] && echo "$f"; done
}

compose_has_service() {
  local file="$1" svc="$2"
  command -v docker >/dev/null 2>&1 || return 1
  docker compose -f "$file" ps --services 2>/dev/null | grep -qx "$svc"
}

svc_compose() {
  local svc="$1" default="${2:-}"
  local f
  for f in $(detect_compose_files); do
    if compose_has_service "$f" "$svc"; then echo "$f"; return; fi
  done
  [[ -n "$default" ]] && echo "$default" || echo ""
}
