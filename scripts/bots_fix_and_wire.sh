#!/usr/bin/env bash
set -Eeuo pipefail
APPS="/opt/ffactory/apps/telegram-bots"; mkdir -p "$APPS"

cat > "$APPS/requirements.txt" <<'PIP'
python-telegram-bot==20.7
httpx==0.27.2
psycopg2-binary==2.9.9
PIP

cat > "$APPS/entry.py" <<'PY'
import os, logging, httpx, psycopg2
from telegram.ext import Application, CommandHandler
logging.basicConfig(level=logging.INFO)
TOKEN=os.getenv("BOT_TOKEN"); ALLOWED=set([x.strip() for x in os.getenv("ALLOWED_USERS","").split(",") if x.strip()])
DB_URL=os.getenv("DB_URL"); BOT_TYPE=os.getenv("BOT_TYPE","bot")
def _ok(uid): return (not ALLOWED) or (str(uid) in ALLOWED)
async def start(u,c):
    if _ok(u.effective_user.id): await u.message.reply_text(f"{BOT_TYPE} ready. chat_id={u.effective_user.id}")
async def whoami(u,c):
    if _ok(u.effective_chat.id): await u.message.reply_text(f"{u.effective_chat.id}")
async def status(u,c):
    if not _ok(u.effective_chat.id): return
    db="down"
    try:
        with psycopg2.connect(DB_URL, connect_timeout=2) as con:
            with con.cursor() as cur: cur.execute("select 1"); cur.fetchone(); db="up"
    except Exception: pass
    async with httpx.AsyncClient(timeout=2) as cli:
        async def ping(u):
            try: r=await cli.get(u); return "up" if r.status_code<400 else "down"
            except Exception: return "down"
        msg=f"DB={db} | NeuralCore={await ping('http://neural-core:8000/health')} | Correlator={await ping('http://correlation-engine:8005/health')} | AI-Reporting={await ping('http://ai-reporting:8080/health')} | MinIO={await ping('http://minio:9000/minio/health/live')}"
    await u.message.reply_text(msg)
def main():
    if not TOKEN: raise SystemExit("BOT_TOKEN missing")
    app=Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("whoami", whoami))
    app.add_handler(CommandHandler("status", status))
    app.run_polling(drop_pending_updates=True)
if __name__=="__main__": main()
PY

cd /opt/ffactory/stack
docker compose -p ffactory build bot-admin bot-nextwin
docker compose -p ffactory up -d bot-admin bot-nextwin
