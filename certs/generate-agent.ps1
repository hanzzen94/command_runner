# Generates a per-agent AMQP client certificate signed by the dev CA.
# The certificate CN matches the agent_id, enabling per-agent identity
# via mTLS when connecting to LavinMQ.
#
# Usage: .\certs\generate-agent.ps1 <agent_id>
# Example: .\certs\generate-agent.ps1 agent-01

param(
    [Parameter(Mandatory=$true)]
    [string]$AgentId
)

$ErrorActionPreference = "Stop"
$Dir = $PSScriptRoot

if (-not (Test-Path "$Dir\ca.key") -or -not (Test-Path "$Dir\ca.crt")) {
    Write-Host "Error: CA certificate not found. Run .\certs\generate.ps1 first." -ForegroundColor Red
    exit 1
}

$Cert = "$Dir\$AgentId.crt"
$Key = "$Dir\$AgentId.key"

Write-Host "==> Generating AMQP client cert for agent '$AgentId'"

& openssl genrsa -out "$Key" 2048 2>$null

Set-Content -Path "$Dir\$AgentId.ext" -Value @"
extendedKeyUsage = clientAuth
"@

& openssl req -new -key "$Key" `
    -subj "/CN=$AgentId" -out "$Dir\$AgentId.csr"

& openssl x509 -req -in "$Dir\$AgentId.csr" -CA "$Dir\ca.crt" -CAkey "$Dir\ca.key" `
    -CAcreateserial -out "$Cert" -days 825 -sha256 `
    -extfile "$Dir\$AgentId.ext" 2>$null

Remove-Item "$Dir\$AgentId.csr", "$Dir\$AgentId.ext" -ErrorAction SilentlyContinue

Write-Host "  Cert: $Cert"
Write-Host "  Key:  $Key"
Write-Host ""
Write-Host "Use in agent config:"
Write-Host "  amqp:"
Write-Host "    cert: certs/$AgentId.crt"
Write-Host "    key:  certs/$AgentId.key"
