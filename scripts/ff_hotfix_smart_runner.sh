#!/usr/bin/env bash
# FFactory Smart Hotfix Runner — idempotent
set -Eeuo pipefail

export COMPOSE_IGNORE_ORPHANS=1
FF=/opt/ffactory
S=$FF/scripts
STACK=$FF/stack
LOGS=$FF/logs
MEMJSON=$FF/system_memory.json
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
mkdir -p "$S" "$LOGS" "$STACK"

say(){ printf "[+] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*\n" >&2; }
die(){ printf "[x] %s\n" "$*\n" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "docker missing"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"

# 0) ثبّت اسم المشروع
grep -q '^COMPOSE_PROJECT_NAME=' "$STACK/.env" 2>/dev/null || echo "COMPOSE_PROJECT_NAME=$PROJECT" >> "$STACK/.env"

# 1) system_memory.sh — آمن وذرّي
sudo tee "$S/system_memory.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
MEM="/opt/ffactory/system_memory.json"
tmp(){ mktemp -p /tmp smem.XXXX.json; }
ensure_json(){
  if ! python3 - <<'PY'
import json,sys
p="/opt/ffactory/system_memory.json"
try:
  d=json.load(open(p))
  assert isinstance(d,dict)
except Exception:
  raise SystemExit(1)
PY
  then
    echo '{"events":[],"services":{},"health_history":[]}' > "$MEM"
  fi
}
write_json(){
  t=$(mktemp -p /tmp smem.XXXX.json)
  cat > "$t"
  mv -f "$t" "$MEM"
}
log_event(){ # log_event <event> [details]
  ensure_json
  python3 - "$MEM" "$1" "${2:-}" <<'PY'
import json,sys,datetime,os,tempfile
p,ev,det = sys.argv[1:]
try:
  d=json.load(open(p))
except: d={"events":[],"services":{},"health_history":[]}
d.setdefault("events",[]).append({"timestamp":datetime.datetime.now().isoformat(timespec="seconds"),"event":ev,"details":det})
d["events"]=d["events"][-200:]
tf=tempfile.NamedTemporaryFile(delete=False)
json.dump(d,tf,indent=2,ensure_ascii=False); tf.close()
os.replace(tf.name,p)
PY
}
service_update(){ # service_update <svc> <status> [port]
  ensure_json
  python3 - "$MEM" "$1" "$2" "${3:-}" <<'PY'
import json,sys,datetime,os,tempfile
p,svc,status,port = sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4] if len(sys.argv)>4 else ""
try: d=json.load(open(p))
except: d={"events":[],"services":{},"health_history":[]}
s=d.setdefault("services",{}).get(svc,{})
s["last_seen"]=datetime.datetime.now().isoformat(timespec="seconds")
s["last_status"]=status
if port: s["last_port"]=port
d["services"][svc]=s
tf=tempfile.NamedTemporaryFile(delete=False)
json.dump(d,tf,indent=2,ensure_ascii=False); tf.close()
os.replace(tf.name,p)
PY
}
service_restart(){ # service_restart <svc> [port]
  ensure_json
  python3 - "$MEM" "$1" "${2:-}" <<'PY'
import json,sys,datetime,os,tempfile
p,svc,port=sys.argv[1],sys.argv[2],sys.argv[3] if len(sys.argv)>3 else ""
try: d=json.load(open(p))
except: d={"events":[],"services":{},"health_history":[]}
s=d.setdefault("services",{}).get(svc,{})
s["restart_count"]=int(s.get("restart_count",0))+1
s["last_seen"]=datetime.datetime.now().isoformat(timespec="seconds")
if port: s["last_port"]=port
d["services"][svc]=s
d.setdefault("events",[]).append({"timestamp":datetime.datetime.now().isoformat(timespec="seconds"),"event":"service_restart","details":svc})
d["events"]=d["events"][-200:]
tf=tempfile.NamedTemporaryFile(delete=False)
json.dump(d,tf,indent=2,ensure_ascii=False); tf.close()
os.replace(tf.name,p)
PY
}
case "${1:-}" in
  health_check) log_event health_check periodic;;
  service_restart) service_restart "${2:-unknown}" "${3:-}";;
  service_update) service_update "${2:-unknown}" "${3:-unknown}" "${4:-}";;
  show) ensure_json; cat "$MEM";;
  *) echo "usage: $0 {health_check|service_restart <svc> [port]|service_update <svc> <status> [port]|show}";;
