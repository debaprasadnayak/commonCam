import { InvalidTransaction, verifySignedTransaction } from "./appStore";
import type { Env } from "./index";
import { signEs256Jwt } from "./jwt";

/** Apple could not tell us a transaction's current state (not configured, unreachable, error, unverifiable answer). */
export class AppStoreUnavailable extends Error {}

/** Where the current state of a transaction comes from; tests swap in a fake fetch. */
export interface TransactionStateSource {
  /** Whether the transaction has since been refunded or revoked. Throws AppStoreUnavailable if Apple can't say. */
  isRevoked(transactionId: string): Promise<boolean>;
}

export interface AppStoreServerApiConfig {
  issuerId: string;
  keyId: string;
  /** In-App Purchase key (.p8, PKCS#8 PEM, P-256) from App Store Connect → Users and Access → Integrations. */
  privateKey: string;
  bundleId: string;
  /** "Sandbox" or "Production" (APP_STORE_ENV). */
  environment: string;
  rootCertB64: string;
}

/** The App Store Server API settings, or null while they aren't configured (see purchases.ts for that policy). */
export function appStoreServerApiConfig(env: Env): AppStoreServerApiConfig | null {
  if (!env.APPSTORE_ISSUER_ID || !env.APPSTORE_KEY_ID || !env.APPSTORE_PRIVATE_KEY) return null;
  return {
    issuerId: env.APPSTORE_ISSUER_ID,
    keyId: env.APPSTORE_KEY_ID,
    privateKey: env.APPSTORE_PRIVATE_KEY,
    bundleId: env.APPLE_BUNDLE_ID,
    environment: env.APP_STORE_ENV,
    rootCertB64: env.APPLE_ROOT_CA_G3,
  };
}

const REQUEST_TIMEOUT_MS = 5000;

/**
 * App Store Server API "Get Transaction Info" (GET /inApps/v1/transactions/{id}) with an ES256 JWT, whose signed
 * answer is verified like a StoreKit transaction.
 * shortcut: not yet tried against Apple (no App Store Connect key); call it with a real Sandbox purchase once one exists.
 */
export function appStoreServerApi(
  config: AppStoreServerApiConfig,
  fetchFn: typeof fetch = (input, init) => fetch(input, init),
): TransactionStateSource {
  const host = config.environment === "Production" ? "api.storekit.itunes.apple.com" : "api.storekit-sandbox.itunes.apple.com";
  return {
    async isRevoked(transactionId) {
      const now = Math.floor(Date.now() / 1000);
      const jwt = await signEs256Jwt(
        config.privateKey,
        { kid: config.keyId, typ: "JWT" },
        { iss: config.issuerId, iat: now, exp: now + 300, aud: "appstoreconnect-v1", bid: config.bundleId },
      );
      let response: Response;
      try {
        response = await fetchFn(`https://${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`, {
          headers: { Authorization: `Bearer ${jwt}` },
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
      } catch (error) {
        throw new AppStoreUnavailable(`request failed: ${error}`);
      }
      if (!response.ok) throw new AppStoreUnavailable(`HTTP ${response.status}`);
      const body = await response.json<{ signedTransactionInfo?: unknown }>().catch(() => null);
      if (typeof body?.signedTransactionInfo !== "string") throw new AppStoreUnavailable("no signedTransactionInfo");
      try {
        const current = await verifySignedTransaction(body.signedTransactionInfo, config, { allowRevoked: true });
        if (current.transactionId !== transactionId) throw new InvalidTransaction("Answer is about another transaction");
        return current.revocationDate !== undefined;
      } catch (error) {
        if (error instanceof InvalidTransaction) throw new AppStoreUnavailable(`unverifiable answer: ${error.message}`);
        throw error;
      }
    },
  };
}
