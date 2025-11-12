#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

banner(){ printf "\n==== %s ====\n" "$*"; }
ok(){ echo "[OK] $*"; }
warn(){ echo "[WARN] $*"; }
err(){ echo "[ERR] $*"; }
has(){ command -v "$1" >/dev/null 2>&1; }
try(){ "$@" >/dev/null 2>&1 && ok "$*" || warn "$* failed"; }

HTTP_GET(){
  local url="$1"
  if has curl; then curl -fsS --max-time 3 "$url"; 
  elif has wget; then wget -qO- "$url"; 
  else return 127; fi
}

# -------- ثابتات --------
ROOT=/opt/ffactory
ENVF=$ROOT/.env
NET=ffactory_ffactory_net
CORE=$ROOT/stack/docker-compose.core.yml
APPS=$ROOT/stack/docker-compose.apps.yml
EXT=$ROOT/stack/docker-compose.apps.ext.yml
AUTO=$ROOT/stack/docker-compose.apps.auto.yml

FF_PORTS=(
  "8081:vision"
  "8082:media"
  "8083:hashset"
  "8086:asr"
  "8000:nlp"
  "8170:correlation"
  "8088:social"
  "5433:postgres"
  "6379:redis"
  "7474:neo4j-http"
  "7687:neo4j-bolt"
  "9000:minio-api"
  "9001:minio-console"
)

