#!/usr/bin/env bash
set -euo pipefail

# Generates a per-agent AMQP client certificate signed by the dev CA.
# The certificate CN matches the agent_id, enabling per-agent identity
# via mTLS when connecting to LavinMQ.
#
# Usage: ./certs/generate-agent.sh <agent_id>
# Example: ./certs/generate-agent.sh agent-01

if [ $# -lt 1 ]; then
  echo "Usage: $0 <agent_id>" >&2
  echo "  Example: $0 agent-01" >&2
  exit 1
fi

AGENT_ID="$1"
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
