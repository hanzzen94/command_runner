# Generates a dev CA, server certificate, client certificate, and AMQP mTLS
# certificates for the central server and LavinMQ broker.
# Usage: .\certs\generate.ps1 [-ClientCn <name>]
# Default client CN: ci-bot
#
# To generate per-agent AMQP client certs, use:
#   .\certs\generate-agent.ps1 <agent_id>
#
# Requires OpenSSL installed and available in PATH.
# Install via:  choco install openssl  or  scoop install openssl

param(
    [string]$ClientCn = "ci-bot"
)

$ErrorActionPreference = "Stop"
$Dir = $PSScriptRoot

Write-Host "==> Generating certificates in $Dir"

# --- CA ---
if (-not (Test-Path "$Dir\ca.key")) {
    Write-Host "  creating CA key + certificate"
    & openssl genrsa -out "$Dir\ca.key" 4096 2>$null
    & openssl req -x509 -new -nodes -key "$Dir\ca.key" -sha256 -days 3650 `
        -subj "/CN=command-runner-dev-ca" -out "$Dir\ca.crt"
} else {
    Write-Host "  CA key already exists, skipping"
}

# --- Server ---
Write-Host "  creating server key + certificate (CN=localhost, SAN=localhost/127.0.0.1)"
& openssl genrsa -out "$Dir\server.key" 2048 2>$null

Set-Content -Path "$Dir\server.ext" -Value @"
subjectAltName = DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
"@

& openssl req -new -key "$Dir\server.key" `
    -subj "/CN=localhost" -out "$Dir\server.csr"

& openssl x509 -req -in "$Dir\server.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Dir\server.crt" -days 825 -sha256 `
    -extfile "$Dir\server.ext" 2>$null

# --- Client ---
Write-Host "  creating client key + certificate (CN=$ClientCn)"
& openssl genrsa -out "$Dir\client.key" 2048 2>$null

Set-Content -Path "$Dir\client.ext" -Value @"
extendedKeyUsage = clientAuth
"@

& openssl req -new -key "$Dir\client.key" `
    -subj "/CN=$ClientCn" -out "$Dir\client.csr"

& openssl x509 -req -in "$Dir\client.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Dir\client.crt" -days 825 -sha256 `
    -extfile "$Dir\client.ext" 2>$null

# --- AMQP Server client cert ---
Write-Host "  creating AMQP server client key + certificate (CN=amqp-server)"
& openssl genrsa -out "$Dir\amqp-server.key" 2048 2>$null

Set-Content -Path "$Dir\amqp-server.ext" -Value @"
extendedKeyUsage = clientAuth
"@

& openssl req -new -key "$Dir\amqp-server.key" `
    -subj "/CN=amqp-server" -out "$Dir\amqp-server.csr"

& openssl x509 -req -in "$Dir\amqp-server.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Dir\amqp-server.crt" -days 825 -sha256 `
    -extfile "$Dir\amqp-server.ext" 2>$null

# --- LavinMQ server cert (for AMQPS listener) ---
Write-Host "  creating LavinMQ server key + certificate (CN=lavinmq, SAN=lavinmq/localhost/127.0.0.1)"
& openssl genrsa -out "$Dir\lavinmq.key" 2048 2>$null

Set-Content -Path "$Dir\lavinmq.ext" -Value @"
subjectAltName = DNS:lavinmq, DNS:localhost, IP:127.0.0.1
extendedKeyUsage = serverAuth
"@

& openssl req -new -key "$Dir\lavinmq.key" `
    -subj "/CN=lavinmq" -out "$Dir\lavinmq.csr"

& openssl x509 -req -in "$Dir\lavinmq.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Dir\lavinmq.crt" -days 825 -sha256 `
    -extfile "$Dir\lavinmq.ext" 2>$null

# --- Cleanup intermediates ---
Remove-Item "$Dir\server.csr", "$Dir\client.csr", "$Dir\server.ext", "$Dir\client.ext", `
    "$Dir\amqp-server.csr", "$Dir\amqp-server.ext", `
    "$Dir\lavinmq.csr", "$Dir\lavinmq.ext" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==> Done. Files created:"
Write-Host "  CA:           $Dir\ca.crt / $Dir\ca.key"
Write-Host "  HTTP Server:  $Dir\server.crt / $Dir\server.key"
Write-Host "  HTTP Client:  $Dir\client.crt / $Dir\client.key (CN=$ClientCn)"
Write-Host "  AMQP Server:  $Dir\amqp-server.crt / $Dir\amqp-server.key"
Write-Host "  LavinMQ:      $Dir\lavinmq.crt / $Dir\lavinmq.key"
Write-Host ""
Write-Host "Per-agent AMQP certs (run separately):"
Write-Host "  .\certs\generate-agent.ps1 <agent_id>"
Write-Host ""
Write-Host "Test with curl:"
Write-Host "  curl --cacert $Dir\ca.crt --cert $Dir\client.crt --key $Dir\client.key ``"
Write-Host "    https://localhost:8443/workloads"
