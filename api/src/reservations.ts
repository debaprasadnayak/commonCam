import type { Env } from "./index";
import { syncStorageWarnings } from "./push";

/**
 * Upload reservations (SEC-01). Issuing an upload (media.ts `createPendingItem`) inserts a 'pending' item only if
 * ready bytes + all reservations + the new bytes fit the cap, so pending media can never push a group past it.
 * A reservation lasts until `items.reserved_until`; byte PUTs, part uploads, multipart completion and confirm all
 * require it to still hold. Expired ones are swept by the hourly lifecycle job (`expireReservations`).
 *
 * Every URL handed out expires before its reservation, so a valid PUT never races the sweep.
 */

/** Single-PUT tickets: the 15-minute upload URL, then time to confirm. */
export const SINGLE_UPLOAD_RESERVATION_S = 60 * 60;
/** Multipart uploads resume across app launches; each part plan or completion renews this from now. */
export const MULTIPART_RESERVATION_S = 24 * 60 * 60;

/** Bytes reserved in group ?2 (SQL; expired-but-unswept reservations still count until their bytes are deleted). */
export const RESERVATIONS_OF_GROUP =
  "SELECT COALESCE(SUM(bytes), 0) FROM items WHERE group_id = ?2 AND status IN ('pending', 'confirming')";

/** Extends a still-valid reservation; false if it has expired, been swept or confirmed. */
export async function renewReservation(env: Env, itemId: string, seconds: number): Promise<boolean> {
  const now = Date.now();
  const { meta } = await env.DB.prepare(
    "UPDATE items SET reserved_until = MAX(reserved_until, ?3) WHERE id = ?1 AND status = 'pending' AND reserved_until > ?2",
  )
    .bind(itemId, new Date(now).toISOString(), new Date(now + seconds * 1000).toISOString())
    .run();
  return meta.changes > 0;
}

// Bounds one run's R2/D1 calls (Workers subrequest limits); the hourly cron picks up any remainder.
const EXPIRIES_PER_RUN = 50;

/** Lifecycle job: expires every upload whose reservation lapsed at `now`, deleting its bytes. */
export async function expireReservations(env: Env, now: number): Promise<void> {
  const { results } = await env.DB.prepare(
    `SELECT id FROM items WHERE (status IN ('pending', 'confirming') AND reserved_until <= ?1) OR status = 'expired'
     ORDER BY reserved_until LIMIT ?2`,
  )
    .bind(new Date(now).toISOString(), EXPIRIES_PER_RUN)
    .all<{ id: string }>();
  for (const { id } of results) {
    // Conditional, so a confirm that claimed the item first keeps it.
    await env.DB.prepare(
      "UPDATE items SET status = 'expired' WHERE id = ? AND status IN ('pending', 'confirming') AND reserved_until <= ?",
    )
      .bind(id, new Date(now).toISOString())
      .run();
    await discardExpired(env, id);
  }
}

/** Releases a pending upload whose bytes can no longer be completed (e.g. R2 refused to assemble the parts). */
export async function releaseReservation(env: Env, itemId: string): Promise<void> {
  await env.DB.prepare("UPDATE items SET status = 'expired' WHERE id = ? AND status = 'pending'").bind(itemId).run();
  await discardExpired(env, itemId);
}

/**
 * Deletes an 'expired' item's R2 bytes (aborting its multipart upload), then its rows. The item stops counting
 * against the cap as soon as it is 'expired'; if R2 fails, the row stays and the next run retries.
 */
async function discardExpired(env: Env, itemId: string) {
  const item = await env.DB.prepare(
    `SELECT i.group_id, i.object_key, u.upload_id, u.completed FROM items i LEFT JOIN multipart_uploads u ON u.item_id = i.id
     WHERE i.id = ? AND i.status = 'expired'`,
  )
    .bind(itemId)
    .first<{ group_id: string; object_key: string; upload_id: string | null; completed: number | null }>();
  if (!item) return;
  if (item.upload_id && !item.completed) {
    // Already-gone uploads throw; the bucket's abort-multipart lifecycle rule is the backstop (README).
    await env.MEDIA.resumeMultipartUpload(item.object_key, item.upload_id).abort().catch(() => {});
  }
  await env.MEDIA.delete(item.object_key);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM multipart_parts WHERE item_id = ?").bind(itemId),
    env.DB.prepare("DELETE FROM multipart_uploads WHERE item_id = ?").bind(itemId),
    env.DB.prepare("DELETE FROM items WHERE id = ? AND status = 'expired'").bind(itemId),
    // Room was freed, like an item delete (deleteItem.ts): the group is no longer marked full by a refusal.
    env.DB.prepare("UPDATE groups SET storage_full = 0 WHERE id = ?").bind(item.group_id),
  ]);
  await syncStorageWarnings(env, item.group_id);
}
