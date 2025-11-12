#!/bin/bash
echo "🔍 فحص شامل للمنافذ والنظام"
echo "==========================="

# 1. فحص المنافذ المستخدمة
echo "📊 المنافذ المستخدمة حاليًا:"
netstat -tuln 2>/dev/null | grep -E ":(8080|8081|8082|8083|8086|8000|8170|8088)" | awk '{print $4}' | sed 's/.*://' | sort -n | uniq

# 2. فحص حاويات FFactory
echo ""
echo "🐳 حاويات FFactory:"
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 3. فحص الشبكة
echo ""
echo "🌐 شبكة FFactory:"
docker network inspect ffactory_ffactory_net 2>/dev/null | jq -r '.[].Containers | keys[]' 2>/dev/null || echo "🔴 الشبكة غير موجودة"

# 4. فحص الملفات الأساسية
echo ""
echo "📁 الملفات الأساسية:"
[ -f "/opt/ffactory/.env" ] && echo "✅ .env موجود" || echo "🔴 .env مفقود"
[ -f "/opt/ffactory/stack/docker-compose.core.yml" ] && echo "✅ core compose موجود" || echo "🔴 core compose مفقود"
[ -f "/opt/ffactory/stack/docker-compose.apps.yml" ] && echo "✅ apps compose موجود" || echo "🔴 apps compose مفقود"
[ -f "/opt/ffactory/stack/docker-compose.apps.ext.yml" ] && echo "✅ ext compose موجود" || echo "🔴 ext compose مفقود"

# 5. توصيات
echo ""
echo "🎯 التوصيات:"
if netstat -tuln 2>/dev/null | grep -q ":8081 "; then
    echo "🔧 المنفذ 8081 مشغول - استخدم سكربت إصلاح المنافذ"
fi
if netstat -tuln 2>/dev/null | grep -q ":8082 "; then
    echo "🔧 المنفذ 8082 مشغول - استخدم سكربت إصلاح المنافذ"  
fi
if netstat -tuln 2>/dev/null | grep -q ":8083 "; then
    echo "🔧 المنفذ 8083 مشغول - استخدم سكربت إصلاح المنافذ"
fi

echo ""
echo "🚀 الحلول:"
echo "1. تشغيل إصلاح المنافذ: sudo bash /opt/ffactory/scripts/ff_port_fix.sh"
echo "2. إعادة بناء كامل: sudo bash /opt/ffactory/scripts/ff_emergency_fix_all.sh"
echo "3. فحص شامل: sudo bash /opt/ffactory/scripts/ff_diagnose.sh"
