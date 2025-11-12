#!/usr/bin/env bash
# FFactory Neo4j Doctor — fix&run&report
set -Eeuo pipefail

OPS=/opt/ffactory/stack/docker-compose.ops.yml
PROJ=ffactory
NET=ffactory_default
REPORT_DIR=/opt/ffactory/reports
LOG_FILE="$REPORT_DIR/neo4j_${PROJ}_$(date +%F_%H%M%S).log"
RESET="${FF_RESET_NEO4J:-0}"   # ضع 1 لعمل reset آمن مع باك أب للفوليم

mkdir -p "$REPORT_DIR"

log(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
sec(){ echo "------------------------------------------------------------"; }

log "Start Neo4j Doctor"

# 0) نظافة بسيطة
if grep -qE '^version:' "$OPS" 2>/dev/null; then
  log "Removing obsolete 'version:' from compose"
  sed -i '/^version:/d' "$OPS" || true
fi

# 1) تأكيد وجود خدمة neo4j بمتغيرات صحيحة
if ! grep -qE '^\s*neo4j:' "$OPS"; then
  log "Appending neo4j service to $OPS"
  cat >> "$OPS" <<'YAML'
  neo4j:
    image: neo4j:5.20
    restart: unless-stopped
    environment:
      NEO4J_AUTH: "neo4j/test123"
      NEO4J_PLUGINS: '["apoc","graph-data-science"]'
      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"
      NEO4J_dbms_security_procedures_unrestricted: "apoc.*,gds.*"
      NEO4J_dbms_security_procedures_allowlist: "apoc.*,gds.*"
      NEO4J_server_memory_heap_initial__size: "512m"
      NEO4J_server_memory_heap_max__size: "1024m"
      NEO4J_server_memory_pagecache_size: "512m"
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
    volumes:
      - neo4j_data:/data
      - neo4j_logs:/logs
      - neo4j_plugins:/plugins
    networks:
      - ffactory_net
YAML
else
  log "Patching env keys in existing neo4j service"
  sed -i 's/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g' "$OPS" || true
  # اجبر صيغة JSON مظبوطة للبلجنز
  if ! grep -q 'NEO4J_PLUGINS: .*apoc' "$OPS"; then
    awk '
      {print}
      /^\s*neo4j:/{inneo=1}
      inneo && /^\s*environment:/{inenv=1}
      inenv && /^\s*NEO4J_PLUGINS:/{
        print "      NEO4J_PLUGINS: '\''[\"apoc\",\"graph-data-science\"]'\''"
        next
      }
    ' "$OPS" > "$OPS.tmp" && mv "$OPS.tmp" "$OPS"
  fi
  # أضف قبول الرخصة لو ناقص
  grep -q 'NEO4J_ACCEPT_LICENSE_AGREEMENT' "$OPS" || \
    sed -i '/NEO4J_PLUGINS:/a\      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"' "$OPS"
  # أذونات الإجراءات
  grep -q 'dbms_security_procedures_unrestricted' "$OPS" || \
    sed -i '/NEO4J_ACCEPT_LICENSE_AGREEMENT:/a\      NEO4J_dbms_security_procedures_unrestricted: "apoc.*,gds.*"\n      NEO4J_dbms_security_procedures_allowlist: "apoc.*,gds.*"' "$OPS"
fi

# 2) تأكيد عدم وجود تضارب بورتات
log "Checking port conflicts (7474/7687)"
CONFLICTS=$(docker ps -a --format '{{.Names}}\t{{.Ports}}' | awk '/(0\.0\.0\.0|127\.0\.0\.1):7474|:7687/ {print $1}' | sort -u)
if [ -n "$CONFLICTS" ]; then
  log "Stopping/removing: $CONFLICTS"
  docker stop $CONFLICTS >/dev/null 2>&1 || true
  docker rm   $CONFLICTS >/dev/null 2>&1 || true
else
  log "No conflicts found"
fi

# 3) فوليمات + صلاحيات
for v in ${PROJ}_neo4j_data ${PROJ}_neo4j_logs ${PROJ}_neo4j_plugins; do
  docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null
done

DATA_MNT=$(docker volume inspect ${PROJ}_neo4j_data -f '{{.Mountpoint}}' 2>/dev/null || true)
LOGS_MNT=$(docker volume inspect ${PROJ}_neo4j_logs -f '{{.Mountpoint}}' 2>/dev/null || true)
PLUG_MNT=$(docker volume inspect ${PROJ}_neo4j_plugins -f '{{.Mountpoint}}' 2>/dev/null || true)

if [ -n "$DATA_MNT" ]; then chown -R 7474:7474 "$DATA_MNT" || true; fi
if [ -n "$LOGS_MNT" ]; then chown -R 7474:7474 "$LOGS_MNT" || true; fi
if [ -n "$PLUG_MNT" ]; then chown -R 7474:7474 "$PLUG_MNT" || true; fi

# 3.1) Reset اختياري مع باك أب
if [ "$RESET" = "1" ] && [ -n "$DATA_MNT" ]; then
  BK="$REPORT_DIR/neo4j_backup_$(date +%F_%H%M%S).tar.gz"
  log "Backup & reset data volume -> $BK"
  tar -czf "$BK" -C "$DATA_MNT" . >/dev/null 2>&1 || true
  find "$DATA_MNT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
  log "Data volume cleared"
fi

# 4) Up Neo4j
log "docker compose up neo4j"
docker compose -p "$PROJ" -f "$OPS" up -d --remove-orphans neo4j

# 5) انتظار UI / جمع لوجز
log "Waiting for http://127.0.0.1:7474 ..."
ok=0
for i in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:7474 >/dev/null 2>&1; then ok=1; break; fi
  # لو الحاوية ماتت بدري، اطلع
  if [ "$(docker inspect -f '{{.State.Running}}' ${PROJ}-neo4j-1 2>/dev/null || echo false)" != "true" ]; then
    break
  fi
  sleep 1
done

if [ "$ok" = "1" ]; then
  log "✅ Neo4j UI responding"
else
  log "❌ Neo4j not responding, capturing logs -> $LOG_FILE"
  docker logs ${PROJ}-neo4j-1 >"$LOG_FILE" 2>&1 || true
  tail -n 120 "$LOG_FILE" || true
fi

# 6) حاول اختبار cypher سريع لو اشتغل
if [ "$ok" = "1" ]; then
  if docker exec ${PROJ}-neo4j-1 bash -lc 'echo "RETURN 1;" | cypher-shell -u neo4j -p test123' >/dev/null 2>&1; then
    log "✅ Cypher-shell test OK"
  else
    log "⚠️  Cypher-shell test failed (check auth/latency)"
  fi
fi

# 7) ارفع الخدمات التابعة
log "Up ingest-gateway & graph-writer"
docker compose -p "$PROJ" -f "$OPS" up -d ingest-gateway graph-writer || true

sec
echo "=== OPS Status ==="
docker compose -p "$PROJ" -f "$OPS" ps
sec
echo "Report:"
echo "  Logs:     $LOG_FILE (if failure)"
echo "  Browser:  http://127.0.0.1:7474"
echo "  Bolt:     bolt://127.0.0.1:7687"
echo "  Reset DB: FF_RESET_NEO4J=1 $0   # (backs up then clears data volume)"
sec
