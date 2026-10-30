-- Reported items are hidden from everyone except the host and co-hosts until one of them reviews the report.
ALTER TABLE items ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;

-- A report targets exactly one item or one member. status: open → restored | deleted.
CREATE TABLE reports (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES groups (id),
  item_id TEXT REFERENCES items (id),
  member_id TEXT REFERENCES members (id),
  reporter_device_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  CHECK ((item_id IS NULL) <> (member_id IS NULL))
);
CREATE INDEX reports_group_status ON reports (group_id, status, created_at);

-- Per-viewer blocks: the blocker no longer sees the blocked member's items. Nobody else is affected.
CREATE TABLE blocks (
  group_id TEXT NOT NULL REFERENCES groups (id),
  blocker_device_id TEXT NOT NULL,
  blocked_member_id TEXT NOT NULL REFERENCES members (id),
  created_at TEXT NOT NULL,
  PRIMARY KEY (group_id, blocker_device_id, blocked_member_id)
);
