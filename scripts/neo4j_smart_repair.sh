#!/usr/bin/env bash
# Neo4j Smart Repair — diagnose+fix+report (for ffactory stack)
set -Eeuo pipefail

OPS=/opt/ffactory/stack/docker-compose.ops.yml
PROJ=ffactory
SERVICE=neo4j
REPORT_DIR=/opt/ffactory/reports
TS=$(date +%F_%H%M%S)
LOG="$REPORT_DIR/neo4j_smart_${TS}.log"
NEWPW="${NEO4J_NEW_PASSWORD:-ChangeMe_12345!}"   # عدّل بمتغير بيئة لو حابب
RESET="${FF_RESET_NEO4J:-0}"                     # 1=backup+reset volume
LIM_OVR="${FF_AUTH_MINLEN_OVERRIDE:-0}"          # 1=خفض مؤقت لحد الطول
DEPS=("ingest-gateway" "graph-writer")          # خدمات تابعة لو وجدت

mkdir -p "$REPORT_DIR"

log(){ printf "[%(%F %T)T] %s\n" -1 "$*" | tee -a "$LOG" ; }
sec(){ echo "------------------------------------------------------------" | tee -a "$LOG"; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
require_cmd docker
require_cmd grep
require_cmd sed
require_cmd awk
require_cmd curl || true

# ---------- helpers ----------
container_id(){
  docker ps -aq --filter "label=com.docker.compose.project=${PROJ}" \
               --filter "label=com.docker.compose.service=${SERVICE}" | head -n1
}

compose_cfg_block(){
  docker compose -p "$PROJ" -f "$OPS" config | sed -n "/^services:/,\$p" \
  | sed -n "/^[[:space:]]*${SERVICE}:/,/^[[:space:]]*[a-zA-Z0-9_-]\+:/p"
}

fix_plugins_and_license(){
  log "Patch compose: unify plugin key + accept license"
  sed -i s/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g "$OPS" || true
  grep -q "NEO4J_ACCEPT_LICENSE_AGREEMENT" "$OPS" || \
    sed -i "/NEO4J_PLUGINS:/a\      NEO4J_ACCEPT_LICENSE_AGREEMENT: \"yes\"" "$OPS" || true
}

set_auth_password(){
  if [ ${#NEWPW} -lt 8 ]; then
    log "NEWPW < 8 chars; overriding to safe default"
    NEWPW="ChangeMe_12345!"
  fi
  log "Enforce NEO4J_AUTH to strong password in compose"
  # غيّر أي قيمة حالية
  sed -i -E "s|(NEO4J_AUTH:\s*)\"?neo4j/[^\"]+\"?|\1\"neo4j/${NEWPW}\"|g" "$OPS" || true
  sed -i -E "s|(NEO4J_AUTH:\s*)neo4j/[^\"]+|\1\"neo4j/${NEWPW}\"|g" "$OPS" || true

  # لو فيه .env أو env_file تفرض قيمة قديمة، بدّلها كمان
  if [ -f /opt/ffactory/stack/.env ]; then
    sed -i -E "s|^NEO4J_AUTH=.*$|NEO4J_AUTH=neo4j/${NEWPW}|" /opt/ffactory/stack/.env || true
  fi

  # بدّل أي env_files مشار إليها
  for f in $(grep -R --null -l -E ^NEO4J_AUTH=
