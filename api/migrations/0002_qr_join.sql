-- Bearer token encoded in the group's QR. Minted when the host first asks for the invite.
ALTER TABLE groups ADD COLUMN qr_token TEXT;
CREATE UNIQUE INDEX groups_qr_token ON groups (qr_token);

-- Guests who joined a group. The host is not a row here but counts against the people cap.
CREATE TABLE members (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL REFERENCES groups (id),
  device_id TEXT NOT NULL,
  display_name TEXT NOT NULL,
  colour TEXT NOT NULL,
  role TEXT NOT NULL,
  status TEXT NOT NULL,
  consent_accepted_at TEXT NOT NULL,
  joined_at TEXT NOT NULL,
  UNIQUE (group_id, device_id)
);

-- Failed join attempts, keyed by device hash or client IP, for rate limiting token guessing.
CREATE TABLE join_failures (
  key TEXT NOT NULL,
  failed_at TEXT NOT NULL
);
CREATE INDEX join_failures_key ON join_failures (key, failed_at);
