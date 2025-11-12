#!/usr/bin/env bash
set -Eeuo pipefail

export COMPOSE_IGNORE_ORPHANS=1
PROJECT=${COMPOSE_PROJECT_NAME:-ffactory}
FF=/opt/ffactory
STACK=$FF/stack

dcf(){ COMPOSE_IGNORE_ORPHANS=1 docker compose -p "$PROJECT" -f "$1" "${@:2}"; }

detect_compose_files(){
  local -a base=("$STACK"/docker-compose.ultimate.yml "$STACK"/docker-compose.complete.yml \
                 "$STACK"/docker-compose.obsv.yml "$STACK"/docker-compose.prod.yml \
                 "$STACK"/docker-compose.dev.yml "$STACK"/docker-compose.yml)
  local f; for f in "${base[@]}"; do [[ -f "$f" ]] && echo "$f"; done
  find "$STACK" -maxdepth 1 -type f -name 'docker-compose*.yml' 2>/dev/null | sort -u
}

declare -A SVC2FILE
map_services_to_files(){
  SVC2FILE=()
  local f svc
  for f in $(detect_compose_files); do
    # استخرج أسماء الخدمات تقريبيًا بين كتلة services:
    awk '
      $0 ~ /^services:/ {inS=1; next}
      inS && $0 ~ /^[^[:space:]]/ {inS=0}
      inS && $1 ~ /^[a-zA-Z0-9_.-]+:/ {gsub(":","",$1); print $1}
    ' "$f" 2>/dev/null | while read -r svc; do
      SVC2FILE["$svc"]="$f"
    done
  done
}

container_name_for(){
  local svc="$1"
  # ابحث بالليبل الرسمي للخدمة
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$svc" \
    --format '{{.Names}}' | head -n1
}

host_port_for(){
  local cn="$1"
  docker inspect -f '{{range $k,$v:=.NetworkSettings.Ports}}{{if $v}}{{(index $v 0).HostIp}}:{{(index $v 0).HostPort}}{{"\n"}}{{end}}{{end}}' "$cn" 2>/dev/null \
   | awk -F: '$3!=""{print $2":"$3; exit}'
}

has_healthy_flag(){
  local cn="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cn" 2>/dev/null | grep -qx healthy
}

probe_http_smart(){
  local svc="$1" endpoints="${2:-/health,/ready,/live,/,/-/ready,/-/healthy,/metrics,/api/health}"
  local cn hostp
  cn=$(container_name_for "$svc"); [[ -z "$cn" ]] && return 1
  # 1) صحة الحاوية نفسها
  if has_healthy_flag "$cn"; then return 0; fi
  # 2) جرّب على البورت المنشور من الهوست
  hostp=$(host_port_for "$cn")
  if [[ -n "$hostp" ]]; then
    IFS=, read -ra arr <<<"$endpoints"
    for ep in "${arr[@]}"; do
      curl -fsS "http://$hostp$ep" >/dev/null 2>&1 && return 0
    done
  fi
  return 1
}

probe_tcp_host(){
  # probe_tcp_host <host:port>
  local hp="$1"
  timeout 2 bash -c "echo > /dev/tcp/${hp/:/\/}" >/dev/null 2>&1
}

wait_for_service(){
  # wait_for_service <svc> [seconds]
  local svc="$1" t="${2:-60}" i=0
  while (( i < t )); do
    probe_service "$svc" && return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

probe_service(){
  local svc="$1"
  case "$svc" in
    prometheus)    probe_http_smart "$svc" "/-/ready,/-/healthy,/metrics,/" ;;
    grafana)       probe_http_smart "$svc" "/api/health,/login,/" ;;
    metabase)      probe_http_smart "$svc" "/api/health,/" ;;
    api-gateway|investigation-api|frontend-dashboard|feedback-api|behavioral-analytics)
                   probe_http_smart "$svc" "/health,/,/ready,/live" ;;
    neo4j)         probe_http_smart "$svc" "/,/" || probe_tcp_host "127.0.0.1:7474" ;;
    minio)         probe_http_smart "$svc" "/minio/health/live,/" ;;
    db)            probe_tcp_host "127.0.0.1:5433" || probe_tcp_host "127.0.0.1:5432" ;;
    redis)         probe_tcp_host "127.0.0.1:6379" ;;
    vault)         probe_http_smart "$svc" "/v1/sys/health,/" ;;
    ollama)        probe_http_smart "$svc" "/api/tags,/" ;;
    *)             probe_http_smart "$svc" "/health,/ready,/live,/" ;;
  esac
}

restart_service(){
  local svc="$1"
  local f="${SVC2FILE[$svc]:-}"
  local cn; cn=$(container_name_for "$svc" || true)
  if [[ -n "$f" ]]; then
    dcf "$f" up -d "$svc" >/dev/null 2>&1 && return 0
  fi
  if [[ -n "$cn" ]]; then
    docker restart "$cn" >/dev/null 2>&1 && return 0
  fi
  return 1
}
