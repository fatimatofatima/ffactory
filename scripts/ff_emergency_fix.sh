#!/bin/bash
echo "🆘 تشغيل وضع الطوارئ للنظام الجنائي..."

# تنظيف أي مشاكل سابقة
docker-compose -f stack/docker-compose.core.yml down
docker-compose -f stack/docker-compose.ai.yml down

# تنظيف الشبكات المعطلة
docker network prune -f

# إعادة التشغيل من الصفر
docker-compose -f stack/docker-compose.core.yml up -d --build
sleep 30
docker-compose -f stack/docker-compose.ai.yml up -d --build

echo "✅ تم إسعاف النظام!"
