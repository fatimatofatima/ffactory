#!/usr/bin/env bash
set -Eeuo pipefail
echo "🔧 FFactory SMART MAINTAIN - Keeping the Throne Strong 🔧"

FF=/opt/ffactory
log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }

# 1) تنظيف الذاكرة والمؤقتات
log "🧹 تنظيف الذاكرة..."
sync && echo 3 > /proc/sys/vm/drop_caches
docker system prune -f 2>/dev/null && log "✅ نظام Docker نظيف"

# 2) تحديث الحاويات
log "🔄 تحديث الحاويات..."
docker compose -f $FF/stack/docker-compose.core.yml pull -q
docker compose -f $FF/stack/docker-compose.apps.ext.yml pull -q 2>/dev/null || true

# 3) إعادة تشغيل ذكي
log "⚡ إعادة تشغيل ذكية..."
docker compose -f $FF/stack/docker-compose.core.yml up -d --force-recreate
sleep 10
docker compose -f $FF/stack/docker-compose.apps.ext.yml up -d 2>/dev/null || true

# 4) فحص الأخطاء
log "🔍 فحص السجلات للأخطاء..."
for container in $(docker ps --filter "name=ffactory" --format "{{.Names}}"); do
    if docker logs $container 2>&1 | tail -5 | grep -i "error\|fail"; then
        log "⚠️  وجدت أخطاء في: $container"
    else
        log "✅ $container: نظيف"
    fi
done

# 5) تقرير الحالة
log "📋 تقرير الحالة النهائي..."
echo "=========================================="
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
echo "=========================================="

log "🎯 الصيانة اكتملت! النظام في أفضل حالة!"
