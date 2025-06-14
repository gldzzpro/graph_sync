#!/bin/bash
# test_custom_modules.sh — Start FastAPI service and trigger a sync operation for Custom category modules

set -euo pipefail

VENV_DIR=".venv"
REQ_FILE="requirements.txt"
ENV_FILE=".env"
CONFIG_FILE="config.yml"
HOST="localhost"
PORT=8000
BASE_URL="http://${HOST}:${PORT}"
NEO4J_SYNC_URL="http://localhost:8001"
LOG_FILE="custom_modules_sync.log"

# Check if config.yaml exists
if [ ! -f "$CONFIG_FILE" ]; then
  if [ -f "${CONFIG_FILE}.example" ]; then
    echo "⚠️ $CONFIG_FILE not found, but ${CONFIG_FILE}.example exists."
    echo "💡 Please create $CONFIG_FILE from the example file:"
    echo "   cp ${CONFIG_FILE}.example ${CONFIG_FILE}"
    echo "   Then edit $CONFIG_FILE to configure your Odoo instances."
    exit 1
  else
    echo "❌ Neither $CONFIG_FILE nor ${CONFIG_FILE}.example found!"
    exit 1
  fi
fi

# Check if INSTANCE_NAME is provided and exists in config
INSTANCE_NAME=${INSTANCE_NAME:-"odoo1"}
if ! grep -q "name: \"$INSTANCE_NAME\"" "$CONFIG_FILE"; then
  echo "⚠️ Instance '$INSTANCE_NAME' not found in $CONFIG_FILE"
  echo "💡 Available instances:"
  grep -A 1 "- name:" "$CONFIG_FILE" | grep "name:" | sed 's/.*name: "\(.*\)".*/   - \1/'
  echo "💡 Please specify a valid instance name or update your $CONFIG_FILE"
  exit 1
fi

# Function to check if service is running
check_service_running() {
  if curl -s "$BASE_URL/healthcheck" >/dev/null 2>&1; then
    return 0  # Service is running
  else
    return 1  # Service is not running
  fi
}

# Check if service is already running
SERVICE_ALREADY_RUNNING=false
if check_service_running; then
  echo "✅ Service is already running on $BASE_URL"
  SERVICE_ALREADY_RUNNING=true
  MS_PID=""  # No PID since we didn't start it
else
  echo "🔍 Service not running, starting itzzz..."
  
  # 1. Create & activate venv if it doesn't exist
  if [ ! -d "$VENV_DIR" ]; then
    echo "🛠️  Creating virtualenv..."
    python3 -m venv "$VENV_DIR"
  fi

  # shellcheck disable=SC1090
  source "$VENV_DIR/bin/activate"

  # 2. Install dependencies
  echo "📦 Installing dependencies..."
  pip install --upgrade pip
  pip install -r "$REQ_FILE"

  # 3. Load environment variables
  if [ -f "$ENV_FILE" ]; then
    echo "🔑 Loading environment from $ENV_FILE"
    set -a
    # shellcheck disable=SC1091
    source "$ENV_FILE"
    set +a
  else
    echo "⚠️  No $ENV_FILE found, using defaults."
  fi

  # 4. Start FastAPI microservice in the background
  echo "🚀 Starting GraphSync microservice on $BASE_URL..."
  uvicorn app:app --host 0.0.0.0 --port "$PORT" --log-level info > "$LOG_FILE" 2>&1 &
  MS_PID=$!

  # 5. Wait for service to be ready
  echo -n "⏳ Waiting for service to start"
  until check_service_running; do
    echo -n "."
    sleep 1
    # Check if service is still running
    if ! kill -0 $MS_PID 2>/dev/null; then
      echo "❌ Service failed to start! Check $LOG_FILE for details."
      cat "$LOG_FILE"
      exit 1
    fi
  done
  echo " ready!"
fi

# Ensure we clean up the service on exit (only if we started it)
function cleanup {
  if [ "$SERVICE_ALREADY_RUNNING" = false ] && [ -n "$MS_PID" ]; then
    echo "🛑 Stopping microservice (PID: $MS_PID)..."
    kill $MS_PID 2>/dev/null || true
  fi
  echo "✅ Test completed"
}
# trap cleanup EXIT  # Commented out to keep service running

# 6. Trigger the sync operation for Custom category modules
echo "🔄 Triggering sync operation for Custom category modules..."

# Use the INSTANCE_NAME that was validated in the config check
echo "📌 Using Odoo instance: $INSTANCE_NAME"

