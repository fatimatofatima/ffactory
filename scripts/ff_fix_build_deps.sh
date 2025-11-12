#!/usr/bin/env bash
set -Eeuo pipefail

# سكربت يحل مشكلة ssdeep وقت الـ build

services="hashset-service media-forensics vision-engine"

for svc in $services; do
  if [ -d "/opt/ffactory/apps/$svc" ]; then
    echo "🔧 Processing $svc ..."
    cd "/opt/ffactory/apps/$svc"

    # لو فيه Dockerfile عدّله في الطاير
    if grep -q "pip install --no-cache-dir -r requirements.txt" Dockerfile; then
      cp Dockerfile Dockerfile.bak.$(date +%s)
      cat > Dockerfile <<'DOCKER'
FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    python3-dev \
    libffi-dev \
    libfuzzy-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --upgrade pip setuptools wheel
RUN pip install --no-cache-dir --use-pep517 -r requirements.txt

COPY . .
CMD ["python", "main.py"]
DOCKER
      echo "✅ Dockerfile for $svc patched."
    fi

    # جرّب تبني
    docker build -t ffactory/$svc:local .
  else
    echo "ℹ️ /opt/ffactory/apps/$svc not found, skip."
  fi
done
