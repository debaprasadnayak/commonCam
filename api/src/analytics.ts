// Anonymous, aggregated analytics: bumps per-day, per-tier counters in `daily_stats`.
// Report: `reports/analytics.sql`. Each helper is a statement to run in the same D1 batch as the
// action it counts, so a rolled-back action is not counted. Both read the tier from the group row
// and insert nothing if that row does not exist (e.g. a refused Taster insert).

/** Counts the creation of group `groupId`. */
export function countGroupCreated(db: D1Database, groupId: string): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO daily_stats (day, tier, groups_created) SELECT date('now'), tier, 1 FROM groups WHERE id = ?
       ON CONFLICT (day, tier) DO UPDATE SET groups_created = groups_created + 1`,
    )
    .bind(groupId);
}

/** Counts one confirmed upload of `bytes` into group `groupId`. */
export function countUpload(db: D1Database, groupId: string, bytes: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO daily_stats (day, tier, uploads, upload_bytes) SELECT date('now'), tier, 1, ?2 FROM groups WHERE id = ?1
       ON CONFLICT (day, tier) DO UPDATE SET uploads = uploads + 1, upload_bytes = upload_bytes + excluded.upload_bytes`,
    )
    .bind(groupId, bytes);
}
