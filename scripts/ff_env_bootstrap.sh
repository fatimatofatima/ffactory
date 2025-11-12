#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
ENV=$FF/.env
lock(){ sudo chattr +i "$ENV" 2>/dev/null || true; }
unlock(){ sudo chattr -i "$ENV" 2>/dev/null || true; }

install -d -m 755 "$FF/scripts"
[ -f "$ENV" ] || sudo install -m 600 /dev/null "$ENV"

unlock
# لا نستبدل قيمًا موجودة
grep -q '^POSTGRES_USER='        "$ENV" || echo "POSTGRES_USER=ffadmin"        | sudo tee -a "$ENV" >/dev/null
grep -q '^POSTGRES_PASSWORD='    "$ENV" || echo "POSTGRES_PASSWORD=ffpass"     | sudo tee -a "$ENV" >/dev/null
grep -q '^POSTGRES_DB='          "$ENV" || echo "POSTGRES_DB=ffactory"         | sudo tee -a "$ENV" >/dev/null
grep -q '^NEO4J_AUTH='           "$ENV" || echo "NEO4J_AUTH=neo4j/neo4jpass"   | sudo tee -a "$ENV" >/dev/null
grep -q '^MINIO_ROOT_USER='      "$ENV" || echo "MINIO_ROOT_USER=minioadmin"   | sudo tee -a "$ENV" >/dev/null
grep -q '^MINIO_ROOT_PASSWORD='  "$ENV" || echo "MINIO_ROOT_PASSWORD=minioadmin" | sudo tee -a "$ENV" >/dev/null
grep -q '^REDIS_PASSWORD='       "$ENV" || echo "REDIS_PASSWORD=ffredis"       | sudo tee -a "$ENV" >/dev/null
lock
echo "[ok] .env جاهز دون استبدال قيم موجودة"
