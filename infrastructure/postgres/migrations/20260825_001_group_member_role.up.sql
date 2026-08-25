BEGIN;

ALTER TABLE user_groups
  ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member';

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'user_groups_role_check'
       AND conrelid = 'user_groups'::regclass
  ) THEN
    ALTER TABLE user_groups
      ADD CONSTRAINT user_groups_role_check
      CHECK (role IN ('admin', 'member'));
  END IF;
END
$migration$;

COMMIT;
