#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! docker compose version &>/dev/null; then
  echo "Error: docker compose is not available" >&2
  exit 1
fi

if [ ! -f certs/ca.crt ] || [ ! -f certs/lavinmq.crt ]; then
  echo "==> Generating dev certificates..."
  ./certs/generate.sh
fi

if [ -f .dev-agent-guid ]; then
  AGENT_GUID=$(cat .dev-agent-guid)
  echo "==> Using existing agent GUID: ${AGENT_GUID}"
else
  AGENT_GUID=$(cat /proc/sys/kernel/random/uuid)
  echo "==> Generating per-agent AMQP certificate for ${AGENT_GUID}..."
  ./certs/generate-agent.sh "$AGENT_GUID"
  echo "$AGENT_GUID" > .dev-agent-guid
fi

echo "==> Starting LavinMQ (for user creation)..."
docker compose up -d lavinmq

echo "==> Waiting for LavinMQ to be healthy..."
for i in $(seq 1 30); do
  if docker compose exec -T lavinmq lavinmqctl status >/dev/null 2>&1; then
    echo "    ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "    timeout — check: docker compose logs lavinmq" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Creating LavinMQ users with per-agent credentials..."
LAVINMQ_HOST=localhost LAVINMQ_AMQP_HOST=lavinmq \
  ./scripts/setup-lavinmq-users.sh "$AGENT_GUID" > /tmp/lavinmq-creds
SERVER_AMQP_URL="$(sed -n '1p' /tmp/lavinmq-creds)"
AGENT_AMQP_URL="$(sed -n '2p' /tmp/lavinmq-creds)"
rm -f /tmp/lavinmq-creds

echo "==> Writing Docker configs..."
cat > config.server.docker.yml <<YAML
listen: "0.0.0.0:8443"

tls:
  cert: /app/certs/server.crt
  key: /app/certs/server.key
  ca: /app/certs/ca.crt

amqp:
  url: "${SERVER_AMQP_URL}"
  task_queue: "tasks"
  result_queue: "results"
  ca: /app/certs/ca.crt
  cert: /app/certs/amqp-server.crt
  key: /app/certs/amqp-server.key

allowed_clients:
  - ci-bot

limits:
  request_body_bytes: 65536
  rate_per_minute: 60

results:
  url: "postgres://command_runner:secretpass@postgres:5432/command_runner"
  results_limit: 100
YAML

cat > config.agent.docker.yml <<YAML
server_cloud_id: "${AGENT_GUID}"

amqp:
  url: "${AGENT_AMQP_URL}"
  task_queue: "tasks"
  result_queue: "results"
  poll_interval: 3
  ca: /app/certs/ca.crt
  cert: /app/certs/${AGENT_GUID}.crt
  key: /app/certs/${AGENT_GUID}.key

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

echo "==> Building and starting remaining containers..."
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
echo "    LavinMQ:         http://localhost:15672 (guest/guest, loopback only)"
echo "    Central server:  https://localhost:8443"
echo "    AMQP auth:       per-agent users with unique passwords + mTLS"
echo ""
  echo "    Submit a task:"
  echo "      curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \\"
  echo "        -X POST https://localhost:8443/tasks \\"
  echo "        -H 'Content-Type: application/json' \\"
  echo "        -d '{\"server_cloud_id\":\"${AGENT_GUID}\",\"customer_id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"workload\":\"echo\",\"params\":{\"message\":\"hello\"}}'"
echo ""
echo "    View results:"
echo "      curl --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \\"
echo "        https://localhost:8443/results"
echo ""
echo "    Logs:"
echo "      docker compose logs -f central_server agent"
echo ""
echo "    Stop:  ./scripts/dev-down.sh"
