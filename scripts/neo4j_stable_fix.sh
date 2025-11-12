#!/usr/bin/env bash
set -Eeuo pipefail

PROJ="${PROJ:-ffactory}"
OPS_NEW="${OPS_NEW:-/opt/ffactory/stack/docker-compose.neo4j.yml}"
CONT_NAME="${CONT_NAME:-ffactory-neo4j-1}"
IMAGE="${IMAGE:-neo4j:5.26.14}"
BOOT_PW="${BOOT_PW:-ChangeMe_12345!}"      # كلمة الإقلاع الأولى فقط
TARGET_PW="${TARGET_PW:-StrongPass_2025!}" # كلمة التشغيل النهائية
RESET="${RESET:-0}"                         # 1 لمسح داتا Neo4j نهائيا

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

write_compose(){
  cat > "$OPS_NEW" <<EOF
services:
  neo4j:
    image: ${IMAGE}
    container_name: ${CONT_NAME}
    ports:
      - "0.0.0.0:7474:7474"
      - "0.0.0.0:7687:7687"
    environment:
      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"
      NEO4J_PLUGINS: '["apoc","graph-data-science"]'
      NEO4J_dbms_security_procedures_unrestricted: "apoc.*,gds.*"
      NEO4J_AUTH: "neo4j/${BOOT_PW}"
    volumes:
      - ${PROJ}_neo4j_data:/data
volumes:
  ${PROJ}_neo4j_data:
EOF
}

kill_port_conflicts(){
  local names
  names=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | awk '/:7474->|:7687->/ {print $1}' | sort -u || true)
  [ -n "${names:-}" ] && { log "stop: $names"; docker stop $names >/dev/null 2>&1 || true; }
  [ -n "${names:-}" ] && { log "rm: $names"; docker rm $names >/dev/null 2>&1 || true; }
}

reset_volume_if_needed(){
  [ "$RESET" != "1" ] && return 0
  local mp
  mp=$(docker volume inspect ${PROJ}_neo4j_data -f '{{.Mountpoint}}' 2>/dev/null || true)
  [ -n "$mp" ] && { log "wipe data volume"; find "$mp" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true; }
}

compose_up(){
  log "compose up neo4j"
  docker compose -p "$PROJ" -f "$OPS_NEW" up -d --force-recreate --remove-orphans neo4j
}

wait_http(){
  log "wait http 7474"
  for i in $(seq 1 60); do
    curl -fsS http://127.0.0.1:7474/ >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

cypher(){
  docker exec -i "$CONT_NAME" bash -lc 'set +H; /var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p "$1" "$2"' -- "$1" "$2"
}

set_password(){
  log "try ping with BOOT_PW"
  if cypher "$BOOT_PW" 'RETURN 1;' >/dev/null 2>&1; then
    log "alter password to TARGET_PW"
    cypher "$BOOT_PW" "ALTER CURRENT USER SET PASSWORD FROM \"$BOOT_PW\" TO \"$TARGET_PW\";" || true
  fi
  log "ping TARGET_PW"
  cypher "$TARGET_PW" 'RETURN 1;'
}

show_endpoints(){
  log "ready"
  echo "HTTP:  http://SERVER_PUBLIC_IP:7474/browser/"
  echo "Bolt:  bolt://SERVER_PUBLIC_IP:7687"
  echo "User:  neo4j"
  echo "Pass:  ${TARGET_PW}"
}

main(){
  log "write compose"
  write_compose
  log "kill port conflicts"
  kill_port_conflicts
  reset_volume_if_needed
  compose_up
  wait_http || { log "http not up"; exit 1; }
  set_password
  show_endpoints
}
main
