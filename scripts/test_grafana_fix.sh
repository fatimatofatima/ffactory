#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
STACK=$FF/stack
SVC=grafana
MEM=$FF/system_memory.json
MEMCMD=$FF/scripts/system_memory.sh
DOCTOR=$FF/scripts/ff_doctor.sh

# 1) اختَر ملف الـ compose اللي فيه Grafana
choose_compose() {
  for f in \
    "$STACK/docker-compose.obsv.yml" \
    "$STACK/docker-compose.ultimate.yml" \
    "$STACK/docker-compose.complete.yml" \
    "$STACK/docker-compose.prod.yml" \
    "$STACK/docker-compose.dev.yml" \
    "$STACK/docker-compose.yml"
  do [[ -f "$f" ]] && docker compose -f "$f" ps --services 2>/dev/null | grep -qx "$SVC" && { echo "$f"; return; }
  done
  echo ""
}

F=$(choose_compose)
[[ -z "$F" ]] && { echo "[x] لم أجد خدمة $SVC في أي compose"; exit 2; }

# 2) جهّز الذاكرة
$MEMCMD health_check >/dev/null 2>&1 || true
[[ -f "$MEM" ]] || $MEMCMD system_start >/dev/null 2>&1

get_count(){ python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
try: d=json.load(open(p)); print(int(d.get("services",{}).get(s,{}).get("restart_count",0)))
except: print(0)
PY
}
BEFORE=$(get_count)

# 3) عطّل Grafana (ونضمن الرجوع في الآخر)
cleanup(){ docker compose -f "$F" up -d "$SVC" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker compose -f "$F" stop "$SVC" >/dev/null

# 4) شغّل الطبيب مرّة واحدة (هيسجّل في الذاكرة ويرستر)
bash "$DOCTOR" --once || true

# 5) تحقّق من رجوع الخدمة
docker compose -f "$F" ps "$SVC"
AFTER=$(get_count)

# آخر حدث restart مُسجّل
LAST_EVT=$(python3 - "$MEM" "$SVC" <<'PY'
import json,sys; p,s=sys.argv[1:]; 
d=json.load(open(p)); ev=[e for e in d.get("events",[]) if e.get("event")=="service_restart" and e.get("details")==s][-1:]
print(ev[0]["timestamp"] if ev else "none")
PY
)

echo "svc=$SVC before=$BEFORE after=$AFTER last_event=$LAST_EVT"
# فحص بسيط للمنفذ 3000 (اختياري)
if command -v curl >/dev/null; then
  curl -sS -m 3 http://127.0.0.1:3000/login >/dev/null && echo "[+] Grafana HTTP OK (:3000)"
fi
