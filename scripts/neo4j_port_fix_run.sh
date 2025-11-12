#!/usr/bin/env bash
set -Eeuo pipefail

PROJ="${PROJ:-ffactory}"
OPS="/opt/ffactory/stack/neo4j.only.yml"
NAME="${NAME:-ffactory-neo4j-1}"
IMAGE="${IMAGE:-neo4j:5.26.14}"

BOOT_PW="${BOOT_PW:-ChangeMe_12345!}"      # كلمة الإقلاع الأولى
TARGET_PW="${TARGET_PW:-StrongPass_2025!}" # كلمة التشغيل النهائية

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

ports_scan(){
  log "scan ports 7474/7687"
  ss -ltnp 2>/dev/null | egrep '(:7474|:7687)' || true
  docker ps -a --format '{{.Names}}\t{{.Ports}}' | egrep '7474|7687' || true
}

kill_port_conflicts(){
  local bad; bad=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' \
    | awk '/:7474->|:7687->/ {print $1}' | sort -u)
  if [ -n "${bad:-}" ]; then
    log "stop: $bad"; docker stop $bad >/dev/null 2>&1 || true
    log "rm:   $bad"; docker rm   $bad >/dev/null 2>&1 || true
  fi
  # إن بقيت PIDs خارج Docker
  for P in 7474 7687; do
    pids=$(ss -ltnp | awk -v p=":$P" '$4 ~ p {print $NF}' | sed 's/.*pid=\([0-9]\+\).*/\1/' | sort -u)
    [ -n "${pids:-}" ] && { log "kill pids on $P: $pids"; kill -9 $pids || true; }
  done
}

write_compose(){
  cat > "$OPS" <<EOF
services:
  neo4j:
    image: ${IMAGE}
    container_name: ${NAME}
    restart: unless-stopped
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
    healthcheck:
      test: ["CMD", "bash", "-lc", "curl -fsS http://localhost:7474/ >/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 12
volumes:
  ${PROJ}_neo4j_data:
EOF
}

up(){
  log "compose up neo4j"
  docker compose -p "$PROJ" -f "$OPS" up -d --force-recreate --remove-orphans neo4j
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
  # تعطيل history expansion لعدم كسر ! في الباسورد
  docker exec -i "$NAME" bash -lc 'set +H; /var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p "$1" "$2"' -- "$1" "$2"
}

set_password(){
  log "try ping with BOOT_PW"
  if cypher "$BOOT_PW" 'RETURN 1;' >/dev/null 2>&1; then
    log "set TARGET_PW"
    cypher "$BOOT_PW" "ALTER CURRENT USER SET PASSWORD FROM \"$BOOT_PW\" TO \"$TARGET_PW\";" || true
  fi
  log "verify TARGET_PW"
  cypher "$TARGET_PW" 'RETURN 1;'
}

summary(){
  log "ready"
  echo "Open from server:  http://127.0.0.1:7474/browser/"
  echo "From خارج السيرفر: http://SERVER_PUBLIC_IP:7474"
  echo "Bolt:              bolt://SERVER_PUBLIC_IP:7687"
  echo "User: neo4j    Pass: ${TARGET_PW}"
}

main(){
  ports_scan
  kill_port_conflicts
  write_compose
  up
  wait_http || { log "HTTP still down"; ports_scan; exit 1; }
  set_password
  ports_scan
  summary
}
main
