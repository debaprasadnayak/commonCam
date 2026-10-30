CREATE TABLE groups (
  id TEXT PRIMARY KEY,
  host_device_id TEXT NOT NULL,
  tier TEXT NOT NULL,
  people_cap INTEGER NOT NULL,
  storage_cap_bytes INTEGER NOT NULL,
  starts_at TEXT NOT NULL,
  ends_at TEXT NOT NULL,
  state TEXT NOT NULL
);

CREATE INDEX groups_host_device_id ON groups (host_device_id);
