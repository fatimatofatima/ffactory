#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; S=$FF/scripts
alert(){
  echo -e "\033[1;33m[تحذير]\033[0m تغيّر ملف: $1 ($2) — راجع آخر أوامر التشغيل"
}
watch_changes(){
  command -v inotifywait >/dev/null 2>&1 || return 0
  inotifywait -mq -e modify,create,delete /opt/ffactory/scripts /opt/ffactory/stack | \
    while read -r dir ev file; do alert "$dir$file" "$ev"; done
}
( watch_changes ) & WPID=$!
trap 'kill $WPID 2>/dev/null || true' EXIT
while true; do
  clear
  echo "===== FFactory Live =====  ($(date '+%F %T'))"
  echo "Project: ${COMPOSE_PROJECT_NAME:-ffactory}    (COMPOSE_IGNORE_ORPHANS=${COMPOSE_IGNORE_ORPHANS:-0})"
  echo
  docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed '1,40!d'
  echo
  echo "--- memory.json (أهم العدّادات) ---"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services | to_entries[] | "\(.key): restart=\(.value.restart_count // 0), status=\(.value.last_status // "n/a")"' /opt/ffactory/system_memory.json 2>/dev/null | sed -n '1,20p' || true
  fi
  echo
  echo "Hints: curl -sf http://127.0.0.1:9090/-/ready  (Prometheus)"
  echo "       curl -sf http://127.0.0.1:3001/health    (frontend-dashboard)"
  sleep 3
done