# FIXED: Changed from /api/sync/trigger to /trigger
# Also updated the request payload to match the TriggerRequest model
SYNC_RESPONSE=$(curl -s -X POST "$BASE_URL/trigger" \
  -H "Content-Type: application/json" \
  -d '{"category_prefixes": ["Custom"], "include_reverse": true, "options": {"exact_match": false, "include_subcategories": true, "max_depth": null, "stop_domains": [], "exclude_domains": []}}')

echo "📊 Sync response: $SYNC_RESPONSE"

# Store the graph_sync response and use it for Neo4j ingestion
echo "🔄 Sending graph data to Neo4j microservice..."
# Wrap the sync response in the expected format
INGEST_PAYLOAD=$(echo "$SYNC_RESPONSE" | jq '{responses: .}')
INGEST_RESPONSE=$(curl -s -X POST "$NEO4J_SYNC_URL/api/graph/ingest" \
  -H "Content-Type: application/json" \
  -d "$INGEST_PAYLOAD")

echo "📊 Neo4j ingest response: $INGEST_RESPONSE"
# 7. Monitor logs for completion
echo "📋 Monitoring logs for completion..."
TIMEOUT=180  # Increased timeout for multi-instance setup
START_TIME=$(date +%s)

while true; do
  # Check for successful completion message
  if grep -q "Sync task completed successfully" "$LOG_FILE"; then
    echo "✅ Sync task completed successfully!"
    
    # 8. Check for Neo4j ingestion confirmation
    if grep -q "Data loading complete" "$LOG_FILE"; then
      echo "🎉 Data successfully ingested into Neo4j!"
    else
      echo "⚠️ Sync completed but Neo4j ingestion status unclear. Check logs for details."
    fi
    
    if [ "$SERVICE_ALREADY_RUNNING" = false ]; then
      echo "👉 Service is still running on $BASE_URL (PID: $MS_PID)"
      echo "👉 Use 'kill $MS_PID' to stop it when you're done"
    else
      echo "👉 Service continues running on $BASE_URL"
    fi
    break
  fi
  
  # Check for various failure conditions
  if grep -q "Sync task failed\|Sync task wrapper failed\|Failed to trigger sync" "$LOG_FILE"; then
    echo "❌ Sync task failed! Check $LOG_FILE for details."
    tail -n 20 "$LOG_FILE"
    exit 1
  fi
  
  # Check for Odoo connection errors
  if grep -q "Odoo RPC error\|No Odoo instance configured\|Odoo instance.*not found" "$LOG_FILE"; then
    echo "❌ Odoo connection error! Check $LOG_FILE for details."
    echo "💡 Make sure the instance name '$INSTANCE_NAME' is correctly configured in config.yaml"
    tail -n 20 "$LOG_FILE"
    exit 1
  fi
  
  # Check for Neo4j connection errors
  if grep -q "Neo4j error\|Failed to connect to Neo4j" "$LOG_FILE"; then
    echo "❌ Neo4j connection error! Check $LOG_FILE for details."
    echo "💡 Make sure Neo4j is running and properly configured in config.yaml"
    tail -n 20 "$LOG_FILE"
    exit 1
  fi
  
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED -gt $TIMEOUT ]; then
    echo "⏰ Timeout waiting for sync to complete!"
    tail -n 20 "$LOG_FILE"
    exit 1
  fi
  
  echo -n "."
  sleep 2
done

# 9. Display summary of nodes and edges (if available in logs)
echo ""
echo "📈 Sync Summary for instance '$INSTANCE_NAME':"
if grep -q "Added [0-9]\+ nodes" "$LOG_FILE"; then
  NODES=$(grep "Added [0-9]\+ nodes" "$LOG_FILE" | tail -n 1 | sed 's/.*Added \([0-9]\+\) nodes.*/\1/')
  echo "   - Nodes added: $NODES"
fi

if grep -q "Added [0-9]\+ relationships" "$LOG_FILE"; then
  EDGES=$(grep "Added [0-9]\+ relationships" "$LOG_FILE" | tail -n 1 | sed 's/.*Added \([0-9]\+\) relationships.*/\1/')
  echo "   - Relationships added: $EDGES"
fi

echo ""
echo "📝 Check $LOG_FILE for detailed logs"
echo "💡 To sync with a different Odoo instance, run:"
echo "   INSTANCE_NAME=odoo2 ./test_custom_modules.sh"