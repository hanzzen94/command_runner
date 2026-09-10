#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NUM_AGENTS="${1:-100}"
TASKS_PER_AGENT="${2:-1}"
AGENT_POLL_INTERVAL=2

TMP_DIR=$(mktemp -d /tmp/command_runner_stress.XXXXXX)
PIDS=()

cleanup() {
  echo ""
  echo "==> Cleaning up agents..."
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ ! -f bin/command_runner ] || [ ! -f bin/central_server ]; then
  echo "==> Building binaries..."
  crystal build src/agent/main.cr -o bin/command_runner
  crystal build src/server/main.cr -o bin/central_server
fi

echo "==> Writing stress-test server config (rate_per_minute: 10000)..."

# Create a stress-test LavinMQ user with broad permissions
STRESS_PASS=$(openssl rand -base64 32 | tr -d '\n/+=' | head -c 32)
curl -sf -u guest:guest -X PUT http://localhost:15672/api/users/stress-test \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"${STRESS_PASS}\",\"tags\":\"\"}" >/dev/null
curl -sf -u guest:guest -X PUT http://localhost:15672/api/permissions/%2F/stress-test \
  -H 'Content-Type: application/json' \
  -d '{"configure":".*","write":".*","read":".*"}' >/dev/null

cat > config.server.docker.yml <<YAML
listen: "0.0.0.0:8443"

tls:
  cert: /app/certs/server.crt
  key: /app/certs/server.key
  ca: /app/certs/ca.crt

amqp:
  url: "amqps://stress-test:${STRESS_PASS}@lavinmq:5671"
  task_queue: "tasks"
  result_queue: "results"
  ca: /app/certs/ca.crt
  cert: /app/certs/amqp-server.crt
  key: /app/certs/amqp-server.key

allowed_clients:
  - ci-bot

limits:
  request_body_bytes: 65536
  rate_per_minute: 10000

results:
  url: "postgres://command_runner:secretpass@postgres:5432/command_runner"
  results_limit: 100000
YAML

if ! docker compose ps --services 2>/dev/null | grep -q lavinmq; then
  echo "==> Starting base services..."
  if [ ! -f certs/ca.crt ]; then
    ./certs/generate.sh
  fi
  docker compose up -d --build lavinmq postgres central_server
else
  echo "==> Restarting central_server with stress-test config..."
  docker compose up -d --force-recreate central_server
fi

echo "==> Waiting for central server..."
for i in $(seq 1 60); do
  if curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
      -sf https://localhost:8443/health &>/dev/null; then
    echo "    ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "    timeout" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Generating $NUM_AGENTS agent configs..."
CUSTOMER_GUID=$(cat /proc/sys/kernel/random/uuid)
SCID_ARRAY=()
for i in $(seq 1 "$NUM_AGENTS"); do
  scid=$(cat /proc/sys/kernel/random/uuid)
  SCID_ARRAY+=("$scid")
  cat > "$TMP_DIR/$scid.yml" <<YAML
server_cloud_id: "$scid"

amqp:
  url: "amqp://stress-test:${STRESS_PASS}@localhost:5672"
  task_queue: "tasks"
  result_queue: "results"
  poll_interval: $AGENT_POLL_INTERVAL

limits:
  output_bytes: 1048576
  default_timeout: 30

workloads:
  - name: echo
    command: ["/bin/echo", "{message}"]
    params:
      - name: message
        required: true
        pattern: "^[a-zA-Z0-9 ._-]+$"
    timeout: 5
YAML
done

echo "==> Launching $NUM_AGENTS agents..."
for i in $(seq 0 $((NUM_AGENTS - 1))); do
  scid="${SCID_ARRAY[$i]}"
  ./bin/command_runner --config "$TMP_DIR/$scid.yml" > "$TMP_DIR/$scid.log" 2>&1 &
  PIDS+=($!)
done

sleep 3
alive=0
for pid in "${PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    alive=$((alive + 1))
  fi
done
echo "    $alive / ${#PIDS[@]} agents alive"

