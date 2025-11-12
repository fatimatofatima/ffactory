import os, logging, psycopg2
from telegram.ext import Application, CommandHandler, ContextTypes
from telegram import Update
from datetime import datetime
logging.basicConfig(level=logging.INFO); log=logging.getLogger("ffactory-bot")

TOKEN=os.getenv("BOT_TOKEN","")
DB_URL=os.getenv("DB_URL","postgresql://forensic_user:forensic_pass@db:5432/forensic_db")
ALLOWED={x.strip() for x in os.getenv("ALLOWED_USERS","").split(",") if x.strip()}

def allowed(uid:int)->bool: return (not ALLOWED) or (str(uid) in ALLOWED)

async def start(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    await u.message.reply_text("✅ Bot ready")

async def idcmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    uu=u.effective_user
    await u.message.reply_text(f"🪪 {uu.id} @{uu.username or 'N/A'}")

async def dbping(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if not allowed(u.effective_user.id): return
    try:
        with psycopg2.connect(DB_URL) as cn:
            with cn.cursor() as cur: cur.execute("SELECT 1")
        await u.message.reply_text(f"🗄️ DB OK @ {datetime.utcnow().isoformat()}")
    except Exception as e:
        await u.message.reply_text(f"❌ DB ERROR: {e}")

def main():
    if not TOKEN: raise SystemExit("TOKEN_MISSING")
    app=Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("id", idcmd))
    app.add_handler(CommandHandler("dbping", dbping))
    app.run_polling(drop_pending_updates=True, allowed_updates=["message","edited_message"])

if __name__=="__main__": main()
