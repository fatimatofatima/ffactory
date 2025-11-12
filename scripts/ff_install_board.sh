#!/usr/bin/env bash
set -Eeuo pipefail

FF=/opt/ffactory
S=$FF/scripts
LOGS=$FF/logs
STACK=$FF/stack
ENV_FILE=$STACK/.env
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

mkdir -p "$S" "$LOGS"

say(){ printf "[+] %s\n" "$*"; }
warn(){ printf "[!] %s\n" "$*" >&2; }
die(){ printf "[x] %s\n" "$*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || die "شغّل كـ root"
command -v docker >/dev/null || die "Docker غير موجود"
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin غير موجود"

# أدوات مساعدة (اختياري لكنها مفيدة)
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y tmux inotify-tools jq >/dev/null 2>&1 || true

# ثبّت COMPOSE_PROJECT_NAME
grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" 2>/dev/null \
  && sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=ffactory/' "$ENV_FILE" \
  || echo 'COMPOSE_PROJECT_NAME=ffactory' >> "$ENV_FILE"
say "ثبّت COMPOSE_PROJECT_NAME=ffactory"

# ===== system_memory.sh (لو مش موجود) =====
if ! [ -x "$S/system_memory.sh" ]; then
  say "تثبيت system_memory.sh"
  tee "$S/system_memory.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
MEM="/opt/ffactory/system_memory.json"
ensure(){ [[ -s "$MEM" ]] || echo '{"events":[],"services":{},"health_history":[]}' > "$MEM"; }
log_event(){ ensure; python3 - "$MEM" "$1" "$2" <<'PY'
import json,sys,datetime; p,ev,det=sys.argv[1:]; d=json.load(open(p))
d["events"].append({"timestamp":datetime.datetime.now().isoformat(timespec="seconds"),"event":ev,"details":det})
d["events"]=d["events"][-200:]; open(p,"w").write(json.dumps(d,indent=2))
PY
}
update_service(){ ensure; python3 - "$MEM" "$1" "$2" "${3:-}" <<'PY'
import json,sys,datetime; p,svc,status,port=sys.argv[1:]; d=json.load(open(p))
s=d.setdefault("services",{}).get(svc,{})
s["last_seen"]=datetime.datetime.now().isoformat(timespec="seconds")
s["last_status"]=status
if port: s["last_port"]=port
if status=="restarted": s["restart_count"]=int(s.get("restart_count",0))+1
d["services"][svc]=s; open(p,"w").write(json.dumps(d,indent=2))
PY
}
case "${1:-}" in
  service_restart) update_service "${2:-unknown}" "restarted" "${3:-}"; log_event service_restart "${2:-unknown}";;
  service_update)  update_service "${2:-unknown}" "${3:-unknown}" "${4:-}";;
  health_check)    log_event health_check "periodic";;
  show)            ensure; cat "$MEM";;
  *) echo "usage: $0 {service_restart <svc> [port]|service_update <svc> <status> [port]|health_check|show}"; exit 2;;
esac
SH
  chmod +x "$S/system_memory.sh"
fi

# ===== مكتبة الصحة الذكية (اعتمادها) =====
# لو عندك ff_health_lib.sh موجود، هنستخدمه كما هو. لو ناقص، هنضيف دوال أساسية مطلوبة للوحة.
if ! grep -q 'probe_service()' "$S/ff_health_lib.sh" 2>/dev/null; then
  say "تجهيز ff_health_lib.sh مبسّط (probe + map)"
  tee "$S/ff_health_lib.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; STACK=$FF/stack
