#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! docker compose version &>/dev/null; then
  echo "Error: docker compose is not available" >&2
  exit 1
fi

if [ ! -f certs/ca.crt ]; then
  echo "==> Generating dev certificates..."
  ./certs/generate.sh
fi

echo "==> Writing Docker configs..."
cat > config.server.docker.yml <<'YAML'
listen: "0.0.0.0:8443"

tls:
  cert: /app/certs/server.crt
  key: /app/certs/server.key
  ca: /app/certs/ca.crt

amqp:
  url: "amqp://guest:guest@lavinmq:5672"
  task_queue: "tasks"
  result_queue: "results"

allowed_clients:
  - ci-bot

limits:
  request_body_bytes: 65536
  rate_per_minute: 60

results:
  url: "postgres://command_runner:secretpass@postgres:5432/command_runner"
  results_limit: 100
YAML

cat > config.agent.docker.yml <<'YAML'
agent_id: "agent-01"

amqp:
  url: "amqp://guest:guest@lavinmq:5672"
  task_queue: "tasks"
  result_queue: "results"
  poll_interval: 3

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

  - name: disk_usage
    command: ["/bin/df", "-h"]
    timeout: 10
YAML

echo "==> Building and starting containers..."
docker compose up -d --build

echo "==> Waiting for central server..."
for i in $(seq 1 60); do
  if curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
      -sf https://localhost:8443/health &>/dev/null; then
    echo "    ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "    timeout — check: docker compose logs central_server" >&2
    exit 1
  fi
  sleep 1
done

echo ""
echo "==> All services running:"
echo "    LavinMQ:         http://localhost:15672 (guest/guest)"
echo "    Central server:  https://localhost:8443"
echo ""
echo "    Submit a task:"
echo "      curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \\"
echo "        -X POST https://localhost:8443/tasks \\"
echo "        -H 'Content-Type: application/json' \\"
echo "        -d '{\"workload\":\"echo\",\"params\":{\"message\":\"hello\"}}'"
echo ""
echo "    View results:"
echo "      curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \\"
echo "        https://localhost:8443/results"
echo ""
echo "    Logs:"
echo "      docker compose logs -f central_server agent"
echo ""
echo "    Stop:  ./scripts/dev-down.sh"
