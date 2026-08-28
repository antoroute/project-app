BEGIN;

ALTER TABLE device_approval_challenges
  DROP CONSTRAINT device_approval_challenges_decision_check,
  ADD CONSTRAINT device_approval_challenges_decision_check
    CHECK (decision IN ('approve', 'reject', 'revoke'));

ALTER TABLE group_device_keys
  ADD COLUMN identity_key_version INT,
  ADD COLUMN binding_signature BYTEA,
  ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN revoked_at TIMESTAMPTZ,
  ALTER COLUMN status SET DEFAULT 'legacy';

UPDATE group_device_keys
   SET status = 'legacy', updated_at = NOW()
 WHERE status = 'active';

UPDATE group_device_keys
   SET revoked_at = COALESCE(revoked_at, created_at, NOW()),
       updated_at = NOW()
 WHERE status = 'revoked';

ALTER TABLE group_device_keys
  ADD CONSTRAINT ck_group_device_keys_status
    CHECK (status IN ('legacy', 'active', 'revoked')),
  ADD CONSTRAINT ck_group_device_keys_identity_version
    CHECK (identity_key_version IS NULL OR identity_key_version >= 1),
  ADD CONSTRAINT ck_group_device_keys_binding_signature
    CHECK (binding_signature IS NULL OR octet_length(binding_signature) = 64),
  ADD CONSTRAINT ck_group_device_keys_trusted_material
    CHECK (
      status <> 'active'
      OR (
        identity_key_version IS NOT NULL
        AND binding_signature IS NOT NULL
        AND octet_length(pk_sig) = 32
        AND octet_length(pk_kem) = 32
      )
    ),
  ADD CONSTRAINT ck_group_device_keys_revoked_at
    CHECK (status <> 'revoked' OR revoked_at IS NOT NULL);

CREATE TABLE group_device_key_history (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  key_version INT NOT NULL CHECK (key_version >= 1),
  identity_key_version INT NOT NULL CHECK (identity_key_version >= 1),
  pk_sig BYTEA NOT NULL CHECK (octet_length(pk_sig) = 32),
  pk_kem BYTEA NOT NULL CHECK (octet_length(pk_kem) = 32),
  binding_signature BYTEA NOT NULL CHECK (octet_length(binding_signature) = 64),
  status TEXT NOT NULL CHECK (status IN ('superseded', 'revoked')),
  activated_at TIMESTAMPTZ NOT NULL,
  retired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (group_id, user_id, device_id, key_version)
);

CREATE INDEX idx_group_device_key_history_lookup
  ON group_device_key_history(group_id, user_id, device_id, key_version);

COMMIT;
