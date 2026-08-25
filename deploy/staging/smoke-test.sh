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
tertiary_email="tc-smoke-tertiary-${run_id}@example.invalid"
tertiary_username="smoke_tertiary_${run_id}"
tertiary_password=$(openssl rand -hex 16)
smoke_tmp_dir=$(mktemp -d)

cleanup() {
  unset password secondary_password tertiary_password access_token \
    secondary_access_token tertiary_access_token refreshed_access_token \
    refresh_token
  if [[ -d "$smoke_tmp_dir" ]]; then
    find "$smoke_tmp_dir" -depth -delete
  fi
}
trap cleanup EXIT

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

secondary_login_payload=$(jq -nc \
  --arg email "$secondary_email" \
  --arg password "$secondary_password" \
  '{email:$email,password:$password}')
secondary_login_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  --data "$secondary_login_payload" \
  "$base_url/auth/login")
secondary_access_token=$(jq -er '.access' <<<"$secondary_login_response")

tertiary_register_payload=$(jq -nc \
  --arg email "$tertiary_email" \
  --arg username "$tertiary_username" \
  --arg password "$tertiary_password" \
  '{email:$email,username:$username,password:$password}')
curl --silent --show-error --fail \
  -H 'content-type: application/json' \
  --data "$tertiary_register_payload" \
  "$base_url/auth/register" >/dev/null

tertiary_login_payload=$(jq -nc \
  --arg email "$tertiary_email" \
  --arg password "$tertiary_password" \
  '{email:$email,password:$password}')
tertiary_login_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  --data "$tertiary_login_payload" \
  "$base_url/auth/login")
tertiary_access_token=$(jq -er '.access' <<<"$tertiary_login_response")

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

# TC-104 : un utilisateur extérieur ne lit pas l'annuaire de clés et ne
# peut pas être injecté dans une conversation avant son adhésion.
assert_status 403 "$base_url/api/keys/group/$group_id" \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

