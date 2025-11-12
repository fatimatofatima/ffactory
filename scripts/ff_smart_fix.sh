#!/usr/bin/env bash
# FFactory Smart Fix: Project unify + multi-compose aware bringup + orphan fallback + health probes + doctor run
# يعمل ككل مرة بدون ما يبوّظ حاجة (idempotent).
set -Eeuo pipefail

# ===== Vars =====
FF=/opt/ffactory
STACK=$FF/stack
S=$FF/scripts
ENV_FILE=$STACK/.env
DOCTOR=$S/ff_doctor.sh
PROJECT=ffactory
LOG=$FF/logs/smart_fix_$(date +%Y%m%d_%H%M%S).log

mkdir -p "$FF/logs" "$S"

# ===== Pretty log =====
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
log(){ echo -e "${GREEN}[+]${NC} $*" | tee -a "$LOG"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG"; }
err(){ echo -e "${RED}[x]${NC} $*" | tee -a "$LOG"; }

# ===== Guards =====
[ "${EUID:-$(id -u)}" -eq 0 ] || { err "شغّل السكربت كـ root"; exit 1; }
command -v docker >/dev/null || { err "Docker مش مثبت"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "Docker Compose plugin غير متاح"; exit 1; }

# ===== Step 1: توحيد اسم المشروع =====
ensure_project_name(){
  install -d -m 755 "$STACK"
  touch "$ENV_FILE"
  if grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE"; then
    sed -i 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=ffactory/' "$ENV_FILE"
  else
    echo 'COMPOSE_PROJECT_NAME=ffactory' >> "$ENV_FILE"
  fi
  export COMPOSE_PROJECT_NAME="$PROJECT"
  log "ثبّت COMPOSE_PROJECT_NAME=$PROJECT في $ENV_FILE"
}

# ===== Step 2: اكتشاف كل ملفات Compose =====
detect_compose_files(){
  local -a base=(
    "$STACK/docker-compose.ultimate.yml"
    "$STACK/docker-compose.complete.yml"
    "$STACK/docker-compose.obsv.yml"
    "$STACK/docker-compose.prod.yml"
    "$STACK/docker-compose.dev.yml"
    "$STACK/docker-compose.yml"
  )
  local f; for f in "${base[@]}"; do [[ -f "$f" ]] && echo "$f"; done
  # أي ملفات إضافية بالمجلد
  find "$STACK" -maxdepth 1 -type f -name "docker-compose*.yml" 2>/dev/null | sort | uniq
}

# ===== Step 3: خريطة service -> compose file (باستخدام config --services) =====
declare -A SVC2FILE
map_services_to_files(){
  SVC2FILE=()
  while IFS= read -r f; do
    while IFS= read -r s; do
      [[ -n "$s" ]] && SVC2FILE["$s"]="$f"
    done < <(docker compose -p "$PROJECT" -f "$f" config --services 2>/dev/null || true)
  done < <(detect_compose_files | sort -u)
  log "تم إنشاء خريطة الخدمات ← ملفاتها (${#SVC2FILE[@]} خدمة)"
}

# ===== Helpers =====
compose_has_service(){ local s="$1"; [[ -n "${SVC2FILE[$s]:-}" ]]; }
compose_file_for(){ local s="$1"; echo "${SVC2FILE[$s]:-}"; }
up_service(){
  local s="$1" f; f="$(compose_file_for "$s")"
  if [[ -n "$f" ]]; then
    log "تشغيل الخدمة $s من الملف $(basename "$f")"
    docker compose -p "$PROJECT" -f "$f" up -d "$s" >>"$LOG" 2>&1 || return 1
    return 0
  fi
  return 2
}

# ابحث عن اسم الكونتينر (لو يتيم/مش مربوط بـcompose معلوم)
container_for_service(){
  local s="$1"
  # لو عندنا compose file، خُد الـID من ps -q
  local f id name
  f="$(compose_file_for "$s")"
  if [[ -n "$f" ]]; then
    id="$(docker compose -p "$PROJECT" -f "$f" ps -q "$s" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      name="$(docker ps --no-trunc --format '{{.Names}}' --filter "id=$id")"
      [[ -n "$name" ]] && { echo "$name"; return 0; }
    fi
  fi
  # fallback: نمط أسماء شائعة
  name="$(docker ps -a --format '{{.Names}}' \
        | grep -E "^(ffactory[-_]?${s}(-[0-9]+)?)$" | head -1 || true)"
  [[ -n "$name" ]] && echo "$name" || return 1
}

restart_orphan(){
  local s="$1" c
  c="$(container_for_service "$s")" || return 1
  warn "fallback: إعادة تشغيل الكونتينر اليتيم: $c"
  docker restart "$c" >>"$LOG" 2>&1
}

# بورت على الهوست (لو معمول نشر)
compose_port(){ # usage: compose_port <service> <internal_port>
  local s="$1" p="$2" f; f="$(compose_file_for "$s")"
  [[ -n "$f" ]] || { return 1; }
  docker compose -p "$PROJECT" -f "$f" port "$s" "$p" 2>/dev/null || true
}

# ===== Step 4: Bringup لمجموعة الـObservability =====
OBS_SVCS=(grafana prometheus node-exporter cadvisor)
bringup_observability(){
  for s in "${OBS_SVCS[@]}"; do
    if compose_has_service "$s"; then
      up_service "$s" || warn "تعذّر تشغيل $s من compose؛ هجرّب fallback"
    else
      warn "$s غير معرّف في أي ملف compose؛ هجرّب fallback"
    fi
    # fallback لو لسه مش ظاهر
    if ! docker ps --format '{{.Names}}' | grep -qE "ffactory[-_]?${s}"; then
      restart_orphan "$s" || warn "ماقدرتش ألاقي كونتينر لـ $s"
    fi
  done
}

# ===== Step 5: Health Probes (من جوّا الكونتينر) =====
curl_in(){
  local c="$1" url="$2"
  docker exec "$c" sh -lc "curl -fsS --max-time 5 $url" >/dev/null 2>&1
}

probe_service(){
  local s="$1" c p ok=1
  c="$(container_for_service "$s" 2>/dev/null || true)"
  if [[ -z "$c" ]]; then warn "مافيش كونتينر ظاهر لـ $s"; return 1; fi

  case "$s" in
    grafana)        p=3000; curl_in "$c" "http://localhost:$p/api/health" && ok=0 ;;
    prometheus)     p=9090; curl_in "$c" "http://localhost:$p/-/ready"  && ok=0 ;;
    node-exporter)  p=9100; curl_in "$c" "http://localhost:$p/metrics"  && ok=0 ;;
    cadvisor)       p=8080; curl_in "$c" "http://localhost:$p/metrics"  && ok=0 ;;
    metabase)       p=3000; curl_in "$c" "http://localhost:$p/api/health" && ok=0 ;;
    minio)          p=9000; curl_in "$c" "http://localhost:$p/minio/health/live" && ok=0 ;;
    neo4j)          p=7474; docker exec "$c" sh -lc "wget -qO- http://localhost:$p/ >/dev/null" && ok=0 ;;
    redis)          p=6379; docker exec "$c" sh -lc "redis-cli -h 127.0.0.1 -p $p ping | grep -q PONG" && ok=0 ;;
    frontend-dashboard) curl_in "$c" "http://localhost:3001/health" && ok=0 ;; # داخلياً بصمتك تشتغل على /health
    *) warn "مافيش probe مخصص لـ $s"; return 2 ;;
  esac

  if [[ $ok -eq 0 ]]; then
    log "✅ $s صحي (probe داخلي ناجح)"
    return 0
  else
    warn "$s لسه مش صحي (probe فشل) — سأحاول إصلاحه"
    # جرّب إعادة التشغيل عبر compose أو fallback
    if compose_has_service "$s"; then
      docker compose -p "$PROJECT" -f "$(compose_file_for "$s")" restart "$s" >>"$LOG" 2>&1 || true
      sleep 6
    else
      restart_orphan "$s" || true
      sleep 6
    fi
    # Probe تاني
    probe_service "$s" && return 0 || return 1
  fi
}

