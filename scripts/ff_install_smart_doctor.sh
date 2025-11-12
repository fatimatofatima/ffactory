#!/usr/bin/env bash
set -Eeuo pipefail

# ========= Basics =========
FF=/opt/ffactory
STACK=$FF/stack
S=$FF/scripts
LOGS=$FF/logs
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
ENV_FILE=$STACK/.env
MEMJSON=$FF/system_memory.json
PATH=/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p "$S" "$LOGS"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || { err "شغّل كـ root"; exit 1; }
command -v docker >/dev/null || { err "Docker غير موجود"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin غير متاح"; exit 1; }

# ========= Ensure ENV =========
install -d -m 755 "$STACK"
touch "$ENV_FILE"
if ! grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE"; then
  echo "COMPOSE_PROJECT_NAME=$PROJECT" >> "$ENV_FILE"
  log "ثبّت COMPOSE_PROJECT_NAME=$PROJECT في $ENV_FILE"
else
  sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$PROJECT/" "$ENV_FILE"
  log "ثبّت COMPOSE_PROJECT_NAME=$PROJECT (تحديث)"
fi

# ========= Patch dc() helper (ff_lib.sh) if exists =========
LIB="$S/ff_lib.sh"
if [[ -f "$LIB" ]] && ! grep -qE '^dc\(\)' "$LIB"; then
  cp -a "$LIB" "${LIB}.bak.$(date +%s)" || true
  cat >> "$LIB" <<'EOF_DC'

# --- Compose helper (bind to ffactory project) ---
dc() {
  local STACK="/opt/ffactory/stack"
  local ENV_FILE="$STACK/.env"
  docker compose --project-name ffactory \
                 --project-directory "$STACK" \
                 --env-file "$ENV_FILE" "$@"
}
EOF_DC
  log "أضفت dc() إلى ff_lib.sh"
fi

# ========= system_memory.sh (idempotent) =========
cat > "$S/system_memory.sh" <<'EOF_MEM'
#!/usr/bin/env bash
set -Eeuo pipefail
MEM="/opt/ffactory/system_memory.json"
mkdir -p /opt/ffactory

ensure_json(){ [[ -f "$MEM" ]] || echo '{"events":[],"services":{},"health_history":[]}' > "$MEM"; }

log_event(){
  ensure_json
  local event="$1" details="${2:-}"
  local ts; ts=$(date -Iseconds)
  python3 - "$MEM" "$ts" "$event" "$details" <<'PY'
import json,sys
p,ts,ev,det=sys.argv[1:]
with open(p) as f: d=json.load(f)
d.setdefault("events",[]).append({"timestamp":ts,"event":ev,"details":det})
d["events"]=d["events"][-100:]
with open(p,"w") as f: json.dump(d,f,indent=2)
PY
}

update_service(){
  ensure_json
  local svc="$1" status="$2" port="${3:-}"
  local ts; ts=$(date -Iseconds)
  python3 - "$MEM" "$svc" "$status" "$port" "$ts" <<'PY'
import json,sys
p,svc,status,port,ts=sys.argv[1:]
with open(p) as f: d=json.load(f)
s=d.setdefault("services",{}).get(svc,{})
s["last_seen"]=ts
s["last_status"]=status
if port: s["last_port"]=port
if status=="restarted": s["restart_count"]=int(s.get("restart_count",0))+1
d["services"][svc]=s
with open(p,"w") as f: json.dump(d,f,indent=2)
PY
}

case "${1:-}" in
  health_check)   log_event health_check "periodic" ;;
  system_start)   log_event system_start "boot" ;;
  system_stop)    log_event system_stop "stop" ;;
  service_restart) update_service "${2:-unknown}" "restarted" "${3:-}"; log_event service_restart "${2:-unknown}" ;;
  service_update)  update_service "${2:-unknown}" "${3:-unknown}" "${4:-}" ;;
  show)           ensure_json; cat "$MEM" ;;
  *) echo "usage: $0 {health_check|system_start|system_stop|service_restart <svc> [port]|service_update <svc> <status> [port]|show}"; exit 2 ;;
esac
EOF_MEM
chmod +x "$S/system_memory.sh"
log "ثبت system_memory.sh"

# ========= Ensure memory JSON valid =========
python3 - <<PY || echo '{"events":[],"services":{},"health_history":[]}' > "$MEMJSON"
import json; json.load(open("$MEMJSON"))
PY
log "تأكيد صلاحية $MEMJSON"

# ========= ff_health_lib.sh =========
cat > "$S/ff_health_lib.sh" <<'EOF_HL'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
FF=/opt/ffactory
STACK=$FF/stack

