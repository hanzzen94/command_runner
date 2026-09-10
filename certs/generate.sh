#!/usr/bin/env bash
set -euo pipefail

# Generates a dev CA, server certificate, client certificate, and AMQP mTLS
# certificates for the central server and LavinMQ broker.
# Usage: ./certs/generate.sh [client_cn]
# Default client CN: ci-bot
#
# To generate per-agent AMQP client certs, use:
#   ./certs/generate-agent.sh <server_cloud_id>

DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT_CN="${1:-ci-bot}"

echo "==> Generating certificates in $DIR"

# --- CA ---
if [ ! -f "$DIR/ca.key" ]; then
  echo "  creating CA key + certificate"
  openssl genrsa -out "$DIR/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$DIR/ca.key" -sha256 -days 3650 \
    -subj "/CN=command-runner-dev-ca" -out "$DIR/ca.crt"
else
  echo "  CA key already exists, skipping"
fi

# --- Server ---
echo "  creating server key + certificate (CN=localhost, SAN=localhost/127.0.0.1)"
openssl genrsa -out "$DIR/server.key" 2048 2>/dev/null

cat > "$DIR/server.ext" <<EOF
subjectAltName = DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

openssl req -new -key "$DIR/server.key" \
  -subj "/CN=localhost" -out "$DIR/server.csr"

openssl x509 -req -in "$DIR/server.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/server.crt" -days 825 -sha256 \
  -extfile "$DIR/server.ext" 2>/dev/null

# --- Client ---
echo "  creating client key + certificate (CN=$CLIENT_CN)"
openssl genrsa -out "$DIR/client.key" 2048 2>/dev/null

cat > "$DIR/client.ext" <<EOF
extendedKeyUsage = clientAuth
EOF

openssl req -new -key "$DIR/client.key" \
  -subj "/CN=$CLIENT_CN" -out "$DIR/client.csr"

openssl x509 -req -in "$DIR/client.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/client.crt" -days 825 -sha256 \
  -extfile "$DIR/client.ext" 2>/dev/null

# --- AMQP Server client cert ---
echo "  creating AMQP server client key + certificate (CN=amqp-server)"
openssl genrsa -out "$DIR/amqp-server.key" 2048 2>/dev/null

cat > "$DIR/amqp-server.ext" <<EOF
extendedKeyUsage = clientAuth
EOF

openssl req -new -key "$DIR/amqp-server.key" \
  -subj "/CN=amqp-server" -out "$DIR/amqp-server.csr"

openssl x509 -req -in "$DIR/amqp-server.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/amqp-server.crt" -days 825 -sha256 \
  -extfile "$DIR/amqp-server.ext" 2>/dev/null

# --- LavinMQ server cert (for AMQPS listener) ---
echo "  creating LavinMQ server key + certificate (CN=lavinmq, SAN=lavinmq/localhost/127.0.0.1)"
openssl genrsa -out "$DIR/lavinmq.key" 2048 2>/dev/null

cat > "$DIR/lavinmq.ext" <<EOF
subjectAltName = DNS:lavinmq, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

openssl req -new -key "$DIR/lavinmq.key" \
  -subj "/CN=lavinmq" -out "$DIR/lavinmq.csr"

openssl x509 -req -in "$DIR/lavinmq.csr" -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" \
  -CAcreateserial -out "$DIR/lavinmq.crt" -days 825 -sha256 \
  -extfile "$DIR/lavinmq.ext" 2>/dev/null

# --- Cleanup intermediates ---
rm -f "$DIR/server.csr" "$DIR/client.csr" "$DIR/server.ext" "$DIR/client.ext" \
  "$DIR/amqp-server.csr" "$DIR/amqp-server.ext" \
  "$DIR/lavinmq.csr" "$DIR/lavinmq.ext"

echo ""
echo "==> Done. Files created:"
echo "  CA:           $DIR/ca.crt / $DIR/ca.key"
echo "  HTTP Server:  $DIR/server.crt / $DIR/server.key"
echo "  HTTP Client:  $DIR/client.crt / $DIR/client.key (CN=$CLIENT_CN)"
echo "  AMQP Server:  $DIR/amqp-server.crt / $DIR/amqp-server.key"
echo "  LavinMQ:      $DIR/lavinmq.crt / $DIR/lavinmq.key"
echo ""
echo "Per-agent AMQP certs (run separately):"
echo "  ./certs/generate-agent.sh <server_cloud_id>"
echo ""
echo "Test with curl:"
echo "  curl --cacert $DIR/ca.crt --cert $DIR/client.crt --key $DIR/client.key \\"
echo "    https://localhost:8443/workloads"
