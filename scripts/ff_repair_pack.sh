#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

FF=/opt/ffactory
S=$FF/scripts
STACK=$FF/stack
LOGS=$FF/logs
ENV_FILE=$STACK/.env
MEM_JSON=$FF/system_memory.json

mkdir -p "$S" "$STACK" "$LOGS"

ok(){ echo -e "\033[0;32m[OK]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*" >&2; }
die(){ echo -e "\033[0;31m[x]\033[0m $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "شغّل كـ root"
command -v docker >/dev/null || die "Docker غير مثبت"
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin غير متاح"

# ---- حزم أساسية (ps, curl, jq, nc, tmux, inotify) ----
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y procps curl jq netcat-openbsd tmux inotify-tools >/dev/null 2>&1 || true
ok "ثبّت الحزم الأساسية"

# ---- ثبّت البيئة: اسم المشروع + تجاهل الأيتام عالمياً ----
mkdir -p /etc/profile.d
tee /etc/profile.d/ffactory.sh >/dev/null <<'E'
export COMPOSE_PROJECT_NAME=ffactory
export COMPOSE_IGNORE_ORPHANS=1
E
chmod +x /etc/profile.d/ffactory.sh
grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" 2>/dev/null \
  && sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=ffactory/' "$ENV_FILE" \
  || { mkdir -p "$(dirname "$ENV_FILE")"; echo 'COMPOSE_PROJECT_NAME=ffactory' >> "$ENV_FILE"; }
ok "ثبّت COMPOSE_PROJECT_NAME=ffactory و COMPOSE_IGNORE_ORPHANS=1"

# ---- system_memory.sh (كتابة أتوميك) ----
tee "$S/system_memory.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
MEM="/opt/ffactory/system_memory.json"
ensure(){
  if ! python3 - "$MEM" >/dev/null 2>&1 <<'PY'
import json,sys,os,tempfile
p=sys.argv[1]
try:
  json.load(open(p))
except:
  d={"events":[],"services":{},"health_history":[]}
  fd, tmp = tempfile.mkstemp(prefix="ffmem_",suffix=".json",dir=os.path.dirname(p) or ".")
  os.write(fd, bytes(__import__("json").dumps(d,indent=2), "utf-8")); os.close(fd)
  os.replace(tmp,p)
PY
  then :; fi
}
log_event(){ ensure; python3 - "$MEM" "$1" "$2" <<'PY'
import json,sys,datetime; p,e,d=sys.argv[1:]; D=json.load(open(p))
D["events"].append({"ts":datetime.datetime.now().isoformat(timespec="seconds"),"event":e,"details":d})
D["events"]=D["events"][-200:]; open(p,"w").write(json.dumps(D,indent=2))
PY
}
update_service(){ ensure; python3 - "$MEM" "$1" "$2" "${3:-}" <<'PY'
import json,sys,datetime; p,svc,st,port=sys.argv[1:]
D=json.load(open(p)); S=D.setdefault("services",{}).get(svc,{})
S["last_seen"]=datetime.datetime.now().isoformat(timespec="seconds"); S["last_status"]=st
if port: S["last_port"]=port
if st=="restarted": S["restart_count"]=int(S.get("restart_count",0))+1
D["services"][svc]=S; open(p,"w").write(json.dumps(D,indent=2))
PY
}
case "${1:-}" in
  service_restart) update_service "${2:-unknown}" "restarted" "${3:-}"; log_event service_restart "${2:-unknown}";;
  service_update)  update_service "${2:-unknown}" "${3:-unknown}" "${4:-}";;
  show)            ensure; cat "$MEM";;
  *) echo "usage: $0 {service_restart <svc> [port]|service_update <svc> <status> [port]|show}"; exit 2;;
esac
SH
chmod +x "$S/system_memory.sh"
"$S/system_memory.sh" show >/dev/null 2>&1 || true
ok "ثبت system_memory.sh وتحقق من JSON"