# Compose file discovery
detect_compose_files(){
  local -a base=(
    "$STACK/docker-compose.ultimate.yml"
    "$STACK/docker-compose.complete.yml"
    "$STACK/docker-compose.obsv.yml"
    "$STACK/docker-compose.prod.yml"
    "$STACK/docker-compose.dev.yml"
    "$STACK/docker-compose.yml"
  )
  local f; for f in "${base[@]}"; do [[ -f "$f" ]] && echo "$f"; done
  # Include any extra files
  find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' 2>/dev/null | sort -u
}

# docker compose wrapper for a specific file
dcf(){ docker compose -p "$PROJECT" -f "$1" "${@:2}"; }

# Map: service -> compose file
declare -Ag SVC2FILE
map_services_to_files(){
  SVC2FILE=()
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      SVC2FILE["$s"]="$f"
    done < <(dcf "$f" config --services 2>/dev/null || true)
  done < <(detect_compose_files | awk '!seen[$0]++')
}

# Find container by compose labels
container_name_for(){
  local svc="$1"
  docker ps -a \
    --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$svc" \
    --format "{{.Names}}" | head -1
}

# Smart HTTP probe from host first, then inside container
probe_http_smart(){
  local svc="$1" endpoint_list="${2:-/health,/ready,/live,/}"
  local cn host_port cport endpoints endpoint code
  cn=$(container_name_for "$svc")
  [[ -n "$cn" ]] || return 1
  endpoints=$(echo "$endpoint_list" | tr ',' ' ')

  # 1) try published host port
  host_port=$(docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
              | awk -F: '$3!=""{print $2":"$3; exit}')
  if [[ -n "$host_port" ]]; then
    for endpoint in $endpoints; do
      if curl -fsS "http://$host_port$endpoint" >/dev/null 2>&1 \
      || wget -qO- "http://$host_port$endpoint" >/dev/null 2>&1 \
      || (command -v nc >/dev/null 2>&1 && nc -z "$(cut -d: -f1 <<<"$host_port")" "$(cut -d: -f2 <<<"$host_port")"); then
        return 0
      fi
    done
  fi

  # 2) fallback inside container on first exposed port or 8080
  cport=$(docker inspect -f '{{range $k,$v:=.Config.ExposedPorts}}{{print $k}}{{"\n"}}{{end}}' "$cn" 2>/dev/null \
          | head -1 | sed 's#/tcp##; s#/udp##')
  [[ -z "$cport" ]] && cport=8080

  for endpoint in $endpoints; do
    docker exec "$cn" sh -lc "curl -fsS http://127.0.0.1:${cport}${endpoint} >/dev/null 2>&1" && return 0 || true
    docker exec "$cn" sh -lc "wget -qO-  http://127.0.0.1:${cport}${endpoint} >/dev/null 2>&1" && return 0 || true
    docker exec "$cn" sh -lc "command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 ${cport}" >/dev/null 2>&1 && return 0 || true
  done

  return 1
}

# Specialized probes (redis/pg/vault/etc.)
probe_service(){
  local svc="$1" cn http_ok
  cn=$(container_name_for "$svc") || true
  [[ -n "$cn" ]] || return 1

  case "$svc" in
    db)
      docker exec "$cn" pg_isready -U postgres >/dev/null 2>&1 && return 0
      (command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 5432) && return 0 || return 1
      ;;
    redis)
      docker exec "$cn" sh -lc 'redis-cli ping 2>/dev/null | grep -q PONG' && return 0 || true
      (command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 6379) && return 0 || return 1
      ;;
    neo4j)        probe_http_smart "$svc" "/,/browser,/health" && return 0 || return 1 ;;
    minio)        probe_http_smart "$svc" "/minio/health/live,/minio/health/ready,/minio/login,/" && return 0 || return 1 ;;
    metabase)     probe_http_smart "$svc" "/api/health,/" && return 0 || return 1 ;;
    grafana)      probe_http_smart "$svc" "/api/health,/login,/" && return 0 || return 1 ;;
    prometheus)   probe_http_smart "$svc" "/-/ready,/-,/metrics,/" && return 0 || return 1 ;;
    node-exporter) probe_http_smart "$svc" "/metrics,/" && return 0 || return 1 ;;
    cadvisor)     probe_http_smart "$svc" "/,/" && return 0 || return 1 ;;
    vault)
      # Accept common Vault health codes (200,429,472,473,501,503)
      local cn; cn=$(container_name_for "$svc")
      local host_port code
      host_port=$(docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
                  | awk -F: '$3!=""{print $2":"$3; exit}')
      if [[ -n "$host_port" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://$host_port/v1/sys/health" || echo 000)
        [[ "$code" =~ ^(200|429|472|473|501|503)$ ]] && return 0 || return 1
      fi
      probe_http_smart "$svc" "/v1/sys/health,/" && return 0 || return 1
      ;;
    ollama)       probe_http_smart "$svc" "/api/tags,/" && return 0 || return 1 ;;
    frontend-dashboard|api-gateway|investigation-api)
                  probe_http_smart "$svc" "/health,/ready,/live,/" && return 0 || return 1 ;;
    *)
      probe_http_smart "$svc" "/health,/ready,/live,/" && return 0 || return 1
      ;;
  esac
}

