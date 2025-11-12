#!/usr/bin/env bash
set -Eeuo pipefail
PW="${PW:-Aa100200@@}"
CN="${CN:-ffactory_db}"
VOL="${VOL:-ffactory_postgres_data}"
IMG="${IMG:-postgres:16}"
VOL_DET="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null || true)"
[ -n "$VOL_DET" ] && VOL="$VOL_DET"
docker rm -f "$CN" >/dev/null 2>&1 || true
run(){ docker run --rm -u postgres -v "$VOL":/var/lib/postgresql/data "$IMG" \
  bash -lc "postgres --single -D \${PGDATA:-/var/lib/postgresql/data} template1 <<< \"$1\" >/dev/null 2>&1 || true"; }
run "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "CREATE ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "ALTER ROLE ffadmin WITH LOGIN SUPERUSER PASSWORD '$PW';"
run "CREATE DATABASE ffactory WITH OWNER ffadmin;"
