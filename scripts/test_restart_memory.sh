#!/usr/bin/env bash
set -Eeuo pipefail
SVC="${1:-frontend-dashboard}"
PORT="${2:-3001}"
MEM=/opt/ffactory/system_memory.json
DOCTOR=/opt/ffactory/scripts/ff_doctor.sh
MEMCMD=/opt/ffactory/scripts/system_memory.sh

# تحضير ذاكرة
$MEMCMD health_check >/dev/null 2>&1 || true
[[ -f "$MEM" ]] || $MEMCMD system_start >/dev/null 2>&1

# قراءة العداد
get_count() {
python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
try: d=json.load(open(p)); print(int(d.get("services",{}).get(s,{}).get("restart_count",0)))
except: print(0)
PY
}

BEFORE=$(get_count)

# إسقاط الصحة مؤقتاً على المضيف
RULE_ADDED=0
if iptables -nL DOCKER-USER >/dev/null 2>&1; then
  iptables -I DOCKER-USER -p tcp --dport "$PORT" -j REJECT; RULE_ADDED=1
else
  iptables -I INPUT -p tcp --dport "$PORT" -j REJECT; RULE_ADDED=2
fi
cleanup() {
  case "$RULE_ADDED" in
    1) iptables -D DOCKER-USER -p tcp --dport "$PORT" -j REJECT || true ;;
    2) iptables -D INPUT       -p tcp --dport "$PORT" -j REJECT || true ;;
  esac
}
trap cleanup EXIT

# تشغيل الطبيب مرة واحدة
"$DOCTOR" --once || true

# قراءة النتائج
AFTER=$(get_count)

# آخر حدث
LAST_EVT=$(python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
d=json.load(open(p)); 
ev=[e for e in d.get("events",[]) if e.get("event")=="service_restart"][-1:] 
print(ev[0]["timestamp"] if ev else "none")
PY
)

printf "svc=%s port=%s before=%s after=%s last_event=%s\n" "$SVC" "$PORT" "$BEFORE" "$AFTER" "$LAST_EVT"
