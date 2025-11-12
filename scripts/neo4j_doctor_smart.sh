#!/usr/bin/env bash
# Neo4j Doctor Smart — diagnose + fix + (re)compose
set -Eeuo pipefail

# -------- Vars (عدّلها إذا لزم) --------
PROJ="${PROJ:-ffactory}"
OPS="${OPS:-/opt/ffactory/stack/docker-compose.ops.yml}"
NEO4J_SERVICE="${NEO4J_SERVICE:-neo4j}"
NEO4J_CONT="${NEO4J_CONT:-ffactory-neo4j-1}"
NEO4J_TARGET_PW="${NEO4J_TARGET_PW:-StrongPass_2025!}"   # الهدف
NEO4J_OLD_PW="${NEO4J_OLD_PW:-ChangeMe_12345!}"          # الحالية (إن وجدت)
REPORT_DIR="${REPORT_DIR:-/opt/ffactory/reports}"
RESET_VOLUME="${RESET_VOLUME:-0}"                         # 1=backup+reset
RECREATE_COMPOSE="${RECREATE_COMPOSE:-0}"                 # 1=إعادة بناء الملف
WITH_APPS="${WITH_APPS:-0}"                               # 1=إضافة الخدمات الاختيارية لاحقًا

mkdir -p "$REPORT_DIR"
TS=$(date +%F_%H%M%S)
LOG="$REPORT_DIR/neo4j_doctor_${TS}.log"

log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG" ; }
sec(){ echo "------------------------------------------------------------" | tee -a "$LOG"; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }

# ---------- Compose template (سليم وبسيط) ----------
write_compose_min(){
cat > "$OPS" <<YAML
services:
  zookeeper:
    image: confluentinc/cp-zookeeper:7.4.0
    container_name: ffactory-zookeeper-1
    environment:
      ZOOKEEPER_CLIENT_PORT: "2181"
    networks: [ffactory_net]

  kafka:
    image: confluentinc/cp-kafka:7.4.0
    container_name: ffactory-kafka-1
    depends_on: [zookeeper]
    environment:
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
    networks: [ffactory_net]

  neo4j:
    image: neo4j:5
    container_name: ffactory-neo4j-1
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
    environment:
      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"
      NEO4J_AUTH: "neo4j/ChangeMe_12345!"
      NEO4J_PLUGINS: [apoc,graph-data-science]
      NEO4J_dbms_security_procedures_unrestricted: "apoc.*,gds.*"
    volumes:
      - ${PROJ}_neo4j_data:/data
    networks: [ffactory_net]

networks:
  ffactory_net: {}

volumes:
  ${PROJ}_neo4j_data: {}
YAML
}

validate_or_rebuild_compose(){
  if docker compose -p "$PROJ" -f "$OPS" config >/dev/null 2>&1; then
    log "Compose looks valid: $OPS"
  else
    log "Compose invalid — rebuilding a minimal, valid template"
    mkdir -p "$(dirname "$OPS")"
    write_compose_min
    docker compose -p "$PROJ" -f "$OPS" config >/dev/null
    log "Compose rebuilt OK"
  fi
}

patch_neo4j_env(){
  # توحيد المفاتيح وإجبار الرخصة والباسوورد
  sed -i s/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g "$OPS" || true
  grep -q "NEO4J_ACCEPT_LICENSE_AGREEMENT" "$OPS" || \
    sed -i "/NEO4J_PLUGINS:/a\      NEO4J_ACCEPT_LICENSE_AGREEMENT: \"yes\"" "$OPS"

  # ضبط الـ AUTH في كل الصيغ المحتملة
  sed -i -E "s|(NEO4J_AUTH:\s*)\"?neo4j/[^\"]+\"?|\1\"neo4j/${NEO4J_OLD_PW}\"|g" "$OPS" || true
  # نبدأ بالحالي (Old) داخل الملف، وبعد تشغيل الحاوية نبدّل للهدف عبر cypher-shell
}

kill_port_conflicts(){
  log "Check port conflicts on 7474/7687"
  local cs; cs=$(docker ps -a --format "{{.Names}}\t{{.Ports}}" | awk "/7474|7687/ {print \$1}" | sort -u)
  if [ -n "${cs:-}" ]; then
    log "Stopping: $cs"
    docker stop $cs >/dev/null 2>&1 || true
    log "Removing: $cs"
    docker rm $cs   >/dev/null 2>&1 || true
  else
    log "No port conflicts"
  fi
}

backup_and_reset_volume(){
  local vol_mount; vol_mount=$(docker volume inspect ${PROJ}_neo4j_data -f {{.Mountpoint}} 2>/dev/null || true)
  [ -z "$vol_mount" ] && { log "Neo4j data volume not found (skip reset)"; return; }
  local tarb="${REPORT_DIR}/neo4j_backup_${TS}.tar.gz"
  log "Backup & reset neo4j volume -> $tarb"
  tar -C "$vol_mount" -czf "$tarb" . 2>/dev/null || true
  find "$vol_mount" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
}

fix_volume_ownership(){
  local vol_mount; vol_mount=$(docker volume inspect ${PROJ}_neo4j_data -f {{.Mountpoint}} 2>/dev/null || true)
  [ -z "$vol_mount" ] && return
  log "Fix volume ownership (uid:gid 7474:7474)"
  chown -R 7474:7474 "$vol_mount" 2>/dev/null || true
}

compose_up(){
  log "Compose up $NEO4J_SERVICE"
  docker compose -p "$PROJ" -f "$OPS" up -d --force-recreate --no-deps "$NEO4J_SERVICE"
}

wait_http(){
  log "Wait for Neo4j HTTP on 127.0.0.1:7474"
  for i in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1; then
      log "Neo4j UI is up"
      return 0
    fi
    sleep 2
  done
  return 1
}

container_id(){
  docker ps -aqf "name=^${NEO4J_CONT}$"
}

tail_for_pwlen_error(){
  local cid; cid=$(container_id)
  [ -z "$cid" ] && return 1
  docker logs --tail 200 "$cid" 2>&1 | tee -a "$LOG" | grep -q "Invalid value for password" && return 9 || return 0
}

# تغيير الباسوورد بأمان حتى لو فيه "!"
change_password_inside(){
  local cid; cid=$(container_id)
  [ -z "$cid" ] && { log "No neo4j container found"; return 1; }
  log "Changing password (inside container) -> target"
  docker exec -i "$cid" bash -lc 