esac
SH
chmod +x "$S/system_memory.sh"
"$S/system_memory.sh" health_check || true

# 2) ff_health_lib.sh — بروبس ذكية + تجاهل الأيتام + انتظار
sudo tee "$S/ff_health_lib.sh" >/dev/null <<'LIB'
#!/usr/bin/env bash
set -Eeuo pipefail

export COMPOSE_IGNORE_ORPHANS=1
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
FF=/opt/ffactory
STACK=$FF/stack

dcf(){ COMPOSE_IGNORE_ORPHANS=1 docker compose -p "$PROJECT" -f "$1" "${@:2}"; }

detect_compose_files(){
  local -a base=("$STACK"/docker-compose.ultimate.yml "$STACK"/docker-compose.complete.yml \
                 "$STACK"/docker-compose.obsv.yml "$STACK"/docker-compose.prod.yml \
                 "$STACK"/docker-compose.dev.yml "$STACK"/docker-compose.yml)
  local f; for f in "${base[@]}"; do [[ -f "$f" ]] && echo "$f"; done
  find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' 2>/dev/null | sort -u
}

declare -A SVC2FILE
map_services_to_files(){
  SVC2FILE=()
  local f svc
  for f in $(detect_compose_files); do
    # استخرج أسماء الخدمات تقريبيًا بين كتلة services:
    awk '
      $0 ~ /^services:/ {inS=1; next}
      inS && $0 ~ /^[^[:space:]]/ {inS=0}
      inS && $1 ~ /^[a-zA-Z0-9_.-]+:/ {gsub(":","",$1); print $1}
    ' "$f" 2>/dev/null | while read -r svc; do
      SVC2FILE["$svc"]="$f"
    done
  done
}

container_name_for(){
  local svc="$1"
  # ابحث بالليبل الرسمي للخدمة
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$svc" \
    --format '{{.Names}}' | head -n1
}

host_port_for(){
  local cn="$1"
  docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
   | awk -F: '$3!=""{print $2":"$3; exit}'
}

has_healthy_flag(){
  local cn="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cn" 2>/dev/null | grep -qx healthy
}

probe_http_smart(){
  local svc="$1" endpoints="${2:-/health,/ready,/live,/,/-/ready,/-/healthy,/metrics,/api/health}"
  local cn hostp
  cn=$(container_name_for "$svc"); [[ -z "$cn" ]] && return 1
  # 1) صحة الحاوية نفسها
  if has_healthy_flag "$cn"; then return 0; fi
  # 2) جرّب على البورت المنشور من الهوست
  hostp=$(host_port_for "$cn")
  if [[ -n "$hostp" ]]; then
    IFS=, read -ra arr <<<"$endpoints"
    for ep in "${arr[@]}"; do
      curl -fsS "http://$hostp$ep" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

probe_tcp_host(){
  # probe_tcp_host <host:port>
  local hp="$1"
  timeout 2 bash -c "echo > /dev/tcp/${hp/:/\/}" >/dev/null 2>&1
}

wait_for_service(){
  # wait_for_service <svc> [seconds]
  local svc="$1" t="${2:-60}" i=0
  while (( i < t )); do
    probe_service "$svc" && return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

probe_service(){
  local svc="$1"
  case "$svc" in
    prometheus)    probe_http_smart "$svc" "/-/ready,/-/healthy,/metrics,/" ;;
    grafana)       probe_http_smart "$svc" "/api/health,/login,/" ;;
    metabase)      probe_http_smart "$svc" "/api/health,/" ;;
    api-gateway|investigation-api|frontend-dashboard|feedback-api|behavioral-analytics)
                   probe_http_smart "$svc" "/health,/,/ready,/live" ;;
    neo4j)         probe_http_smart "$svc" "/,/" || probe_tcp_host "127.0.0.1:7474" ;;
    minio)         probe_http_smart "$svc" "/minio/health/live,/" ;;
    db)            probe_tcp_host "127.0.0.1:5433" || probe_tcp_host "127.0.0.1:5432" ;;
    redis)         probe_tcp_host "127.0.0.1:6379" ;;
    vault)         probe_http_smart "$svc" "/v1/sys/health,/" ;;
    ollama)        probe_http_smart "$svc" "/api/tags,/" ;;
    *)             probe_http_smart "$svc" "/health,/ready,/live,/" ;;
  esac
}

