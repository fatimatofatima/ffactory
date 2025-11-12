#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/ffactory/stack

# تشغيل core يجب أن يكون جاهزًا مسبقًا
docker compose -p ffactory -f docker-compose.core.yml up -d

# بناء وتشغيل الحزم المتقدمة
docker compose -p ffactory -f docker-compose.advanced.yml build --parallel
docker compose -p ffactory -f docker-compose.core.yml -f docker-compose.advanced.yml up -d

echo "== health =="
curl -sf http://127.0.0.1:8000/health && echo || true
curl -sf http://127.0.0.1:8080/health && echo || true

docker compose -p ffactory -f docker-compose.core.yml ps
docker compose -p ffactory -f docker-compose.advanced.yml ps
