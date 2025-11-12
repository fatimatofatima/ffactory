#!/usr/bin/env bash
# استعمال:
#   ff_comment.sh <service> <severity:info|warn|error|crit> "your message"
set -Eeuo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <service> <severity> \"message\""; exit 1; }
FF="/opt/ffactory"
STACK="$FF/stack"
ENV_FILE="$STACK/.env"
set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a

SVC="$1"; SEV="$2"; shift 2; MSG="$*"
TS=$(date -Iseconds)
OUTDIR="$FF/logs/comments"; mkdir -p "$OUTDIR"
FILE="$OUTDIR/$(date +%Y%m%d).jsonl"

# خزّن محليًا
jq -nc --arg ts "$TS" --arg svc "$SVC" --arg sev "$SEV" --arg msg "$MSG" \
  '{ts:$ts, service:$svc, severity:$sev, message:$msg}' >> "$FILE"
echo "✔ saved locally -> $FILE"

# جرّب تبعته للـ feedback-api (/analyze كـ قناة عامة)
URL="http://127.0.0.1:${FEEDBACK_API_PORT:-8070}/analyze"
PAY="$(jq -nc --arg svc "$SVC" --arg sev "$SEV" --arg msg "$MSG" \
  '{data:{type:"comment",service:$svc,severity:$sev,message:$msg}}')"
if curl -fsS -H 'Content-Type: application/json' -d "$PAY" "$URL" >/dev/null; then
  echo "✔ posted to feedback-api"
else
  echo "… feedback-api unreachable, kept local."
fi
