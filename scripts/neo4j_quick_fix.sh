#!/usr/bin/env bash
set -Eeuo pipefail
OPS=/opt/ffactory/stack/docker-compose.ops.yml
PROJ=ffactory
PW="${NEO4J_NEW_PASSWORD:-ChangeMe_12345!}"

echo "[*] Patch compose keys + license"
sed -i 's/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g' "$OPS" || true
grep -q 'NEO4J_ACCEPT_LICENSE_AGREEMENT' "$OPS" || sed -i '/NEO4J_PLUGINS:/a\      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"' "$OPS"

echo "[*] Enforce strong NEO4J_AUTH everywhere"
sed -i -E "s|(NEO4J_AUTH:\s*)\"?neo4j/[^\"]+\"?|\1\"neo4j/'"$PW"'\"|g" "$OPS" || true
[ -f /opt/ffactory/stack/.env ] && sed -i -E "s|^NEO4J_AUTH=.*$|NEO4J_AUTH=neo4j/$PW|" /opt/ffactory/stack/.env || true

echo "[*] Kill port conflicts on 7474/7687 (if any)"
NAMES=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | awk '/7474|7687/ {print $1}' | sort -u)
[ -n "$NAMES" ] && docker stop $NAMES >/dev/null 2>&1 || true
[ -n "$NAMES" ] && docker rm $NAMES   >/dev/null 2>&1 || true

echo "[*] Recreate neo4j"
docker compose -p "$PROJ" -f "$OPS" up -d --force-recreate --no-deps neo4j

echo "[*] Wait for HTTP 7474"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1; then echo "[*] UI up"; break; fi
  sleep 2
done

echo "[*] Cypher-shell ping"
CID=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJ" --filter "label=com.docker.compose.service=neo4j" | head -n1)
docker exec -it "$CID" bash -lc "/var/lib/neo4j/bin/cypher-shell -u neo4j -p '$PW' 'RETURN 1;'" || echo "[!] Ping failed (check logs)"

echo "[*] Done"
