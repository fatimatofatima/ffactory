#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== FFactory Complete System Verification ==="
echo

# 1. Container Status
echo "1. Container Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_
echo

# 2. Service Health Check
echo "2. Service Health Check:"

check_service() {
    local name=$1
    local port=$2
    local endpoint=${3:-/}
    
    if curl -fs "http://127.0.0.1:$port$endpoint" >/dev/null 2>&1 || \
       nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "✅ $name (port $port)"
        return 0
    else
        echo "❌ $name (port $port)"
        return 1
    fi
}

# Core Services
check_service "PostgreSQL" 5433
check_service "Redis" 6379
check_service "Neo4j HTTP" 7474
check_service "Neo4j Bolt" 7687
check_service "MinIO API" 9000
check_service "MinIO Console" 9001

# Application Services
check_service "Vision" 8081 "/health"
check_service "Media Forensics" 8082 "/health" 
check_service "Hashset" 8083 "/health"
check_service "ASR Engine" 8086 "/health"
check_service "NLP Engine" 8000 "/health"
check_service "Correlation" 8170 "/health"
echo

# 3. Network Verification
echo "3. Network Verification:"
docker network inspect ffactory_ffactory_net --format '{{.Name}}: {{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "Network not found"
echo

# 4. Resource Usage
echo "4. Resource Usage:"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep ffactory_ 2>/dev/null || echo "No resource data available"
echo

# 5. Recent Logs Check
echo "5. Recent Error Logs:"
docker ps --filter "name=ffactory" --format "{{.Names}}" | while read container; do
    if docker logs "$container" --tail=5 2>&1 | grep -i "error\|exception\|failed" >/dev/null; then
        echo "⚠️  Errors in $container - check logs with: docker logs $container"
    fi
done
echo

echo "=== Verification Complete ==="
