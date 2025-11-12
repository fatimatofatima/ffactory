#!/usr/bin/env bash
set -Eeuo pipefail
NET=ffactory_ffactory_net
docker run --rm --network "$NET" curlimages/curl:8.10.1 sh -lc '
  set -e
  # Postgres TCP
  python - <<PY
import socket,sys
for host,port in [("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]:
    s=socket.socket(); s.settimeout(5)
    try: s.connect((host,port)); print(f"{host}:{port}=OK")
    except Exception as e: print(f"{host}:{port}=FAIL:{e}"); sys.exit(1)
PY
  # MinIO HTTP
  curl -fsS http://ffactory_minio:9000/minio/health/live >/dev/null
'
