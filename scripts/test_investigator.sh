#!/bin/bash
echo "🧠 اختبار المحقق الافتراضي الجديد..."
echo "======================================"

# اختبار الصحة
echo "1. 🔍 فحص صحة الخدمة..."
curl -s http://127.0.0.1:8005/health | jq .

# اختبار التحليل الاستخباراتي
echo ""
echo "2. 🎯 تشغيل التحليل الاستخباراتي..."
result=$(curl -s -X POST "http://127.0.0.1:8005/correlate/CASE_001")

echo "📊 النتائج:"
echo "$result" | jq '{
    status: .status,
    overall_risk_score: .overall_risk_score,
    risk_level: .risk_level,
    hypotheses_count: (.critical_hypotheses | length),
    recommendations_count: (.investigation_recommendations | length)
}'

# عرض الفرضيات
echo ""
echo "3. 🕵️ الفرضيات الاستخباراتية:"
echo "$result" | jq -r '.critical_hypotheses[]? | "\(.severity) - \(.type): \(.reason)"'

# عرض التوصيات
echo ""
echo "4. 📋 توصيات التحقيق:"
echo "$result" | jq -r '.investigation_recommendations[]? | "   • \(.)"'

echo ""
echo "✅ اختبار المحقق الافتراضي اكتمل!"
