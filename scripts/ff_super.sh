#!/usr/bin/env bash
set -Eeuo pipefail

# ================== إعدادات عامة ==================
ROOT=/opt/ffactory
STACK="$ROOT/stack"
LOGD="$ROOT/logs"
SCRIPTS="$ROOT/scripts"
NET=ffactory_ffactory_net
CORE_YML="$STACK/docker-compose.core.yml"
APPS_YML="$STACK/docker-compose.apps.yml"
PW="\${FF_PW:-Aa100200}"   # تقدر تغيّرها بتصدير FF_PW قبل التشغيل

mkdir -p "$STACK" "$LOGD" "$SCRIPTS"
LOG="$LOGD/ff_super.$(date +%F_%H%M%S).log"

ts(){ date '+%F %T'; }
log(){ printf "[%s] %s\n" "$(ts)" "$*" | tee -a "$LOG"; }
ok(){ log "✅ $*"; }
warn(){ log "⚠️  $*"; }
die(){ log "❌ $*"; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "الأمر $1 غير موجود"; }

# ================== 0) فحوصات ==================
need_cmd docker
need_cmd curl
need_cmd sed

# ================== 1) الشبكة ==================
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  docker network create "$NET" >/dev/null
  ok "أنشأنا الشبكة $NET"
else
  ok "الشبكة $NET موجودة"
fi

# ================== 2) كتابة core ==================
cat >"$CORE_YML" <<EOF
version: "3.9"
services:
  db:
    image: postgres:15
    container_name: ffactory_db
    restart: unless-stopped
    networks: [ "$NET" ]
    environment:
      POSTGRES_USER: ffactory
      POSTGRES_PASSWORD: ${PW}
      POSTGRES_DB: ffactory
    volumes:
      - ffactory_db_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5433:5432"

  redis:
    image: redis:7
    container_name: ffactory_redis
    restart: unless-stopped
    networks: [ "$NET" ]
    command: ["redis-server", "--requirepass", "${PW}"]
    volumes:
      - ffactory_ff_redis:/data
    ports:
      - "127.0.0.1:6379:6379"

  minio:
    image: minio/minio:latest
    container_name: ffactory_minio
    restart: unless-stopped
    networks: [ "$NET" ]
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: ${PW}
    command: server /data --console-address ":9001"
    volumes:
      - ffactory_ff_minio:/data
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"

  neo4j:
    image: neo4j:5
    container_name: ffactory_neo4j
    restart: unless-stopped
    networks: [ "$NET" ]
    environment:
      NEO4J_AUTH: neo4j/${PW}
      NEO4J_dbms_security_auth__minimum__password__length: 4
      NEO4J_PLUGINS: '["apoc"]'
    volumes:
      - ffactory_ff_neo4j:/data
      - ffactory_neo4j_plugins:/plugins
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"

networks:
  $NET:
    external: true

volumes:
  ffactory_db_data:
  ffactory_ff_redis:
  ffactory_ff_minio:
  ffactory_ff_neo4j:
  ffactory_neo4j_plugins:
  ffactory_ff_pg:
EOF
ok "كتبنا ملف CORE: $CORE_YML"

# ================== 3) كتابة apps ==================
cat >"$APPS_YML" <<'EOF'
version: "3.9"
services:
  vision:
    image: ealen/echo-server
    container_name: ffactory_vision
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: vision
    ports:
      - "127.0.0.1:8081:8080"

  media_forensics:
    image: ealen/echo-server
    container_name: ffactory_media_forensics
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: media_forensics
    ports:
      - "127.0.0.1:8082:8080"

  hashset:
    image: ealen/echo-server
    container_name: ffactory_hashset
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: hashset
    ports:
      - "127.0.0.1:8083:8080"

  asr:
    image: ealen/echo-server
    container_name: ffactory_asr
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: asr
    ports:
      - "127.0.0.1:8086:8080"

  nlp:
    image: ealen/echo-server
    container_name: ffactory_nlp
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: nlp
    ports:
      - "127.0.0.1:8000:8080"

  correlation:
    image: ealen/echo-server
    container_name: ffactory_correlation
    restart: unless-stopped
    networks: [ ffactory_ffactory_net ]
    environment:
      PORT: 8080
      SERVICE_NAME: correlation
    ports:
      - "127.0.0.1:8170:8080"

networks:
  ffactory_ffactory_net:
    external: true
EOF
ok "كتبنا ملف APPS: $APPS_YML"

# ================== 4) تشغيل core ==================
log "تشغيل CORE…"
( cd "$STACK" && docker compose -f "$CORE_YML" up -d ) || die "فشل تشغيل CORE"

# ================== 5) انتظار جاهزية الأساسيات ==================
wait_for_port(){
  local name="$1" host="$2" port="$3" tries=25
  while ((tries>0)); do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      ok "$name جاهز على $host:$port"
      return 0
    fi
    sleep 1
    ((tries--))
  done
  warn "$name لم يصبح جاهزًا في الوقت المتوقع"
  return 1
}

wait_for_port "PostgreSQL" 127.0.0.1 5433
wait_for_port "Redis" 127.0.0.1 6379
wait_for_port "MinIO" 127.0.0.1 9000
wait_for_port "Neo4j" 127.0.0.1 7474

# ================== 6) تشغيل التطبيقات ==================
log "تشغيل التطبيقات…"
( cd "$STACK" && docker compose -f "$APPS_YML" up -d ) || warn "فشل تشغيل بعض التطبيقات"

# ================== 7) تشغيل أي خدمة ناقصة ==================
SERVICES=(db redis minio neo4j vision media_forensics hashset asr nlp correlation)
for s in "${SERVICES[@]}"; do
  cname="ffactory_${s}"
  if ! docker ps --format '{{.Names}}' | grep -qx "$cname"; then
    warn "الخدمة $cname ليست شغالة، نحاول تشغيلها…"
    docker start "$cname" >/dev/null 2>&1 && ok "شغّلنا $cname" || warn "ما قدرنا نشغّل $cname"
  fi
done

# ================== 8) فحص صحة سريع ==================
log "===== فحص صحة سريع ====="
for svc in vision media_forensics hashset asr nlp correlation; do
  port=""
  case "$svc" in
    vision) port=8081 ;;
    media_forensics) port=8082 ;;
    hashset) port=8083 ;;
    asr) port=8086 ;;
    nlp) port=8000 ;;
    correlation) port=8170 ;;
  esac
  if curl -fs "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
    ok "$svc ✅ على المنفذ ${port}"
  else
    warn "$svc ❌ لا يرد على ${port}"
  fi
done

# ================== 9) طباعة الحالة ==================
log "===== الحالة النهائية ====="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_ || true
ok "ملف اللوج: $LOG"
