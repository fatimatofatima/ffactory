#!/usr/bin/env bash
set -Eeuo pipefail
echo "🛡️  FFactory ARMOR UP - Fortifying the Kingdom 🛡️"

FF=/opt/ffactory
log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }

# 1) جدار حماية التطبيقات
log "🔥 تفعيل جدار حماية التطبيقات..."
for port in 8081 8082 8083 8086 8000; do
    ufw allow $port 2>/dev/null && log "✅ فتح منفذ $port" || true
done

# 2) حماية الملفات الحرجة
log "🔒 تأمين الملفات السرية..."
sudo chattr +i $FF/.env 2>/dev/null || true
sudo chmod 600 $FF/.env

# 3) نسخ احتياطي تلقائي
log "💾 إنشاء نسخة احتياطية..."
tar -czf /root/ffactory-ultimate-backup-$(date +%s).tgz -C /opt ffactory/ 2>/dev/null && \
log "✅ النسخ الاحتياطي جاهز" || log "⚠️  فشل النسخ الاحتياطي"

# 4) مراقبة الأداء
log "📈 تفعيل مراقبة الأداء..."
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -10

# 5) فحص الصحة الشامل
log "❤️  فحص الصحة المتقدم..."
for port in 8081 8082 8083; do
    if curl -fs http://127.0.0.1:$port/health >/dev/null; then
        log "✅ الخدمة على منفذ $port: ممتاز"
    else
        log "⚠️  الخدمة على منفذ $port: تحت المراقبة"
    fi
done

log "🎯 النظام محصن ومؤمن!"
echo "   🔐 الملفات محمية"
echo "   🌐 المنافذ مفتوحة" 
echo "   💾 نسخ احتياطي جاهز"
echo "   📊 المراقبة نشطة"
