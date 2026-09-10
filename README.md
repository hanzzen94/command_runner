# command_runner

A task execution system with a central server and pull-based agents, using
LavinMQ as the message broker and PostgreSQL for result persistence.

## Architecture

```mermaid
flowchart TB
    Submitter["Task Submitter<br/>(ci-bot, etc.)"]

    subgraph Server["Central Server"]
        direction TB
        API["Crystal HTTP API<br/>POST /tasks · GET /results"]
        MQ["LavinMQ (AMQP)<br/>tasks.{agent} queues | results queue"]
        DB[("PostgreSQL<br/>tasks · task_results")]
        API -->|"publish task"| MQ
        MQ -->|"consume result"| API
        API -->|"store task + result"| DB
    end

    Submitter -->|"mTLS"| API

    AgentA["Agent (node A)<br/>poll tasks.A · execute · publish"]
    AgentB["Agent (node B)<br/>poll tasks.B · execute · publish"]

    MQ -->|"AMQPS (mTLS)"| AgentA
    MQ -->|"AMQPS (mTLS)"| AgentB
    AgentA -->|"publish result"| MQ
    AgentB -->|"publish result"| MQ
```

- **Central server** (`central_server` binary): mTLS-secured HTTP API that
  accepts task submissions and publishes them to a per-agent LavinMQ queue
  (`tasks.{server_cloud_id}`). Consumes results from a shared `results` queue
  and stores tasks and results in PostgreSQL.
- **Agent** (`command_runner` binary): Polls its dedicated `tasks.{server_cloud_id}`
  queue every N seconds, executes the requested workload using local
  definitions, and publishes the result to the `results` queue.
- **LavinMQ**: AMQP 0-9-1 message broker. Tasks are routed to per-agent queues
  so each agent only receives tasks addressed to it. AMQP connections are
  secured with mutual TLS — each agent and the server present a client
  certificate signed by the shared CA.
- **PostgreSQL**: Stores submitted tasks and their results. The server runs
  automatic migrations on startup.

## Quick start

### Option A — Docker Compose (all services)

The fastest way to get everything running:

```sh
./scripts/dev-up.sh
```

This generates dev certs (including per-agent AMQP mTLS certs), creates
per-agent LavinMQ users with unique passwords, builds the Docker images,
and starts LavinMQ, PostgreSQL, the central server, and one agent. When done:

```sh
./scripts/dev-down.sh
```

### Option B — Manual setup

#### 1. Start LavinMQ and PostgreSQL

```sh
docker compose up -d lavinmq postgres
```

Services will be available on:
- LavinMQ AMQP: `localhost:5672` (plaintext) and `localhost:5671` (TLS/mTLS)
- LavinMQ Management UI: `http://localhost:15672` (guest/guest, loopback only)
- PostgreSQL: `localhost:5432`

#### 2. Generate dev certs

```sh
./certs/generate.sh              # CA, HTTP server/client, AMQP server, LavinMQ
./certs/generate-agent.sh 550e8400-e29b-41d4-a716-446655440000   # Per-agent AMQP mTLS cert
```

#### 3. Create LavinMQ users

```sh
./scripts/setup-lavinmq-users.sh 550e8400-e29b-41d4-a716-446655440000
```

This creates the `amqp-server` and `550e8400-e29b-41d4-a716-446655440000` LavinMQ users with unique
random passwords and restrictive permissions. The script prints `amqps://`
URLs with credentials to stdout — use these in the config files below.

#### 4. Copy and edit configs

```sh
cp config.agent.example.yml config.agent.yml
cp config.server.example.yml config.server.yml
```

Paste the generated `amqps://` URLs into the `amqp.url` fields.

#### 5. Build both binaries

```sh
crystal build src/agent/main.cr -o bin/command_runner
crystal build src/server/main.cr -o bin/central_server
```

#### 6. Start the central server

```sh
./bin/central_server --config config.server.yml
```

#### 7. Start an agent

```sh
./bin/command_runner --config config.agent.yml
```

#### 8. Submit a task

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     -X POST https://localhost:8443/tasks \
     -H 'Content-Type: application/json' \
     -d '{"server_cloud_id":"550e8400-e29b-41d4-a716-446655440000","customer_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","workload":"echo","params":{"message":"hello"}}'
```

Response (HTTP 201):
```json
{"task_id":"...","status":"queued","customer_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890"}
```

#### 9. Check results

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     "https://localhost:8443/results?limit=50&offset=0"
```

## API

All endpoints require a client certificate signed by the configured CA.

