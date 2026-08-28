#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ENV_FILE [BASE_URL]" >&2
  exit 64
fi

env_file=$1
base_url=${2:-http://127.0.0.1:18080}
if [[ ! -r "$env_file" ]]; then
  echo "Environment file is not readable: $env_file" >&2
  exit 66
fi

assert_status() {
  local expected=$1
  local url=$2
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$url")
  if [[ "$status" != "$expected" ]]; then
    echo "Unexpected HTTP status for $url: expected $expected, got $status" >&2
    exit 1
  fi
}

assert_status 200 "$base_url/healthz"
assert_status 200 "$base_url/health/auth"
assert_status 200 "$base_url/health/messaging"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
docker compose \
  --project-name trust-circle-staging \
  --env-file "$env_file" \
  -f "$script_dir/compose.yml" \
  exec -T \
  -e TC_DEVICE_TRUST_SMOKE_BASE_URL=http://gateway:8080 \
  messaging node dist/tools/deviceTrustStagingSmoke.js

echo "Smoke tests passed: health and TC-106 lot D end-to-end security transitions."
