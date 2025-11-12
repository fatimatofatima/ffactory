#!/bin/sh
set -eu
python3 - "$@" <<'PY'
import os, socket, sys, time
def wait(host, port, timeout=180):
    t0=time.time()
    while True:
        try:
            with socket.create_connection((host, port), 2):
                return
        except Exception:
            if time.time()-t0>timeout: sys.exit(1)
            time.sleep(2)
db_host=os.environ.get("DB_HOST","db");    db_port=int(os.environ.get("DB_PORT","5432"))
neo_host=os.environ.get("NEO4J_HOST","neo4j"); neo_port=int(os.environ.get("NEO4J_PORT","7687"))
wait(db_host, db_port, 180)
wait(neo_host, neo_port, 180)
if os.environ.get("WAIT_REDIS","0")=="1":
    wait(os.environ.get("REDIS_HOST","redis"), int(os.environ.get("REDIS_PORT","6379")), 60)
PY
exec "$@"
