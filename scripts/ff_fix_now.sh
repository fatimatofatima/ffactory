#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*" >&2; }
die(){ echo "[x] $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker غير موجود"
docker compose version >/dev/null 2>&1 || die "docker compose غير موجود"

FF=/opt/ffactory
S=$FF/scripts
STACK=$FF/stack
APPS=$FF/apps
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

install -d -m 755 "$S"

# 1) Entrypoint انتظاري موحّد
EP_SRC="$S/docker-entrypoint.wait.sh"
cat >"$EP_SRC" <<'EP'
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
[[ -n "${DB_HOST:-}"    ]] && wait_for PostgreSQL "${DB_HOST:-db}"    "${DB_PORT:-5433}" 180
[[ -n "${NEO4J_HOST:-}" ]] && wait_for Neo4j     "${NEO4J_HOST:-neo4j}" "${NEO4J_PORT:-7687}" 180
[[ "${WAIT_REDIS:-0}" = "1" ]] && wait_for Redis "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}" 60
exec "$@"
EP
chmod +x "$EP_SRC"

# 2) حقن ENTRYPOINT لكل صور Python قبل CMD؛ أو إضافة بنهاية الملف إن لم توجد CMD
patched=0
shopt -s nullglob
for DF in "$APPS"/*/Dockerfile; do
  [[ -f "$DF" ]] || continue
  grep -qiE '^[[:space:]]*FROM[[:space:]]+.*python' "$DF" || continue
  dir="$(dirname "$DF")"
  install -m 755 "$EP_SRC" "$dir/docker-entrypoint.sh"
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

# 3) تجميع ملفات compose بأمان باستخدام مصفوفة (يمنع خطأ: open /root/-f)
declare -a ARGS=()
while IFS= read -r -d '' f; do ARGS+=(-f "$f"); done < <(find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' -print0 | sort -z)
[[ -f "$STACK/docker-compose.health.yml" ]] && ARGS+=(-f "$STACK/docker-compose.health.yml")
((${#ARGS[@]})) || die "لا توجد ملفات compose في $STACK"

# 4) down/build/up بدون خلط remove-orphans
export COMPOSE_IGNORE_ORPHANS=1
docker compose -p "$PROJECT" "${ARGS[@]}" down -v || true
docker compose -p "$PROJECT" "${ARGS[@]}" build --no-cache
docker compose -p "$PROJECT" "${ARGS[@]}" up -d

# 5) فحوص سريعة
sleep 25
log "حالة الحاويات:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$PROJECT" || true

# Prometheus readiness
if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
  log "Prometheus READY"
else
  warn "Prometheus NOT ready"
fi

# Frontend /health على 3001 ثم 3000
front_ok=0
for p in 3001 3000; do
  if curl -fsS "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
    log "Frontend OK on :$p"
    front_ok=1; break
  fi
done
[[ $front_ok -eq 1 ]] || warn "Frontend NOT healthy"

# ff-healthd summary إن وُجد
if curl -fsS http://127.0.0.1:9191/summary >/dev/null 2>&1; then
  log "ff-healthd summary:"
  curl -sS http://127.0.0.1:9191/summary
else
  warn "ff-healthd غير متاح"
fi

log "انتهى."