TOTAL_TASKS=$((NUM_AGENTS * TASKS_PER_AGENT))

echo ""
echo "==> Submitting $TOTAL_TASKS tasks ($TASKS_PER_AGENT per agent)..."
INITIAL_RESULTS=$(curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  -s "https://localhost:8443/results?limit=100000" | python3 -c \
  "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "    pre-existing results in DB: $INITIAL_RESULTS"

SUBMIT_START=$(date +%s%N)

SUBMITTED=0
FAILED=0
for i in $(seq 0 $((NUM_AGENTS - 1))); do
  scid="${SCID_ARRAY[$i]}"
  for j in $(seq 1 "$TASKS_PER_AGENT"); do
    code=$(curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
      -s -o /dev/null -w '%{http_code}' \
      -X POST https://localhost:8443/tasks \
      -H 'Content-Type: application/json' \
      -d "{\"server_cloud_id\":\"$scid\",\"customer_id\":\"$CUSTOMER_GUID\",\"workload\":\"echo\",\"params\":{\"message\":\"task-$j\"}}")
    if [ "$code" = "201" ]; then
      SUBMITTED=$((SUBMITTED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  done
done

SUBMIT_END=$(date +%s%N)
SUBMIT_MS=$(( (SUBMIT_END - SUBMIT_START) / 1000000 ))
echo "    submitted: $SUBMITTED, failed: $FAILED (${SUBMIT_MS}ms)"

if [ "$SUBMITTED" -eq 0 ]; then
  echo "    no tasks submitted, aborting" >&2
  exit 1
fi

echo ""
echo "==> Waiting for results..."
WAIT_START=$(date +%s%N)
TIMEOUT=120
RESULTS=0
while true; do
  RESULTS=$(curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
    -s "https://localhost:8443/results?limit=100000" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

  NEW_RESULTS=$((RESULTS - INITIAL_RESULTS))
  ELAPSED=$(( ($(date +%s%N) - WAIT_START) / 1000000000 ))
  echo "    new results: $NEW_RESULTS / $SUBMITTED (${ELAPSED}s)"

  if [ "$NEW_RESULTS" -ge "$SUBMITTED" ]; then
    echo "    all results received!"
    break
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "    timeout after ${TIMEOUT}s — got $NEW_RESULTS of $SUBMITTED" >&2
    break
  fi

  sleep 2
done
WAIT_END=$(date +%s%N)
WAIT_MS=$(( (WAIT_END - WAIT_START) / 1000000 ))
TOTAL_MS=$(( (WAIT_END - SUBMIT_START) / 1000000 ))

echo ""
echo "============================================"
echo "  STRESS TEST RESULTS"
echo "============================================"
echo "  Agents:           $NUM_AGENTS"
echo "  Tasks per agent:  $TASKS_PER_AGENT"
echo "  Total tasks:      $TOTAL_TASKS"
echo "  Submitted:        $SUBMITTED"
echo "  Failed (429/etc): $FAILED"
echo "  Results received: $NEW_RESULTS"
echo "  Submit time:      ${SUBMIT_MS}ms"
echo "  Wait for results: ${WAIT_MS}ms"
echo "  Total time:       ${TOTAL_MS}ms"
if [ "$TOTAL_MS" -gt 0 ] && [ "$NEW_RESULTS" -gt 0 ]; then
  THROUGHPUT=$(python3 -c "print(f'{$NEW_RESULTS * 1000 / $TOTAL_MS:.1f}')")
  echo "  Throughput:       ${THROUGHPUT} tasks/sec"
fi
if [ "$SUBMITTED" -gt 0 ]; then
  SUCCESS_RATE=$(python3 -c "print(f'{$NEW_RESULTS * 100 / $SUBMITTED:.1f}')")
  echo "  Success rate:     ${SUCCESS_RATE}%"
fi
echo "============================================"
echo ""
  echo "  Agent logs:       $TMP_DIR/"
  echo "  LavinMQ queues:   http://localhost:15672 (guest/guest, loopback only)"
  echo "  Stop everything:  ./scripts/dev-down.sh"