# ---- ff_health_lib.sh كامل ----
tee "$S/ff_health_lib.sh" >/dev/null <<'LIB'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; STACK=$FF/stack
dcf(){ COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$1" "${@:2}"; }

detect_compose_files(){
  local -a base=("$STACK/docker-compose.ultimate.yml" "$STACK/docker-compose.complete.yml" "$STACK/docker-compose.obsv.yml" "$STACK/docker-compose.prod.yml" "$STACK/docker-compose.dev.yml" "$STACK/docker-compose.yml")
  local f; for f in "${base[@]}"; do [[ -f "$f" ]] && echo "$f"; done
  find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' 2>/dev/null | sort -u
}
declare -A SVC2FILE
map_services_to_files(){
  SVC2FILE=(); while read -r f; do
    [[ -f "$f" ]] || continue
    while read -r s; do [[ -n "$s" ]] && SVC2FILE["$s"]="$f"; done < <(docker compose -f "$f" config --services 2>/dev/null || true)
  done < <(detect_compose_files)
}
container_name_for(){
  local svc="$1" proj="${COMPOSE_PROJECT_NAME:-ffactory}"
  docker ps --format '{{.Names}}' | { grep -Fx "${proj}_${svc//-/_}" || grep -Fx "${proj}-${svc//_/-}" || true; }
}
host_port_of(){
  local cn="$1"
  docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
  | awk -F: '$3!=""{print $2":"$3; exit}'
}
http_ok(){
  local url="$1"
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && return 0
  wget -qO- "$url" >/dev/null 2>&1 && return 0
  return 1
}
probe_http_smart(){
  local svc="$1" endpoints="${2:-/health,/ready,/live,/,-/ready,-/healthy,/metrics,/api/health}"
  local cn hp ep
  cn="$(container_name_for "$svc")"; [[ -n "$cn" ]] || return 1
  hp="$(host_port_of "$cn")"
  for ep in ${endpoints//,/ }; do
    [[ -n "$hp" ]] && http_ok "http://${hp}${ep}" && return 0
  done
  # آخر محاولة من داخل الحاوية على 127.0.0.1:PORT (افتراضي 8080)
  dcf "${SVC2FILE[$svc]}" exec -T "$svc" sh -lc 'p=${PORT:-8080}; for e in '"${endpoints//,/ }"'; do wget -qO- "http://127.0.0.1:${p}${e}" >/dev/null 2>&1 && exit 0; done; exit 1' && return 0
  return 1
}
probe_service(){
  local svc="$1"
  case "$svc" in
    prometheus)          probe_http_smart "$svc" "/-/ready,/-/healthy,/metrics,/" ;;
    grafana)             probe_http_smart "$svc" "/api/health,/login,/" ;;
    frontend-dashboard)  probe_http_smart "$svc" "/health,/api/health,/ready" ;;  # 404 على / عادي
    metabase)            probe_http_smart "$svc" "/api/health,/" ;;
    minio)               probe_http_smart "$svc" "/minio/health/live" ;;
    neo4j)               http_ok "http://127.0.0.1:7474/" ;;
    db|postgres|postgresql)
                         dcf "${SVC2FILE[db]:-${SVC2FILE[postgresql]}}" exec -T "${svc}" sh -lc 'pg_isready -U postgres' >/dev/null 2>&1 ;;
    *)                   probe_http_smart "$svc" ;;
  esac
}
restart_service(){
  local svc="$1" f="${SVC2FILE[$svc]:-}"
  [[ -n "$f" ]] || return 1
  COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$f" restart "$svc" >/dev/null 2>&1 \
  || COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$f" up -d --no-deps "$svc" >/dev/null 2>&1
}
wait_for_service(){
  local svc="$1" t="${2:-60}" i=0
  while (( i < t )); do probe_service "$svc" && return 0; sleep 3; i=$((i+3)); done
  return 1
}
LIB
chmod +x "$S/ff_health_lib.sh"
ok "كتب ff_health_lib.sh كامل"

# ---- ff_doctor_enhanced.sh ----
tee "$S/ff_doctor_enhanced.sh" >/dev/null <<'DOC'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; S=$FF/scripts; LOGS=$FF/logs; MEM=$S/system_memory.sh
. "$S/ff_health_lib.sh"
mkdir -p "$LOGS"
log(){ echo "[+] $*"; }
main(){
  map_services_to_files
  for svc in "${!SVC2FILE[@]}"; do
    if probe_service "$svc"; then
      log "✅ $svc صحي"; "$MEM" service_update "$svc" ok >/dev/null 2>&1 || true
    else
      log "🔴 $svc غير صحي — إصلاح"
      if restart_service "$svc"; then
        "$MEM" service_restart "$svc" >/dev/null 2>&1 || true
        wait_for_service "$svc" 60 || true
        if probe_service "$svc"; then
          log "🟡 $svc تعافى"; "$MEM" service_update "$svc" fixed >/dev/null 2>&1 || true
        else
          echo "[!] $svc مازال غير سليم"; "$MEM" service_update "$svc" still-bad >/dev/null 2>&1 || true
        fi
      else
        echo "[x] فشل restart لـ $svc"; "$MEM" service_update "$svc" restart-failed >/dev/null 2>&1 || true
      fi
    fi
  done
}
main "$@"
DOC
chmod +x "$S/ff_doctor_enhanced.sh"
ok "كتب ff_doctor_enhanced.sh"

# ---- لوحة شاشة بسيطة + تحذير التعديلات (اختياري) ----
tee "$S/ff_board.sh" >/dev/null <<'BRD'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; S=$FF/scripts
alert(){
  echo -e "\033[1;33m[تحذير]\033[0m تغيّر ملف: $1 ($2) — راجع آخر أوامر التشغيل"
}
watch_changes(){
  command -v inotifywait >/dev/null 2>&1 || return 0
  inotifywait -mq -e modify,create,delete /opt/ffactory/scripts /opt/ffactory/stack | \
    while read -r dir ev file; do alert "$dir$file" "$ev"; done
}
( watch_changes ) & WPID=$!
trap 'kill $WPID 2>/dev/null || true' EXIT
while true; do
  clear
  echo "===== FFactory Live =====  ($(date '+%F %T'))"
  echo "Project: ${COMPOSE_PROJECT_NAME:-ffactory}    (COMPOSE_IGNORE_ORPHANS=${COMPOSE_IGNORE_ORPHANS:-0})"
  echo
  docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed '1,40!d'
  echo
  echo "--- memory.json (أهم العدّادات) ---"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.services | to_entries[] | "\(.key): restart=\(.value.restart_count // 0), status=\(.value.last_status // "n/a")"' /opt/ffactory/system_memory.json 2>/dev/null | sed -n '1,20p' || true
  fi
  echo
  echo "Hints: curl -sf http://127.0.0.1:9090/-/ready  (Prometheus)"
  echo "       curl -sf http://127.0.0.1:3001/health    (frontend-dashboard)"
  sleep 3
done
BRD
chmod +x "$S/ff_board.sh"
ok "ثبت لوحة ff_board.sh (تحذير عند أي تعديل)"

# ---- تشغيل دكتور مرة للتأكيد ----
"$S/ff_doctor_enhanced.sh" || true
ok "تشغيل doctor تم"

echo
ok "تم تثبيت الحزمة. للتشغيل الحي:  tmux new -s ffboard /opt/ffactory/scripts/ff_board.sh"
