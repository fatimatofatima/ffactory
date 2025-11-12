#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; S=$FF/scripts; MEM=$FF/system_memory.json
D=$S/ff_doctor_enhanced.sh; F=/opt/ffactory/stack/docker-compose.obsv.yml

fix_json(){ python3 - <<'PY' || echo '{"events":[],"services":{},"health_history":[]}' > "$1"
import json,sys; json.load(open(sys.argv[1]))
PY
}
count(){ python3 - <<'PY'
import json; d=json.load(open("/opt/ffactory/system_memory.json"))
print(d.get("services",{}).get("grafana",{}).get("restart_count",0))
PY
}
fix_json "$MEM"
BEFORE=$(count)
echo "[i] restart_count(grafana) before = $BEFORE"
docker compose -p ffactory -f "$F" stop grafana
"$D"
AFTER=$(count)
echo "[i] restart_count(grafana) after  = $AFTER"
docker compose -p ffactory -f "$F" ps grafana || true
