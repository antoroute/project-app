BEGIN;

DROP TABLE IF EXISTS group_device_key_history;

DELETE FROM device_approval_challenges WHERE decision = 'revoke';

ALTER TABLE device_approval_challenges
  DROP CONSTRAINT device_approval_challenges_decision_check,
  ADD CONSTRAINT device_approval_challenges_decision_check
    CHECK (decision IN ('approve', 'reject'));

UPDATE group_device_keys
   SET status = 'active'
 WHERE status = 'legacy';

ALTER TABLE group_device_keys
  DROP CONSTRAINT IF EXISTS ck_group_device_keys_revoked_at,
  DROP CONSTRAINT IF EXISTS ck_group_device_keys_trusted_material,
  DROP CONSTRAINT IF EXISTS ck_group_device_keys_binding_signature,
  DROP CONSTRAINT IF EXISTS ck_group_device_keys_identity_version,
  DROP CONSTRAINT IF EXISTS ck_group_device_keys_status,
  DROP COLUMN IF EXISTS revoked_at,
  DROP COLUMN IF EXISTS updated_at,
  DROP COLUMN IF EXISTS binding_signature,
  DROP COLUMN IF EXISTS identity_key_version,
  ALTER COLUMN status SET DEFAULT 'active';

COMMIT;
