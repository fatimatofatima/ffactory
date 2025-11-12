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