conversations_before=$(curl --silent --show-error \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/conversations")
conversation_count_before=$(jq -er 'length' <<<"$conversations_before")
forbidden_conversation_payload=$(jq -nc \
  --arg group_id "$group_id" \
  --arg outsider_id "$secondary_user_id" \
  '{groupId:$group_id,type:"private",memberIds:[$outsider_id]}')
assert_status 403 "$base_url/api/conversations" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$forbidden_conversation_payload"
conversations_after=$(curl --silent --show-error \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/conversations")
conversation_count_after=$(jq -er 'length' <<<"$conversations_after")
if [[ "$conversation_count_before" != "$conversation_count_after" ]]; then
  echo "Denied conversation creation changed persistent state." >&2
  exit 1
fi

# Le propriétaire gère l'adhésion, le membre simple ne voit pas les
# demandes, puis le rôle admin reçoit uniquement les permissions prévues.
device_key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
join_payload=$(jq -nc \
  --arg device_id "smoke-device-$run_id" \
  --arg key "$device_key" \
  '{deviceId:$device_id,deviceSigPubKey:$key,deviceKemPubKey:$key}')
join_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$join_payload" \
  "$base_url/api/groups/$group_id/join-requests")
join_request_id=$(jq -er '.requestId' <<<"$join_response")

owner_requests=$(curl --silent --show-error \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/groups/$group_id/join-requests")
jq -e --arg request_id "$join_request_id" \
  'any(.[]; .id == $request_id)' >/dev/null <<<"$owner_requests"

handle_payload='{"action":"accept"}'
assert_status 200 "$base_url/api/groups/$group_id/join-requests/$join_request_id/handle" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$handle_payload"

assert_status 403 "$base_url/api/groups/$group_id/join-requests" \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'
assert_status 403 "$base_url/api/groups/$group_id/join-requests/$join_request_id/vote" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data '{"vote":true}'
assert_status 200 "$base_url/api/keys/group/$group_id" \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

# TC-105 : le chemin nominal conversation/message exerce les requêtes
# verrouillées réelles, puis une course publication/révocation doit finir revoked.
owner_device_id="smoke-owner-device-$run_id"
owner_device_payload=$(jq -nc \
  --arg device_id "$owner_device_id" \
  --arg key "$device_key" \
  '{deviceId:$device_id,pk_sig:$key,pk_kem:$key,key_version:1}')
assert_status 201 "$base_url/api/keys/group/$group_id/devices" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$owner_device_payload"

conversation_payload=$(jq -nc \
  --arg group_id "$group_id" \
  --arg member_id "$secondary_user_id" \
  '{groupId:$group_id,type:"private",memberIds:[$member_id]}')
conversation_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$conversation_payload" \
  "$base_url/api/conversations")
conversation_id=$(jq -er '.id' <<<"$conversation_response")

assert_status 200 "$base_url/api/conversations/$conversation_id/read" \
  -X POST \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

message_id=$(cat /proc/sys/kernel/random/uuid)
message_payload=$(jq -nc \
  --arg group_id "$group_id" \
  --arg conv_id "$conversation_id" \
  --arg message_id "$message_id" \
  --arg sender_id "$authenticated_user_id" \
  --arg sender_device "$owner_device_id" \
  --arg recipient_id "$secondary_user_id" \
  --arg recipient_device "smoke-device-$run_id" \
  --argjson sent_at "$(date +%s)" \
  '{
    v:2,
    alg:{kem:"X25519",kdf:"HKDF-SHA256",aead:"AES-256-GCM",sig:"Ed25519"},
    groupId:$group_id,convId:$conv_id,messageId:$message_id,sentAt:$sent_at,
    sender:{userId:$sender_id,deviceId:$sender_device,eph_pub:"AA==",key_version:1},
    recipients:[{userId:$recipient_id,deviceId:$recipient_device,wrap:"AA==",nonce:"AA=="}],
    iv:"AA==",ciphertext:"AA==",sig:"AA==",salt:"AA=="
  }')
message_response=$(curl --silent --show-error \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$message_payload" \
  "$base_url/api/messages")
stored_message_id=$(jq -er '.id' <<<"$message_response")
messages_response=$(curl --silent --show-error \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/conversations/$conversation_id/messages")
jq -e --arg stored_id "$stored_message_id" \
  'any(.items[]; .id == $stored_id)' >/dev/null <<<"$messages_response"

curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$owner_device_payload" \
  "$base_url/api/keys/group/$group_id/devices" \
  >"$smoke_tmp_dir/key-publish.status" &
publish_pid=$!
curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -X DELETE \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/keys/group/$group_id/devices/$owner_device_id" \
  >"$smoke_tmp_dir/key-revoke.status" &
revoke_pid=$!
wait "$publish_pid"
wait "$revoke_pid"
publish_status=$(<"$smoke_tmp_dir/key-publish.status")
revoke_status=$(<"$smoke_tmp_dir/key-revoke.status")
if [[ "$revoke_status" != "200" || \
      ("$publish_status" != "201" && "$publish_status" != "403") ]]; then
  echo "Unexpected key race statuses: publish=$publish_status revoke=$revoke_status" >&2
  exit 1
fi
owner_devices=$(curl --silent --show-error \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/keys/group/$group_id/my-devices")
jq -e --arg device_id "$owner_device_id" \
  'any(.[]; .deviceId == $device_id and .status == "revoked")' \
  >/dev/null <<<"$owner_devices"
assert_status 403 "$base_url/api/keys/group/$group_id/devices" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$owner_device_payload"
assert_status 403 "$base_url/api/messages" \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$(jq --arg message_id "$(cat /proc/sys/kernel/random/uuid)" '.messageId=$message_id' <<<"$message_payload")"

role_payload='{"role":"admin"}'
role_response=$(curl --silent --show-error \
  -X PATCH \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$role_payload" \
  "$base_url/api/groups/$group_id/members/$secondary_user_id/role")
jq -e '.role == "admin"' >/dev/null <<<"$role_response"

assert_status 200 "$base_url/api/groups/$group_id/join-requests" \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0'

tertiary_join_payload=$(jq -nc \
  --arg device_id "smoke-tertiary-device-$run_id" \
  --arg key "$device_key" \
  '{deviceId:$device_id,deviceSigPubKey:$key,deviceKemPubKey:$key}')
curl --silent --show-error --output "$smoke_tmp_dir/join-a.body" --write-out '%{http_code}' \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $tertiary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$tertiary_join_payload" \
  "$base_url/api/groups/$group_id/join-requests" \
  >"$smoke_tmp_dir/join-a.status" &
join_a_pid=$!
curl --silent --show-error --output "$smoke_tmp_dir/join-b.body" --write-out '%{http_code}' \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $tertiary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data "$tertiary_join_payload" \
  "$base_url/api/groups/$group_id/join-requests" \
  >"$smoke_tmp_dir/join-b.status" &
join_b_pid=$!
wait "$join_a_pid"
wait "$join_b_pid"
join_a_status=$(<"$smoke_tmp_dir/join-a.status")
join_b_status=$(<"$smoke_tmp_dir/join-b.status")
if [[ "$(printf '%s\n%s\n' "$join_a_status" "$join_b_status" | sort | tr '\n' ' ')" != "201 409 " ]]; then
  echo "Concurrent join requests did not produce one 201 and one 409." >&2
  exit 1
fi
if [[ "$join_a_status" == "201" ]]; then
  tertiary_join_request_id=$(jq -er '.requestId' "$smoke_tmp_dir/join-a.body")
else
  tertiary_join_request_id=$(jq -er '.requestId' "$smoke_tmp_dir/join-b.body")
fi

admin_requests=$(curl --silent --show-error \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  "$base_url/api/groups/$group_id/join-requests")
jq -e --arg request_id "$tertiary_join_request_id" \
  'any(.[]; .id == $request_id)' >/dev/null <<<"$admin_requests"
curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data '{"action":"accept"}' \
  "$base_url/api/groups/$group_id/join-requests/$tertiary_join_request_id/handle" \
  >"$smoke_tmp_dir/decision-a.status" &
decision_a_pid=$!
curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  -X POST \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data '{"action":"reject"}' \
  "$base_url/api/groups/$group_id/join-requests/$tertiary_join_request_id/handle" \
  >"$smoke_tmp_dir/decision-b.status" &
decision_b_pid=$!
wait "$decision_a_pid"
wait "$decision_b_pid"
decision_a_status=$(<"$smoke_tmp_dir/decision-a.status")
decision_b_status=$(<"$smoke_tmp_dir/decision-b.status")
if [[ "$(printf '%s\n%s\n' "$decision_a_status" "$decision_b_status" | sort | tr '\n' ' ')" != "200 403 " ]]; then
  echo "Concurrent decisions did not produce one 200 and one 403." >&2
  exit 1
fi

assert_status 403 "$base_url/api/groups/$group_id/members/$authenticated_user_id/role" \
  -X PATCH \
  -H 'content-type: application/json' \
  -H "authorization: Bearer $secondary_access_token" \
  -H "x-app-secret: $app_secret" \
  -H 'x-client-version: 2.0.0' \
  --data '{"role":"member"}'

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

echo "Smoke tests passed: health, tokens, identity, atomic conversation/message/read, concurrent join/decision/key races, owner/admin ACL, role isolation and Socket.IO handshake."
