import { storageJson } from "./storageCap";
import { TASTER_LIMIT_PER_DEVICE, TIERS, type Tier } from "./tiers";

const DAY_MS = 24 * 60 * 60 * 1000;

export interface GroupRow {
  id: string;
  tier: string;
  state: string;
  people_cap: number;
  storage_cap_bytes: number;
  storage_used_bytes: number;
  storage_full?: number;
  starts_at: string;
  ends_at: string;
  /** Set when the group enters Grace (lifecycle.ts); null while Active. */
  grace_ends_at?: string | null;
}

/** A new Active group starting now, with the tier's limits. */
export function newGroupRow(tier: Tier): GroupRow {
  const limits = TIERS[tier];
  const startsAt = new Date();
  return {
    id: crypto.randomUUID(),
    tier,
    state: "Active",
    people_cap: limits.peopleCap,
    storage_cap_bytes: limits.storageCapBytes,
    storage_used_bytes: 0,
    starts_at: startsAt.toISOString(),
    ends_at: new Date(startsAt.getTime() + limits.days * DAY_MS).toISOString(),
  };
}

export function insertGroup(db: D1Database, hostDeviceId: string, row: GroupRow): D1PreparedStatement {
  return db.prepare(`INSERT INTO groups (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).bind(...values(hostDeviceId, row));
}

/**
 * Inserts nothing (changes = 0) once the device has used up its free Tasters; atomic, so no race. A group
 * started as a Taster if it has no tier purchase order, so upgraded Tasters still count.
 */
export function insertTasterGroup(db: D1Database, hostDeviceId: string, row: GroupRow): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO groups (${COLUMNS}) SELECT ?, ?, ?, ?, ?, ?, ?, ?
       WHERE (SELECT COUNT(*) FROM groups g WHERE host_device_id = ? AND NOT EXISTS
               (SELECT 1 FROM orders o WHERE o.group_id = g.id AND o.sku IN (${PAID_TIER_PRODUCT_IDS}))) < ?`,
    )
    .bind(...values(hostDeviceId, row), hostDeviceId, TASTER_LIMIT_PER_DEVICE);
}

const PAID_TIER_PRODUCT_IDS = Object.values(TIERS)
  .flatMap((tier) => (tier.productId ? [`'${tier.productId}'`] : []))
  .join(", ");

const COLUMNS = "id, host_device_id, tier, people_cap, storage_cap_bytes, starts_at, ends_at, state";

function values(hostDeviceId: string, row: GroupRow) {
  return [row.id, hostDeviceId, row.tier, row.people_cap, row.storage_cap_bytes, row.starts_at, row.ends_at, row.state];
}

/** Selects what `toJson` needs; every endpoint returning groups reads them with this, so their JSON matches. */
export const GROUP_SELECT =
  "SELECT id, tier, state, people_cap, storage_cap_bytes, storage_used_bytes, storage_full, starts_at, ends_at, grace_ends_at FROM groups";

export function loadGroup(db: D1Database, groupId: string) {
  return db.prepare(`${GROUP_SELECT} WHERE id = ?`).bind(groupId).first<GroupRow>();
}

export function toJson(row: GroupRow) {
  return {
    id: row.id,
    tier: row.tier,
    state: row.state,
    peopleCap: row.people_cap,
    ...storageJson(row),
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    graceEndsAt: row.grace_ends_at ?? null,
  };
}
