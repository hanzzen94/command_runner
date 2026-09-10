# Generates a per-agent AMQP client certificate signed by the dev CA.
# The certificate CN matches the server_cloud_id, enabling per-agent identity
# via mTLS when connecting to LavinMQ.
#
# Usage: .\certs\generate-agent.ps1 <server_cloud_id>
# Example: .\certs\generate-agent.ps1 550e8400-e29b-41d4-a716-446655440000

param(
    [Parameter(Mandatory=$true)]
    [string]$ServerCloudId
)

$ErrorActionPreference = "Stop"
$Dir = $PSScriptRoot

if (-not (Test-Path "$Dir\ca.key") -or -not (Test-Path "$Dir\ca.crt")) {
    Write-Host "Error: CA certificate not found. Run .\certs\generate.ps1 first." -ForegroundColor Red
    exit 1
}

$Cert = "$Dir\$ServerCloudId.crt"
$Key = "$Dir\$ServerCloudId.key"

Write-Host "==> Generating AMQP client cert for agent '$ServerCloudId'"

& openssl genrsa -out "$Key" 2048 2>$null

Set-Content -Path "$Dir\$ServerCloudId.ext" -Value @"
extendedKeyUsage = clientAuth
"@

& openssl req -new -key "$Key" `
    -subj "/CN=$ServerCloudId" -out "$Dir\$ServerCloudId.csr"

& openssl x509 -req -in "$Dir\$ServerCloudId.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Cert" -days 825 -sha256 `
    -extfile "$Dir\$ServerCloudId.ext" 2>$null

Remove-Item "$Dir\$ServerCloudId.csr", "$Dir\$ServerCloudId.ext" -ErrorAction SilentlyContinue

Write-Host "  Cert: $Cert"
Write-Host "  Key:  $Key"
Write-Host ""
Write-Host "Use in agent config:"
Write-Host "  amqp:"
Write-Host "    cert: certs/$ServerCloudId.crt"
Write-Host "    key:  certs/$ServerCloudId.key"