dcf(){ COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$1" "${@:2}"; }

detect_compose_files(){ ls -1 "$STACK"/docker-compose*.yml 2>/dev/null || true; }

declare -A SVC2FILE
map_services_to_files(){
  SVC2FILE=()
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r s; do
      [ -n "$s" ] && SVC2FILE["$s"]="$f"
    done < <(docker compose -f "$f" config --services 2>/dev/null || true)
  done < <(detect_compose_files)
}

container_name_for(){
  local svc="$1" f="${SVC2FILE[$svc]:-}"; [ -n "$f" ] || return 1
  # صيغة compose v2: اسم المشروع + "_" + الخدمة
  local proj="${COMPOSE_PROJECT_NAME:-ffactory}"
  # بعض ملفات obsv بتستخدم "-" بدل "_"
  local name1="${proj}_${svc//-/_}"
  local name2="${proj}-${svc//_/-}"
  docker ps --format '{{.Names}}' | { grep -Fx "$name1" || grep -Fx "$name2" || true; }
}

probe_http_smart(){
  # probe_http_smart <svc> [list_of_endpoints]
  local svc="$1" endpoints="${2:-/health,/ready,/live,/,-/ready,-/healthy,/metrics,/api/health}"
  local cn host_port
  cn="$(container_name_for "$svc" 2>/dev/null || true)" || return 1
  # جرّب البورت المنشور
  host_port="$(docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
               | awk -F: '$3 !="" {print $2":"$3; exit}')"
  for ep in ${endpoints//,/ }; do
    if [ -n "$host_port" ] && curl -fsS "http://${host_port}${ep}" >/dev/null 2>&1; then return 0; fi
    # محاولة داخل الحاوية على 127.0.0.1 إن فشل البورت المنشور
    if dcf "${SVC2FILE[$svc]}" exec -T "$svc" sh -lc "timeout 5 curl -fsS http://127.0.0.1:${PORT:-8080}${ep} >/dev/null 2>&1"; then
      return 0
    fi
  done
  return 1
}

probe_service(){
  local svc="$1"
  # قواعد خاصة
  case "$svc" in
    redis)    docker exec "$(container_name_for "$svc")" redis-cli ping 2>/dev/null | grep -q PONG && return 0 || return 1 ;;
    neo4j)    curl -fsS http://127.0.0.1:7474/ >/dev/null 2>&1 && return 0 || return 1 ;;
    minio)    curl -fsS http://127.0.0.1:9001/minio/health/live >/dev/null 2>&1 && return 0 || return 1 ;;
    db|postgres|postgresql) docker exec "$(container_name_for db)" pg_isready -U postgres >/dev/null 2>&1 && return 0 || return 1 ;;
    prometheus) probe_http_smart "$svc" "/-/ready,/metrics,/" && return 0 || return 1 ;;
    grafana)  probe_http_smart "$svc" "/api/health,/login,/" && return 0 || return 1 ;;
    *)        probe_http_smart "$svc" && return 0 || return 1 ;;
  esac
}

restart_service(){
  local svc="$1" f="${SVC2FILE[$svc]:-}"; [ -n "$f" ] || return 1
  COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$f" restart "$svc" >/dev/null 2>&1 \
    || COMPOSE_IGNORE_ORPHANS=1 docker compose -p "${COMPOSE_PROJECT_NAME:-ffactory}" -f "$f" up -d --no-deps "$svc" >/dev/null 2>&1
}
SH
  chmod +x "$S/ff_health_lib.sh"
else
  # ضمان تجاهل الأيتام
  sed -i 's/docker compose/COMPOSE_IGNORE_ORPHANS=1 docker compose/g' "$S/ff_health_lib.sh" || true
fi

# ===== ff_board.sh (لوحة حيّة) =====
tee "$S/ff_board.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; S=$FF/scripts; LOGS=$FF/logs; ALERT="$LOGS/.ff_alert"
. "$S/ff_health_lib.sh"
MEM="$FF/system_memory.json"

color(){ tput setaf "$1"; }
bold(){ tput bold; }
reset(){ tput sgr0; }

