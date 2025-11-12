#!/usr/bin/env bash
# يراقب أحداث Docker للحاويات التابعة لمشروع ffactory ويرسل تنبيهات عند die/restart/unhealthy
set -Eeuo pipefail
FF="/opt/ffactory"; STACK="$FF/stack"; ENV_FILE="$STACK/.env"; LOG="$FF/logs/crashwatch.log"
set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a

has(){ command -v "$1" >/dev/null 2>&1; }
send_tg(){
  local msg="$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$msg" '{chat_id:$chat_id,text:$text,disable_web_page_preview:true}')" >/dev/null 2>&1 || true
  fi
}

# متطلبات
has docker || { echo "docker not found" | tee -a "$LOG"; exit 1; }
has jq || { apt-get update -y && apt-get install -y jq >/dev/null; }

echo "[$(date +%F\ %T)] CrashWatch started." | tee -a "$LOG"

docker events \
  --filter 'type=container' \
  --filter 'label=com.docker.compose.project=ffactory' \
  --format '{{json .}}' | while read -r line; do
    [[ -z "$line" ]] && continue
    ev=$(echo "$line" | jq -r .Action)
    name=$(echo "$line" | jq -r .Actor.Attributes.name)
    exitc=$(echo "$line" | jq -r '.Actor.Attributes.exitCode // empty')
    health=$(echo "$line" | jq -r '.Actor.Attributes.health_status // empty')
    ts=$(date +%F\ %T)

    case "$ev" in
      die|restart)
        echo "[$ts] ${name} -> $ev (exit $exitc)" | tee -a "$LOG"
        send_tg "⚠️ *FFactory* — الحاوية \`${name}\` حدث: *${ev}* (exit=${exitc:-?})"
        ;;
      health_status)
        if [[ "$health" == "unhealthy" ]]; then
          echo "[$ts] ${name} unhealthy" | tee -a "$LOG"
          send_tg "⚠️ *FFactory* — \`${name}\` أصبحت *unhealthy*"
        fi
        ;;
    esac
done
