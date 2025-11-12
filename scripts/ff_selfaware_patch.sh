#!/usr/bin/env bash
set -Eeuo pipefail

FF=/opt/ffactory
S=$FF/scripts
DOCTOR=$S/ff_doctor.sh

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }
install -d -m 755 "$S"

# --- A) multi-compose helpers ---
cat >"$S/ff_lib_multi.sh"<<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory
STACK=$FF/stack

detect_compose_files() {
  local f
  for f in \
    "$STACK/docker-compose.ultimate.yml" \
    "$STACK/docker-compose.complete.yml" \
    "$STACK/docker-compose.obsv.yml" \
    "$STACK/docker-compose.prod.yml" \
    "$STACK/docker-compose.dev.yml" \
    "$STACK/docker-compose.yml"
  do [[ -f "$f" ]] && echo "$f"; done
}

compose_has_service() {
  local file="$1" svc="$2"
  command -v docker >/dev/null 2>&1 || return 1
  docker compose -f "$file" ps --services 2>/dev/null | grep -qx "$svc"
}

svc_compose() {
  local svc="$1" default="${2:-}"
  local f
  for f in $(detect_compose_files); do
    if compose_has_service "$f" "$svc"; then echo "$f"; return; fi
  done
  [[ -n "$default" ]] && echo "$default" || echo ""
}
EOF
chmod +x "$S/ff_lib_multi.sh"

# --- B) ضمّن multi-lib جوّه ff_lib.sh لو مش متضمّنة ---
if [[ -f "$S/ff_lib.sh" ]] && ! grep -q 'ff_lib_multi.sh' "$S/ff_lib.sh"; then
  sed -i '1a . /opt/ffactory/scripts/ff_lib_multi.sh || true' "$S/ff_lib.sh"
fi

# --- C) Patch ff_doctor.sh: mem hook + compose-aware wrappers + استبدال الأوامر ---
if [[ -f "$DOCTOR" ]]; then
  cp -a "$DOCTOR" "${DOCTOR}.bak.$(date +%s)"

  # 1) أدخل بلوك الباتش بعد الـ shebang مع الحفاظ عليه
  PATCHBLOCK=$(mktemp)
  cat >"$PATCHBLOCK"<<'EOX'
# FF_PATCH:BEGIN
. /opt/ffactory/scripts/ff_lib.sh 2>/dev/null || true
. /opt/ffactory/scripts/ff_lib_multi.sh 2>/dev/null || true
MEMORY_SCRIPT="/opt/ffactory/scripts/system_memory.sh"

_guess_port(){ # أحسن تخمين لبورت منشور
  local svc="$1" cn p
  cn=$(docker ps --format '{{.Names}}' | grep -E "ffactory[_-]${svc//-/_}$" || true)
  [[ -z "$cn" ]] && cn=$(docker ps --format '{{.Names}}' | grep -i "$svc" | head -1 || true)
  if [[ -n "$cn" ]]; then p=$(docker port "$cn" 2>/dev/null | head -1 | awk -F: '{print $2}'); fi
  echo "${p:-}"
}

mem_hook(){ # يسجل في الذاكرة قبل أي restart
  local svc="$1" p; p=$(_guess_port "$svc")
  [[ -x "$MEMORY_SCRIPT" ]] && "$MEMORY_SCRIPT" service_restart "$svc" "${p:-}" || true
}

docker_compose_restart(){ # compose-aware restart
  local svc="$1" F
  F="$(svc_compose "$svc" "$COMPOSE")"; [[ -n "$F" ]] || F="$COMPOSE"
  mem_hook "$svc"
  docker compose -f "$F" restart "$svc"
}

docker_compose_up(){ # compose-aware up --build
  local svc="$1" F
  F="$(svc_compose "$svc" "$COMPOSE")"; [[ -n "$F" ]] || F="$COMPOSE"
  docker compose -f "$F" up -d --build "$svc"
}
# FF_PATCH:END
EOX

  FIRSTLINE="$(head -n1 "$DOCTOR" || true)"
  TMP="${DOCTOR}.tmp"
  if [[ "$FIRSTLINE" =~ ^#! ]]; then
    { echo "$FIRSTLINE"; cat "$PATCHBLOCK"; tail -n +2 "$DOCTOR"; } > "$TMP"
  else
    { cat "$PATCHBLOCK"; cat "$DOCTOR"; } > "$TMP"
  fi
  mv "$TMP" "$DOCTOR"
  rm -f "$PATCHBLOCK"

  # 2) استبدالات مباشرة لأوامر docker compose في الدكتور
  sed -i -E \
    -e 's#docker[[:space:]]+compose[[:space:]]+-f[[:space:]]+"?\$COMPOSE"?[[:space:]]+restart[[:space:]]+"?\$svc"?#docker_compose_restart "$svc"#g' \
    -e 's#docker[[:space:]]+compose[[:space:]]+-f[[:space:]]+\$COMPOSE[[:space:]]+restart[[:space:]]+\$svc#docker_compose_restart "$svc"#g' \
    -e 's#docker[[:space:]]+compose[[:space:]]+-f[[:space:]]+"?\$COMPOSE"?[[:space:]]+up[[:space:]]+-d([[:space:]]+--build)?[[:space:]]+"?\$svc"?#docker_compose_up "$svc"#g' \
    "$DOCTOR"

  chmod +x "$DOCTOR"
else
  echo "[!] لم أجد $DOCTOR — باتش المكتبات فقط."
fi

# --- D) سكربت اختبار قوي يمنع كل الترافيك للكونتينر (بدون لمس الخدمة من الداخل) ---
cat >"$S/test_restart_memory_v3.sh"<<'EOF'
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
EOF
chmod +x "$S/test_restart_memory_v3.sh"

echo "[+] Patch completed."