ensure_alert_watcher(){
  command -v inotifywait >/dev/null 2>&1 || return 0
  ( setsid bash -c '
      set -Eeuo pipefail
      WATCH="/opt/ffactory/stack /opt/ffactory/scripts /opt/ffactory/system_memory.json"
      while true; do
        inotifywait -qq -e modify,create,delete,move $WATCH 2>/dev/null | {
          read -r path action file || true
          echo "$(date +%H:%M:%S) | ${path}${file:-} | ${action}" > "'"$ALERT"'"
        }
      done
    ' >/dev/null 2>&1 & ) || true
}

get_restart_count(){
  command -v jq >/dev/null 2>&1 && jq -r --arg s "$1" '.services[$s].restart_count // 0' "$MEM" 2>/dev/null || \
  python3 - "$MEM" "$1" 2>/dev/null <<'PY'
import json,sys; p,svc=sys.argv[1:]; 
try: d=json.load(open(p)); print(d.get("services",{}).get(svc,{}).get("restart_count",0))
except: print(0)
PY
}

draw(){
  clear
  echo -e "$(bold)FFactory Live Board$(reset)  $(date '+%Y-%m-%d %H:%M:%S')"
  [ -s "$ALERT" ] && { echo; color 3; echo "⚠ تنبيه تغيّر ملف: $(cat "$ALERT")"; reset; }

  map_services_to_files
  local ok=0 bad=0 unk=0 total=0
  for svc in "${!SVC2FILE[@]}"; do total=$((total+1)); if probe_service "$svc"; then ok=$((ok+1)); else bad=$((bad+1)); fi; done

  echo
  echo "الإجمالي: $total  | صحي: $ok  | مشاكل: $bad"
  echo
  printf "%-26s  %-8s  %-8s  %s\n" "SERVICE" "STATE" "RESTARTS" "COMPOSE FILE"
  printf "%-26s  %-8s  %-8s  %s\n" "-------" "-----" "--------" "-----------"

  # اعرض حتى 24 خدمة بشكل ثابت
  local count=0
  for svc in $(printf "%s\n" "${!SVC2FILE[@]}" | sort); do
    state="BAD"
    if probe_service "$svc"; then state="OK"; fi
    case "$state" in
      OK) color 2;;
      BAD) color 1;;
      *) color 7;;
    esac
    printf "%-26s  %-8s  %-8s  %s\n" "$svc" "$state" "$(get_restart_count "$svc")" "${SVC2FILE[$svc]##*/}"
    reset
    count=$((count+1)); [ $count -ge 24 ] && break
  done

  echo
  echo "n: تحديث فوري  | q: خروج  | r <svc>: إصلاح خدمة  | g: توليد تقرير HTML"
}

repair_one(){
  local svc="$1"
  map_services_to_files
  if restart_service "$svc"; then
    "$S/system_memory.sh" service_restart "$svc" >/dev/null 2>&1 || true
    sleep 5
  fi
}

html_report(){
  local out="$LOGS/board_$(date +%Y%m%d_%H%M%S).html"
  map_services_to_files
  {
    echo "<html><head><meta charset='utf-8'><title>FFactory Board</title></head><body>"
    echo "<h3>FFactory Board - $(date)</h3>"
    echo "<table border=1 cellpadding=4 cellspacing=0>"
    echo "<tr><th>Service</th><th>State</th><th>Restarts</th><th>Compose</th></tr>"
    for svc in $(printf "%s\n" "${!SVC2FILE[@]}" | sort); do
      if probe_service "$svc"; then st="OK"; col="green"; else st="BAD"; col="red"; fi
      rc="$(get_restart_count "$svc")"
      printf "<tr><td>%s</td><td style='color:%s'>%s</td><td>%s</td><td>%s</td></tr>\n" \
        "$svc" "$col" "$st" "$rc" "${SVC2FILE[$svc]##*/}"
    done
    echo "</table></body></html>"
  } > "$out"
  echo "Report: $out"
}

main(){
  ensure_alert_watcher
  stty -echo -icanon time 0 min 0 || true
  trap 'stty sane; exit 0' INT TERM
  while true; do
    draw
    # مفاتيح سريعة غير حاجبة
    read -r -t 1 key rest || true
    case "${key:-}" in
      q) stty sane; exit 0 ;;
      n) : ;; # مجرد إعادة رسم
      r) [ -n "$rest" ] && repair_one "$rest" ;;
      g) html_report; sleep 2 ;;
    esac
  done
}
main "$@"
SH
chmod +x "$S/ff_board.sh"
say "ثبت ff_board.sh (لوحة حيّة)"

# ===== خدمة systemd لتثبيت اللوحة على شاشة مستقلة (tmux) =====
tee /etc/systemd/system/ff-board.service >/dev/null <<'UNIT'
[Unit]
Description=FFactory Live Board (tmux session)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/tmux new -d -s ffboard '/opt/ffactory/scripts/ff_board.sh'
ExecStop=/usr/bin/tmux kill-session -t ffboard
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ff-board.service >/dev/null 2>&1 || true
say "شغّلنا ff-board.service (جلسة tmux اسمها: ffboard)"

# تلميح سريع للوصول
say "للعرض: tmux attach -t ffboard   | للخروج من العرض: Ctrl-b ثم d"
say "لتوليد تنبيه عند أي تعديل ملفات، تم تفعيل inotify داخل اللوحة تلقائيًا (سطر تحذير أصفر أعلى الشاشة)."
