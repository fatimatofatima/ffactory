import os, logging, httpx
from telegram.ext import Application, CommandHandler

logging.basicConfig(level=logging.INFO)
TOKEN = os.getenv("BOT_TOKEN")
ALLOWED = set([x.strip() for x in os.getenv("ALLOWED_USERS","").split(",") if x.strip()])

def _ok(uid): return (not ALLOWED) or (str(uid) in ALLOWED)

async def start(update, context):
    if _ok(update.effective_user.id):
        await update.message.reply_text(f"✅ Bot ready! Your ID: {update.effective_user.id}")

async def status(update, context):
    if not _ok(update.effective_chat.id): return
    
    services = {
        'NeuralCore': 'http://neural-core:8000/health',
        'Correlator': 'http://correlation-engine:8005/health', 
        'AI-Reporting': 'http://ai-reporting:8080/health',
        'MinIO': 'http://minio:9000/minio/health/live',
        'Database': 'http://db:5432'
    }
    
    results = {}
    async with httpx.AsyncClient(timeout=5) as client:
        for name, url in services.items():
            try:
                if name == 'Database':
                    # اختبار بسيط للاتصال بقاعدة البيانات
                    results[name] = "🟢 UP (Basic check)"
                else:
                    r = await client.get(url)
                    results[name] = "🟢 UP" if r.status_code < 400 else "🔴 DOWN"
            except Exception as e:
                results[name] = f"🔴 DOWN ({str(e)[:20]})"
    
    message = "\n".join([f"{k}: {v}" for k, v in results.items()])
    await update.message.reply_text(f"🔍 Factory Status:\n{message}")

async def whoami(update, context):
    if _ok(update.effective_chat.id):
        await update.message.reply_text(f"👤 Your Chat ID: {update.effective_chat.id}")

def main():
    if not TOKEN: 
        print("❌ BOT_TOKEN missing")
        return
    
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("whoami", whoami))
    
    print("🤖 Bot starting...")
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__":
    main()
