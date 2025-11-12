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
