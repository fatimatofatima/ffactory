#!/usr/bin/env bash
# FFactory Ultimate Fixer: Dependency Wait + Build + Safe Restart
set -Eeuo pipefail

# --- Configuration ---
FF=/opt/ffactory
STACK=$FF/stack
APPS=$FF/apps
S=$FF/scripts
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}

# --- Styling and Logging ---
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*" >&2; }
die(){ echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# --- Guards and Utility Functions ---
check_tools() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "شغّل السكربت كـ root (بـ sudo)"
    command -v docker >/dev/null || die "Docker غير مثبت"
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin غير متاح"
    command -v nc >/dev/null || warn "netcat (nc) غير مثبت. قد يفشل انتظار التبعيات. يرجى التثبيت: sudo apt install netcat-openbsd"
    mkdir -p "$S" "$STACK" "$APPS"
    grep -q '^COMPOSE_PROJECT_NAME=' "$STACK/.env" 2>/dev/null || echo "COMPOSE_PROJECT_NAME=$PROJECT" >> "$STACK/.env"
}

get_compose_files() {
  find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' 2>/dev/null | sort -u
}

args_from_files() {
  # يحوّل قائمة الملفات إلى صيغة -f
  awk '{print "-f",$0}' RS='\n' ORS=' '
}

# -----------------------------------------------------
# المرحلة 1: إنشاء Entrypoint الانتظار (Dependency Wait)
# -----------------------------------------------------
create_wait_script() {
  log "إنشاء سكريبت انتظار التبعيات (docker-entrypoint.wait.sh)"
  sudo tee "$S/docker-entrypoint.wait.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
# FFactory Dependency Wait Entrypoint
set -Eeuo pipefail

wait_for() {
  local name="$1" host="$2" port="$3" timeout="${4:-120}" t=0
  echo "Waiting for $name ($host:$port)..."
  # استخدام Netcat (nc) لفحص البورت
  while ! nc -z -w 1 "$host" "$port" 2>/dev/null; do
    sleep 2; t=$((t+2)); if (( t>=timeout )); then
      echo "Timeout waiting for $name"; exit 1
    fi
  done
  echo "$name ready"
}

# يتم تمريرها كمتغيرات بيئة من compose
wait_for PostgreSQL "${DB_HOST:-db}" "${DB_PORT:-5432}" 180
wait_for Neo4j     "${NEO4J_HOST:-neo4j}" "${NEO4J_PORT:-7687}" 180
# يمكنك إضافة Redis أو أي تبعية أخرى هنا

exec "$@" # نفّذ الأمر الأصلي للحاوية (CMD)
SH
  sudo chmod +x "$S/docker-entrypoint.sh"
}

# -----------------------------------------------------
# المرحلة 2: حقن Entrypoint في صور Python (لإصلاح Connection Refused)
# -----------------------------------------------------
patch_entrypoints() {
  log "حقن آلية الانتظار في ملفات Dockerfile لخدمات Python..."
  local count=0
  shopt -s nullglob
  for d in "$APPS"/*; do
    [[ -f "$d/Dockerfile" ]] || continue
    if grep -qiE '^FROM[[:space:]]+.*python' "$d/Dockerfile"; then
      log "  <- يتم حقن: $d"
      cp -f "$S/docker-entrypoint.wait.sh" "$d/docker-entrypoint.sh"
      # لا نكرر الإضافة
      if ! grep -q 'docker-entrypoint.sh' "$d/Dockerfile"; then
        printf '\n# [FFIX]: Dependency Waiter\nCOPY docker-entrypoint.sh /usr/local/bin/\nRUN chmod +x /usr/local/bin/docker-entrypoint.sh\nENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]\n' >> "$d/Dockerfile"
      fi
      count=$((count + 1))
    fi
  done
  log "تم حقن $count خدمة Python بنجاح."
}

# -----------------------------------------------------
# المرحلة 3: الطبيب الشامل (Down, Build, Up)
# -----------------------------------------------------
run_doctor() {
  log "بدء الطبيب الشامل (إيقاف، بناء، تشغيل)"
  mapfile -t files < <(get_compose_files)
  ((${#files[@]})) || die "لا توجد ملفات docker-compose*.yml في $STACK"
  ARGS="$(printf "%s\n" "${files[@]}" | args_from_files)"

  log "1. إيقاف شامل وإزالة الأيتام والحاويات القديمة..."
  eval docker compose -p "$PROJECT" $ARGS down --remove-orphans -v || warn "down فشل (ربما لا توجد حاويات أصلاً)"

  log "2. إعادة بناء صور الخدمات (لاجتذاب Entrypoint الجديد)..."
  # --no-cache يضمن بناء الصور بالـ Entrypoint الجديد
  eval docker compose -p "$PROJECT" $ARGS build --no-cache || die "فشل البناء"

  log "3. تشغيل الخدمات مجدداً (ستنتظر قواعد البيانات)..."
  eval docker compose -p "$PROJECT" $ARGS up -d --remove-orphans || die "فشل تشغيل compose up"
}

# -----------------------------------------------------
# المرحلة 4: التحقق النهائي
# -----------------------------------------------------
final_check() {
  log "انتظار أولي 20 ثانية لتشغيل الـ DB..."
  sleep 20
  
  log "نتائج الفحص السريع:"
  
  # Neo4j Check (Port 7474 for HTTP)
  curl -fsS http://127.0.0.1:7474/ >/dev/null 2>&1 && log "✅ Neo4j (7474) يعمل" || warn "🔴 Neo4j (7474) غير جاهز"

  # Postgres Check (Port 5433 or 5432)
  if bash -c '>/dev/tcp/127.0.0.1/5433' 2>/dev/null || bash -c '>/dev/tcp/127.0.0.1/5432' 2>/dev/null; then
    log "✅ Postgres/DB يعمل"
  else
    warn "🔴 Postgres/DB غير جاهز"
  fi
  
  # Prometheus Check (Port 9090)
  curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1 && log "✅ Prometheus (9090) جاهز" || warn "🔴 Prometheus (9090) غير جاهز"

  log "ملخص حالة الحاويات النشطة:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Health}}" | grep "$PROJECT" || true

  log "${GREEN}✅ انتهى الإصلاح الشامل. الخدمات الجديدة ستبدأ الانتظار قبل العمل.${NC}"
}

# --- Execution Flow ---
check_tools
create_wait_script
patch_entrypoints
run_doctor
final_check

