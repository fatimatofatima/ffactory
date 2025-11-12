#!/usr/bin/env bash
set -Eeuo pipefail
echo "🔥 FFactory ULTIMATE LAUNCH - Brought to you by THE KING 🔥"

FF=/opt/ffactory
log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }

# 1) تنظيف وتهيئة
log "🧹 تنظيف ساحة المعركة..."
docker compose -f $FF/stack/docker-compose.core.yml down 2>/dev/null || true
docker compose -f $FF/stack/docker-compose.apps.ext.yml down 2>/dev/null || true
docker rm -f $(docker ps -aq --filter "name=ffactory") 2>/dev/null || true

# 2) شبكة احترافية
log "🌐 شبكة القيادة..."
docker network create ffactory_ffactory_net 2>/dev/null || true

# 3) تشغيل الأساسيات بقوة
log "⚡ تشغيل المحرك الأساسي..."
docker compose -f $FF/stack/docker-compose.core.yml up -d --force-recreate

# 4) انتظار تكتيكي
log "⏳ انتظار استعداد القواعد..."
sleep 20

# 5) تطبيقات التحليل
log "🔍 تشغيل أسلحة التحليل..."
docker compose -f $FF/stack/docker-compose.apps.ext.yml up -d --build --force-recreate

# 6) تطبيقات الذكاء الاصطناعي
log "🧠 تشغيل العقل الاصطناعي..."
[ -f "$FF/stack/docker-compose.apps.auto.yml" ] && \
docker compose -f $FF/stack/docker-compose.apps.auto.yml up -d --build 2>/dev/null || \
log "⚠️  تطبيقات AI جاهزة للتثبيت لاحقاً"

# 7) فحص نهائي
log "📊 فحص القوة النهائية..."
echo "=========================================="
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "=========================================="

log "✅ النظام أصبح جاهزاً للهيمنة!"
log "🌐 الروابط:"
echo "   Vision: http://127.0.0.1:8081"
echo "   Media:  http://127.0.0.1:8082" 
echo "   Hashset: http://127.0.0.1:8083"
echo "   MinIO:   http://127.0.0.1:9000"
echo "   Neo4j:   http://127.0.0.1:7474"
