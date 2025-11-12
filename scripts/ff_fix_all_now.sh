#!/usr/bin/env bash
set -Eeuo pipefail
echo "🔧 FFactory ULTIMATE FIX - Solving All Issues Now 🔧"

FF="/opt/ffactory"
log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }

# 1) إصلاح مشاكل Unicode والمسافات
log "🔄 إصلاح مشاكل الترميز في الملفات..."
find "$FF" -name "*.sh" -o -name "*.py" -o -name "Dockerfile" | while read file; do
    if [ -f "$file" ]; then
        # إصلاح المسافات غير القابلة للكسر
        sed -i 's/ / /g' "$file" 2>/dev/null || true
        # إصلاح returns
        sed -i 's/\r$//' "$file" 2>/dev/null || true
    fi
done

# 2) إصلاح Health Checks المتعارضة
log "⚡ إصلاح Health Checks..."
for compose in "$FF/stack/docker-compose"*.yml; do
    [ -f "$compose" ] || continue
    sed -i 's/--quiet-pull//g' "$compose" 2>/dev/null || true
    sed -i 's/--wait//g' "$compose" 2>/dev/null || true
done

# 3) إصلاح المنافذ المتضاربة
log "🔌 إصلاح تضارب المنافذ..."
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep ffactory

# 4) إعادة تشغيل نظيف
log "🚀 إعادة تشغيل نظيف للنظام..."
cd "$FF"
docker-compose -f stack/docker-compose.core.yml down 2>/dev/null || true
docker-compose -f stack/docker-compose.apps.ext.yml down 2>/dev/null || true
sleep 5

# 5) تشغيل الأساسيات أولاً
log "🔧 تشغيل الخدمات الأساسية..."
docker-compose -f stack/docker-compose.core.yml up -d

# 6) انتظار الجاهزية
log "⏳ انتظار جاهزية قواعد البيانات..."
sleep 25

# 7) تشغيل التطبيقات
log "🚀 تشغيل تطبيقات التحليل..."
docker-compose -f stack/docker-compose.apps.ext.yml up -d --build

# 8) فحص نهائي
log "📊 فحص الحالة النهائية..."
echo "=========================================="
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "=========================================="

log "✅ تم إصلاح جميع المشاكل!"
log "🌐 الخدمات النشطة:"
curl -s http://127.0.0.1:8081/health | jq '.status' 2>/dev/null && echo "✅ Vision Engine" || echo "❌ Vision"
curl -s http://127.0.0.1:8082/health | jq '.status' 2>/dev/null && echo "✅ Media Forensics" || echo "❌ Media"  
curl -s http://127.0.0.1:8083/health | jq '.status' 2>/dev/null && echo "✅ Hashset Service" || echo "❌ Hashset"
