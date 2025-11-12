#!/bin/bash
set -e

echo "🔍 بدء الفحص الشامل للنظام والأخطاء..."
echo "==========================================="

# الألوان لل输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# دالة للطباعة الملونة
print_status() {
    if [ "$1" = "SUCCESS" ]; then
        echo -e "${GREEN}✅ $2${NC}"
    elif [ "$1" = "ERROR" ]; then
        echo -e "${RED}❌ $2${NC}"
    elif [ "$1" = "WARNING" ]; then
        echo -e "${YELLOW}⚠️ $2${NC}"
    elif [ "$1" = "INFO" ]; then
        echo -e "${BLUE}ℹ️ $2${NC}"
    fi
}

# 1. فحص الهيكل الأساسي
echo ""
echo "1. 📁 فحص هيكل المجلدات..."
if [ -d "/opt/ffactory/stack" ]; then
    print_status "SUCCESS" "المجلد الرئيسي موجود"
    
    # فحص المجلدات الأساسية
    essential_dirs=("correlation-engine" "neural-core" "ai-reporting" "advanced-forensics" "scripts" "docs")
    for dir in "${essential_dirs[@]}"; do
        if [ -d "/opt/ffactory/stack/$dir" ]; then
            print_status "SUCCESS" "  - $dir موجود"
        else
            print_status "ERROR" "  - $dir مفقود"
        fi
    done
else
    print_status "ERROR" "المجلد الرئيسي /opt/ffactory/stack غير موجود"
fi

# 2. فحص ملفات docker-compose
echo ""
echo "2. 🐳 فحص تكوين Docker..."
compose_files=("docker-compose.ultimate.yml" "docker-compose.yml")
for file in "${compose_files[@]}"; do
    if [ -f "/opt/ffactory/stack/$file" ]; then
        print_status "SUCCESS" "  - $file موجود"
        # فحص إذا كان الملف فارغاً
        if [ ! -s "/opt/ffactory/stack/$file" ]; then
            print_status "ERROR" "    - الملف فارغ!"
        fi
    else
        print_status "WARNING" "  - $file غير موجود"
    fi
done

# 3. فحص الخدمات النشطة
echo ""
echo "3. 🔄 فحص حالة الخدمات..."
if command -v docker &> /dev/null; then
    print_status "SUCCESS" "Docker مثبت"
    
    # فحص إذا كان Docker يعمل
    if docker info &> /dev/null; then
        print_status "SUCCESS" "Docker daemon يعمل"
        
        # فحص الحاويات النشطة
        echo "   📊 الحاويات النشطة:"
        active_containers=$(docker ps --format "{{.Names}}" | wc -l)
        print_status "INFO" "   - عدد الحاويات النشطة: $active_containers"
        
        # قائمة الخدمات المتوقعة
        expected_services=("neural-core" "correlation-engine" "ai-reporting" "db" "redis" "neo4j" "ollama" "minio" "metabase")
        for service in "${expected_services[@]}"; do
            if docker ps --format "{{.Names}}" | grep -q "ffactory-$service"; then
                status=$(docker ps --filter "name=ffactory-$service" --format "{{.Status}}")
                print_status "SUCCESS" "   - $service: $status"
            else
                print_status "ERROR" "   - $service: غير نشط"
            fi
        done
        
    else
        print_status "ERROR" "Docker daemon لا يعمل"
    fi
else
    print_status "ERROR" "Docker غير مثبت"
fi

# 4. فحص المنافذ والاتصالات
echo ""
echo "4. 🔌 فحص المنافذ والاتصالات..."
expected_ports=("8000" "8005" "8080" "5433" "6379" "7474" "7687" "11434" "3000" "9001" "9002")
for port in "${expected_ports[@]}"; do
    if ss -tulpn | grep -q ":$port "; then
        service=$(ss -tulpn | grep ":$port " | awk '{print $5}' | head -1)
        print_status "SUCCESS" "  - Port $port: مفتوح ($service)"
    else
        print_status "ERROR" "  - Port $port: مغلق"
    fi
done

# 5. فحص ملف .env والإعدادات
echo ""
echo "5. ⚙️ فحص الإعدادات والبيئة..."
if [ -f "/opt/ffactory/stack/.env" ]; then
    print_status "SUCCESS" "ملف .env موجود"
    
    # فحص المتغيرات الأساسية
    essential_vars=("POSTGRES_PASSWORD" "MINIO_ROOT_PASSWORD" "NEO4J_AUTH")
    for var in "${essential_vars[@]}"; do
        if grep -q "^$var=" /opt/ffactory/stack/.env; then
            print_status "SUCCESS" "  - $var: مضبوط"
        else
            print_status "ERROR" "  - $var: غير مضبوط"
        fi
    done
else
    print_status "ERROR" "ملف .env مفقود"
fi

# 6. فحص قواعد البيانات
echo ""
echo "6. 🗄️ فحص اتصالات قواعد البيانات..."

# PostgreSQL
if pg_isready -h 127.0.0.1 -p 5433 &> /dev/null; then
    print_status "SUCCESS" "PostgreSQL: متصل على port 5433"
else
    print_status "ERROR" "PostgreSQL: غير متصل"
