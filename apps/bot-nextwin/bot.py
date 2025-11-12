import os, requests, psycopg2, psycopg2.extras
from datetime import datetime
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

TOKEN=os.getenv("BOT_NEXTWIN_TOKEN",""); CHAT=os.getenv("BOT_NEXTWIN_CHAT_ID","")
PGHOST=os.getenv("PGHOST","db"); PGPORT=int(os.getenv("PGPORT","5432"))
PGUSER=os.getenv("PGUSER","warehouse"); PGPASS=os.getenv("PGPASSWORD",""); PGDB=os.getenv("PGDB","analytics")
LLM_EP=os.getenv("LLM_ENDPOINT","http://ollama:11434/api/generate")
LLM_MODEL=os.getenv("LLM_MODEL","llama3:8b")

def db_ok():
    try:
        with psycopg2.connect(host=PGHOST, port=PGPORT, user=PGUSER, password=PGPASS, dbname=PGDB) as con:
            with con.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
                cur.execute("select 1"); return True
    except Exception: return False

async def start_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if CHAT and str(u.effective_chat.id)!=CHAT: return
    await u.message.reply_text("Nextwin جاهز.")

async def status_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if CHAT and str(u.effective_chat.id)!=CHAT: return
    now=datetime.utcnow().strftime("%F %T UTC"); ok="ok" if db_ok() else "down"
    await u.message.reply_text(f"✅ {now} | DB={ok}")

async def ai_cmd(u:Update,c:ContextTypes.DEFAULT_TYPE):
    if CHAT and str(u.effective_chat.id)!=CHAT: return
    q=" ".join(c.args).strip()
    if not q: await u.message.reply_text("استعمل: /ai نص_السؤال"); return
    try:
        r=requests.post(LLM_EP, json={"model":LLM_MODEL,"prompt":q,"stream":False}, timeout=180)
        txt=r.json().get("response","خطأ")
        await u.message.replyText if len(txt)>3500 else u.message.reply_text(txt[:3500])
    except Exception as e:
        await u.message.reply_text(f"خطأ النموذج: {e}")

def main():
    if not TOKEN: raise SystemExit("BOT_NEXTWIN_TOKEN missing")
    app=Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("status", status_cmd))
    app.add_handler(CommandHandler("ai", ai_cmd))
    app.run_polling(drop_pending_updates=True)

if __name__=="__main__": main()
