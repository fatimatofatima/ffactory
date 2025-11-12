#!/bin/bash
echo "🩺 FFactory Doctor - الإصدار المصحح"
echo "==================================="
echo "✅ النظام: $(hostname)"
echo "⏰ الوقت: $(date)"
echo "🔧 فحص سريع..."
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "❌ Docker غير متاح"
echo "✅ الفحص اكتمل"
