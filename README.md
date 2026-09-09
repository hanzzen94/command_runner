# command_runner

A small, secure HTTPS server that triggers predefined shell workloads on the host.
All connections require mutual TLS (mTLS) — only clients presenting a certificate
signed by your trusted CA can connect.

## Quick start

```sh
# 1. Generate dev CA + server + client certs
./certs/generate.sh

# 2. Copy and edit config
cp config.example.yml config.yml

# 3. Build and run
crystal build src/main.cr -o bin/command_runner
./bin/command_runner --config config.yml
```

## API

All endpoints require a client certificate signed by the configured CA.

| Method | Path                        | Description                          |
|--------|-----------------------------|--------------------------------------|
| GET    | `/workloads`                | List workloads the client may run    |
| POST   | `/workloads/:name/run`      | Execute a named workload             |

### Example

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     https://localhost:8443/workloads

curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     -X POST https://localhost:8443/workloads/echo/run \
     -H 'Content-Type: application/json' \
     -d '{"params":{"message":"hello"}}'
```

## Security

- **mTLS enforced**: server requires a client cert chaining to the trusted CA;
  connections without a valid client cert are rejected at the TLS handshake.
- **Named workloads only**: no arbitrary command execution; commands are
  pre-registered in config with validated parameters.
- **No shell**: all commands run via `exec` (no `sh -c`), eliminating injection.
- **Per-client authorization**: global allowlist + per-workload `allowed_clients`.
- **Audit logging**: every request is logged with client CN, workload, and result.
- **Rate limiting**: per-client token bucket (configurable).
- **Output caps**: stdout/stderr truncated at configurable size.
- **Timeouts**: per-workload kill on timeout.

## Configuration

See `config.example.yml` for all options.

## systemd service

Run `command_runner` as an unprivileged user. The service account needs read
access to the server cert/key and CA cert, and (if using the `chef_client`
workload) passwordless sudo for `chef-client`.

### 1. Install the binary and config

```sh
sudo install -d -o command_runner -g command_runner /opt/command_runner
sudo install -o command_runner -g command_runner bin/command_runner /opt/command_runner/
sudo install -o command_runner -g command_runner -m 640 config.yml /opt/command_runner/
sudo install -d -o command_runner -g command_runner /opt/command_runner/certs
sudo install -o command_runner -g command_runner -m 640 certs/server.crt certs/server.key certs/ca.crt /opt/command_runner/certs/
```

### 2. Grant sudo for chef-client (if needed)

```sh
echo 'command_runner ALL=(root) NOPASSWD: /usr/bin/chef-client' | sudo tee /etc/sudoers.d/command_runner
sudo chmod 440 /etc/sudoers.d/command_runner
sudo visudo -c  # validate syntax
```

### 3. Create the service unit

```sh
sudo tee /etc/systemd/system/command_runner.service > /dev/null <<'UNIT'
[Unit]
Description=Command Runner (mTLS workload server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=command_runner
Group=command_runner
WorkingDirectory=/opt/command_runner
ExecStart=/opt/command_runner/command_runner --config /opt/command_runner/config.yml
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictSUIDSGID=true

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=command_runner

[Install]
WantedBy=multi-user.target
UNIT
```

### 4. Enable and start

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now command_runner
sudo systemctl status command_runner
sudo journalctl -u command_runner -f
```

> **Note**: `ProtectSystem=strict` makes the filesystem read-only except for
> paths listed in `ReadWritePaths`. If your workloads need to write to other
> directories (e.g. `/var/chef`), add them to `ReadWritePaths`.
