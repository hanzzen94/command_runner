# Generates a dev CA, server certificate, and client certificate for mTLS testing.
# Usage: .\certs\generate.ps1 [-ClientCn <name>]
# Default client CN: ci-bot
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

# --- Cleanup intermediates ---
Remove-Item "$Dir\server.csr", "$Dir\client.csr", "$Dir\server.ext", "$Dir\client.ext" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==> Done. Files created:"
Write-Host "  CA:     $Dir\ca.crt / $Dir\ca.key"
Write-Host "  Server: $Dir\server.crt / $Dir\server.key"
Write-Host "  Client: $Dir\client.crt / $Dir\client.key (CN=$ClientCn)"
Write-Host ""
Write-Host "Test with curl:"
Write-Host "  curl --cacert $Dir\ca.crt --cert $Dir\client.crt --key $Dir\client.key ``"
Write-Host "    https://localhost:8443/workloads"
