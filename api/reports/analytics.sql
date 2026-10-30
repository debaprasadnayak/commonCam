-- Anonymous analytics report (issue #22): groups created, uploads, conversion, cost per group,
-- per tier plus an 'all' row, over everything in daily_stats (add `WHERE day >= 'YYYY-MM-DD'` to
-- the `per_tier` CTE for a period). Run against dev:
--   cd api && npx wrangler d1 execute commoncam --remote --file reports/analytics.sql
--
-- conversion_pct ('all' row only): paid groups / all groups created. Counts are anonymous, so this
-- is not per-device Taster→paid conversion.
-- Upgrades and add-ons (#16, POST /groups/:id/purchases) are not counted: an upgrade is not a new
-- group, and a Taster upgraded to paid stays counted as a Taster creation (not a conversion).
--
-- shortcut: est_cost_* is an estimate, not billing data. R2 prices from COST_MODEL.md section 2:
-- storage $0.015/GB-month held for tier days + 14 grace days (days mirror api/src/tiers.ts),
-- $4.50 per million Class A ops (one per upload), $0.03 fixed per group (API/compute), $0 egress.
-- Uploaded bytes are charged for the whole retention even if deleted earlier (an upper bound);
-- downloads (Class B ops) are not counted.
WITH per_tier AS (
  SELECT tier,
    SUM(groups_created) AS groups_created,
    SUM(uploads) AS uploads,
    SUM(upload_bytes) AS upload_bytes
  FROM daily_stats GROUP BY tier
), costed AS (
  SELECT *,
    upload_bytes / 1073741824.0 * 0.015
      * (CASE tier WHEN 'taster' THEN 1 WHEN 'pocket' THEN 2 WHEN 'party' THEN 5 WHEN 'festival' THEN 10 END + 14) / 30.0
    + uploads * 4.50 / 1000000
    + groups_created * 0.03 AS est_cost_usd
  FROM per_tier
)
SELECT tier, groups_created, uploads, upload_bytes,
  ROUND(est_cost_usd / NULLIF(groups_created, 0), 4) AS est_cost_per_group_usd,
  NULL AS conversion_pct
FROM costed
UNION ALL
SELECT 'all', SUM(groups_created), SUM(uploads), SUM(upload_bytes),
  ROUND(SUM(est_cost_usd) / NULLIF(SUM(groups_created), 0), 4),
  ROUND(100.0 * SUM(CASE WHEN tier = 'taster' THEN 0 ELSE groups_created END) / NULLIF(SUM(groups_created), 0), 1)
FROM costed
