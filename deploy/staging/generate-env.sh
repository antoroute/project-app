#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 ENV_FILE GIT_COMMIT IMAGE_TAG POSTGRES_IMAGE_DIGEST NGINX_IMAGE_DIGEST" >&2
  exit 64
fi

env_file=$1
git_commit=$2
image_tag=$3
postgres_image=$4
nginx_image=$5

if [[ -e "$env_file" ]]; then
  echo "Refusing to overwrite existing environment file: $env_file" >&2
  exit 73
fi

if [[ ! "$git_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "GIT_COMMIT must be a full 40-character SHA." >&2
  exit 64
fi

if [[ "$postgres_image" != postgres@sha256:* ]]; then
  echo "PostgreSQL image must be pinned as postgres@sha256:..." >&2
  exit 64
fi

if [[ "$nginx_image" != nginx@sha256:* ]]; then
  echo "Nginx image must be pinned as nginx@sha256:..." >&2
  exit 64
fi

env_dir=$(dirname -- "$env_file")
install -d -m 0700 -- "$env_dir"
umask 077

db_password=$(openssl rand -hex 32)
jwt_secret=$(openssl rand -hex 48)
app_secret=$(openssl rand -hex 32)

{
  printf 'TC_GIT_COMMIT=%s\n' "$git_commit"
  printf 'TC_IMAGE_TAG=%s\n' "$image_tag"
  printf 'TC_POSTGRES_IMAGE=%s\n' "$postgres_image"
  printf 'TC_NGINX_IMAGE=%s\n' "$nginx_image"
  printf 'TC_DB_NAME=trust_circle_staging\n'
  printf 'TC_DB_USER=trust_circle_staging\n'
  printf 'TC_DB_PASSWORD=%s\n' "$db_password"
  printf 'TC_JWT_SECRET=%s\n' "$jwt_secret"
  printf 'TC_APP_SECRET=%s\n' "$app_secret"
  printf 'TC_STAGING_HTTP_PORT=18080\n'
} > "$env_file"

chmod 0600 -- "$env_file"
echo "Staging environment file created with mode 0600. Values were not printed."
