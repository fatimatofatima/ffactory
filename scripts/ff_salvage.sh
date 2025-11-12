#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير مثبت"
docker compose version >/dev/null 2>&1 || die "docker compose غير مثبت"

FF=/opt/ffactory
S=$FF/scripts
APPS=$FF/apps
STACK=$FF/stack
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
install -d -m 755 "$S" "$APPS" "$STACK"

# 1) Entrypoint انتظاري موحد (لا يعمل إلا لو عرّفت متغيرات env في الخدمة)
EP="$S/docker-entrypoint.wait.sh"
cat >"$EP" <<'EP'
#!/usr/bin/env bash
set -Eeuo pipefail
wait_for(){ # name host port [timeout]
  local n="$1" h="$2" p="$3" t="${4:-180}" c=0
  echo "Waiting for $n ($h:$p)..."
  while ! bash -c ">/dev/tcp/$h/$p" 2>/dev/null; do
    sleep 2; c=$((c+2)); ((c>=t)) && { echo "Timeout $n"; exit 1; }
  done
  echo "$n ready"
}
[[ -n "${DB_HOST:-}"    ]] && wait_for PostgreSQL "${DB_HOST:-db}"      "${DB_PORT:-5432}" 180
[[ -n "${NEO4J_HOST:-}" ]] && wait_for Neo4j     "${NEO4J_HOST:-neo4j}" "${NEO4J_PORT:-7687}" 180
[[ "${WAIT_REDIS:-0}" = "1" ]] && wait_for Redis "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}" 60
exec "$@"
EP
chmod +x "$EP"

# 2) حقن ENTRYPOINT لخدمات Python مرة واحدة وبشكل آمن
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

# 3) ملف override للصحة والتهيئة
HC="$STACK/docker-compose.health.yml"
cat >"$HC" <<'YAML'
services:
  prometheus:
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:9090/-/ready"]
      interval: 15s
      timeout: 3s
      retries: 10
  grafana:
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 5s
      retries: 5
  frontend-dashboard:
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 5
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML

# 4) تجميع ملفات compose كمصفوفة صحيحة ومنظمة
declare -a ARGS=()
while IFS= read -r -d '' f; do ARGS+=(-f "$f"); done < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' ! -name 'docker-compose.health.yml' -print0 | sort -z)
ARGS+=(-f "$HC")
((${#ARGS[@]})) || die "لا توجد ملفات compose في $STACK"

# 5) دورة down/build/up بلا تعارض أيتام
export COMPOSE_IGNORE_ORPHANS=1
log "compose down..."
docker compose -p "$PROJECT" "${ARGS[@" ]}" down -v || true
log "build --no-cache..."
docker compose -p "$PROJECT" "${ARGS[@]}" build --no-cache
log "up -d..."
docker compose -p "$PROJECT" "${ARGS[@]}" up -d

# 6) خطوتان اختياريتان: سحب نموذج Ollama إن وجد، وتهيئة Neo4j index إن لزم
if docker compose -p "$PROJECT" ps 2>/dev/null | grep -q '\bollama\b'; then
  warn "ollama: محاولة سحب llama3:8b (اختياري)"
  docker compose -p "$PROJECT" exec -T ollama sh -lc 'ollama list || true; ollama pull llama3:8b || true' || true
fi

# 7) تحقق صحي سريع
sleep 25
log "حالة الحاويات (بدون .Health لتفادي خطأ القالب):"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  log "Prometheus READY"
else
  warn "Prometheus NOT ready"
fi

front_ok=0
for p in 3001 3000; do
  if curl -fsS "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
    log "Frontend OK on :$p"
    front_ok=1; break
  fi
done
[[ $front_ok -eq 1 ]] || warn "Frontend NOT healthy"

if curl -fsS http://127.0.0.1:9191/summary >/dev/null 2>&1; then
  log "ff-healthd summary:"
  curl -sS http://127.0.0.1:9191/summary
else
  warn "ff-healthd غير متاح"
fi

# 8) تقرير نصي سريع بالمشاكل المحتملة ونصيحة العمل التالية
cat <<'TXT'

== اقتراح ونصيحة مباشرة ==
1) اربط خدمات Python بقاعدة البيانات قبل البدء:
   أضف لهذه الخدمات env:
     DB_HOST=db DB_PORT=5432
     NEO4J_HOST=neo4j NEO4J_PORT=7687
   ومعها WAIT_REDIS=1 إذا كانت تعتمد Redis.
   هذا يفعّل الانتظار داخل ENTRYPOINT.

2) صحح الفحوص للخدمات الحرجة:
   - Prometheus: /-/ready
   - Grafana:    /api/health
   - Frontend:   /health
   لا تفحص الجذر /. لا تعتمد على ps داخل الحاويات.

3) Neo4j:
   طبّق فهارس وقيود للعُقَد الأساسية (:Person, :File, :Event).
   شغّل ETL في correlation-engine بعد جاهزية Neo4j.

4) الصوت واللغة:
   - asr-engine: استخدم faster-whisper + pyannote.audio (تمييز متحدثين).
   - neural-core: فعّل CAMeL Tools أو AraBERT للـ NER العربي.

5) مراقبة:
   اعتمد HealthStatus للحاويات إن لم تُنشر المنافذ. أو وفّر منافذ للهوست.

== انتهى ==
TXT
