#!/usr/bin/env bash
set -Eeuo pipefail
SVC="${1:-frontend-dashboard}"
MEM=/opt/ffactory/system_memory.json
MEMCMD=/opt/ffactory/scripts/system_memory.sh
DOCTOR=/opt/ffactory/scripts/ff_doctor.sh

command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 2; }

get_count() {
python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
try:
  d=json.load(open(p)); print(int(d.get("services",{}).get(s,{}).get("restart_count",0)))
except: print(0)
PY
}

# جهّز الذاكرة
$MEMCMD health_check >/dev/null 2>&1 || true
[[ -f "$MEM" ]] || $MEMCMD system_start >/dev/null 2>&1

BEFORE=$(get_count)

# اعثر على الكونتينر + IP + كل البورتات المنشورة
CID=$(docker ps --format '{{.ID}} {{.Names}}' | awk -v s="$SVC" 'BEGIN{IGNORECASE=1} $2 ~ s{print $1; exit}')
[[ -z "$CID" ]] && { echo "container for $SVC not found"; exit 3; }
CIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CID" | awk '{print $1}')
PORTS=($(docker port "$CID" 2>/dev/null | awk -F: '{print $2}'))

# اختَر سلسلة مناسبة
CHAIN=DOCKER-USER
iptables -nL DOCKER-USER >/dev/null 2>&1 || CHAIN=INPUT

# احجب كل الترافيك للكونتينر (بالـIP) + كل البورتات المنشورة كـ fallback
RULES=()
if [[ -n "$CIP" ]]; then
  iptables -I "$CHAIN" -d "$CIP" -j REJECT; RULES+=("$CHAIN -d $CIP -j REJECT")
fi
for p in "${PORTS[@]}"; do
  iptables -I "$CHAIN" -p tcp --dport "$p" -j REJECT; RULES+=("$CHAIN -p tcp --dport $p -j REJECT")
done

cleanup() {
  for r in "${RULES[@]}"; do iptables -D $r 2>/dev/null || true; done
}
trap cleanup EXIT

# شغّل الدكتور محاولة واحدة (هيستخدم wrappers الجديدة)
if [[ -x "$DOCTOR" ]]; then
  "$DOCTOR" --once || true
else
  echo "doctor not found, manual fallback"
  /opt/ffactory/scripts/system_memory.sh service_restart "$SVC" "" || true
fi

AFTER=$(get_count)

# آخر حدث
LAST_EVT=$(python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
d=json.load(open(p)); ev=[e for e in d.get("events",[]) if e.get("event")=="service_restart" and e.get("details")==s][-1:] 
print(ev[0]["timestamp"] if ev else "none")
PY
)

echo "svc=$SVC before=$BEFORE after=$AFTER last_event=$LAST_EVT"
