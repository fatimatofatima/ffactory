#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مثبت"
command -v curl >/dev/null || warn "curl غير موجود على المضيف. فحوص HTTP ستُقلّ."

FF=/opt/ffactory
S=$FF/scripts
APPS=$FF/apps
STACK=$FF/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
install -d -m 755 "$S" "$APPS" "$STACK"

# ---------- 1) Entrypoint انتظاري آمن ----------
EP="$S/docker-entrypoint.wait.sh"
cat >"$EP" <<'EP'
#!/usr/bin/env bash
set -Eeuo pipefail
wait_tcp(){ # host port timeout
  local h="$1" p="$2" t="${3:-180}" c=0
  while ! bash -c ">/dev/tcp/$h/$p" 2>/dev/null; do
    sleep 2; c=$((c+2)); ((c>=t)) && return 1
  done
  return 0
}
wait_first(){ # name host "p1 p2 p3" [timeout]
  local n="$1" h="$2" plist="$3" t="${4:-180}"
  echo "Waiting for $n at $h on ports: $plist"
  local start=$(date +%s)
  while :; do
    for p in $plist; do wait_tcp "$h" "$p" 2 && { echo "$n ready on $p"; exec "$@"; exit 0; }; done
    sleep 2
    (( $(date +%s) - start >= t )) && { echo "Timeout $n"; exit 1; }
  done
}

# DB: جرّب 5433 ثم 5432 افتراضياً
if [[ -n "${DB_HOST:-}" || -n "${DB_PORT:-}" ]]; then
  wait_first PostgreSQL "${DB_HOST:-db}" "${DB_PORT:-5433} 5432" 180 "$@" || exit 1
fi
# Neo4j: جرّب 7687 Bolt
if [[ -n "${NEO4J_HOST:-}" || -n "${NEO4J_PORT:-}" ]]; then
  wait_first Neo4j "${NEO4J_HOST:-neo4j}" "${NEO4J_PORT:-7687}" 180 "$@" || exit 1
fi
# Redis اختياري
if [[ "${WAIT_REDIS:-0}" = "1" ]]; then
  wait_first Redis "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}" 60 "$@" || exit 1
fi

exec "$@"
EP
chmod +x "$EP"

# ---------- 2) حقن ENTRYPOINT لخدمات Python ----------
patched=0
shopt -s nullglob
for DF in "$APPS"/*/Dockerfile; do
  [[ -f "$DF" ]] || continue
  grep -qiE '^[[:space:]]*FROM[[:space:]]+.*python' "$DF" || continue
  dir="$(dirname "$DF")"
  install -m 755 "$EP" "$dir/docker-entrypoint.sh"
  if ! grep -qE 'ENTRYPOINT *\["/usr/local/bin/docker-entrypoint.sh"\]' "$DF"; then
    if grep -qE '^[[:space:]]*CMD' "$DF"; then
      awk -v add='COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
' 'BEGIN{done=0}
     { if(!done && $0 ~ /^[[:space:]]*CMD/){ printf "%s", add; done=1 } print }' "$DF" >"$DF.tmp" && mv "$DF.tmp" "$DF"
    else
      cat >>"$DF" <<'EOFADD'
# FFIX: dependency waiter
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
EOFADD
    fi
    patched=$((patched+1))
  fi
done
log "Dockerfiles patched: $patched"

# ---------- 3) Override صحي (Prometheus + Frontend + extra_hosts) ----------
HC="$STACK/docker-compose.health.yml"
cat >"$HC" <<'YAML'
services:
  prometheus:
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/-/ready >/dev/null"]
      interval: 15s
      timeout: 3s
      retries: 10
  grafana:
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 5
  frontend-dashboard:
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/health >/dev/null"]
      interval: 30s
      timeout: 5s
      retries: 5
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML

# ---------- 4) تجميع ملفات compose كمصفوفة صحيحة ----------
declare -a ARGS=()
# كل ملفات stack باستثناء health ثم أضف health أخيراً
while IFS= read -r -d '' f; do
  [[ "$(basename "$f")" == "docker-compose.health.yml" ]] && continue
  ARGS+=(-f "$f")
done < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' -print0 | sort -z)
ARGS+=(-f "$HC")
((${#ARGS[@]})) || die "لا توجد ملفات compose في $STACK"

# ---------- 5) down/build/up بدون --remove-orphans ----------
export COMPOSE_IGNORE_ORPHANS=1
log "compose down ..."
docker compose -p "$PROJECT" "${ARGS[@]}" down -v || true

log "build --no-cache ..."
docker compose -p "$PROJECT" "${ARGS[@]}" build --no-cache

log "up -d ..."
docker compose -p "$PROJECT" "${ARGS[@]}" up -d

# ---------- 6) فحوص سريعة بعد الإقلاع ----------
sleep 25

log "حالة الحاويات:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

if command -v curl >/dev/null; then
  curl -sf http://127.0.0.1:9090/-/ready >/dev/null && log "Prometheus READY" || warn "Prometheus NOT ready"
  front_ok=0
  for p in 3001 3000; do
    curl -sf "http://127.0.0.1:$p/health" >/dev/null && { log "Frontend OK on :$p"; front_ok=1; break; }
  done
  [[ $front_ok -eq 1 ]] || warn "Frontend NOT healthy"
  if curl -sf http://127.0.0.1:9191/summary >/dev/null; then
    log "ff-healthd summary:"; curl -sS http://127.0.0.1:9191/summary
  fi
fi

# ---------- 7) تلميحات تشغيل دقيقة ----------
cat <<'TIP'
== نصائح تنفيذ حرجة ==
1) عرّف بيئياً على الخدمات التي تعتمد قواعد البيانات قبل البناء/التشغيل:
   DB_HOST=db DB_PORT=5433 NEO4J_HOST=neo4j NEO4J_PORT=7687  (و WAIT_REDIS=1 عند الحاجة)
   الـ ENTRYPOINT سيَنتظر تلقائياً 5433 ثم 5432.

2) فحوص الصحة تعتمد /-/ready لـ Prometheus و /api/health لـ Grafana و /health للواجهة.
   لا تفحص الجذر /. لا تعتمد ps داخل الحاويات.

3) بعد الاستقرار، شغّل ETL في correlation-engine بعد Neo4j:
   فهارس/قيود للعُقَد (:Person, :File, :Event) ثم ضخ العلاقات.

4) للصوت واللغة:
   asr-engine: faster-whisper + pyannote.audio
   neural-core: CAMeL Tools أو AraBERT للـ NER العربي.

انتهى.
TIP
