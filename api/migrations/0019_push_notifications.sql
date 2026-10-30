-- Push notifications (#19). APNs tokens belong to a device identity (the hashed bearer token); one identity
-- can be on several phones (iCloud Keychain), so the APNs token is the key.
CREATE TABLE push_tokens (
  apns_token TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX push_tokens_device ON push_tokens (device_id);

-- Notifications already sent, so each fires once. `ref` tells repeats apart: the grace_ends_at a reminder was
-- for (a paid extension starts a new grace), '' for storage warnings (row deleted when the level drops again).
CREATE TABLE notifications_sent (
  group_id TEXT NOT NULL REFERENCES groups (id),
  kind TEXT NOT NULL,
  ref TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  PRIMARY KEY (group_id, kind, ref)
);
