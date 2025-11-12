#!/usr/bin/env bash
set -Eeuo pipefail
SVC="${1:-frontend-dashboard}"
MEM=/opt/ffactory/system_memory.json
MEMCMD=/opt/ffactory/scripts/system_memory.sh
DOCTOR=/opt/ffactory/scripts/ff_doctor.sh

command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 2; }

# جِب اسم الكونتينر
CID=$(docker ps --format '{{.Names}}' | grep -E "ffactory[_-]${SVC//-/_}$" || true)
[[ -z "$CID" ]] && CID=$(docker ps --format '{{.Names}}' | grep -i "$SVC" | head -1 || true)
[[ -z "$CID" ]] && { echo "Container for $SVC not found"; exit 3; }

# اعرف بورت منشور على الهوست
HP=$(docker port "$CID" 2>/dev/null | awk -F':' 'NR==1{print $2}')
[[ -z "$HP" ]] && { echo "No published port found for $CID"; exit 4; }

get_count() {
python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]
try: d=json.load(open(p)); print(int(d.get("services",{}).get(s,{}).get("restart_count",0)))
except: print(0)
PY
}

# حضّر الذاكرة
$MEMCMD health_check >/dev/null 2>&1 || true
[[ -f "$MEM" ]] || $MEMCMD system_start >/dev/null 2>&1

before=$(get_count)

# بلوك مؤقت على البورت
CHAIN=INPUT
iptables -nL DOCKER-USER >/dev/null 2>&1 && CHAIN=DOCKER-USER
iptables -I "$CHAIN" -p tcp --dport "$HP" -j REJECT
trap 'iptables -D "'"$CHAIN"'" -p tcp --dport "'"$HP"'" -j REJECT || true' EXIT

# شغّل الدكتور محاولة واحدة
if [[ -x "$DOCTOR" ]]; then
  "$DOCTOR" --once || true
else
  echo "doctor not found, doing manual compose restart"
  # fallback: هتسجل في الذاكرة + ريستارت يدوي يثبت المسار
  /opt/ffactory/scripts/system_memory.sh service_restart "$SVC" "$HP" || true
  # محاولة تخمين ملف compose المناسب:
  . /opt/ffactory/scripts/ff_lib.sh
  . /opt/ffactory/scripts/ff_lib_multi.sh
  F=$(svc_compose "$SVC" "$(detect_compose)")
  [[ -n "$F" ]] && docker compose -f "$F" restart "$SVC" || true
fi

after=$(get_count)
echo "svc=$SVC host_port=$HP before=$before after=$after"
