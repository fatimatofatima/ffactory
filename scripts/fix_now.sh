#!/usr/bin/env bash
set -Eeuo pipefail

echo "🚀 Fix-Pack: تهيئة جداول البوت + فحص الخدمات + إعادة تشغيل البوتات"
cd /opt/ffactory/stack || { echo "❌ /opt/ffactory/stack غير موجود"; exit 1; }

# 1) تهيئة جداول البوت (لن تُنشأ إذا موجودة)
echo "🗄️ إنشاء/تأكيد جداول bot_users و bot_messages..."
cat > /tmp/init_bot.sql <<'SQL'
CREATE TABLE IF NOT EXISTS bot_users(
  chat_id BIGINT PRIMARY KEY,
  role TEXT DEFAULT 'user',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE TABLE IF NOT EXISTS bot_messages(
  id BIGSERIAL PRIMARY KEY,
  chat_id BIGINT REFERENCES bot_users(chat_id),
  cmd TEXT, payload JSONB, ts TIMESTAMPTZ DEFAULT now()
);
SQL

psql "host=127.0.0.1 port=5433 user=forensic_user dbname=forensic_db" -f /tmp/init_bot.sql

# 2) ملف بيئة البوتات (إن لم يوجد)
if [ ! -f bots.env ]; then
  echo "🧩 إنشاء bots.env بقيم افتراضية (عدّل التوكنات لاحقاً)..."
  cat > bots.env <<'ENV'
BOT_DB_URL=postgresql://forensic_user:Forensic123!@db:5432/forensic_db
BOT_ALLOWED_USERS=795444729

# ضع توكناتك الحقيقية هنا قبل التشغيل:
NEXTWIN_BOT_TOKEN=123456789:REPLACE_WITH_REAL_TOKEN
ADMIN_BOT_TOKEN=987654321:REPLACE_WITH_REAL_TOKEN

NEURAL_CORE_URL=http://neural-core:8000
CORRELATION_URL=http://correlation-engine:8005
AI_REPORTING_URL=http://ai-reporting:8080
MINIO_URL=http://minio:9000
ENV
else
  echo "ℹ️ bots.env موجود مسبقاً — لن أستبدله."
fi

# 3) تشغيل/إعادة تشغيل البوتات (إن كانت معرفة في compose)
echo "🤖 إعادة تشغيل bot-admin و bot-nextwin (إن وُجدا في compose)..."
docker compose -p ffactory --env-file bots.env up -d bot-admin bot-nextwin || true
docker compose -p ffactory restart bot-admin bot-nextwin || true

# 4) فحص المنافذ الحرجة والخدمات
check() {
  local name="$1" url="$2"
  if curl -sS --max-time 3 "$url" >/dev/null; then
    echo "✅ $name: UP ($url)"
  else
    echo "❌ $name: DOWN ($url)"
  fi
}

echo "🩺 فحص Health:"
check "Neural-Core"       "http://127.0.0.1:8000/health"
check "Correlation-Engine" "http://127.0.0.1:8005/health"
check "AI-Reporting"      "http://127.0.0.1:8080/health"
check "MinIO API"         "http://127.0.0.1:9000/minio/health/live"
check "MinIO Console"     "http://127.0.0.1:9001"

# تلميحات إذا في مشاكل مع 8005 أو 9001
echo
echo "💡 ملاحظات:"
echo "- لو Correlation-Engine يظهر DOWN و الحاوية Up: تأكد من نشر المنفذ في docker-compose:"
echo "  services: correlation-engine: ports: [\"127.0.0.1:8005:8005\"] ووجود مسار /health في التطبيق."
echo "- لو MinIO Console (9001) مغلق: تأكد من الأمر:"
echo "  command: server /data --console-address \":9001\"  والـ ports: [\"127.0.0.1:9000:9000\", \"127.0.0.1:9001:9001\"]"
echo
echo "🎯 تم تنفيذ Fix-Pack."
