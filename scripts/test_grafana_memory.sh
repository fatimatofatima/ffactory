#!/usr/bin/env bash
set -Eeuo pipefail

FF=/opt/ffactory
S=$FF/scripts
MEMJSON=$FF/system_memory.json
MEM=$S/system_memory.sh
DOCTOR=$S/ff_doctor_enhanced.sh
. "$S/ff_health_lib.sh"

PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

# تجهيز
map_services_to_files

# function: restart_count
count_of(){
python3 - "$MEMJSON" "$1" <<'PY'
import json,sys
p,svc=sys.argv[1:]
try:
  d=json.load(open(p))
  print(int(d.get("services",{}).get(svc,{}).get("restart_count",0)))
except:
  print(0)
PY
}

svc=grafana
f="$(compose_file_for "$svc" || true)"
c="$(container_name_for "$svc" || true)"

echo "[i] compose file for grafana: ${f:-<none>}"
echo "[i] container for grafana   : ${c:-<none>}"

# تسجيل baseline
[[ -x "$MEM" ]] && "$MEM" health_check >/dev/null 2>&1 || true
before="$(count_of "$svc")"
echo "[i] restart_count($svc) before = $before"

# إيقاف Grafana (من compose إن أمكن، وإلا الكونتينر)
if [[ -n "$f" ]]; then
  docker compose -p "$PROJECT" -f "$f" stop "$svc" >/dev/null || true
else
  [[ -n "$c" ]] && docker stop "$c" >/dev/null || true
fi

# تشغيل الدكتور المحسّن
"$DOCTOR" || true

# قراءة restart_count بعد الفحص
after="$(count_of "$svc")"
echo "[i] restart_count($svc) after  = $after"

# فحص أن Grafana رجعت سليمة من جوّا الكونتينر
. "$S/ff_health_lib.sh"
map_services_to_files
if probe_service "$svc"; then
  echo "[OK] grafana صحي بعد إصلاح الدكتور"
else
  echo "[!!] grafana مازال غير سليم — راجع اللوج"
fi