| Method | Path                  | Description                          |
|--------|-----------------------|--------------------------------------|
| POST   | `/tasks`              | Submit a task for execution          |
| GET    | `/results`            | List recent results (`limit`, `offset`, `customer_id` query params) |
| GET    | `/results/:task_id`   | Get a specific result                |
| GET    | `/health`             | Health check                         |

### Submit a task

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     -X POST https://localhost:8443/tasks \
     -H 'Content-Type: application/json' \
     -d '{"server_cloud_id":"550e8400-e29b-41d4-a716-446655440000","customer_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","workload":"chef_client","params":{"recipe":"cookbook::default"}}'
```

The request body must include:

| Field              | Type                    | Description                                      |
|--------------------|-------------------------|--------------------------------------------------|
| `server_cloud_id`  | string (GUID)           | Target agent (routes to `tasks.{server_cloud_id}` queue) |
| `customer_id`      | string (GUID)           | Customer GUID for tracking/auditing              |
| `workload`         | string                  | Must match a workload defined in the agent's config |
| `params`           | object (string→string)  | Parameters for the workload                       |

The central server does not know what workloads exist — it simply forwards
the task to the queue for the specified agent.

### List results

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
      "https://localhost:8443/results?limit=100&offset=0"
```

Returns an array of `TaskResult` objects, most recent first. Without query
params, returns up to `results_limit` results (from server config).

Filter by customer_id:

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     "https://localhost:8443/results?customer_id=a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

## Security

- **mTLS enforced on central server**: only clients presenting a certificate
  signed by the trusted CA can submit tasks.
- **mTLS enforced on AMQP broker**: both the central server and each agent
  present a client certificate when connecting to LavinMQ. The broker
  rejects any connection without a CA-signed cert. Each agent has its own
  keypair (`certs/{server_cloud_id}.crt`/`.key`) with `CN={server_cloud_id}`.
- **Per-agent LavinMQ users**: each agent and the server authenticate to
  LavinMQ with a unique username (matching the cert CN) and a unique random
  password. This provides a second authentication factor alongside mTLS —
  the certificate proves identity and the password adds a shared secret.
  Permissions are restrictive: each agent can only access its own task queue
  and the shared results queue. The default `guest` user is restricted to
  loopback connections only.
- **Client allowlist**: the server only accepts tasks from CNs listed in
  `allowed_clients`.
- **Per-workload client restrictions**: each workload can optionally restrict
  which client CNs may request it via `allowed_clients`.
- **Named workloads only**: agents only execute commands pre-registered in
  their local config. No arbitrary command execution.
- **No shell**: all commands run via `exec` (no `sh -c`), eliminating injection.
- **Param validation**: required params, regex patterns, and unknown-param
  rejection.
- **Audit logging**: every task submission and result is logged.
- **Rate limiting**: per-client token bucket on the central server.
- **Output caps**: stdout/stderr truncated at configurable size.
- **Timeouts**: per-workload kill on timeout.

## Configuration

### Agent (`config.agent.yml`)

```yaml
server_cloud_id: "550e8400-e29b-41d4-a716-446655440000"

amqp:
  url: "amqps://550e8400-e29b-41d4-a716-446655440000:<password>@localhost:5671"
  # Username must match server_cloud_id (and cert CN). Password is generated by
  # ./scripts/setup-lavinmq-users.sh
  task_queue: "tasks"
  result_queue: "results"
  poll_interval: 5
  ca: certs/ca.crt              # CA cert to verify the broker
  cert: certs/550e8400-e29b-41d4-a716-446655440000.crt      # per-agent client cert (CN must match server_cloud_id)
  key: certs/550e8400-e29b-41d4-a716-446655440000.key       # per-agent private key

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

  - name: chef_client
    command: ["sudo", "chef-client", "-o", "recipe[{recipe}]"]
    params:
      - name: recipe
        required: true
        pattern: "^[a-zA-Z0-9_:-]+$"
    allowed_clients:
      - ci-bot
    timeout: 1800
    cwd: /var/chef
```

#### Workload fields

| Field             | Type            | Description                                              |
|-------------------|-----------------|----------------------------------------------------------|
| `name`            | string          | Unique workload identifier                               |
| `command`         | array of string | Command template; `{param}` placeholders are substituted |
| `params`          | array           | Parameter definitions (name, required, pattern)          |
| `allowed_clients` | array of string | Optional CN allowlist for this workload (empty = all)    |
| `timeout`         | int             | Per-workload timeout in seconds (default: `default_timeout`) |
| `cwd`             | string          | Optional working directory for the command               |

