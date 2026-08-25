BEGIN;

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM join_requests
     WHERE status = 'pending'
     GROUP BY group_id, user_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate pending join requests must be resolved before migration'
      USING ERRCODE = '23505';
  END IF;
END
$migration$;

CREATE UNIQUE INDEX IF NOT EXISTS uidx_join_requests_pending_group_user
  ON join_requests(group_id, user_id)
  WHERE status = 'pending';

COMMIT;
