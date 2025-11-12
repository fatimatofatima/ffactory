#!/usr/bin/env bash
set -Eeuo pipefail
echo "🤖 FFactory AI APPS CREATOR - Building the Brain 🤖"

FF=/opt/ffactory
log(){ printf "[$(date '+%F %T')] %s\n" "$*"; }

# إنشاء ملف التطبيقات المتقدمة
log "📁 إنشاء تطبيقات الذكاء الاصطناعي..."
sudo tee $FF/stack/docker-compose.apps.auto.yml >/dev/null <<'YML'
version: "3.9"
name: ffactory
networks:
  default:
    external: true
    name: ffactory_ffactory_net

services:
  asr-engine:
    build: 
      context: ../apps/asr-engine
      dockerfile: Dockerfile
    container_name: ffactory_asr
    networks:
      - default
    ports:
      - "127.0.0.1:8086:8080"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  nlp:
    build:
      context: ../apps/nlp
      dockerfile: Dockerfile
    container_name: ffactory_nlp
    networks:
      - default
    ports:
      - "127.0.0.1:8000:8080"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  correlation:
    build:
      context: ../apps/correlation
      dockerfile: Dockerfile
    container_name: ffactory_correlation
    networks:
      - default
    ports:
      - "127.0.0.1:8170:8080"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

log "🚀 تشغيل تطبيقات AI..."
docker compose -f $FF/stack/docker-compose.apps.auto.yml up -d --build

log "✅ تطبيقات الذكاء الاصطناعي جاهزة!"
echo "   🎤 ASR Engine: http://127.0.0.1:8086"
echo "   📝 NLP: http://127.0.0.1:8000"
echo "   🔗 Correlation: http://127.0.0.1:8170"
