#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/opt/ffactory
APP=$BASE/apps/telegram-bots
mkdir -p "$APP"

# ===== bot code (متحمل) =====
cat > "$APP/enhanced_bot.py" <<'PY'
import os, logging, psycopg2
from telegram.ext import Application, CommandHandler, ContextTypes
from telegram import Update
from datetime import datetime

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("ffactory-bot")

TOKEN = os.getenv("BOT_TOKEN", "")
DB_URL = os.getenv("DB_URL", "postgresql://forensic_user:forensic_pass@db:5432/forensic_db")
ALLOWED = {x.strip() for x in os.getenv("ALLOWED_USERS","").split(",") if x.strip()}

def allowed(uid:int)->bool:
    return (not ALLOWED) or (str(uid) in ALLOWED)

async def start(update:Update, ctx:ContextTypes.DEFAULT_TYPE):
    if not allowed(update.effective_user.id): return
    await update.message.reply_text("✅ Bot ready")

async def id(update:Update, ctx:ContextTypes.DEFAULT_TYPE):
    if not allowed(update.effective_user.id): return
    u=update.effective_user
    await update.message.reply_text(f"🪪 {u.id} @{u.username or 'N/A'}")

async def dbping(update:Update, ctx:ContextTypes.DEFAULT_TYPE):
    if not allowed(update.effective_user.id): return
    try:
        with psycopg2.connect(DB_URL) as cn:
            with cn.cursor() as cur:
                cur.execute("SELECT 1")
        await update.message.reply_text(f"🗄️ DB OK @ {datetime.utcnow().isoformat()}")
    except Exception as e:
        await update.message.reply_text(f"❌ DB ERROR: {e}")

def main():
    if not TOKEN:
        log.error("TOKEN_MISSING"); raise SystemExit(10)
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("id", id))
    app.add_handler(CommandHandler("dbping", dbping))
    log.info("🤖 run_polling()")
    # يفضل polling: بسيط وثابت داخل Docker
    app.run_polling(drop_pending_updates=True, allowed_updates=["message","edited_message"])

if __name__ == "__main__":
    main()
PY

# ===== env للبوتات (إوعى تحط التوكنات صراحة في السكربت! خليها في الملف ده) =====
ENV_BOTS=/opt/ffactory/stack/.env.bots
[ -f "$ENV_BOTS" ] || {
  echo "!! ملف التوكنات $ENV_BOTS مش موجود. أنشأته لك فاضي. عبّي القيم وبعدين شغّل السكربت تاني."
  cat > "$ENV_BOTS" <<'ENV'
NEXTWIN_TOKEN=
MYSERV_TOKEN=
ALLOWED_USERS=
DB_URL=postgresql://forensic_user:forensic_pass@db:5432/forensic_db
TZ=Asia/Kuwait
ENV
  chmod 600 "$ENV_BOTS"
  exit 1
}
chmod 600 "$ENV_BOTS"
set -a; . "$ENV_BOTS"; set +a

if [ -z "${NEXTWIN_TOKEN:-}" ] || [ -z "${MYSERV_TOKEN:-}" ]; then
  echo "!! رجاءً عَبّي NEXTWIN_TOKEN و MYSERV_TOKEN في $ENV_BOTS ثم أعد التشغيل."
  exit 2
fi

# ===== أعد إنشاء الحاويتين بنمط موحد + healthcheck =====
docker rm -f smartnext-bot myservtiydatatesr-bot >/dev/null 2>&1 || true

docker run -d --name smartnext-bot \
  --network ffactory_default \
  -e BOT_TOKEN="$NEXTWIN_TOKEN" \
  -e ALLOWED_USERS="$ALLOWED_USERS" \
  -e DB_URL="${DB_URL:-postgresql://forensic_user:forensic_pass@db:5432/forensic_db}" \
  --health-cmd='sh -c "apk add --no-cache curl >/dev/null 2>&1 || true; curl -fsS https://api.telegram.org/bot$BOT_TOKEN/getMe >/dev/null"' \
  --health-interval=30s --health-timeout=5s --health-retries=3 \
  -v "$APP":/app -w /app \
  --restart unless-stopped \
  python:3.11-slim sh -c "pip install --no-cache-dir python-telegram-bot==20.7 psycopg2-binary==2.9.9 httpx==0.25.2 && python enhanced_bot.py"

docker run -d --name myservtiydatatesr-bot \
  --network ffactory_default \
  -e BOT_TOKEN="$MYSERV_TOKEN" \
  -e ALLOWED_USERS="$ALLOWED_USERS" \
  -e DB_URL="${DB_URL:-postgresql://forensic_user:forensic_pass@db:5432/forensic_db}" \
  --health-cmd='sh -c "apk add --no-cache curl >/dev/null 2>&1 || true; curl -fsS https://api.telegram.org/bot$BOT_TOKEN/getMe >/dev/null"' \
  --health-interval=30s --health-timeout=5s --health-retries=3 \
  -v "$APP":/app -w /app \
  --restart unless-stopped \
  python:3.11-slim sh -c "pip install --no-cache-dir python-telegram-bot==20.7 psycopg2-binary==2.9.9 httpx==0.25.2 && python enhanced_bot.py"

# ===== systemd للوحدة الناقصة (smartnext-bot) =====
sudo tee /etc/systemd/system/smartnext-bot.service >/dev/null <<'UNIT'
[Unit]
Description=SmartNext Telegram Bot (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=5
ExecStart=/usr/bin/docker start -a smartnext-bot
ExecStop=/usr/bin/docker stop -t 30 smartnext-bot

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now smartnext-bot

echo ""
echo "=== READY CHECK ==="
/usr/local/sbin/ffactory-ready-check.sh || true

echo ""
echo "Tip: جرّب من تليجرام:"
echo "  /start"
echo "  /id"
echo "  /dbping"
