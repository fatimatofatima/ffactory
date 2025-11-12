#!/bin/bash
set -e

FILE="/opt/ffactory/stack/docker-compose.ultimate.yml"
BACKUP="${FILE}.backup.$(date +%Y%m%d_%H%M%S)"

echo "إنشاء نسخة احتياطية..."
cp "$FILE" "$BACKUP"

echo "بدء إصلاح ملف YAML..."

# استبدال جميع الـ inline dictionaries بصيغة multi-line
perl -0777 -i -pe 's/environment:\s*\{\s*([^}]+)\s*\}/environment:\n      \1/g' "$FILE"
perl -0777 -i -pe 's/healthcheck:\s*\{\s*([^}]+)\s*\}/healthcheck:\n      \1/g' "$FILE"
perl -0777 -i -pe 's/depends_on:\s*\{\s*([^}]+)\s*\}/depends_on:\n      \1/g' "$FILE"
perl -0777 -i -pe 's/build:\s*\{\s*([^}]+)\s*\}/build:\n      \1/g' "$FILE"
perl -0777 -i -pe 's/volumes:\s*\[\s*([^]]+)\s*\]/volumes:\n      - \1/g' "$FILE"
perl -0777 -i -pe 's/ports:\s*\[\s*([^]]+)\s*\]/ports:\n      - \1/g' "$FILE"
perl -0777 -i -pe 's/networks:\s*\[\s*([^]]+)\s*\]/networks:\n      - \1/g' "$FILE"

# استبدال الفواصل بأسطر جديدة في الـ environment
sed -i '/environment:/,/^[[:space:]]*[^[:space:]:]/s/, /\n      /g' "$FILE"

# استبدال الفواصل بأسطر جديدة في الـ healthcheck
sed -i '/healthcheck:/,/^[[:space:]]*[^[:space:]:]/s/, /\n      /g' "$FILE"

# استبدال الفواصل بأسطر جديدة في الـ depends_on
sed -i '/depends_on:/,/^[[:space:]]*[^[:space:]:]/s/, /\n      /g' "$FILE"

# استبدال الفواصل بأسطر جديدة في الـ build
sed -i '/build:/,/^[[:space:]]*[^[:space:]:]/s/, /\n      /g' "$FILE"

# تصحيح command لـ Redis بشكل صريح
sed -i 's|command: redis-server --requirepass ${REDIS_PASSWORD}|command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]|' "$FILE"

# إضافة مسافات بعد النقطتين في المفاتيح
sed -i 's/^\([[:space:]]*[a-zA-Z_-]\+\):\([^[:space:]]\)/\1: \2/' "$FILE"

# إصلاح المشاكل في services المدمجة (مثل السطور 95-116)
perl -0777 -i -pe 's/(\n  [a-zA-Z-]+:)\s*\{([^}]+)\}/\1\n    \2/g' "$FILE"

# استبدال الفواصل داخل services المدمجة
perl -0777 -i -pe 's/(\n    [a-zA-Z_]+: [^,\n]+),/\1\n    /g' "$FILE"

echo "تم إصلاح الملف بنجاح!"
echo "التحقق من صحة YAML..."

# اختبار الملف
if docker compose -f "$FILE" config > /dev/null 2>&1; then
    echo "✅ الملف صحيح الآن!"
else
    echo "⚠️  لا يزال هناك مشكلة، جرب الطريقة البديلة..."
    # الطريقة البديلة: إعادة إنشاء الملف
    cp "$BACKUP" "$FILE"
    
    # استخدام Python لإصلاح YAML
    python3 -c "
import yaml
import re

with open('$FILE', 'r') as f:
    content = f.read()

# استبدال جميع الـ inline dictionaries
content = re.sub(r'environment:\s*\{([^}]+)\}', r'environment:\n      \1', content)
content = re.sub(r'healthcheck:\s*\{([^}]+)\}', r'healthcheck:\n      \1', content)
content = re.sub(r'ports:\s*\[([^]]+)\]', r'ports:\n      - \1', content)
content = re.sub(r'volumes:\s*\[([^]]+)\]', r'volumes:\n      - \1', content)
content = re.sub(r'networks:\s*\[([^]]+)\]', r'networks:\n      - \1', content)

# استبدال command لـ Redis
content = re.sub(r'command: redis-server --requirepass \${REDIS_PASSWORD}', 
                 r'command: [\"redis-server\", \"--requirepass\", \"\${REDIS_PASSWORD}\"]', content)

# استبدال الفواصل بأسطر جديدة
content = re.sub(r',\s*', r'\n      ', content)

with open('$FILE', 'w') as f:
    f.write(content)
"
    echo "تم الإصلاح باستخدام Python"
fi
