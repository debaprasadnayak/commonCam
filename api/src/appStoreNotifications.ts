import { InvalidTransaction, verifyAppleSignedPayload, verifySignedTransaction } from "./appStore";
import type { Env } from "./index";

/** Notification types that change whether a transaction may still be redeemed: true = revoked. */
const REVOCATION_TYPES: Record<string, boolean> = { REFUND: true, REVOKE: true, REFUND_REVERSED: false };

/**
 * `POST /app-store/notifications`: App Store Server Notifications V2 (unauthenticated; the payload is App Store-signed).
 * Records refunds and revocations by transaction id, checked when a transaction is redeemed (purchases.ts). Answers
 * 200 to anything verified, including types it ignores and repeats, so Apple stops retrying; 4xx otherwise.
 */
export async function handleAppStoreNotifications(request: Request, url: URL, env: Env): Promise<Response | null> {
  if (url.pathname !== "/app-store/notifications" || request.method !== "POST") return null;
  const body = await request.json<{ signedPayload?: unknown }>().catch(() => null);
  if (typeof body?.signedPayload !== "string") return new Response("Expected {signedPayload}", { status: 400 });

  let transactionId: string;
  let revoked: boolean;
  let notification: Record<string, any>;
  try {
    notification = await verifyAppleSignedPayload(body.signedPayload, { rootCertB64: env.APPLE_ROOT_CA_G3 });
    const data = notification.data ?? {};
    if (data.bundleId !== env.APPLE_BUNDLE_ID || data.environment !== env.APP_STORE_ENV) {
      console.log(`app-store: ignored a notification for ${data.bundleId} (${data.environment})`);
      return new Response(null, { status: 200 });
    }
    if (!(notification.notificationType in REVOCATION_TYPES)) return new Response(null, { status: 200 });
    if (typeof data.signedTransactionInfo !== "string" || typeof notification.signedDate !== "number") {
      return new Response("Notification is missing its transaction", { status: 400 });
    }
    const transaction = await verifySignedTransaction(
      data.signedTransactionInfo,
      { rootCertB64: env.APPLE_ROOT_CA_G3, bundleId: env.APPLE_BUNDLE_ID, environment: env.APP_STORE_ENV },
      { allowRevoked: true },
    );
    transactionId = transaction.transactionId;
    revoked = REVOCATION_TYPES[notification.notificationType];
  } catch (error) {
    if (error instanceof InvalidTransaction) return new Response(`Invalid notification: ${error.message}`, { status: 403 });
    throw error;
  }

  // Only a newer notification changes the row: repeats are no-ops, and late, older deliveries can't undo newer state.
  await env.DB.prepare(
    `INSERT INTO app_store_revocations (transaction_id, revoked, notification_type, signed_date, notification_uuid, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT (transaction_id) DO UPDATE SET revoked = ?2, notification_type = ?3, signed_date = ?4, notification_uuid = ?5, updated_at = ?6
     WHERE ?4 > app_store_revocations.signed_date`,
  )
    .bind(
      transactionId,
      revoked ? 1 : 0,
      notification.notificationType,
      notification.signedDate,
      typeof notification.notificationUUID === "string" ? notification.notificationUUID : null,
      new Date().toISOString(),
    )
    .run();
  return new Response(null, { status: 200 });
}

/** Whether App Store notifications say this transaction was refunded or revoked (and not reinstated since). */
export async function isRevokedByNotification(env: Env, transactionId: string): Promise<boolean> {
  const row = await env.DB.prepare("SELECT revoked FROM app_store_revocations WHERE transaction_id = ?").bind(transactionId).first<{ revoked: number }>();
  return row?.revoked === 1;
}
