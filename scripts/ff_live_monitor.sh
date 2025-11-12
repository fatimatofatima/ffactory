#!/bin/bash
echo "📊 مراقبة حية للنظام الجنائي..."
watch -n 5 '
echo "=== حالة الخدمات ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "=== استخدام الموارد ==="
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -10
'
