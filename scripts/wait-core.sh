#!/usr/bin/env bash
set -Eeuo pipefail
docker run --rm --network ffactory_ffactory_net python:3.11-alpine python - <<'PY'
import socket,sys
targets=[("db",5432),("neo4j",7687),("ffactory_minio",9000),("ffactory_redis",6379)]
for h,p in targets:
    s=socket.socket(); s.settimeout(6)
    try: s.connect((h,p)); print(f"{h}:{p}=OK")
    except Exception as e: print(f"{h}:{p}=FAIL:{e}"); sys.exit(1)
PY
