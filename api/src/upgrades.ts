import type { AppStoreTransaction } from "./appStore";
import { loadGroup, toJson } from "./groups";
import { isHostOrCoHost } from "./hostControls";
import type { Env } from "./index";
import { isOpen } from "./media";
import { isReplayedTransaction, recordOrder, verifyPurchase } from "./purchases";
import { syncStorageWarnings } from "./push";
import { addOnForProductId, parseUpgradeProductId, upgradeIncrease, type LimitIncrease, type Tier } from "./tiers";

// POST /groups/:id/purchases {signedTransaction}: applies a mid-event upgrade or add-on (host or co-host).
export async function handleUpgrades(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const match = url.pathname.match(/^\/groups\/([^/]+)\/purchases$/);
  if (!match || request.method !== "POST") return null;
  const groupId = match[1];
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const group = await loadGroup(env.DB, groupId);
  if (!group) return new Response("Not found", { status: 404 });

  const body = await request.json<{ signedTransaction?: unknown }>().catch(() => ({}) as { signedTransaction?: unknown });
  const transaction = await verifyPurchase(env, body.signedTransaction);
  if (transaction instanceof Response) return transaction;
  // Binds the payment to this group, so it can't be redeemed on another one.
  if (transaction.appAccountToken?.toLowerCase() !== groupId.toLowerCase()) {
    return new Response("Transaction was bought for another group", { status: 400 });
  }

  const upgrade = parseUpgradeProductId(transaction.productId);
  const addOn = addOnForProductId(transaction.productId);
  if (!upgrade && !addOn) return new Response("Not an upgrade or add-on", { status: 400 });
  if (!isOpen(group)) return new Response("This group is no longer open", { status: 410 });
  if (upgrade && upgrade.from !== group.tier) return new Response(`This group is not on ${upgrade.from}`, { status: 400 });
  if (addOn && group.tier === "taster") return new Response("Add-ons need a paid tier; upgrade instead", { status: 400 });

  const tier = group.tier as Tier;
  const applied = upgrade
    ? await applyPurchase(env.DB, groupId, tier, upgradeIncrease(upgrade.from, upgrade.to), transaction, upgrade.to)
    : await applyPurchase(env.DB, groupId, tier, addOn!, transaction);
  if (applied instanceof Response) return applied;
  await syncStorageWarnings(env, groupId);
  return Response.json(toJson((await loadGroup(env.DB, groupId))!));
}

/**
 * Records the order and raises the group's limits in one D1 transaction, provided the group is still
 * on `expectedTier` (a concurrent upgrade makes this a 400). Replayed transaction ids → 409.
 * #18's extension (extension.ts) batches recordOrder (purchases.ts)/raiseLimits itself, after reopening the group.
 */
export async function applyPurchase(
  db: D1Database,
  groupId: string,
  expectedTier: Tier,
  increase: LimitIncrease,
  transaction: AppStoreTransaction,
  newTier: Tier = expectedTier,
): Promise<Response | null> {
  try {
    const [order] = await db.batch([
      recordOrder(db, groupId, expectedTier, transaction, { withCredit: newTier !== expectedTier }),
      raiseLimits(db, groupId, expectedTier, increase, newTier),
    ]);
    if (order.meta.changes === 0) return new Response("The group's tier changed; try again", { status: 400 });
  } catch (error) {
    if (isReplayedTransaction(error)) return new Response("Transaction already used", { status: 409 });
    throw error;
  }
  return null;
}

/** Adds `increase` to the group's caps and end date (and sets `newTier`) if it is still Active on `expectedTier`. */
export function raiseLimits(
  db: D1Database,
  groupId: string,
  expectedTier: Tier,
  increase: LimitIncrease,
  newTier: Tier = expectedTier,
): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE groups SET tier = ?1, people_cap = people_cap + ?2, storage_cap_bytes = storage_cap_bytes + ?3,
         ends_at = strftime('%Y-%m-%dT%H:%M:%fZ', ends_at, ?4)
       WHERE id = ?5 AND tier = ?6 AND state = 'Active'`,
    )
    .bind(newTier, increase.peopleCap, increase.storageCapBytes, `+${increase.days} days`, groupId, expectedTier);
}
