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
