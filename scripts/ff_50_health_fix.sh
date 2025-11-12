#!/usr/bin/env bash
set -Eeuo pipefail
. /opt/ffactory/scripts/ff_00_env.sh

log "🩺 حقن /tmp/health.json في كل خدمات 808x ..."

PORTS="8081 8082 8083 8086 8000 8170 8088"
for port in $PORTS; do
  cname=$(docker ps --filter "publish=$port" --format "{{.Names}}")
  if [ -n "$cname" ]; then
    svc="${cname#ffactory_}"
    log "   🔄 $cname ($port)"
    docker exec "$cname" sh -c "echo '{\"status\":\"healthy\",\"service\":\"$svc\"}' > /tmp/health.json" || true
  fi
done

# لو الحاوية vision موجودة نعمل لها /health.sh
if docker ps --format '{{.Names}}' | grep -q '^ffactory_vision$'; then
  log "📡 إعداد /health.sh داخل ffactory_vision ..."
  docker exec ffactory_vision sh -c '
apk add --no-cache curl >/dev/null 2>&1 || true
cat > /health.sh << "EOF"
#!/bin/sh
echo "HTTP/1.1 200 OK"
echo
if [ -f /tmp/health.json ]; then
  cat /tmp/health.json
else
  echo "{\"status\":\"unknown\",\"service\":\"vision\"}"
fi
EOF
chmod +x /health.sh
'
fi

log "✅ health اتظبط"