### Central server (`config.server.yml`)

```yaml
listen: "0.0.0.0:8443"

tls:
  cert: certs/server.crt
  key: certs/server.key
  ca: certs/ca.crt

amqp:
  url: "amqps://amqp-server:<password>@localhost:5671"
  # Password is generated by ./scripts/setup-lavinmq-users.sh
  task_queue: "tasks"
  result_queue: "results"
  ca: certs/ca.crt              # CA cert to verify the broker
  cert: certs/amqp-server.crt   # server's AMQP client cert
  key: certs/amqp-server.key    # server's AMQP private key

allowed_clients:
  - ci-bot

limits:
  request_body_bytes: 65536
  rate_per_minute: 60

results:
  url: "postgres://command_runner:secretpass@localhost:5432/command_runner"
  results_limit: 100
```

## Project structure

```
src/
  command_runner.cr       # Shared: module, error types, log
  config.cr               # Shared: AgentConfig, ServerConfig, AmqpConfig, etc.
  tls.cr                  # Shared: TLS context builders (server + client mTLS)
  task.cr                 # Shared: Task, TaskResult, TaskReceipt structs
  amqp.cr                 # Shared: AmqpClient wrapper (per-agent queue routing)
  agent/
    main.cr               # Agent entry point
    agent.cr              # Polling loop: pull tasks, execute, publish results
    executor.cr           # Process execution with timeout + output caps
    workloads.cr          # Workload registry: param validation, command building
  server/
    main.cr               # Server entry point
    central_server.cr     # HTTP server, AMQP publisher, results consumer, Database
    router.cr             # HTTP routes: POST /tasks, GET /results
    auth.cr               # mTLS client cert extraction + CN authorization
    middleware.cr         # Error handling, request size, audit log, rate limit
spec/                     # Test suite (crystal spec)
scripts/
  dev-up.sh               # Generate certs, create LavinMQ users, build, start all Docker services
  dev-down.sh             # Stop Docker containers
  setup-lavinmq-users.sh  # Create per-agent LavinMQ users with unique passwords
  stress-test.sh          # Launch N agents and submit tasks, report throughput
certs/
  generate.sh             # Generate CA, HTTP server/client, AMQP server, LavinMQ certs
  generate-agent.sh       # Generate per-agent AMQP mTLS cert (CN=<server_cloud_id>)
```

## Scripts

| Script             | Description                                                        |
|--------------------|--------------------------------------------------------------------|
| `dev-up.sh`        | Generates dev certs, creates LavinMQ users, builds images, starts all services via Docker |
| `dev-down.sh`      | Stops Docker containers (pass `-v` to also remove data volumes)    |
| `setup-lavinmq-users.sh` | Creates per-agent and server LavinMQ users with unique passwords and restrictive permissions. Usage: `./scripts/setup-lavinmq-users.sh [--agents-only] <server_cloud_id> [<server_cloud_id> ...]` |
| `stress-test.sh`   | Launches N local agents (default 100), submits tasks, and reports throughput and success rate. Usage: `./scripts/stress-test.sh [num_agents] [tasks_per_agent]` |
| `certs/generate.sh`        | Generates CA, HTTP server/client, AMQP server, and LavinMQ TLS certs |
| `certs/generate-agent.sh`  | Generates a per-agent AMQP mTLS client cert. Usage: `./certs/generate-agent.sh <server_cloud_id> [--create-user]` |

## systemd services

### Central server

```sh
sudo tee /etc/systemd/system/central_server.service > /dev/null <<'UNIT'
[Unit]
Description=Command Runner Central Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=command_runner
Group=command_runner
WorkingDirectory=/opt/command_runner
ExecStart=/opt/command_runner/central_server --config /opt/command_runner/config.server.yml
Restart=on-failure
RestartSec=5

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
RestrictRealtime=true
RestrictSUIDSGID=true

StandardOutput=journal
StandardError=journal
SyslogIdentifier=central_server

[Install]
WantedBy=multi-user.target
UNIT
```

### Agent

```sh
sudo tee /etc/systemd/system/command_runner.service > /dev/null <<'UNIT'
[Unit]
Description=Command Runner Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=command_runner
Group=command_runner
WorkingDirectory=/opt/command_runner
ExecStart=/opt/command_runner/command_runner --config /opt/command_runner/config.agent.yml
Restart=on-failure
RestartSec=5

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
RestrictRealtime=true
RestrictSUIDSGID=true

StandardOutput=journal
StandardError=journal
SyslogIdentifier=command_runner

[Install]
WantedBy=multi-user.target
UNIT
```
