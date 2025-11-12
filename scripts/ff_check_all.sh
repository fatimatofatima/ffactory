#!/usr/bin/env bash
set -Eeuo pipefail
echo "[*] حاويات FFactory:"
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo; echo "[*] Health:"
for p in 8081 8082 8083 8086 8000 8170 8088; do
  curl -fsS "http://127.0.0.1:$p/health" 2>/dev/null | jq -c . || echo "port $p: no health"
done
