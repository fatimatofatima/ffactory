#!/usr/bin/env bash
set -Eeuo pipefail
LOGD="/opt/ffactory/logs"; mkdir -p "$LOGD"
LOGF="$LOGD/selfaware_$(date +%F).log"
note(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGF"; }

note "start self-aware monitor"

# A) فحص صحة بوابة المصنع
if curl -fsS http://127.0.0.1:8170/health >/dev/null; then
  note "health: ok"
else
  note "health: fail -> restarting sf-factory"
  systemctl restart sf-factory.service || note "warn: restart failed"
fi

# B) فحص compose لملفات صحيحة فقط
errors=0
while IFS= read -r -d '' f; do
  [[ ! -s "$f" ]] && continue
  if ! grep -Eq '^\s*services\s*:' "$f"; then
    note "skip (not compose): $f"
    continue
  fi
  if docker compose -f "$f" config >/dev/null 2>&1; then
    note "compose OK: $f"
  else
    note "compose ERROR: $f"; errors=$((errors+1))
  fi
done < <(find /opt/ffactory/stack -maxdepth 2 -type f -name "*.yml" -print0 2>/dev/null)

note "done. errors=$errors"
exit 0
