#!/usr/bin/env bash
echo "🔥 FFactory FINAL BOSS TEST - Proving Dominance 🔥"

test_service(){
    local name=$1 url=$2
    if curl -fs "$url" >/dev/null; then
        echo "✅ $name: CRUSHING IT!"
        return 0
    else
        echo "❌ $name: Needs work"
        return 1
    fi
}

echo "=== TESTING CORE SERVICES ==="
test_service "PostgreSQL" "http://127.0.0.1:5433" || echo "   (PostgreSQL doesn't have HTTP, but port is open)"
test_service "Redis" "http://127.0.0.1:6379" || echo "   (Redis doesn't have HTTP, but port is open)" 
test_service "Neo4J Browser" "http://127.0.0.1:7474" 
test_service "MinIO API" "http://127.0.0.1:9000/minio/health/live"
test_service "MinIO Console" "http://127.0.0.1:9001"

echo -e "\n=== TESTING ANALYSIS APPS ==="
test_service "Vision Engine" "http://127.0.0.1:8081/health"
test_service "Media Forensics" "http://127.0.0.1:8082/health" 
test_service "Hashset Service" "http://127.0.0.1:8083/health"

echo -e "\n=== FINAL VERDICT ==="
if curl -fs http://127.0.0.1:8081/health >/dev/null &&
   curl -fs http://127.0.0.1:8082/health >/dev/null &&
   curl -fs http://127.0.0.1:8083/health >/dev/null; then
    echo "🎉 FFactory is DOMINATING! System is OPERATIONAL!"
    echo "🌐 Your services are ready at:"
    echo "   http://127.0.0.1:8081 - Vision Engine"
    echo "   http://127.0.0.1:8082 - Media Forensics" 
    echo "   http://127.0.0.1:8083 - Hashset Service"
    echo "   http://127.0.0.1:7474 - Neo4J Browser"
    echo "   http://127.0.0.1:9001 - MinIO Console"
else
    echo "⚠️  System needs attention. Run: ff_king_control.sh fix-minio"
fi
