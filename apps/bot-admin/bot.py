import os, psycopg2, psycopg2.extras
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

TOKEN=os.getenv("BOT_ADMIN_TOKEN","")
CHAT =os.getenv("BOT_ADMIN_CHAT_ID","")
PGHOST=os.getenv("PGHOST","db"); PGPORT=int(os.getenv("PGPORT","5432"))
PGUSER=os.getenv("PGUSER","warehouse"); PGPASS=os.getenv("PGPASSWORD","")
PGDB  =os.getenv("PGDB","analytics")

def db_exec(sql):
    try:
        with psycopg2.connect(host=PGHOST, port=PGPORT, user=PGUSER, password=PGPASS, dbname=PGDB) as con:
            with con.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
                cur.execute(sql); return cur.fetchall()
    except Exception as e:
        return [["err", str(e)]]

async def start_cmd(u:Update, c:ContextTypes.DEFAULT_TYPE):
    if CHAT and str(u.effective_chat.id) != CHAT: return
    await u.message.reply_text("bot-admin جاهز.")

async def status_cmd(u:Update, c:ContextTypes.DEFAULT_TYPE):
    if CHAT and str(u.effective_chat.id) != CHAT: return
    now = datetime.utcnow().strftime("%F %T UTC")
    ok = db_exec("select 1")
    await u.message.reply_text(f"✅ {now} | DB={'ok' if ok and str(ok[0][0])=='1' else 'down'}")

async def whoami(u:Update, c:ContextTypes.DEFAULT_TYPE):
    await u.message.reply_text(f"chat_id={u.effective_chat.id}")

def main():
    if not TOKEN: raise SystemExit("BOT_ADMIN_TOKEN missing")
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("status", status_cmd))
    app.add_handler(CommandHandler("whoami", whoami))
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__": main()
