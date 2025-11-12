#!/usr/bin/env bash
. /opt/ffactory/scripts/ff_lib_multi.sh || true
set -Eeuo pipefail
FF=/opt/ffactory
STACK=$FF/stack
ENV_FILE=$STACK/.env

detect_compose() {
  local c
  for c in "$STACK"/docker-compose.{ultimate,complete,obsv,prod,dev}.yml "$STACK"/docker-compose.yml; do
    [[ -f "$c" ]] && { echo "$c"; return; }
  done
  c=$(ls "$STACK"/docker-compose*.yml 2>/dev/null | head -n1 || true)
  [[ -n "${c:-}" ]] && { echo "$c"; return; }
  echo ""
}

container_name() {
  local svc="$1"
  local compose; compose="$(detect_compose)"
  if [[ -n "$compose" ]] && command -v docker >/dev/null 2>&1; then
    docker compose -f "$compose" ps --services 2>/dev/null | grep -qx "$svc" || { echo "ffactory_${svc//-/_}"; return; }
    docker compose -f "$compose" ps --status running 2>/dev/null | awk -v s="^${svc}\$" '$1 ~ s {print $1; ok=1; exit} END{if(!ok)print ""}'
    return
  fi
  echo "ffactory_${svc//-/_}"
}

load_env() { [[ -f "$ENV_FILE" ]] && set -a && . "$ENV_FILE" && set +a || true; }

# --- Compose helper (bind to the real project) ---
dc() {
  docker compose --project-name ffactory \
                --project-directory "$STACK" \
                --env-file "$ENV_FILE" \
                "$@"
}
