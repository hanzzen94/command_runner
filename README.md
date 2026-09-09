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

    MQ -->|"AMQP (TLS)"| AgentA
    MQ -->|"AMQP (TLS)"| AgentB
    AgentA -->|"publish result"| MQ
    AgentB -->|"publish result"| MQ
```

- **Central server** (`central_server` binary): mTLS-secured HTTP API that
  accepts task submissions and publishes them to a per-agent LavinMQ queue
  (`tasks.{agent_id}`). Consumes results from a shared `results` queue and
  stores tasks and results in PostgreSQL.
- **Agent** (`command_runner` binary): Polls its dedicated `tasks.{agent_id}`
  queue every N seconds, executes the requested workload using local
  definitions, and publishes the result to the `results` queue.
- **LavinMQ**: AMQP 0-9-1 message broker. Tasks are routed to per-agent queues
  so each agent only receives tasks addressed to it.
- **PostgreSQL**: Stores submitted tasks and their results. The server runs
  automatic migrations on startup.

## Quick start

### Option A — Docker Compose (all services)

The fastest way to get everything running:

```sh
./scripts/dev-up.sh
```

This generates dev certs, builds the Docker images, and starts LavinMQ,
PostgreSQL, the central server, and one agent. When done:

```sh
./scripts/dev-down.sh
```

### Option B — Manual setup

#### 1. Start LavinMQ and PostgreSQL

```sh
docker compose up -d lavinmq postgres
```

Services will be available on:
- LavinMQ AMQP: `localhost:5672`
- LavinMQ Management UI: `http://localhost:15672` (guest/guest)
- PostgreSQL: `localhost:5432`

#### 2. Generate dev certs (for central server mTLS)

```sh
./certs/generate.sh
```

#### 3. Copy and edit configs

```sh
cp config.agent.example.yml config.agent.yml
cp config.server.example.yml config.server.yml
```

#### 4. Build both binaries

```sh
crystal build src/agent/main.cr -o bin/command_runner
crystal build src/server/main.cr -o bin/central_server
```

#### 5. Start the central server

```sh
./bin/central_server --config config.server.yml
```

#### 6. Start an agent

```sh
./bin/command_runner --config config.agent.yml
```

#### 7. Submit a task

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     -X POST https://localhost:8443/tasks \
     -H 'Content-Type: application/json' \
     -d '{"agent_id":"server-01","workload":"echo","params":{"message":"hello"}}'
```

Response (HTTP 201):
```json
{"task_id":"...","status":"queued"}
```

#### 8. Check results

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
| GET    | `/results`            | List recent results (`limit`, `offset` query params) |
| GET    | `/results/:task_id`   | Get a specific result                |
| GET    | `/health`             | Health check                         |

### Submit a task

```sh
curl --cacert certs/ca.crt \
     --cert certs/client.crt \
     --key certs/client.key \
     -X POST https://localhost:8443/tasks \
     -H 'Content-Type: application/json' \
     -d '{"agent_id":"server-01","workload":"chef_client","params":{"recipe":"cookbook::default"}}'
```

The request body must include:

| Field      | Type                    | Description                                      |
|------------|-------------------------|--------------------------------------------------|
| `agent_id` | string                  | Target agent (routes to `tasks.{agent_id}` queue) |
| `workload` | string                  | Must match a workload defined in the agent's config |
| `params`   | object (string→string)  | Parameters for the workload                       |

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

## Security

- **mTLS enforced on central server**: only clients presenting a certificate
  signed by the trusted CA can submit tasks.
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
agent_id: "server-01"

amqp:
  url: "amqp://agent:secretpass@localhost:5672"
  task_queue: "tasks"
  result_queue: "results"
  poll_interval: 5
  ca: certs/ca.crt  # for amqps:// TLS verification

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
  url: "amqp://server:secretpass@localhost:5672"
  task_queue: "tasks"
  result_queue: "results"

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
  tls.cr                  # Shared: TLS context builders (server + client)
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
  dev-up.sh               # Generate certs, build, and start all Docker services
  dev-down.sh             # Stop Docker containers
  stress-test.sh          # Launch N agents and submit tasks, report throughput
```

## Scripts

| Script             | Description                                                        |
|--------------------|--------------------------------------------------------------------|
| `dev-up.sh`        | Generates dev certs, builds images, starts all services via Docker |
| `dev-down.sh`      | Stops Docker containers (pass `-v` to also remove data volumes)    |
| `stress-test.sh`   | Launches N local agents (default 100), submits tasks, and reports throughput and success rate. Usage: `./scripts/stress-test.sh [num_agents] [tasks_per_agent]` |

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
