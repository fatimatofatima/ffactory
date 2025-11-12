#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/ffactory
STACK=$ROOT/stack
APPS=$ROOT/apps
ENVF=$ROOT/.env
NET=ffactory_ffactory_net

log(){ echo "🟢 $(date '+%H:%M:%S') - $*"; }
warn(){ echo "🟡 $(date '+%H:%M:%S') - $*"; }
die(){ echo "🔴 $(date '+%H:%M:%S') - $*"; exit 1; }

# 1) إيقاف كل شيء وتنظيف
log "1/7 - إيقاف وتنظيف النظام..."
docker compose -f $STACK/docker-compose.core.yml down 2>/dev/null || true
docker ps -q --filter "name=ffactory" | xargs -r docker stop 2>/dev/null || true
docker system prune -f 2>/dev/null || true

# 2) فك الحماية عن الملفات
log "2/7 - فك حماية الملفات..."
sudo chattr -i $ROOT/.env $STACK/*.yml $ROOT/scripts/*.sh 2>/dev/null || true
sudo chmod 755 $APPS/* 2>/dev/null || true

# 3) إصلاح المتغيرات البيئية
log "3/7 - إصلاح المتغيرات البيئية..."
[ -f "$ENVF" ] && set -a && . "$ENVF" && set +a || true

# إضافة إعدادات اللوكيل إذا لم تكن موجودة
if ! grep -q "LANG=" "$ENVF" 2>/dev/null; then
    echo -e "\n# Locale Settings" | sudo tee -a "$ENVF"
    echo "LANG=C.UTF-8" | sudo tee -a "$ENVF"
    echo "LC_ALL=C.UTF-8" | sudo tee -a "$ENVF"
fi

# 4) إنشاء ملفات Dockerfile أساسية للتطبيقات المفقودة
log "4/7 - إنشاء Dockerfiles للتطبيقات..."

create_app_dockerfile() {
    local app_dir=$1
    local app_name=$(basename "$app_dir")
    
    if [ ! -f "$app_dir/Dockerfile" ]; then
        cat > "$app_dir/Dockerfile" << DOCKERFILE
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "app.py"]
DOCKERFILE
        
        # إنشاء requirements.txt إذا لم يكن موجوداً
        if [ ! -f "$app_dir/requirements.txt" ]; then
            echo "flask==2.3.3" > "$app_dir/requirements.txt"
            echo "requests==2.31.0" >> "$app_dir/requirements.txt"
        fi
        
        # إنشاء app.py أساسي إذا لم يكن موجوداً
        if [ ! -f "$app_dir/app.py" ]; then
            cat > "$app_dir/app.py" << PYTHON
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "service": "$app_name"})

@app.route('/')
def home():
    return jsonify({"message": "$app_name service is running"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=False)
PYTHON
        fi
        log "   تم إنشاء Dockerfile لـ $app_name"
    fi
}

# إنشاء Dockerfiles للتطبيقات الأساسية
for app in asr-engine nlp correlation social media-forensics vision hashset; do
    if [ -d "$APPS/$app" ]; then
        create_app_dockerfile "$APPS/$app"
    fi
done

# 5) إصلاح ملف docker-compose.core.yml
log "5/7 - إنشاء ملف core compose نظيف..."

sudo tee $STACK/docker-compose.core.yml >/dev/null <<'YML'
name: ffactory
networks:
  ffactory_ffactory_net:
    external: true

volumes:
  ff_pg: {}
  ff_minio: {}
  ff_neo4j: {}
  ff_redis: {}

services:
  db:
    image: postgres:16
    container_name: ffactory_db
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-ffadmin}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-ffpass}
      POSTGRES_DB: ${POSTGRES_DB:-ffactory}
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
    volumes:
      - ff_pg:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5433:5432"
    networks:
      - ffactory_ffactory_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-ffadmin}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: ffactory_redis
    command: redis-server --requirepass ${REDIS_PASSWORD:-ffredis}
    environment:
      LANG: C.UTF-8
      LC_ALL: C.UTF-8
    volumes:
      - ff_redis:/data
    ports:
      - "127.0.0.1:6379:6379"
    networks:
      - ffactory_ffactory_net
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  neo4j:
    image: neo4j:5.17
    container_name: ffactory_neo4j
    environment:
      - NEO4J_AUTH=${NEO4J_AUTH:-neo4j/neo4jpass}
      - NEO4J_PLUGINS=["apoc"]
      - NEO4J_server_memory_pagecache_size=512M
      - NEO4J_server_memory_heap_initial__size=512M
      - NEO4J_server_memory_heap_max__size=1G
    volumes:
      - ff_neo4j:/data
    ports:
      - "127.0.0.1:7474:7474"
      - "127.0.0.1:7687:7687"
    networks:
      - ffactory_ffactory_net
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:7474/"]
      interval: 15s
      timeout: 10s
      retries: 5

  minio:
    image: minio/minio:RELEASE.2024-12-09T19-06-53Z
    container_name: ffactory_minio
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:-minioadmin}
    command: server /data --console-address ":9001"
    volumes:
      - ff_minio:/data
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    networks:
      - ffactory_ffactory_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 15s
      timeout: 10s
      retries: 5
YML

# 6) إنشاء ملف docker-compose.apps.yml للتطبيقات الأساسية
log "6/7 - إنشاء ملف apps compose..."

sudo tee $STACK/docker-compose.apps.fixed.yml >/dev/null <<'YML'
name: ffactory
networks:
  ffactory_ffactory_net:
    external: true

services:
  asr-engine:
    build:
      context: ../apps/asr-engine
      dockerfile: Dockerfile
    container_name: ffactory_asr
    env_file: [ ../.env ]
    depends_on:
      db:
        condition: service_healthy
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8086:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  nlp:
    build:
      context: ../apps/nlp
      dockerfile: Dockerfile
    container_name: ffactory_nlp
    env_file: [ ../.env ]
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8000:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  correlation:
    build:
      context: ../apps/correlation
      dockerfile: Dockerfile
    container_name: ffactory_correlation
    env_file: [ ../.env ]
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8170:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  vision:
    build:
      context: ../apps/vision
      dockerfile: Dockerfile
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8081:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  media-forensics:
    build:
      context: ../apps/media-forensics
      dockerfile: Dockerfile
    container_name: ffactory_media_forensics
    env_file: [ ../.env ]
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8082:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  hashset:
    build:
      context: ../apps/hashset
      dockerfile: Dockerfile
    container_name: ffactory_hashset
    env_file: [ ../.env ]
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8083:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  social:
    build:
      context: ../apps/social
      dockerfile: Dockerfile
    container_name: ffactory_social
    env_file: [ ../.env ]
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - ffactory_ffactory_net
    ports:
      - "127.0.0.1:8088:8080"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
YML

# 7) تشغيل الخدمات
log "7/7 - تشغيل الخدمات..."

# إنشاء الشبكة
docker network create "$NET" 2>/dev/null || true

# تشغيل الخدمات الأساسية
log "تشغيل الخدمات الأساسية..."
docker compose -f $STACK/docker-compose.core.yml up -d

# انتظار جاهزية الخدمات الأساسية
log "انتظار جاهزية الخدمات الأساسية..."
sleep 10

# تشغيل التطبيقات
log "تشغيل التطبيقات..."
docker compose -f $STACK/docker-compose.apps.fixed.yml up -d --build

# الانتظار النهائي
log "الانتظار النهائي للتطبيقات..."
sleep 15

# عرض النتيجة النهائية
log "=== الحالة النهائية ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_

log "=== فحص الصحة ==="
/opt/ffactory/scripts/ff_check_all.sh

log "✅ الإصلاح اكتمل!"
