#!/usr/bin/env bash
set -Eeuo pipefail
host_port_ok(){ python - "$@" <<'PY'
import socket,sys
pairs=[(sys.argv[i],int(sys.argv[i+1])) for i in range(0,len(sys.argv),2)]
for h,p in pairs:
    s=socket.socket(); s.settimeout(5)
    s.connect((h,p)); s.close()
PY
}
host_port_ok db 5432 neo4j 7687 || { echo "deps down"; exit 1; }
exec "$@"
