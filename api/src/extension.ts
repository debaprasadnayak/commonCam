import { InvalidTransaction, verifySignedTransaction } from "./appStore";
import { toJson, type GroupRow } from "./groups";
import type { Env } from "./index";
import { EXTENSION } from "./tiers";

const DAY_MS = 24 * 60 * 60 * 1000;

// Ended but not yet deleted: in Grace, or Active past ends_at before the hourly cron has noticed.
// Binds ?1 = group id, ?2 = host device hash, ?3 = now (ISO).
const EXTENDABLE = `id = ?1 AND host_device_id = ?2
  AND ((state = 'Grace' AND grace_ends_at > ?3) OR (state = 'Active' AND ends_at <= ?3))`;

/** `POST /groups/:id/extend {signedTransaction}`: the host pays to reopen an ended group for EXTENSION.days. */
export async function handleExtension(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/extend$/);
  if (!route || request.method !== "POST") return null;
  const groupId = route[1];

  const group = await env.DB.prepare("SELECT state, ends_at FROM groups WHERE id = ? AND host_device_id = ?")
    .bind(groupId, deviceId)
    .first<{ state: string; ends_at: string }>();
  if (!group) return new Response("Not found", { status: 404 });
  const now = new Date();
  if (group.state === "Active" && Date.parse(group.ends_at) > now.getTime()) {
    return new Response("This group has not ended yet", { status: 409 });
  }

  const body = await request.json<{ signedTransaction?: unknown }>().catch(() => ({}) as Record<string, unknown>);
  if (typeof body.signedTransaction !== "string") return new Response("Extension needs a signedTransaction", { status: 400 });
  let transaction;
  try {
    transaction = await verifySignedTransaction(body.signedTransaction, { rootCertB64: env.APPLE_ROOT_CA_G3, bundleId: env.APPLE_BUNDLE_ID });
  } catch (error) {
    if (error instanceof InvalidTransaction) return new Response(`Invalid transaction: ${error.message}`, { status: 403 });
    throw error;
  }
  if (transaction.productId !== EXTENSION.productId) return new Response("Transaction is not an extension", { status: 400 });

  const endsAt = new Date(Math.max(now.getTime(), Date.parse(group.ends_at)) + EXTENSION.days * DAY_MS).toISOString();
  const params = [groupId, deviceId, now.toISOString()];
  let results;
  try {
    // One transaction: the order is only recorded if the group is still extendable (not deleted meanwhile),
    // and a replayed transaction id rolls the extension back.
    results = await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO orders (id, group_id, apple_transaction_id, sku, amount_milliunits, currency, environment, created_at)
         SELECT ?4, ?1, ?5, ?6, ?7, ?8, ?9, ?3 WHERE EXISTS (SELECT 1 FROM groups WHERE ${EXTENDABLE})`,
      ).bind(
        ...params,
        crypto.randomUUID(),
        transaction.transactionId,
        transaction.productId,
        transaction.price ?? null,
        transaction.currency ?? null,
        transaction.environment ?? null,
      ),
      env.DB.prepare(`UPDATE groups SET state = 'Active', ends_at = ?4, grace_ends_at = NULL WHERE ${EXTENDABLE}`).bind(...params, endsAt),
    ]);
  } catch (error) {
    if (String(error).includes("UNIQUE constraint failed: orders.apple_transaction_id")) {
      return new Response("Transaction already used", { status: 409 });
    }
    throw error;
  }
  if (results[1].meta.changes === 0) return new Response("This group has been deleted", { status: 410 });

  const row = await env.DB.prepare(
    `SELECT id, tier, state, people_cap, storage_cap_bytes, storage_used_bytes, starts_at, ends_at, grace_ends_at FROM groups WHERE id = ?`,
  )
    .bind(groupId)
    .first<GroupRow>();
  return Response.json(toJson(row!));
}
