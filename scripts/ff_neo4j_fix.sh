#!/usr/bin/env bash
set -Eeuo pipefail

log(){ echo "🟢 $(date '+%H:%M:%S') - $*"; }
warn(){ echo "🟡 $(date '+%H:%M:%S') - $*"; }

# Stop Neo4j container
log "Stopping Neo4j..."
docker stop ffactory_neo4j 2>/dev/null || true
sleep 3

# Remove the container
docker rm ffactory_neo4j 2>/dev/null || true

# Remove Neo4j volume to reset authentication
log "Resetting Neo4j authentication..."
docker volume rm ffactory_ff_neo4j 2>/dev/null || warn "Volume already removed or in use"

# Start Neo4j with fresh authentication
log "Starting Neo4j with fresh setup..."
docker run -d \
  --name ffactory_neo4j \
  -p 127.0.0.1:7474:7474 \
  -p 127.0.0.1:7687:7687 \
  -e NEO4J_AUTH=neo4j/neo4jpass \
  -e NEO4J_PLUGINS='["apoc"]' \
  --network ffactory_ffactory_net \
  -v ffactory_ff_neo4j:/data \
  neo4j:5.17

log "Waiting for Neo4j to initialize..."
sleep 20

# Test connection
if curl -s http://127.0.0.1:7474/ >/dev/null; then
    log "✅ Neo4j is now accessible"
    log "🔑 Default credentials: neo4j/neo4jpass"
else
    warn "❌ Neo4j still having issues - waiting longer..."
    sleep 30
    curl -s http://127.0.0.1:7474/ >/dev/null && log "✅ Neo4j finally up!" || warn "Neo4j needs manual intervention"
fi

log "=== Final Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep ffactory_neo4j
