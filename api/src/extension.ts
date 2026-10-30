import { toJson, type GroupRow } from "./groups";
import type { Env } from "./index";
import { isReplayedTransaction, verifyPurchase } from "./purchases";
import { EXTENSION, type Tier } from "./tiers";
import { raiseLimits, recordOrder } from "./upgrades";

/**
 * `POST /groups/:id/extend {signedTransaction}`: the host pays to reopen an ended group (Grace → Active)
 * for EXTENSION.days more, counted from now (or from ends_at if the cron has not caught up yet).
 */
export async function handleExtension(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/extend$/);
  if (!route || request.method !== "POST") return null;
  const groupId = route[1];

  const group = await env.DB.prepare("SELECT tier, state, ends_at FROM groups WHERE id = ? AND host_device_id = ?")
    .bind(groupId, deviceId)
    .first<{ tier: Tier; state: string; ends_at: string }>();
  if (!group) return new Response("Not found", { status: 404 });
  if (group.state === "Deleted") return new Response("This group has been deleted", { status: 410 });
  // 400, not 409: the app finishes transactions on 409 (already redeemed), and this one should stay
  // unfinished so it is redeemed once the group has ended. Before then the +1 day add-on applies.
  if (group.state === "Active" && Date.parse(group.ends_at) > Date.now()) {
    return new Response("This group has not ended yet", { status: 400 });
  }

  const body = await request.json<{ signedTransaction?: unknown }>().catch(() => ({}) as { signedTransaction?: unknown });
  const transaction = await verifyPurchase(env, body.signedTransaction);
  if (transaction instanceof Response) return transaction;
  if (transaction.productId !== EXTENSION.productId) return new Response("Transaction is not an extension", { status: 400 });
  if (transaction.appAccountToken?.toLowerCase() !== groupId.toLowerCase()) {
    return new Response("Transaction was bought for another group", { status: 400 });
  }

  try {
    // One D1 transaction. Reopening first makes the group Active again; recordOrder/raiseLimits only
    // touch Active groups, so a group deleted meanwhile gets neither an order nor new limits.
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE groups SET state = 'Active', grace_ends_at = NULL, ends_at = MAX(ends_at, ?2)
         WHERE id = ?1 AND (state = 'Grace' OR (state = 'Active' AND ends_at <= ?2))`,
      ).bind(groupId, new Date().toISOString()),
      recordOrder(env.DB, groupId, group.tier, transaction, { withCredit: false }),
      raiseLimits(env.DB, groupId, group.tier, EXTENSION),
    ]);
  } catch (error) {
    if (isReplayedTransaction(error)) return new Response("Transaction already used", { status: 409 });
    throw error;
  }

  const row = await env.DB.prepare(
    "SELECT id, tier, state, people_cap, storage_cap_bytes, storage_used_bytes, starts_at, ends_at, grace_ends_at FROM groups WHERE id = ?",
  )
    .bind(groupId)
    .first<GroupRow>();
  if (row!.state !== "Active") return new Response("This group has been deleted", { status: 410 });
  return Response.json(toJson(row!));
}