mask(){
  local v="$1"
  [[ -z "$v" ]] && { echo "<empty>"; return; }
  local n=${#v}
  if (( n<=6 )); then echo "****"; else echo "${v:0:3}***${v:n-2:2}"; fi
}

# -------- رأس التقرير --------
banner "System"
hostnamectl 2>/dev/null || true
echo -n "Time: "; date -Is
echo -n "Uptime: "; uptime
echo
has lscpu && lscpu | awk -F: '/Model name|CPU\(s\)/{gsub(/^[ \t]+/,"",$2);print $1 ":" $2}' || true
free -h || true

banner "Disk"
df -hT | awk 'NR==1||/^\/dev/'; echo
has df && df -ih | awk 'NR==1||/^\/dev/' || true
has lsblk && lsblk -f || true

banner "Network"
ip -brief addr || true
echo; echo "Listening TCP:"
ss -ltnp 2>/dev/null | awk 'NR==1||/LISTEN/' || true
echo; echo "Default route:"
ip route 2>/dev/null | sed -n '1,3p' || true

# -------- Docker --------
banner "Docker"
if has docker; then
  docker -v
  if docker info >/dev/null 2>&1; then ok "docker daemon reachable"; else err "docker daemon not reachable"; fi
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"; 
  elif has docker-compose; then COMPOSE="docker-compose"; else COMPOSE=""; fi
  echo; echo "Containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo; echo "Networks:"
  docker network ls | grep -E 'ffactory|NAME' || true
  if docker network inspect "$NET" >/dev/null 2>&1; then
    ok "network $NET exists"
    docker network inspect "$NET" 2>/dev/null | jq -r '.[0].Containers|keys[]' 2>/dev/null || true
  else
    err "network $NET missing"
  fi
else
  err "docker not installed"
fi

# -------- ملفات المشروع --------
banner "FFactory files"
for f in "$ENVF" "$CORE" "$APPS" "$EXT" "$AUTO"; do
  if [ -f "$f" ]; then ok "found $f"; stat -c "  %n %s bytes mtime:%y" "$f"; else warn "missing $f"; fi
done
echo; echo "Immutability (lsattr):"
if has lsattr; then lsattr -d "$ROOT" "$ROOT/.env" "$ROOT/stack" "$ROOT/scripts" 2>/dev/null || true; else warn "lsattr not available"; fi

# -------- .env ملخص --------
banner ".env summary"
if [ -f "$ENVF" ]; then
  # طباعة قيم مهمة مع إخفاء
  declare -A keys=(
    [POSTGRES_USER]=""
    [POSTGRES_PASSWORD]=""
    [POSTGRES_DB]=""
    [NEO4J_AUTH]=""
    [MINIO_ROOT_USER]=""
    [MINIO_ROOT_PASSWORD]=""
    [REDIS_PASSWORD]=""
  )
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^#|^$ ]] && continue
    if [[ -n "${keys[$k]+x}" ]]; then keys[$k]="$v"; fi
  done < <(grep -E '^[A-Za-z0-9_]+=' "$ENVF" || true)

  for k in "${!keys[@]}"; do
    if [ -n "${keys[$k]}" ]; then echo "$k=$(mask "${keys[$k]}")"; else echo "$k=<missing>"; fi
  done
else
  err "$ENVF not found"
fi

# -------- تحقق من ملفات Compose --------
banner "Compose validation"
if [ -n "$COMPOSE" ]; then
  for y in "$CORE" "$APPS" "$EXT" "$AUTO"; do
    if [ -f "$y" ]; then
      if $COMPOSE -f "$y" config -q >/dev/null 2>&1; then ok "valid: $(basename "$y")"; else err "invalid: $(basename "$y")"; $COMPOSE -f "$y" config >/dev/null || true; fi
    fi
  done
else
  warn "compose CLI not found"
fi

# -------- صحة الخدمات عبر /health --------
banner "HTTP health"
for pair in "${FF_PORTS[@]}"; do
  p="${pair%%:*}"; n="${pair#*:}"
  out="$(HTTP_GET "http://127.0.0.1:$p/health" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then echo "[$n@$p] $out" | tr -d '\n' && echo; else echo "[$n@$p] no response"; fi
done

# -------- فحوصات خاصة للخدمات الأساسية --------
banner "Core services deep checks"
# Postgres
if docker ps --format '{{.Names}}' | grep -q '^ffactory_db$'; then
  try docker exec ffactory_db pg_isready -U postgres
else
  warn "ffactory_db container not found"
fi
# Redis
if docker ps --format '{{.Names}}' | grep -q '^ffactory_redis$'; then
  if [ -f "$ENVF" ]; then REDIS_PASSWORD=$(grep -E '^REDIS_PASSWORD=' "$ENVF" | cut -d= -f2- || true); fi
  [ -n "${REDIS_PASSWORD:-}" ] && try docker exec ffactory_redis redis-cli -a "$REDIS_PASSWORD" ping || warn "redis-cli ping skipped"
fi
# Neo4j
if ss -ltn | grep -q ':7687 '; then ok "neo4j bolt 7687 listening"; else warn "neo4j bolt not listening"; fi
HTTP_GET "http://127.0.0.1:7474" >/dev/null 2>&1 && ok "neo4j http 7474 reachable" || warn "neo4j http not reachable"
# MinIO
HTTP_GET "http://127.0.0.1:9000/minio/health/live" >/dev/null 2>&1 && ok "minio live" || warn "minio live check failed"

# -------- تعارضات المنافذ --------
banner "Port conflicts"
conflicts=0
for pair in "${FF_PORTS[@]}"; do
  p="${pair%%:*}"; n="${pair#*:}"
  hits=$(ss -ltnp 2>/dev/null | awk -v P="$p" '$4 ~ ":"P"$" {print $0}' | wc -l)
  if (( hits>1 )); then echo "[CONFLICT] port $p ($n) has $hits listeners"; conflicts=$((conflicts+1)); fi
done
(( conflicts==0 )) && ok "no port conflicts detected"

# -------- ملخص --------
banner "Summary"
echo "Docker reachable: $(docker info >/dev/null 2>&1 && echo yes || echo no)"
echo "Network $NET: $(docker network inspect $NET >/dev/null 2>&1 && echo present || echo missing)"
echo ".env: $( [ -f "$ENVF" ] && echo present || echo missing )"
echo "Compose files: core=$( [ -f "$CORE" ] && echo y || echo n ) apps=$( [ -f "$APPS" ] && echo y || echo n ) ext=$( [ -f "$EXT" ] && echo y || echo n ) auto=$( [ -f "$AUTO" ] && echo y || echo n )"
echo "Health summary:"
for pair in "${FF_PORTS[@]}"; do
  p="${pair%%:*}"; n="${pair#*:}"
  if HTTP_GET "http://127.0.0.1:$p/health" >/dev/null 2>&1; then echo "  $n:$p up"; else echo "  $n:$p down"; fi
done

echo
ok "report done"
