#!/bin/bash
echo "💥 FFactory 70+ SERVICES ACTIVATOR 💥"
echo "======================================"

# كشف التطبيقات المتاحة
echo "🎯 التطبيقات المتاحة للتنشيط:"
apps_count=0
for app in /opt/ffactory/apps/*; do
    if [ -d "$app" ]; then
        app_name=$(basename "$app")
        echo "   🔓 $app_name"
        ((apps_count++))
    fi
done

echo ""
echo "📦 حاويات جاهزة للتنشيط:"
containers_count=0
for compose in /opt/ffactory/stack/docker-compose.*.yml; do
    if [ -f "$compose" ]; then
        compose_name=$(basename "$compose")
        echo "   🐳 $compose_name"
        ((containers_count++))
    fi
done

echo ""
echo "🎪 إحصائيات القوة العظمى:"
echo "   💪 $apps_count تطبيق مخفي"
echo "   🚀 $containers_count ملف تشغيل" 
echo "   🔥 $(find /opt/ffactory/scripts -name "*.sh" | wc -l) سكربت قوة"
echo "   ⚡ $(docker ps -q --filter "name=ffactory" | wc -l) خدمة نشطة"

echo ""
echo "🎮 أوامر التنشيط:"
echo "   📡 sudo /opt/ffactory/scripts/ff_power_pack.sh"
echo "   🧠 sudo /opt/ffactory/scripts/ff_ultimate_power.sh"
echo "   🔗 sudo /opt/ffactory/scripts/ff_relation_pack.sh"
echo "   🌐 sudo /opt/ffactory/scripts/ff_social_pack.sh"
echo ""
echo "💎 القوة بين يديك! اختر سلاحك!"
