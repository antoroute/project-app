BEGIN;

CREATE TABLE device_bootstrap_grants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash BYTEA UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (octet_length(token_hash) = 32),
  CHECK (expires_at > created_at)
);

CREATE TABLE account_devices (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  identity_public_key BYTEA NOT NULL,
  identity_key_version INT NOT NULL DEFAULT 1 CHECK (identity_key_version >= 1),
  platform TEXT NOT NULL CHECK (platform IN ('android','ios','windows','macos','unknown')),
  device_name TEXT NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
  status TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
  proof_verified_at TIMESTAMPTZ NOT NULL,
  activated_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, device_id),
  UNIQUE (user_id, identity_public_key),
  CHECK (octet_length(identity_public_key) = 32),
  CHECK (status <> 'active' OR activated_at IS NOT NULL),
  CHECK (status <> 'pending' OR activated_at IS NULL),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE TABLE device_registration_challenges (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  identity_public_key BYTEA NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('android','ios','windows','macos','unknown')),
  device_name TEXT NOT NULL CHECK (char_length(device_name) BETWEEN 1 AND 64),
  challenge_nonce BYTEA NOT NULL,
  transcript BYTEA NOT NULL,
  bootstrap_grant_id UUID REFERENCES device_bootstrap_grants(id) ON DELETE SET NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (octet_length(identity_public_key) = 32),
  CHECK (octet_length(challenge_nonce) = 32),
  CHECK (octet_length(transcript) = 163),
  CHECK (expires_at > created_at),
  CHECK (
    (consumed_at IS NULL AND result IS NULL)
    OR (consumed_at IS NOT NULL AND result IS NOT NULL)
  )
);

CREATE INDEX idx_account_devices_user_status
  ON account_devices(user_id, status);

CREATE INDEX idx_device_challenges_outstanding
  ON device_registration_challenges(user_id, device_id, expires_at)
  WHERE consumed_at IS NULL;

CREATE INDEX idx_device_bootstrap_grants_user_expiry
  ON device_bootstrap_grants(user_id, expires_at);

COMMIT;
