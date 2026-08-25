BEGIN;

ALTER TABLE user_groups
  DROP CONSTRAINT IF EXISTS user_groups_role_check;

ALTER TABLE user_groups
  DROP COLUMN IF EXISTS role;

COMMIT;
