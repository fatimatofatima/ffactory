#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/ffactory/stack/.env || true
check(){ curl -fsS "$1" >/dev/null && echo "✅ OK  $1" || echo "⚠️ FAIL $1"; }
check "http://127.0.0.1:${FRONTEND_PORT:-3000}/"
check "http://127.0.0.1:${INVESTIGATION_API_PORT:-8080}/health"
check "http://127.0.0.1:${ANALYTICS_PORT:-8090}/health"
check "http://127.0.0.1:${FEEDBACK_API_PORT:-8070}/health"
check "http://127.0.0.1:8060/health"
check "http://127.0.0.1:8001/health"
check "http://127.0.0.1:${NEO4J_HTTP_PORT:-7474}/"
check "http://127.0.0.1:${MINIO_PORT:-9002}/"
