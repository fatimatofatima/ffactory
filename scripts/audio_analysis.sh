#!/bin/bash
echo "🎤 بدء تحليل الصوت المتكامل..."
echo "==============================="

cd /opt/ffactory/stack

# اختبار ASR Engine
echo "1. 🔍 فحص ASR Engine..."
if curl -s http://127.0.0.1:8004/health > /dev/null; then
    echo "✅ ASR Engine يعمل"
else
    echo "❌ ASR Engine غير متاح"
fi

# اختبار Neural Core
echo "2. 🧠 اختبار Neural Core..."
response=$(curl -s -X POST "http://127.0.0.1:8000/analyze" \
    -H "Content-Type: application/json" \
    -d '{"text": "اختبار تحليل النص العربي", "case_id": "AUDIO_TEST"}')

if echo "$response" | grep -q "entities"; then
    echo "✅ Neural Core يعمل بنجاح"
else
    echo "❌ Neural Core به مشكلة"
fi

echo "🎉 اكتمل اختبار التحليل الصوتي"
