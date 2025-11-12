#!/usr/bin/env bash
set -Eeuo pipefail

OPS="/opt/ffactory/stack/docker-compose.ops.yml"
PROJ="ffactory"
APP_DIR="/opt/ffactory/apps/behavioral-analytics"
OVR="/opt/ffactory/stack/docker-compose.behavior.yml"
NEO4J_TARGET_PW="${NEO4J_TARGET_PW:-StrongPass_2025!}"

log(){ printf "[%(%F %T)T] %s\n" -1 "$*"; }

require(){
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }
}

wait_http(){
  local url="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

neo4j_container(){
  docker ps -aqf "name=${PROJ}-neo4j-1" || true
}

patch_ops_minimal(){
  log "patch compose keys"
  # NEO4JLABS_PLUGINS -> NEO4J_PLUGINS
  sed -i 's/NEO4JLABS_PLUGINS/NEO4J_PLUGINS/g' "$OPS" || true
  # add license once
  grep -q 'NEO4J_ACCEPT_LICENSE_AGREEMENT' "$OPS" || \
    sed -i '/NEO4J_PLUGINS:/a\      NEO4J_ACCEPT_LICENSE_AGREEMENT: "yes"' "$OPS" || true

  # remove any stray behavioral-analytics service mistakenly appended to OPS
  awk '
    BEGIN{skip=0}
    # start skipping at service block indent level 2
    /^[[:space:]]{2}behavioral-analytics:/ {skip=1; next}
    # stop skipping at next service or top-level key
    skip==1 && (/^[[:space:]]{2}[A-Za-z0-9_-]+:/ || /^[^[:space:]]/){skip=0}
    skip==0 {print $0}
  ' "$OPS" > "${OPS}.tmp" && mv "${OPS}.tmp" "$OPS"

  # keep only the first root-level "networks:" block, drop extra duplicates
  awk '
    BEGIN{in_dup=0; seen=0}
    # detect root-level networks:
    /^[^[:space:]]/ {root=1}
    /^networks:$/ && root==1 {
      seen++
      if(seen>1){in_dup=1; next} else {print; next}
    }
    in_dup==1 {
      # end duplicate block when next top-level key appears
      if($0 ~ /^[^[:space:]]/){in_dup=0; print $0}
      next
    }
    {print $0}
  ' "$OPS" > "${OPS}.tmp" && mv "${OPS}.tmp" "$OPS"
}

ensure_neo4j_up(){
  log "compose up neo4j"
  docker compose -p "$PROJ" -f "$OPS" up -d --force-recreate --no-deps neo4j
  log "wait http 7474"
  wait_http "http://127.0.0.1:7474" 60 || { echo "neo4j http down"; exit 1; }
}

discover_env_pw(){
  # read NEO4J_AUTH from running container env if present
  local cid pw
  cid="$(neo4j_container)"
  if [ -n "$cid" ]; then
    pw="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= '/^NEO4J_AUTH=/{print $2}' | awk -F/ '{print $2}')"
    [ -n "$pw" ] && echo "$pw" && return 0
  fi
  # fallback
  echo "ChangeMe_12345!"
}

set_final_password(){
  local cid cur ok=0
  cid="$(neo4j_container)"
  [ -z "$cid" ] && { echo "no neo4j container"; exit 1; }

  # candidate current passwords to try
  CUR_PW_CANDIDATES=()
  CUR_PW_CANDIDATES+=( "$(discover_env_pw)" )
  CUR_PW_CANDIDATES+=( "ChangeMe_12345!" "test123" "neo4j" "$NEO4J_TARGET_PW" )

  for cur in "${CUR_PW_CANDIDATES[@]}"; do
    if docker exec -it "$cid" bash -lc "/var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p '$cur' 'RETURN 1;'" >/dev/null 2>&1; then
      ok=1
      if [ "$cur" != "$NEO4J_TARGET_PW" ]; then
        log "alter password -> target"
        docker exec -it "$cid" bash -lc "/var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p '$cur' \"ALTER CURRENT USER SET PASSWORD FROM '$cur' TO '$NEO4J_TARGET_PW';\"" >/dev/null
      fi
      break
    fi
  done

  [ "$ok" -eq 1 ] || { echo "auth failed for all candidates"; exit 1; }

  # verify
  docker exec -it "$cid" bash -lc "/var/lib/neo4j/bin/cypher-shell -a bolt://localhost:7687 -u neo4j -p '$NEO4J_TARGET_PW' 'CALL dbms.components();'" >/dev/null
  log "neo4j password verified"
}

write_behavior_app(){
  log "write behavioral-analytics app"
  install -d -m 755 "$APP_DIR"

  cat > "$APP_DIR/requirements.txt" <<'REQ'
fastapi
uvicorn
REQ

  cat > "$APP_DIR/Dockerfile" <<'DOCKER'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8090
CMD ["python","-m","uvicorn","main:app","--host","0.0.0.0","--port","8090"]
DOCKER

  cat > "$APP_DIR/ontology.py" <<'PY'
EVENT_SCHEMA = {
    "FILE_ACCESS": ["read","write","delete","rename"],
    "NETWORK_COMMUNICATION": ["tcp","udp","http","https"],
    "PROCESS_EXECUTION": ["powershell","cmd","bash","service_start"],
    "AUTHENTICATION": ["login_success","login_failure","session_start"]
}
BEHAVIORAL_ONTOLOGY = {
    "AntiForensicBehaviors": {
        "DATA_CONCEALMENT": [
            "RAPID_FILE_ENCRYPTION","MASS_FILE_DELETION","LOG_CLEARING","METADATA_TAMPERING"
        ]
    }
}
PY

  cat > "$APP_DIR/detection_engine.py" <<'PY'
from datetime import datetime
from typing import Dict, List, Any
from ontology import BEHAVIORAL_ONTOLOGY
import random

class UserBaseline:
    def __init__(self, user_id: str):
        self.user_id = user_id
        self.avg_daily_operations = random.randint(50, 200)
        self.avg_off_hours_activity = random.uniform(0.01, 0.05)
        self.usual_process_names = ["explorer.exe", "chrome.exe", "outlook.exe"]

class AdvancedBehavioralAnalytics:
    def __init__(self):
        self.ontology = BEHAVIORAL_ONTOLOGY
        self.baselines: Dict[str, UserBaseline] = {}

    def get_user_baseline(self, user_id: str) -> UserBaseline:
        if user_id not in self.baselines:
            self.baselines[user_id] = UserBaseline(user_id)
        return self.baselines[user_id]

    def _is_off_hours(self, ts_str: Any) -> bool:
        try:
            ts = datetime.fromisoformat(str(ts_str).replace('Z', '+00:00'))
            return ts.hour >= 22 or ts.hour < 6
        except Exception:
            return False

    def calculate_anomaly_score(self, events: List[Dict], baseline: UserBaseline) -> int:
        score = 0
        total = len(events)
        if total > baseline.avg_daily_operations * 2:
            score += 15
        off = sum(1 for e in events if self._is_off_hours(e.get("timestamp")))
        if (off / (total or 1)) > baseline.avg_off_hours_activity * 5:
            score += 20
        unusual = 0
        for e in events:
            pn = (e.get("process_name") or "").lower()
            if pn and not any(p in pn for p in baseline.usual_process_names):
                unusual += 1
        if unusual > 5:
            score += 25
        return min(score, 60)

    def detect_anti_forensic_patterns(self, events: List[Dict]) -> bool:
        deletion = sum(1 for e in events if e.get("operation") == "DELETE")
        encrypted = sum(1 for e in events if e.get("file_type") == "ENCRYPTED")
        return deletion >= 5 or encrypted >= 3

    def calculate_final_risk_score(self, detected: List[str], anomaly: int, sensitivity: str = "LOW") -> int:
        weights = {"ANTI_FORENSIC_BEHAVIOR": 40, "PRIVILEGE_ESCALATION_ATTEMPT": 50}
        mult = {"LOW": 1, "MEDIUM": 1.5, "HIGH": 2}
        score = sum(weights.get(p, 10) for p in detected) + anomaly
        return min(int(score * mult.get(sensitivity, 1)), 100)

    def analyze_user_behavior(self, events: List[Dict], asset_sensitivity: str = "LOW") -> Dict:
        user_id = events[0].get("user_id", "UNKNOWN") if events else "UNKNOWN"
        base = self.get_user_baseline(user_id)
        detected = []
        if self.detect_anti_forensic_patterns(events):
            detected.append("ANTI_FORENSIC_BEHAVIOR")
        anomaly = self.calculate_anomaly_score(events, base)
        risk = self.calculate_final_risk_score(detected, anomaly, asset_sensitivity)
        return {
            "risk_score": risk,
            "anomaly_score": anomaly,
            "detected_patterns": detected,
            "recommended_actions": ["تحقيق فوري في شذوذ النشاط" if anomaly > 20 else "مراجعة لسجلات المستخدم"]
        }
PY

  cat > "$APP_DIR/main.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from typing import List, Optional, Dict
from detection_engine import AdvancedBehavioralAnalytics

app = FastAPI(title="FFactory Behavioral Analytics API")
analyzer = AdvancedBehavioralAnalytics()

class Event(BaseModel):
    event_id: str
    timestamp: str
    user_id: str
    event_type: str
    source_ip: Optional[str] = None
    destination_ip: Optional[str] = None
    file_path: Optional[str] = None
    process_name: Optional[str] = None
    command_line: Optional[str] = None
    operation: Optional[str] = None
    file_type: Optional[str] = None

class AnalyzeRequest(BaseModel):
    user_id: str
    asset_sensitivity: Optional[str] = "LOW"
    events: List[Event]

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/analyze/behavior")
def analyze(req: AnalyzeRequest) -> Dict:
    result = analyzer.analyze_user_behavior([e.dict() for e in req.events], req.asset_sensitivity)
    return {"user_id": req.user_id, **result}
PY
}

write_behavior_override(){
  log "write compose override"
  cat > "$OVR" <<YAML
services:
  behavioral-analytics:
    build: ../apps/behavioral-analytics
    container_name: ffactory_behavioral_analytics
    ports:
      - "127.0.0.1:8090:8090"
    environment:
      NEO4J_URL: bolt://neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: ${NEO4J_TARGET_PW}
    depends_on:
      - kafka
      - neo4j
    healthcheck:
      test: ["CMD","curl","-fsS","http://localhost:8090/health"]
      interval: 20s
      timeout: 3s
      retries: 15
YAML
}

build_and_up_behavior(){
  log "build and up behavioral-analytics"
  docker compose -p "$PROJ" -f "$OPS" -f "$OVR" up -d --build behavioral-analytics
  log "wait api 8090"
  wait_http "http://127.0.0.1:8090/health" 60 || { echo "api down"; exit 1; }
}

smoke(){
  log "neo4j http"
  curl -fsS http://127.0.0.1:7474/ | head -n1 || true
  log "api health"
  curl -fsS http://127.0.0.1:8090/health

  log "post anomaly test"
  UNUSUAL_EVENTS='{"user_id":"anomaly_user","asset_sensitivity":"MEDIUM","events":['
  for i in $(seq 1 100); do
    UNUSUAL_EVENTS+='{"event_id":"evt_'"$i"'","timestamp":"2025-10-31T01:00:00Z","user_id":"anomaly_user","event_type":"PROCESS_EXECUTION","process_name":"mimikatz.exe","operation":"READ_MEM"},'
  done
  UNUSUAL_EVENTS="${UNUSUAL_EVENTS%,}]}"
  curl -fsS -X POST http://127.0.0.1:8090/analyze/behavior -H "Content-Type: application/json" -d "$UNUSUAL_EVENTS"
  echo
}

main(){
  require docker
  require curl
  [ -f "$OPS" ] || { echo "missing $OPS"; exit 1; }

  patch_ops_minimal
  ensure_neo4j_up
  set_final_password
  write_behavior_app
  write_behavior_override
  build_and_up_behavior
  smoke
  log "done"
}

main
