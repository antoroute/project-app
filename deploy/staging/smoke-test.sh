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

read_env_value() {
  local key=$1
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$env_file"
}

app_secret=$(read_env_value TC_APP_SECRET)
if [[ -z "$app_secret" ]]; then
  echo "TC_APP_SECRET is missing." >&2
  exit 65
fi

run_id=$(date -u +%Y%m%d%H%M%S)
email="tc-smoke-${run_id}@example.invalid"
username="smoke_${run_id}"
password=$(openssl rand -hex 16)
secondary_email="tc-smoke-secondary-${run_id}@example.invalid"
secondary_username="smoke_secondary_${run_id}"
secondary_password=$(openssl rand -hex 16)

assert_status() {
  local expected=$1
  local url=$2
  shift 2
  local status
  status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$@" "$url")
  if [[ "$status" != "$expected" ]]; then
    echo "Unexpected HTTP status for $url: expected $expected, got $status" >&2
    exit 1
  fi
}

assert_status 200 "$base_url/healthz"
assert_status 200 "$base_url/health/auth"
assert_status 200 "$base_url/health/messaging"

register_payload=$(jq -nc \
  --arg email "$email" \
  --arg username "$username" \
  --arg password "$password" \
  '{email:$email,username:$username,password:$password}')

register_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -H 'content-type: application/json' \
  --data "$register_payload" \
  "$base_url/auth/register")
if [[ "$register_status" != "201" ]]; then
  echo "Registration smoke test failed with HTTP $register_status." >&2
  exit 1
fi

login_payload=$(jq -nc --arg email "$email" --arg password "$password" '{email:$email,password:$password}')
login_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  --data "$login_payload" \
  "$base_url/auth/login")
access_token=$(jq -er '.access' <<<"$login_response")
refresh_token=$(jq -er '.refresh' <<<"$login_response")
authenticated_user_id=$(jq -er '.user.id' <<<"$login_response")

secondary_register_payload=$(jq -nc \
  --arg email "$secondary_email" \
  --arg username "$secondary_username" \
  --arg password "$secondary_password" \
  '{email:$email,username:$username,password:$password}')
secondary_register_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  --data "$secondary_register_payload" \
  "$base_url/auth/register")
secondary_user_id=$(jq -er '.id' <<<"$secondary_register_response")

assert_status 401 "$base_url/auth/refresh" \
  -X POST \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret"

assert_status 401 "$base_url/auth/me" \
  -H "authorization: Bearer $refresh_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

assert_status 401 "$base_url/api/groups" \
  -H "authorization: Bearer $refresh_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

refresh_response=$(curl --silent --show-error \
  -X POST \
  -H "authorization: Bearer $refresh_token" \
  -H "x-app-secret: $app_secret" \
  "$base_url/auth/refresh")
refreshed_access_token=$(jq -er '.access' <<<"$refresh_response")

assert_status 200 "$base_url/auth/me" \
  -H "authorization: Bearer $refreshed_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

assert_status 403 "$base_url/api/groups" \
  -H "authorization: Bearer $access_token" \
  -H 'x-app-secret: deliberately-invalid' \
  -H 'x-client-version: 2.0.0'

group_payload=$(jq -nc --arg name "Smoke $run_id" '{name:$name}')
group_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$group_payload" \
  "$base_url/api/groups")
group_id=$(jq -er '.groupId | select(type == "string")' <<<"$group_response")

# L'identité de l'expéditeur fait partie de l'enveloppe signée, mais ne fait
# jamais autorité : le serveur doit refuser B lorsque le token appartient à A.
forged_message_payload=$(jq -nc \
  --arg group_id "$group_id" \
  --arg conv_id "$(cat /proc/sys/kernel/random/uuid)" \
  --arg message_id "$(cat /proc/sys/kernel/random/uuid)" \
  --arg sender_id "$secondary_user_id" \
  --arg recipient_id "$authenticated_user_id" \
  --argjson sent_at "$(date +%s)" \
  '{
    v: 2,
    alg: {kem:"X25519",kdf:"HKDF-SHA256",aead:"AES-256-GCM",sig:"Ed25519"},
    groupId:$group_id,
    convId:$conv_id,
    messageId:$message_id,
    sentAt:$sent_at,
    sender:{userId:$sender_id,deviceId:"forged-device",eph_pub:"AA==",key_version:1},
    recipients:[{userId:$recipient_id,deviceId:"recipient-device",wrap:"AA==",nonce:"AA=="}],
    iv:"AA==",ciphertext:"AA==",sig:"AA==",salt:"AA=="
  }')
assert_status 403 "$base_url/api/messages" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$forged_message_payload"

groups_response=$(curl --silent --show-error \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/groups")
jq -e 'type == "array" and length >= 1' >/dev/null <<<"$groups_response"

socket_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  "$base_url/socket/?EIO=4&transport=polling")
if [[ "$socket_status" != "200" ]]; then
  echo "Socket.IO handshake smoke test failed with HTTP $socket_status." >&2
  exit 1
fi

assert_status 401 "$base_url/auth/logout" \
  -X POST \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret"

assert_status 200 "$base_url/auth/logout" \
  -X POST \
  -H "authorization: Bearer $refresh_token" \
  -H "x-app-secret: $app_secret"

assert_status 401 "$base_url/auth/refresh" \
  -X POST \
  -H "authorization: Bearer $refresh_token" \
  -H "x-app-secret: $app_secret"

unset password secondary_password access_token refreshed_access_token refresh_token
echo "Smoke tests passed: health, login, strict access/refresh separation, refresh revocation, forged sender rejection, app-secret rejection, group write/read and Socket.IO handshake."
