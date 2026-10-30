-- Anonymous, aggregated analytics (SPEC.md section 10): counters per UTC day and tier only. No
-- device, member or group ids, and no foreign key to groups, so the counts survive group deletion.
CREATE TABLE daily_stats (
  day TEXT NOT NULL,
  tier TEXT NOT NULL,
  groups_created INTEGER NOT NULL DEFAULT 0,
  uploads INTEGER NOT NULL DEFAULT 0,
  upload_bytes INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, tier)
);