fi

# Redis
if redis-cli -h 127.0.0.1 -p 6379 ping &> /dev/null; then
    print_status "SUCCESS" "Redis: متصل على port 6379"
else
    print_status "ERROR" "Redis: غير متصل"
fi

# 7. فحص السكربتات
echo ""
echo "7. 📜 فحص السكربتات المساعدة..."
scripts_dir="/opt/ffactory/scripts"
if [ -d "$scripts_dir" ]; then
    essential_scripts=("test_investigator.sh" "audio_analysis.sh" "system_audit.sh")
    for script in "${essential_scripts[@]}"; do
        if [ -f "$scripts_dir/$script" ]; then
            if [ -x "$scripts_dir/$script" ]; then
                print_status "SUCCESS" "  - $script: موجود وقابل للتنفيذ"
            else
                print_status "WARNING" "  - $script: موجود لكن غير قابل للتنفيذ"
            fi
        else
            print_status "ERROR" "  - $script: مفقود"
        fi
    done
else
    print_status "ERROR" "مجلد السكربتات غير موجود"
fi

# 8. فحص التوثيق
echo ""
echo "8. 📚 فحص التوثيق..."
docs_dir="/opt/ffactory/docs"
if [ -d "$docs_dir" ]; then
    doc_files=("correlation-engine-enhanced.md" "api-endpoints.md")
    for doc in "${doc_files[@]}"; do
        if [ -f "$docs_dir/$doc" ]; then
            print_status "SUCCESS" "  - $doc: موجود"
        else
            print_status "WARNING" "  - $doc: مفقود"
        fi
    done
else
    print_status "WARNING" "مجلد التوثيق غير موجود"
fi

# 9. فحص موارد النظام
echo ""
echo "9. 💻 فحص موارد النظام..."
echo "   🖥️  استخدام الذاكرة:"
free -h | grep Mem | awk '{print "     - الذاكرة: " $3 " / " $2 " (" $4 " free)"}'

echo "   💾 استخدام التخزين:"
df -h /opt | awk 'NR==2 {print "     - التخزين: " $3 " / " $2 " (" $5 " used)"}'

echo "   🔄 استخدام المعالج:"
top -bn1 | grep "Cpu(s)" | awk '{print "     - المعالج: " $2 "% used"}'

# 10. فحص الأخطاء في السجلات
echo ""
echo "10. 📋 فحص الأخطاء في السجلات..."
echo "    سجلات Docker الأخيرة:"
docker logs ffactory-correlation-engine-1 --tail 5 2>/dev/null | while read line; do
    if echo "$line" | grep -q -i "error\|fail\|exception"; then
        print_status "ERROR" "    - $line"
    fi
done

# 11. فحص APIs الرئيسية
echo ""
echo "11. 🌐 فحص واجهات APIs..."
apis=(
    "http://127.0.0.1:8000/health"
    "http://127.0.0.1:8005/health" 
    "http://127.0.0.1:8080/health"
    "http://127.0.0.1:3000"
    "http://127.0.0.1:7474"
)

for api in "${apis[@]}"; do
    if curl -s --connect-timeout 5 "$api" > /dev/null; then
        print_status "SUCCESS" "  - $api: يستجيب"
    else
        print_status "ERROR" "  - $api: لا يستجيب"
    fi
done

# 12. تقرير النتائج
echo ""
echo "==========================================="
echo "📊 تقرير الفحص الشامل"
echo "==========================================="

# عد الأخطاء والتحذيرات
errors=$(grep -o "❌" <<< "$output" | wc -l)
warnings=$(grep -o "⚠️" <<< "$output" | wc -l)
success=$(grep -o "✅" <<< "$output" | wc -l)

echo "✅ المهام الناجحة: $success"
echo "⚠️  التحذيرات: $warnings" 
echo "❌ الأخطاء: $errors"
echo ""

if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
    print_status "SUCCESS" "🎉 النظام يعمل بشكل ممتاز!"
elif [ $errors -eq 0 ]; then
    print_status "WARNING" "⚠️ النظام يعمل مع بعض التحذيرات"
else
    print_status "ERROR" "🚨 هناك أخطاء تحتاج إلى معالجة!"
    
    echo ""
    echo "🔧 الإصلاحات المطلوبة:"
    
    # اقتراحات إصلاح بناءً على الأخطاء المكتشفة
    if ! docker ps | grep -q "ffactory-correlation-engine"; then
        echo "   - إعادة تشغيل correlation-engine: docker compose -p ffactory up -d correlation-engine"
    fi
    
    if ! ss -tulpn | grep -q ":8005 "; then
        echo "   - فتح port 8005 أو إعادة تشغيل الخدمة"
    fi
    
    if [ ! -d "/opt/ffactory/stack/correlation-engine" ]; then
        echo "   - إنشاء مجلد correlation-engine: mkdir -p /opt/ffactory/stack/correlation-engine"
    fi
fi

echo ""
echo "📝 للتشغيل الفوري: cd /opt/ffactory/stack && docker compose -p ffactory up -d"
echo "🌐 للواجهات: http://127.0.0.1:3000 (Metabase), http://127.0.0.1:8000/docs (Neural Core)"
