#!/bin/bash
echo "🔧 إصلاح تعارض المنافذ الفوري"
echo "============================"

FF=/opt/ffactory

# 1. إيقاف الخدمات التي تعاني من تعارض المنافذ
echo "🛑 إيقاف الخدمات المتعارضة..."
docker stop ffactory_vision ffactory_media_forensics 2>/dev/null || true
docker rm ffactory_vision ffactory_media_forensics 2>/dev/null || true

# 2. البحث عن منافذ شاغرة
echo "🔍 البحث عن منافذ شاغرة..."
find_free_port() {
    local port=$1
    while netstat -tuln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
    done
    echo $port
}

VISION_PORT=$(find_free_port 8081)
MEDIA_PORT=$(find_free_port 8082) 
HASHSET_PORT=$(find_free_port 8083)
SOCIAL_PORT=$(find_free_port 8088)

echo "📊 المنافذ الجديدة:"
echo "👁️  Vision: $VISION_PORT"
echo "🔍 Media: $MEDIA_PORT"
echo "🔐 Hashset: $HASHSET_PORT"
echo "📱 Social: $SOCIAL_PORT"

# 3. تحديث ملف Compose بالمنافذ الجديدة
echo "📝 تحديث إعدادات المنافذ..."
cat > "$FF/stack/docker-compose.apps.ext.yml" << YML
name: ffactory
networks: { ffactory_ffactory_net: { external: true } }
volumes: { hashsets_data: {} }

services:
  vision-engine:
    build: { context: ../apps/vision-engine, dockerfile: Dockerfile }
    container_name: ffactory_vision
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${VISION_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  media-forensics:
    build: { context: ../apps/media-forensics, dockerfile: Dockerfile }
    container_name: ffactory_media_forensics
    env_file: [ ../.env ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${MEDIA_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40

  hashset-service:
    build: { context: ../apps/hashset-service, dockerfile: Dockerfile }
    container_name: ffactory_hashset
    env_file: [ ../.env ]
    environment:
      - NSRL_DB_PATH=/data/hashsets/nsrl.sqlite
    volumes: [ "hashsets_data:/data/hashsets" ]
    networks: [ ffactory_ffactory_net ]
    ports: [ "127.0.0.1:${HASHSET_PORT}:8080" ]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 40
YML

# 4. إعادة التشغيل
echo "🚀 إعادة تشغيل الخدمات..."
cd "$FF"
docker compose -f stack/docker-compose.apps.ext.yml up -d

# 5. انتظار وفحص
echo "⏳ انتظار تهيئة الخدمات..."
sleep 10

# 6. فحص النتيجة
echo "📊 فحص النتيجة:"
docker ps --filter "name=ffactory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "🎯 فحص الصحة:"
curl -s http://127.0.0.1:$VISION_PORT/health | jq '.ready' 2>/dev/null && echo "✅ Vision: صحي" || echo "🔴 Vision: غير متاح"
curl -s http://127.0.0.1:$MEDIA_PORT/health | jq '.status' 2>/dev/null && echo "✅ Media: صحي" || echo "🔴 Media: غير متاح" 
curl -s http://127.0.0.1:$HASHSET_PORT/health | jq '.status' 2>/dev/null && echo "✅ Hashset: صحي" || echo "🔴 Hashset: غير متاح"

echo ""
echo "🌐 روابط جديدة:"
echo "👁️  Vision: http://127.0.0.1:$VISION_PORT/health"
echo "🔍 Media: http://127.0.0.1:$MEDIA_PORT/health"
echo "🔐 Hashset: http://127.0.0.1:$HASHSET_PORT/health"

echo "✅ تم إصلاح تعارض المنافذ!"
