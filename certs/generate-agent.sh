#!/usr/bin/env bash
set -euo pipefail

# Generates a per-agent AMQP client certificate signed by the dev CA.
# The certificate CN matches the server_cloud_id, enabling per-agent identity
# via mTLS when connecting to LavinMQ.
#
# With --create-user, also creates a matching LavinMQ user with a unique
# random password and restrictive permissions. Requires LavinMQ to be
# running and reachable on the management API.
#
# Usage: ./certs/generate-agent.sh <server_cloud_id> [--create-user]
# Example: ./certs/generate-agent.sh 550e8400-e29b-41d4-a716-446655440000
# Example: ./certs/generate-agent.sh 550e8400-e29b-41d4-a716-446655440000 --create-user

CREATE_USER=false

if [ $# -lt 1 ]; then
  echo "Usage: $0 <server_cloud_id> [--create-user]" >&2
  echo "  Example: $0 550e8400-e29b-41d4-a716-446655440000" >&2
  echo "  Example: $0 550e8400-e29b-41d4-a716-446655440000 --create-user" >&2
  exit 1
fi

AGENT_ID="$1"
shift

while [ $# -gt 0 ]; do
  case "$1" in
    --create-user) CREATE_USER=true ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$DIR/ca.key" ] || [ ! -f "$DIR/ca.crt" ]; then
  echo "Error: CA certificate not found. Run ./certs/generate.sh first." >&2
  exit 1
fi

CERT="$DIR/${AGENT_ID}.crt"
KEY="$DIR/${AGENT_ID}.key"

echo "==> Generating AMQP client cert for agent '${AGENT_ID}'"

openssl genrsa -out "$KEY" 2048 2>/dev/null

cat > "$DIR/${AGENT_ID}.ext" <<EOF
extendedKeyUsage = clientAuth
EOF

openssl req -new -key "$KEY" \
  -subj "/CN=${AGENT_ID}" -out "$DIR/${AGENT_ID}.csr"

openssl x509 -req -in "$DIR/${AGENT_ID}.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$CERT" -days 825 -sha256 \
  -extfile "$DIR/${AGENT_ID}.ext" 2>/dev/null

rm -f "$DIR/${AGENT_ID}.csr" "$DIR/${AGENT_ID}.ext"

echo "  Cert: $CERT"
echo "  Key:  $KEY"
echo ""
echo "Use in agent config:"
echo "  amqp:"
echo "    cert: certs/${AGENT_ID}.crt"
echo "    key:  certs/${AGENT_ID}.key"

if [ "$CREATE_USER" = true ]; then
  echo ""
  SCRIPTS_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
  echo "==> Creating LavinMQ user for '${AGENT_ID}'..."
  AMQP_URL="$("$SCRIPTS_DIR/setup-lavinmq-users.sh" --agents-only "$AGENT_ID" | tail -1)"
  echo "  AMQP URL: ${AMQP_URL}"
  echo ""
  echo "Full agent amqp config:"
  echo "  amqp:"
  echo "    url: \"${AMQP_URL}\""
  echo "    cert: certs/${AGENT_ID}.crt"
  echo "    key:  certs/${AGENT_ID}.key"
fi
