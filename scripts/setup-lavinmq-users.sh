#!/usr/bin/env bash
set -euo pipefail

# Creates per-agent and server LavinMQ users with unique random passwords
# and restrictive permissions. Each agent's LavinMQ username matches its
# certificate CN (server_cloud_id), providing a second authentication factor
# alongside mTLS.
#
# The guest user is left in place (loopback-only) for management UI access.
#
# Usage: ./scripts/setup-lavinmq-users.sh [--agents-only] <server_cloud_id> [<server_cloud_id> ...]
# Example: ./scripts/setup-lavinmq-users.sh 550e8400-e29b-41d4-a716-446655440000
# Example: ./scripts/setup-lavinmq-users.sh --agents-only 6ba7b810-9dad-11d1-80b4-00c04fd430c8
#
# Without --agents-only, creates the amqp-server user plus one user per agent.
# With --agents-only, skips the amqp-server user (use when adding agents later).
#
# Output: Prints amqps:// URLs with credentials to stdout, one per line.
#         Without --agents-only, the first line is the server URL;
#         subsequent lines are per-agent.
#         Exits non-zero if LavinMQ is unreachable or user creation fails.
#
# Environment variables:
#   LAVINMQ_HOST   — management API host (default: localhost)
#   LAVINMQ_PORT   — management API port (default: 15672)
#   LAVINMQ_USER   — admin username for API calls (default: guest)
#   LAVINMQ_PASS   — admin password for API calls (default: guest)
#   LAVINMQ_AMQP_HOST — AMQP host for generated URLs (default: same as LAVINMQ_HOST)
#   LAVINMQ_AMQP_PORT — AMQPS port for generated URLs (default: 5671)

LAVINMQ_HOST="${LAVINMQ_HOST:-localhost}"
LAVINMQ_PORT="${LAVINMQ_PORT:-15672}"
LAVINMQ_USER="${LAVINMQ_USER:-guest}"
LAVINMQ_PASS="${LAVINMQ_PASS:-guest}"
LAVINMQ_AMQP_HOST="${LAVINMQ_AMQP_HOST:-$LAVINMQ_HOST}"
LAVINMQ_AMQP_PORT="${LAVINMQ_AMQP_PORT:-5671}"

API_URL="http://${LAVINMQ_HOST}:${LAVINMQ_PORT}/api"
VHOST="%2F"

gen_password() {
  openssl rand -base64 32 | tr -d '\n/+=' | head -c 32
}

url_encode() {
  # RFC 3986 percent-encoding for password in URL
  local s="$1"
  local encoded=""
  local i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:$i:1}"
    case "$ch" in
      [a-zA-Z0-9._~-]) encoded+="$ch" ;;
      *) encoded+=$(printf '%%%02X' "'$ch") ;;
    esac
  done
  printf '%s' "$encoded"
}

wait_for_lavinmq() {
  echo "==> Waiting for LavinMQ management API at ${LAVINMQ_HOST}:${LAVINMQ_PORT}..." >&2
  for i in $(seq 1 30); do
    if curl -sf -u "${LAVINMQ_USER}:${LAVINMQ_PASS}" \
         "${API_URL}/overview" >/dev/null 2>&1; then
      echo "    ready" >&2
      return 0
    fi
    sleep 1
  done
  echo "Error: LavinMQ management API unreachable after 30s" >&2
  return 1
}

create_user() {
  local username="$1"
  local password="$2"
  local tags="${3:-}"

  local json_password json_tags
  json_password="$(json_escape "$password")"
  json_tags="$(json_escape "$tags")"

  curl -sf -u "${LAVINMQ_USER}:${LAVINMQ_PASS}" \
    -X PUT "${API_URL}/users/${username}" \
    -H 'Content-Type: application/json' \
    -d "{\"password\":\"${json_password}\",\"tags\":\"${json_tags}\"}" >/dev/null
}

json_escape() {
  # Escape backslashes and double quotes for JSON string values
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

set_permissions() {
  local username="$1"
  local configure="$2"
  local write="$3"
  local read="$4"

  local json_configure json_write json_read
  json_configure="$(json_escape "$configure")"
  json_write="$(json_escape "$write")"
  json_read="$(json_escape "$read")"

  curl -sf -u "${LAVINMQ_USER}:${LAVINMQ_PASS}" \
    -X PUT "${API_URL}/permissions/${VHOST}/${username}" \
    -H 'Content-Type: application/json' \
    -d "{\"configure\":\"${json_configure}\",\"write\":\"${json_write}\",\"read\":\"${json_read}\"}" >/dev/null
}

setup_server_user() {
  local password
  password="$(gen_password)"

  echo "==> Creating LavinMQ user: amqp-server" >&2

  create_user "amqp-server" "$password" ""

  # Server needs to:
  #   - declare any tasks.* queue and the results queue (configure)
  #   - publish to the default exchange to route to per-agent task queues (write)
  #   - consume from the results queue (read)
  set_permissions "amqp-server" \
    "^tasks\\..*$|^results$" \
    ".*" \
    "^results$"

  local encoded_pass
  encoded_pass="$(url_encode "$password")"
  printf 'amqps://amqp-server:%s@%s:%s\n' "$encoded_pass" "$LAVINMQ_AMQP_HOST" "$LAVINMQ_AMQP_PORT"
}

setup_agent_user() {
  local server_cloud_id="$1"
  local password
  password="$(gen_password)"

  echo "==> Creating LavinMQ user: ${server_cloud_id}" >&2

  create_user "$server_cloud_id" "$password" ""

  # Agent needs to:
  #   - declare its own tasks.{server_cloud_id} queue and the results queue (configure)
  #   - basic_get from its own tasks.{server_cloud_id} queue (read)
  #   - publish results to the default exchange (write)
  local queue_pattern
  queue_pattern="^tasks\\.${server_cloud_id}$|^results$"

  set_permissions "$server_cloud_id" \
    "$queue_pattern" \
    ".*" \
    "^tasks\\.${server_cloud_id}$"

  local encoded_pass
  encoded_pass="$(url_encode "$password")"
  printf 'amqps://%s:%s@%s:%s\n' "$server_cloud_id" "$encoded_pass" "$LAVINMQ_AMQP_HOST" "$LAVINMQ_AMQP_PORT"
}

main() {
  local agents_only=false

  if [ $# -lt 1 ]; then
    echo "Usage: $0 [--agents-only] <server_cloud_id> [<server_cloud_id> ...]" >&2
    echo "  Creates the amqp-server user (unless --agents-only) plus one user per server_cloud_id." >&2
    echo "" >&2
    echo "  Output: amqps:// URLs with credentials, one per line." >&2
    echo "  Without --agents-only, the first line is the server URL;" >&2
    echo "  subsequent lines are per-agent." >&2
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --agents-only) agents_only=true ;;
      --*) echo "Unknown option: $1" >&2; exit 1 ;;
      *) break ;;
    esac
    shift
  done

  if [ $# -lt 1 ]; then
    echo "Error: at least one server_cloud_id is required" >&2
    exit 1
  fi

  wait_for_lavinmq

  if [ "$agents_only" = false ]; then
    setup_server_user
  fi

  for server_cloud_id in "$@"; do
    setup_agent_user "$server_cloud_id"
  done

  echo "" >&2
  echo "==> Done. Users created with restrictive permissions." >&2
  echo "    The 'guest' user remains for management UI (loopback only)." >&2
}

main "$@"
