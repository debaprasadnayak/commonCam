import { countGroupCreated } from "./analytics";
import { InvalidTransaction, verifySignedTransaction, type AppStoreTransaction } from "./appStore";
import { insertGroup, newGroupRow, toJson } from "./groups";
import type { Env } from "./index";
import { TIERS, type PaidTier } from "./tiers";

/** Activates a paid group from a StoreKit 2 signed transaction and records the order. */
// shortcut: the transaction is not bound to the buying device (StoreKit `appAccountToken`), so an
// unused signed transaction leaked from one device could be redeemed by another, once.
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
      env.DB.prepare(
        `INSERT INTO orders (id, group_id, apple_transaction_id, sku, amount_milliunits, currency, environment, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        crypto.randomUUID(),
        row.id,
        transaction.transactionId,
        transaction.productId,
        transaction.price ?? null,
        transaction.currency ?? null,
        transaction.environment ?? null,
        new Date().toISOString(),
      ),
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
    return await verifySignedTransaction(signedTransaction, { rootCertB64: env.APPLE_ROOT_CA_G3, bundleId: env.APPLE_BUNDLE_ID });
  } catch (error) {
    if (error instanceof InvalidTransaction) return new Response(`Invalid transaction: ${error.message}`, { status: 403 });
    throw error;
  }
}

export function isReplayedTransaction(error: unknown): boolean {
  return String(error).includes("UNIQUE constraint failed: orders.apple_transaction_id");
}
