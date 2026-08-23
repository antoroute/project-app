#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /absolute/path/to/staging.env" >&2
  exit 64
fi

env_file=$1
if [[ "$env_file" != /* || ! -r "$env_file" ]]; then
  echo "The staging environment file must be an absolute readable path." >&2
  exit 66
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compose_file="$repo_root/deploy/staging/compose.yml"

docker compose \
  --project-name trust-circle-staging \
  --env-file "$env_file" \
  -f "$compose_file" config --quiet

docker compose \
  --project-name trust-circle-staging \
  --env-file "$env_file" \
  -f "$compose_file" up -d --build
