#!/usr/bin/env bash
set -Eeuo pipefail
FF=/opt/ffactory; . "$FF/.env"
NET=ffactory_ffactory_net
MC="docker run --rm --network $NET minio/mc"
$MC alias set ffminio "http://ffactory_minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
$MC mb --with-lock ffminio/forensic-evidence >/dev/null 2>&1 || true
$MC version enable ffminio/forensic-evidence >/dev/null
$MC retention set ffminio/forensic-evidence --default compliance 365d >/dev/null
$MC retention info ffminio/forensic-evidence