# ===== Step 6: Patch ff_doctor (fallback يتعامل مع الأيتام) =====
patch_doctor_fallback(){
  [[ -f "$DOCTOR" ]] || { warn "ff_doctor.sh غير موجود، هتخطّى الباتش"; return 0; }
  if ! grep -q 'fallback_container_restart' "$DOCTOR"; then
    log "إضافة fallback للأيتام داخل ff_doctor.sh"
    cat >> "$DOCTOR" <<'PATCH'
# ===== Fallback for orphan containers (auto-appended by ff_smart_fix.sh) =====
find_orphan_container_by_service() {
  local s="$1" name
  name="$(docker ps -a --format '{{.Names}}' \
        | grep -E "^(ffactory[-_]?"$s"(-[0-9]+)?)$" | head -1 || true)"
  [[ -n "$name" ]] && echo "$name" || return 1
}
fallback_container_restart() {
  local s="$1" c
  c="$(find_orphan_container_by_service "$s")" || return 1
  echo "[fallback] docker restart $c" >&2
  docker restart "$c" >/dev/null
}
PATCH
    chmod +x "$DOCTOR"
    log "تم حقن fallback بنجاح"
  else
    log "ff_doctor فيه fallback بالفعل — لا حاجة للتعديل"
  fi
}

# ===== Step 7: تشغيل الطبيب مرة واحدة =====
run_doctor(){
  if [[ -x "$DOCTOR" ]]; then
    log "تشغيل ff_doctor.sh --once"
    "$DOCTOR" --once >>"$LOG" 2>&1 || true
  else
    warn "ff_doctor.sh غير قابل للتنفيذ/مفقود"
  fi
}

# ===== Step 8: ملخص نهائي =====
summary(){
  echo
  log "ملخص سريع:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/ /'
  echo
  log "ملخص البورتات المتاحة على الهوست (لو متاحة):"
  for entry in "grafana:3000" "prometheus:9090" "cadvisor:8080" "node-exporter:9100" "metabase:3000" "minio:9000" ; do
    s="${entry%%:*}"; p="${entry##*:}"
    out="$(compose_port "$s" "$p" || true)"; [[ -n "$out" ]] && echo "  $s -> $out" | tee -a "$LOG"
  done
  echo
  log "اللوج التفصيلي: $LOG"
}

# ===== Main =====
ensure_project_name
map_services_to_files
bringup_observability

# Probe أهم الخدمات (أقدر تزود القائمة لو تحب)
CHECK_SVCS=(grafana prometheus node-exporter cadvisor metabase minio neo4j redis frontend-dashboard)
for s in "${CHECK_SVCS[@]}"; do
  probe_service "$s" || warn "فحص $s لم ينجح تماماً (راجع اللوج)"
done

patch_doctor_fallback
run_doctor
summary
