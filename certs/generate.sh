#!/usr/bin/env bash
set -euo pipefail

# Generates a dev CA, server certificate, and client certificate for mTLS testing.
# Usage: ./certs/generate.sh [client_cn]
# Default client CN: ci-bot

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

# --- Cleanup intermediates ---
rm -f "$DIR/server.csr" "$DIR/client.csr" "$DIR/server.ext" "$DIR/client.ext"

echo ""
echo "==> Done. Files created:"
echo "  CA:     $DIR/ca.crt / $DIR/ca.key"
echo "  Server: $DIR/server.crt / $DIR/server.key"
echo "  Client: $DIR/client.crt / $DIR/client.key (CN=$CLIENT_CN)"
echo ""
echo "Test with curl:"
echo "  curl --cacert $DIR/ca.crt --cert $DIR/client.crt --key $DIR/client.key \\"
echo "    https://localhost:8443/workloads"
