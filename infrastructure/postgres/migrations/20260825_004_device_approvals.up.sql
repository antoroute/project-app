BEGIN;

CREATE TABLE device_approval_challenges (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  approver_device_id UUID NOT NULL,
  approver_identity_key_version INT NOT NULL CHECK (approver_identity_key_version >= 1),
  approver_identity_public_key BYTEA NOT NULL,
  target_device_id UUID NOT NULL,
  target_identity_key_version INT NOT NULL CHECK (target_identity_key_version >= 1),
  target_identity_public_key BYTEA NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('approve','reject')),
  challenge_nonce BYTEA NOT NULL,
  transcript BYTEA NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ,
  result TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  FOREIGN KEY (user_id, approver_device_id)
    REFERENCES account_devices(user_id, device_id) ON DELETE CASCADE,
  FOREIGN KEY (user_id, target_device_id)
    REFERENCES account_devices(user_id, device_id) ON DELETE CASCADE,
  CHECK (approver_device_id <> target_device_id),
  CHECK (octet_length(approver_identity_public_key) = 32),
  CHECK (octet_length(target_identity_public_key) = 32),
  CHECK (octet_length(challenge_nonce) = 32),
  CHECK (octet_length(transcript) = 216),
  CHECK (expires_at > created_at),
  CHECK (
    (consumed_at IS NULL AND result IS NULL)
    OR (consumed_at IS NOT NULL AND result IS NOT NULL)
  )
);

CREATE INDEX idx_device_approvals_outstanding_target
  ON device_approval_challenges(user_id, target_device_id, expires_at)
  WHERE consumed_at IS NULL;

CREATE INDEX idx_device_approvals_approver_created
  ON device_approval_challenges(user_id, approver_device_id, created_at);

COMMIT;
