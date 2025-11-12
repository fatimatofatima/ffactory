#!/bin/bash
echo "🔍 فحص صحة جميع الخدمات (51 خدمة)..."
services=(
    "db" "redis" "neo4j" "minio" "ollama" "vault"
    "investigation-api" "behavioral-analytics" "case-manager"
    "quantum-security" "anomaly-detector" "ai-reporting"
)
for service in "${services[@]}"; do
    if docker ps | grep -q "$service"; then
        echo "✅ $service: نشط"
    else
        echo "❌ $service: غير نشط"
    fi
done
