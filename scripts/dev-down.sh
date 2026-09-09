#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose down "$@"

echo "==> Containers stopped"
echo "    Use './scripts/dev-down.sh -v' to also remove the LavinMQ data volume."
