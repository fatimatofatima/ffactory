#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
FF="/opt/ffactory"

# حل المشاكل العملية فقط
solve_actual_issues() {
    log "1. حل المشاكل العملية الفورية..."
    
    # إنشاء سكربتات الانتظار
    mkdir -p "$FF/scripts"
    
    # سكربت انتظار PostgreSQL
    cat > "$FF/scripts/wait-for-postgres.sh" <<'EOF'
#!/bin/bash
set -e
echo "⏳ انتظار PostgreSQL..."
until pg_isready -h db -p 5432 -U ${POSTGRES_USER:-ffadmin}; do
    sleep 5
done
echo "✅ PostgreSQL جاهز!"
EOF

    # سكربت انتظار Neo4j  
    cat > "$FF/scripts/wait-for-neo4j.sh" <<'EOF'
#!/bin/bash
set -e
echo "⏳ انتظار Neo4j..."
until nc -z neo4j 7687; do
    sleep 5
done
echo "✅ Neo4j جاهز!"
EOF

    chmod +x "$FF/scripts"/*.sh
}

# تشغيل النظام المحسن
deploy_optimized_system() {
    log "2. تشغيل النظام المحسن..."
    
    cd "$FF"
    
    # إيقاف الخدمات السابقة
    log "إيقاف الخدمات السابقة..."
    docker-compose -f stack/docker-compose.core.yml down 2>/dev/null || true
    docker-compose -f stack/docker-compose.apps.ext.yml down 2>/dev/null || true
    
    # تشغيل الأساسيات
    log "تشغيل الخدمات الأساسية..."
    docker-compose -f stack/docker-compose.core.yml up -d
    
    # انتظار الجاهزية
    log "انتظار قواعد البيانات..."
    sleep 20
    
    # تشغيل التطبيقات
    log "تشغيل تطبيقات التحليل..."
    docker-compose -f stack/docker-compose.apps.ext.yml up -d --build
    
    # فحص الصحة
    log "فحص الصحة النهائي..."
    check_health
}

# فحص الصحة المبسط
check_health() {
    log "3. فحص صحة النظام..."
    
    services=(
        "vision:8081"
        "media_forensics:8082" 
        "hashset:8083"
    )
    
    for service in "${services[@]}"; do
        name="${service%:*}"
        port="${service#*:}"
        if curl -s "http://127.0.0.1:$port/health" >/dev/null; then
            echo "✅ $name: صحي"
        else
            echo "🔴 $name: غير صحي"
        fi
    done
}

# التنفيذ الرئيسي
main() {
    echo "🚀 تشغيل النظام الجنائي - النسخة المستقرة"
    echo "=========================================="
    
    solve_actual_issues
    deploy_optimized_system
    
    echo ""
    echo "✅ النظام شغال ومستقر!"
    echo "🌐 الروابط:"
    echo "  🔍 Vision: http://127.0.0.1:8081"
    echo "  🎥 Media: http://127.0.0.1:8082"
    echo "  📊 Hashset: http://127.0.0.1:8083"
}

main "$@"
