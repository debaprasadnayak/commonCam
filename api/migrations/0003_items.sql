-- Bytes of confirmed items, counted against storage_cap_bytes.
ALTER TABLE groups ADD COLUMN storage_used_bytes INTEGER NOT NULL DEFAULT 0;

-- Shared photos/videos. A row is created 'pending' when an upload URL is issued and becomes
-- 'ready' (visible in the gallery, counted in storage) once the contributor confirms it.
-- member_id is NULL for the host, who has no members row.
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES groups (id),
  member_id TEXT REFERENCES members (id),
  contributor_device_id TEXT NOT NULL,
  type TEXT NOT NULL,
  content_type TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX items_group_status ON items (group_id, status, created_at);