restart_service(){
  local svc="$1"
  local f="${SVC2FILE[$svc]:-}"
  local cn; cn=$(container_name_for "$svc" || true)
  if [[ -n "$f" ]]; then
    dcf "$f" up -d "$svc" >/dev/null 2>&1 && return 0
  fi
  if [[ -n "$cn" ]]; then
    docker restart "$cn" >/dev/null 2>&1 && return 0
  fi
  return 1
}
LIB
chmod +x "$S/ff_health_lib.sh"

# 3) ff_doctor_enhanced.sh — دكتور محسّن
sudo tee "$S/ff_doctor_enhanced.sh" >/dev/null <<'DOC'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
S=$FF/scripts
LOGS=$FF/logs
MEM=$S/system_memory.sh
. "$S/ff_health_lib.sh"

mkdir -p "$LOGS"
LOG="$LOGS/doctor_enhanced_$(date +%Y%m%d_%H%M%S).log"

say(){ echo "[+] $*" | tee -a "$LOG"; }
warn(){ echo "[!] $*" | tee -a "$LOG"; }
err(){ echo "[x] $*"  | tee -a "$LOG"; }

record_restart(){ [[ -x "$MEM" ]] && "$MEM" service_restart "$1" >/dev/null 2>&1 || true; }
record_status(){  [[ -x "$MEM" ]] && "$MEM" service_update "$1" "$2" >/dev/null 2>&1 || true; }

main(){
  say "بدء الفحص المحسّن"
  map_services_to_files

  # قائمة من النظام الجاري لتفادي نقص اكتشاف من ملفات YML
  mapfile -t running_svcs < <(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-ffactory}" \
    --format '{{.Label "com.docker.compose.service"}}' | sort -u)

  # دمج
  for svc in "${running_svcs[@]}"; do :; done
  for svc in "${!SVC2FILE[@]}"; do running_svcs+=( "$svc" ); done
  # فريد
  mapfile -t all_svcs < <(printf "%s\n" "${running_svcs[@]}" | awk 'NF' | sort -u)

  for svc in "${all_svcs[@]}"; do
    if probe_service "$svc"; then
      say "✅ $svc صحي"
      record_status "$svc" "ok"
    else
      warn "🔴 $svc غير صحي — إصلاح"
      if restart_service "$svc"; then
        record_restart "$svc"
        wait_for_service "$svc" 60 || true
        if probe_service "$svc"; then
          say "🟡 $svc تعافى"
          record_status "$svc" "fixed"
        else
          err "$svc مازال غير صحي"
          record_status "$svc" "still-bad"
        fi
      else
        err "فشل إعادة تشغيل $svc"
        record_status "$svc" "restart-failed"
      fi
    fi
  done
  say "انتهى"
}
main "$@"
DOC
chmod +x "$S/ff_doctor_enhanced.sh"

# 4) إصلاح JSON لو فاسد مسبقًا
python3 - <<'PY' || echo '{"events":[],"services":{},"health_history":[]}' > "$MEMJSON"
import json,sys; json.load(open("/opt/ffactory/system_memory.json"))
PY

# 5) تشغيل الدكتور مرة
"$S/ff_doctor_enhanced.sh" >/dev/null || true

# 6) اختباران سريعين: زيادة عدّاد Grafana + جاهزية Prometheus
GFILE="$STACK/docker-compose.obsv.yml"
if [[ -f "$GFILE" ]]; then
  docker compose -p "$PROJECT" -f "$GFILE" stop grafana >/dev/null 2>&1 || true
  "$S/ff_doctor_enhanced.sh" >/dev/null || true
fi

curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && echo "Prometheus READY" || echo "Prometheus not ready yet"
python3 - <<'PY'
import json,sys
p="/opt/ffactory/system_memory.json"
try:
  d=json.load(open(p))
  print("restart_count(grafana) =", d.get("services",{}).get("grafana",{}).get("restart_count",0))
except Exception as e:
  print("memory_json_error:", e)
PY
