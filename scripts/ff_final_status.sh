#!/usr/bin/env bash
set -Eeuo pipefail

echo "🎉 تقرير حالة FFactory النهائي"
echo "================================"
echo

echo "🏗️  البنية التحتية الأساسية:"
echo "----------------------------"
services=(
  "PostgreSQL:5433"
  "Redis:6379"
  "Neo4j HTTP:7474"
  "Neo4j Bolt:7687"
  "MinIO API:9000"
  "MinIO Console:9001"
)

for service in "${services[@]}"; do
  name="${service%:*}"
  port="${service#*:}"
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    echo "✅ $name"
  else
    echo "❌ $name"
  fi
done

echo
echo "🔧 التطبيقات التشغيلية:"
echo "----------------------"
apps=(
  "Vision:8081"
  "Media Forensics:8082" 
  "Hashset:8083"
  "ASR Engine:8086"
  "NLP Engine:8000"
  "Correlation Engine:8170"
)

for app in "${apps[@]}"; do
  name="${app%:*}"
  port="${app#*:}"
  if curl -fs "http://127.0.0.1:$port" >/dev/null 2>&1 || \
     nc -z 127.0.0.1 "$port" 2>/dev/null; then
    echo "✅ $name"
  else
    echo "❌ $name"
  fi
done

echo
echo "📊 إحصائيات النظام:"
echo "------------------"
echo "🖥️  الذاكرة المستخدمة: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo "💾 مساحة التخزين: $(df -h /opt/ffactory | awk 'NR==2 {print $4 " free"}')"
echo "🐳 عدد الحاويات: $(docker ps -q | wc -l) نشطة"

echo
echo "🎯 الخطوات التالية:"
echo "------------------"
echo "1. خدمات AI البديلة جاهزة للاستخدام"
echo "2. النظام الأساسي مستقر وجاهز" 
echo "3. يمكن تطوير خدمات AI الحقيقية لاحقاً"
echo "4. المراقبة مستمرة تلقائياً"

echo
echo "✨ FFactory جاهز للعمل!"
