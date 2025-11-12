#!/usr/bin/env bash
set -euo pipefail
OUT="/opt/ffactory/audit/$(date +%F_%H%M%S).md"
{
echo "# Audit $(hostname) $(date +%F\ %T)"
echo "## System"; uname -a; lsb_release -a 2>/dev/null || true; echo
echo "## Uptime"; uptime; echo
echo "## Disk usage (top 15)"; du -xhd1 / | sort -h | tail -n 15; echo
echo "## Failed units"; systemctl --failed --no-pager || true; echo
echo "## Timers"; systemctl list-timers --all --no-pager | sed -n '1,40p'; echo
echo "## Open ports"; ss -ltnp; echo
echo "## Docker ps"; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
} > "$OUT"
# إرسال اختياري إلى تيليجرام
ENVF="/opt/ffactory/stack/.env"
BOT=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENVF" | cut -d= -f2- || true)
CHAT=$(grep -E '^TELEGRAM_CHAT_ID=' "$ENVF" | cut -d= -f2- || true)
if [ -n "${BOT:-}" ] && [ -n "${CHAT:-}" ]; then
  curl -s -X POST "https://api.telegram.org/bot${BOT}/sendDocument" \
    -F chat_id="${CHAT}" -F document=@"$OUT" \
    -F caption="Audit $(hostname)"; echo
fi
echo "$OUT"
