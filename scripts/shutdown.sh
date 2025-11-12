#!/bin/bash
echo "🛑 إيقاف آمن لجميع الخدمات (51 خدمة)..."
cd "$STACK"
docker compose -p "$PROJECT" down --timeout 30
echo "✅ جميع الخدمات متوقفة"
