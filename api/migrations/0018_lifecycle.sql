-- Lifecycle (ARCHITECTURE.md section 6): a scheduled job moves Active groups to 'Grace' when ends_at
-- passes (read-only; grace_ends_at = ends_at + GRACE_DAYS) and to 'Deleted' when grace_ends_at passes.
ALTER TABLE groups ADD COLUMN grace_ends_at TEXT;
CREATE INDEX groups_state_ends ON groups (state, ends_at);

-- Audit trail of permanent deletions: one row per deleted group. objects_remaining is what an R2 list
-- of the group's prefix returned right after deleting (0 = verified empty).
CREATE TABLE deletions (
  group_id TEXT PRIMARY KEY REFERENCES groups (id),
  objects_deleted INTEGER NOT NULL,
  objects_remaining INTEGER NOT NULL,
  items_deleted INTEGER NOT NULL,
  deleted_at TEXT NOT NULL
);