restart_service(){
  local svc="$1"
  local f="${SVC2FILE[$svc]:-}"
  [[ -n "$f" ]] || { echo "no compose file for $svc" >&2; return 1; }
  dcf "$f" up -d "$svc"
}
EOF_HL
chmod +x "$S/ff_health_lib.sh"
log "ثبت ff_health_lib.sh"

# ========= ff_doctor_enhanced.sh =========
cat > "$S/ff_doctor_enhanced.sh" <<'EOF_DOC'
#!/usr/bin/env bash
# Enhanced Doctor: multi-compose walk + smart probes + memory integration
set -Eeuo pipefail
FF=/opt/ffactory
S=$FF/scripts
LOGS=$FF/logs
MEM=$S/system_memory.sh
. "$S/ff_health_lib.sh"

mkdir -p "$LOGS"
LOG="$LOGS/doctor_enhanced_$(date +%Y%m%d_%H%M%S).log"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG"; }
err(){ echo -e "${RED}[x]${NC} $*" | tee -a "$LOG"; }

record_restart(){ [[ -x "$MEM" ]] && "$MEM" service_restart "$1" >/dev/null 2>&1 || true; }
record_status(){  [[ -x "$MEM" ]] && "$MEM" service_update "$1" "$2" >/dev/null 2>&1 || true; }

main(){
  log "بدء الفحص المحسّن (multi-compose + smart-probes)"
  map_services_to_files

  local -a all
  while IFS= read -r k; do all+=("$k"); done < <(printf "%s\n" "${!SVC2FILE[@]}" | sort)
  log "اكتشفت ${#all[@]} خدمة عبر ملفات Compose متعددة"

  local ok=0 fixed=0 bad=0
  for svc in "${all[@]}"; do
    if probe_service "$svc"; then
      log "✅ $svc صحي"
      record_status "$svc" "ok"
      ((ok++))
      continue
    fi
    warn "$svc غير صحي — سأحاول إصلاحه"
    if restart_service "$svc"; then
      record_restart "$svc"
      sleep 5
      if probe_service "$svc"; then
        log "✅ $svc اتصلح وبقى صحي"
        record_status "$svc" "fixed"
        ((fixed++))
      else
        err "$svc لسه غير صحي بعد الإصلاح"
        record_status "$svc" "still-bad"
        ((bad++))
      fi
    else
      err "تعذّر تشغيل/إصلاح $svc"
      record_status "$svc" "restart-failed"
      ((bad++))
    fi
  done

  log "النتيجة: ok=$ok | fixed=$fixed | bad=$bad"
  log "سجلّ اللوج: $LOG"
}
main "$@"
EOF_DOC
chmod +x "$S/ff_doctor_enhanced.sh"
log "ثبت ff_doctor_enhanced.sh"

# ========= Quick run once =========
log "تشغيل الدكتور المحسّن أول مرة..."
"$S/ff_doctor_enhanced.sh" || true

# ========= Optional Grafana test (only if service exists) =========
log "تحقق من وجود grafana لاختبار restart_count..."
GFILE=""
# اكتشف خريطة الخدمات/ملفاتها سريعًا
declare -Ag SVC2FILE
. "$S/ff_health_lib.sh"
map_services_to_files
if [[ -n "${SVC2FILE[grafana]:-}" ]]; then
  GFILE="${SVC2FILE[grafana]}"
  log "Grafana موجودة في: $GFILE"

  # عدّاد قبل
  BEFORE=$(python3 - <<'PY'
import json,sys
p="/opt/ffactory/system_memory.json"
try:
  d=json.load(open(p))
  print(int(d.get("services",{}).get("grafana",{}).get("restart_count",0)))
except Exception:
  print(0)
PY
)
  log "restart_count(grafana) قبل = $BEFORE"

  # أوقفها وشغّل الدكتور
  dcf "$GFILE" stop grafana || true
  sleep 2
  "$S/ff_doctor_enhanced.sh" || true

  AFTER=$(python3 - <<'PY'
import json,sys
p="/opt/ffactory/system_memory.json"
try:
  d=json.load(open(p))
  print(int(d.get("services",{}).get("grafana",{}).get("restart_count",0)))
except Exception:
  print(0)
PY
)
  log "restart_count(grafana) بعد  = $AFTER"
else
  warn "grafana غير موجودة حالياً—تخطي الاختبار."
fi

log "تم التثبيت والتشغيل."
