import type { Env } from "./index";
import { sendGraceReminders } from "./push";
import { expireReservations } from "./reservations";

/**
 * The scheduled lifecycle job (ARCHITECTURE.md section 6), run hourly by the cron trigger in wrangler.jsonc.
 * `now` is the cron's scheduled time. Uploads already stop at ends_at (media.ts `isOpen`); this makes it a state.
 */
export async function runLifecycle(env: Env, now: number): Promise<void> {
  await enterGrace(env, now);
  await expireReservations(env, now);
  await sendGraceReminders(env, now);
  await deleteAfterGrace(env, now);
}

// Bounds one run's R2/D1 calls (Workers subrequest limits); the hourly cron picks up any remainder.
const DELETIONS_PER_RUN = 25;

/** Active groups past their paid period become read-only Grace groups until ends_at + GRACE_DAYS. */
async function enterGrace(env: Env, now: number) {
  await env.DB.prepare(
    `UPDATE groups SET state = 'Grace', grace_ends_at = strftime('%Y-%m-%dT%H:%M:%fZ', ends_at, ?1)
     WHERE state = 'Active' AND ends_at <= ?2`,
  )
    .bind(`+${graceDays(env)} days`, new Date(now).toISOString())
    .run();
}

/** Grace groups past grace_ends_at: delete every R2 object under the group's prefix, then its data. */
async function deleteAfterGrace(env: Env, now: number) {
  const { results } = await env.DB.prepare(
    "SELECT id FROM groups WHERE state = 'Grace' AND grace_ends_at <= ? ORDER BY grace_ends_at LIMIT ?",
  )
    .bind(new Date(now).toISOString(), DELETIONS_PER_RUN)
    .all<{ id: string }>();
  for (const { id } of results) await deleteGroup(env, id, now);
}

async function deleteGroup(env: Env, groupId: string, now: number) {
  const { results: unfinished } = await env.DB.prepare(
    `SELECT i.object_key, u.upload_id FROM multipart_uploads u JOIN items i ON i.id = u.item_id
     WHERE i.group_id = ? AND u.completed = 0`,
  )
    .bind(groupId)
    .all<{ object_key: string; upload_id: string }>();
  for (const upload of unfinished) {
    // Already-gone uploads throw; the bucket's abort-multipart lifecycle rule is the backstop (README).
    await env.MEDIA.resumeMultipartUpload(upload.object_key, upload.upload_id).abort().catch(() => {});
  }

  const prefix = `groups/${groupId}/`;
  const objectsDeleted = await deletePrefix(env.MEDIA, prefix);
  const objectsRemaining = (await env.MEDIA.list({ prefix })).objects.length;
  if (objectsRemaining > 0) {
    // Stay in Grace (still read-only) so the next run retries; never record a deletion that did not happen.
    console.error(`lifecycle: ${objectsRemaining} objects left under ${prefix}; will retry`);
    return;
  }

  const itemsOf = "SELECT id FROM items WHERE group_id = ?1";
  // Children before parents (foreign keys), all in one transaction; the groups row stays as a tombstone
  // (orders reference it, and it keeps counting towards the device's free Taster limit).
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO deletions (group_id, objects_deleted, objects_remaining, items_deleted, deleted_at)
       VALUES (?1, ?2, ?3, (SELECT COUNT(*) FROM items WHERE group_id = ?1), ?4)`,
    ).bind(groupId, objectsDeleted, objectsRemaining, new Date(now).toISOString()),
    env.DB.prepare(`DELETE FROM multipart_parts WHERE item_id IN (${itemsOf})`).bind(groupId),
    env.DB.prepare(`DELETE FROM multipart_uploads WHERE item_id IN (${itemsOf})`).bind(groupId),
    env.DB.prepare("DELETE FROM reports WHERE group_id = ?").bind(groupId),
    env.DB.prepare("DELETE FROM blocks WHERE group_id = ?").bind(groupId),
    env.DB.prepare("DELETE FROM notifications_sent WHERE group_id = ?").bind(groupId),
    env.DB.prepare("DELETE FROM items WHERE group_id = ?").bind(groupId),
    env.DB.prepare("DELETE FROM members WHERE group_id = ?").bind(groupId),
    env.DB.prepare(
      "UPDATE groups SET state = 'Deleted', storage_used_bytes = 0, qr_token = NULL, pin = NULL WHERE id = ?",
    ).bind(groupId),
  ]);
}

/** Deletes every object whose key starts with `prefix`; returns how many there were. */
async function deletePrefix(bucket: R2Bucket, prefix: string): Promise<number> {
  let deleted = 0;
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix, cursor });
    if (page.objects.length > 0) await bucket.delete(page.objects.map((o) => o.key));
    deleted += page.objects.length;
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return deleted;
}

function graceDays(env: Env): number {
  const days = Number(env.GRACE_DAYS);
  if (!Number.isInteger(days) || days < 1) throw new Error(`GRACE_DAYS must be a positive whole number, got ${env.GRACE_DAYS}`);
  return days;
}
