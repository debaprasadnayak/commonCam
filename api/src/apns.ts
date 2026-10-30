import type { Env } from "./index";
import type { Push, PushSender } from "./push";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** Contents of the .p8 file (PKCS#8 PEM, P-256). */
  privateKey: string;
  /** App bundle id (apns-topic). */
  topic: string;
  sandbox: boolean;
}

/** The APNs settings, or null while they aren't configured (then pushes are skipped with a log line). */
export function apnsConfig(env: Env): ApnsConfig | null {
  if (!env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_PRIVATE_KEY) return null;
  return {
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
    privateKey: env.APNS_PRIVATE_KEY,
    topic: env.APPLE_BUNDLE_ID,
    sandbox: env.APNS_ENV !== "production",
  };
}

// Apple rejects tokens older than an hour and throttles refreshing more than every 20 minutes.
const JWT_LIFETIME_MS = 50 * 60 * 1000;
let cachedJwt: { cacheKey: string; jwt: string; issuedAt: number } | null = null;

/**
 * Token-based APNs (ES256 JWT signed with the .p8 key via Web Crypto), POST /3/device/<token> per push.
 * shortcut: not yet tried against Apple (no .p8 key), so HTTP/2 negotiation and Apple's replies are untested;
 * send a real push as soon as the APNS_* key is set up.
 */
export function apnsSender(config: ApnsConfig, fetchFn: typeof fetch = fetch, now: () => number = Date.now): PushSender {
  const host = config.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return {
    async send(push: Push) {
      const response = await fetchFn(`https://${host}/3/device/${push.deviceToken}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${await providerToken(config, now())}`,
          "apns-topic": config.topic,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-collapse-id": `${push.groupId}:${push.kind}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          aps: { alert: { title: push.title, body: push.body }, sound: "default" },
          groupId: push.groupId,
          kind: push.kind,
        }),
      });
      if (response.ok) return;
      const reason = await response.json<{ reason?: string }>().then((b) => b.reason, () => undefined);
      if (response.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") return "unregistered";
      throw new Error(`APNs ${response.status} ${reason ?? ""}`.trim());
    },
  };
}

async function providerToken(config: ApnsConfig, now: number): Promise<string> {
  const cacheKey = `${config.teamId}/${config.keyId}`;
  if (cachedJwt && cachedJwt.cacheKey === cacheKey && now - cachedJwt.issuedAt < JWT_LIFETIME_MS) return cachedJwt.jwt;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(config.privateKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signingInput = `${base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }))}.${base64url(
    JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) }),
  )}`;
  // Web Crypto's ECDSA signature is raw r||s, which is exactly what JWS ES256 wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput));
  const jwt = `${signingInput}.${base64url(new Uint8Array(signature))}`;
  cachedJwt = { cacheKey, jwt, issuedAt: now };
  return jwt;
}

function pemBytes(pem: string): Uint8Array {
  const base64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function base64url(data: string | Uint8Array): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
