import { countGroupCreated } from "./analytics";
import { InvalidTransaction, verifySignedTransaction, type AppStoreTransaction } from "./appStore";
import { insertGroup, newGroupRow, toJson } from "./groups";
import type { Env } from "./index";
import { TIER_CREDIT_PRODUCT_IDS, TIERS, type PaidTier, type Tier } from "./tiers";

/** Activates a paid group from a StoreKit 2 signed transaction and records the order. */
// shortcut: the transaction is not bound to the buying device (StoreKit `appAccountToken`), so an unused
// signed transaction leaked from one device could be redeemed by another, once; bind it if leaks are seen.
export async function createPaidGroup(
  env: Env,
  hostDeviceId: string,
  tier: PaidTier,
  signedTransaction: unknown,
): Promise<Response> {
  const transaction = await verifyPurchase(env, signedTransaction);
  if (transaction instanceof Response) return transaction;
  if (transaction.productId !== TIERS[tier].productId) {
    return new Response("Transaction is for a different tier", { status: 400 });
  }

  const row = newGroupRow(tier);
  try {
    // A D1 batch is one transaction: a replayed transaction id rolls back the group too.
    await env.DB.batch([
      insertGroup(env.DB, hostDeviceId, row),
      recordOrder(env.DB, row.id, tier, transaction, { withCredit: false }),
      countGroupCreated(env.DB, row.id),
    ]);
  } catch (error) {
    if (isReplayedTransaction(error)) {
      return new Response("Transaction already used", { status: 409 });
    }
    throw error;
  }
  return Response.json(toJson(row), { status: 201 });
}

/** The verified App Store transaction, or the 400/403 response to send instead. */
export async function verifyPurchase(env: Env, signedTransaction: unknown): Promise<AppStoreTransaction | Response> {
  if (typeof signedTransaction !== "string") return new Response("Purchases need a signedTransaction", { status: 400 });
  try {
    return await verifySignedTransaction(signedTransaction, {
      rootCertB64: env.APPLE_ROOT_CA_G3,
      bundleId: env.APPLE_BUNDLE_ID,
      environment: env.APP_STORE_ENV,
    });
  } catch (error) {
    if (error instanceof InvalidTransaction) return new Response(`Invalid transaction: ${error.message}`, { status: 403 });
    throw error;
  }
}

export function isReplayedTransaction(error: unknown): boolean {
  return String(error).includes("UNIQUE constraint failed: orders.apple_transaction_id");
}

/**
 * Inserts the order if the group is Active on `expectedTier` (Grace/Deleted groups take no purchases; #18's
 * extension reopens the group, and a new paid group is inserted, earlier in the same batch). With `withCredit`
 * (upgrades), `credit_applied` is what was already paid towards the group's tier (TIER_CREDIT_PRODUCT_IDS): the
 * tier purchase plus earlier upgrades, not add-ons or extensions.
 */
export function recordOrder(
  db: D1Database,
  groupId: string,
  expectedTier: Tier,
  transaction: AppStoreTransaction,
  { withCredit }: { withCredit: boolean },
): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO orders (id, group_id, apple_transaction_id, sku, amount_milliunits, currency, credit_applied, environment, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6,
              CASE WHEN ?7 THEN (SELECT COALESCE(SUM(amount_milliunits), 0) FROM orders
                                 WHERE group_id = ?2 AND sku IN (${TIER_CREDIT_PRODUCT_IDS.map((id) => `'${id}'`).join(", ")})) ELSE 0 END,
              ?8, ?9
       WHERE EXISTS (SELECT 1 FROM groups WHERE id = ?2 AND tier = ?10 AND state = 'Active')`,
    )
    .bind(
      crypto.randomUUID(),
      groupId,
      transaction.transactionId,
      transaction.productId,
      transaction.price ?? null,
      transaction.currency ?? null,
      withCredit ? 1 : 0,
      transaction.environment ?? null,
      new Date().toISOString(),
      expectedTier,
    );
}
