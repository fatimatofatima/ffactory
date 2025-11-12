#!/usr/bin/env bash
set -e
echo "🔍 صحة الخدمات:"
for x in \
 "db:5433" "redis:6379" "neo4j-http:7474" "neo4j-bolt:7687" \
 "minio-api:9000" "minio-console:9001" "metabase:3000" \
 "neural-core:8000" "correlation:8005" "ai-reporting:8080" \
 "advanced-forensics:8015" "ollama:11434"
do
  n=${x%%:*}; p=${x##*:}
  if curl -sSf "http://127.0.0.1:$p/health" >/dev/null 2>&1 || nc -z 127.0.0.1 "$p"; then
    echo "✅ $n ($p)"
  else
    echo "❌ $n ($p)"
  fi
done
