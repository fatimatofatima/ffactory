#!/usr/bin/env bash
set -Eeuo pipefail
# FFIX: استخدام nc للانتظار الموثوق (يحتاج netcat-openbsd)
HOSTS=("db:5432" "neo4j:7687" "minio:9000" "redis:6379")
for host_port in "${HOSTS[@]}"; do
    host=${host_port%:*}
    port=${host_port#*:}
    echo "Waiting for $host:$port..."
    if ! timeout 60 bash -c "while ! nc -z $host $port; do sleep 1; done"; then
        echo "Error: $host:$port failed to start."
        exit 1
    fi
done
