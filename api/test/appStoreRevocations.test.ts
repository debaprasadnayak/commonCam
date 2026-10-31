import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { appStoreServerApi, AppStoreUnavailable } from "../src/appStoreServerApi";
import worker, { type Env } from "../src/index";
import { p8Key } from "./support/apnsKey";
import { signTransaction } from "./support/fakeAppStore";

const PARTY = "app.commoncam.tier.party";
let nextTransactionId = 5_000_000_000;

function api(path: string, init: RequestInit & { token?: string } = {}, workerEnv?: Env) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  const request = new Request(`https://api.test${path}`, { ...init, headers });
  return workerEnv ? worker.fetch(request, workerEnv) : exports.default.fetch(request);
}

function transaction(overrides: Record<string, unknown> = {}) {
  const id = String(nextTransactionId++);
  return {
    transactionId: id,
    originalTransactionId: id,
    bundleId: "app.commoncam.CommonCam",
    productId: PARTY,
    purchaseDate: Date.now(),
    signedDate: Date.now(),
    type: "Consumable",
    environment: "Sandbox",
    price: 9990,
    currency: "USD",
    ...overrides,
  };
}

async function signed(payload: object, leafKey = env.TEST_APPLE_PKI.leafKey) {
  const key = await crypto.subtle.importKey("jwk", leafKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return signTransaction(payload, env.TEST_APPLE_PKI.chain, key);
}

/** An App Store Server Notification V2 about `tx`, as Apple POSTs it. */
async function notification(type: string, tx: ReturnType<typeof transaction>, signedDate: number, extra: Record<string, unknown> = {}) {
  const revoked = type === "REFUND_REVERSED" ? tx : { ...tx, revocationDate: signedDate, revocationReason: 0 };
  return JSON.stringify({
    signedPayload: await signed({
      notificationType: type,
      notificationUUID: crypto.randomUUID(),
      version: "2.0",
      signedDate,
      data: { bundleId: "app.commoncam.CommonCam", environment: tx.environment, signedTransactionInfo: await signed(revoked) },
      ...extra,
    }),
  });
}

function notify(body: string) {
  return api("/app-store/notifications", { method: "POST", body });
}

async function buyParty(tx: ReturnType<typeof transaction>, workerEnv?: Env) {
  const body = JSON.stringify({ tier: "party", signedTransaction: await signed(tx) });
  return api("/groups", { method: "POST", token: `host-${crypto.randomUUID()}`, body }, workerEnv);
}

describe("POST /app-store/notifications", () => {
  it("a refund notified before redemption stops the original transaction activating a group", async () => {
    const tx = transaction();
    expect((await notify(await notification("REFUND", tx, Date.now()))).status).toBe(200);

    expect((await buyParty(tx)).status).toBe(403);
  });

  it("a revoke (Family Sharing) likewise blocks an add-on for an existing group", async () => {
    const host = `host-${crypto.randomUUID()}`;
    const group = await (
      await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "party", signedTransaction: await signed(transaction()) }) })
    ).json<any>();
    const addOn = transaction({ productId: "app.commoncam.addon.storage", price: 2490, appAccountToken: group.id });
    expect((await notify(await notification("REVOKE", addOn, Date.now()))).status).toBe(200);

    const res = await api(`/groups/${group.id}/purchases`, {
      method: "POST",
      token: host,
      body: JSON.stringify({ signedTransaction: await signed(addOn) }),
    });
    expect(res.status).toBe(403);
  });

  it("accepts duplicate deliveries of the same notification", async () => {
    const tx = transaction();
    const body = await notification("REFUND", tx, Date.now());

    expect((await notify(body)).status).toBe(200);
    expect((await notify(body)).status).toBe(200);
    expect((await buyParty(tx)).status).toBe(403);
  });

  it("keeps the newest state when a refund and its reversal arrive out of order", async () => {
    const reversedLast = transaction();
    await notify(await notification("REFUND_REVERSED", reversedLast, Date.now() - 1000));
    await notify(await notification("REFUND", reversedLast, Date.now() - 2000));
    expect((await buyParty(reversedLast)).status).toBe(201);

    const refundedLast = transaction();
    await notify(await notification("REFUND", refundedLast, Date.now() - 1000));
    await notify(await notification("REFUND_REVERSED", refundedLast, Date.now() - 2000));
    expect((await buyParty(refundedLast)).status).toBe(403);
  });

  it("ignores other notification types and refuses forged or malformed ones", async () => {
    const tx = transaction();
    expect((await notify(await notification("CONSUMPTION_REQUEST", tx, Date.now()))).status).toBe(200);
    const forger = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])) as CryptoKeyPair;
    const forged = JSON.stringify({
      signedPayload: await signed(
        { notificationType: "REFUND", signedDate: Date.now(), data: { bundleId: "app.commoncam.CommonCam", environment: "Sandbox", signedTransactionInfo: await signed(tx) } },
        await crypto.subtle.exportKey("jwk", forger.privateKey),
      ),
    });

    expect((await notify(forged)).status).toBe(403);
    expect((await notify("{}")).status).toBe(400);
    expect((await buyParty(tx)).status).toBe(201);
  });

  it("still activates a valid purchase once, and refuses its replay", async () => {
    const tx = transaction();
    expect((await buyParty(tx)).status).toBe(201);
    expect((await buyParty(tx)).status).toBe(409);
  });
});

describe("current transaction state from the App Store Server API", () => {
  afterEach(() => vi.restoreAllMocks());

  async function configured(overrides: Partial<Env> = {}): Promise<Env> {
    return { ...env, APPSTORE_ISSUER_ID: "issuer-1", APPSTORE_KEY_ID: "KEY1", APPSTORE_PRIVATE_KEY: (await p8Key()).pem, ...overrides };
  }

  /** Apple's Get Transaction Info answers with `tx` as it is now. */
  function appleReturns(tx: object | null, status = 200) {
    return vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = new URL(input instanceof Request ? input.url : String(input));
      if (!url.hostname.startsWith("api.storekit")) throw new Error(`unexpected fetch ${url}`);
      return tx ? Response.json({ signedTransactionInfo: await signed(tx) }, { status }) : new Response("", { status });
    });
  }

  it("refuses a transaction Apple now reports as refunded, though the submitted copy is not", async () => {
    const tx = transaction();
    const fetchSpy = appleReturns({ ...tx, revocationDate: Date.now(), revocationReason: 1 });

    expect((await buyParty(tx, await configured())).status).toBe(403);
    const [request] = fetchSpy.mock.calls[0];
    expect(String(request instanceof Request ? request.url : request)).toBe(
      `https://api.storekit-sandbox.itunes.apple.com/inApps/v1/transactions/${tx.transactionId}`,
    );
  });

  it("activates a transaction Apple reports as current", async () => {
    const tx = transaction();
    appleReturns(tx);

    expect((await buyParty(tx, await configured())).status).toBe(201);
  });

  it("in Production refuses with 503 (purchase stays unfinished, retried later) when Apple can't be asked", async () => {
    const tx = transaction({ environment: "Production" });
    appleReturns(null, 500);

    const unreachable = await buyParty(tx, await configured({ APP_STORE_ENV: "Production" }));
    expect(unreachable.status).toBe(503);
    expect(unreachable.headers.get("Retry-After")).toBeTruthy();
    const unconfigured = await buyParty(tx, { ...env, APP_STORE_ENV: "Production" });
    expect(unconfigured.status).toBe(503);

    appleReturns({ ...tx });
    expect((await buyParty(tx, await configured({ APP_STORE_ENV: "Production" }))).status).toBe(201);
  });

  it("in Sandbox allows the purchase with a log line when Apple can't be asked", async () => {
    appleReturns(null, 500);
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    expect((await buyParty(transaction(), await configured())).status).toBe(201);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("App Store Server API unavailable"));
  });
});

describe("App Store Server API client", () => {
  it("asks for the transaction with an ES256 JWT for the app, and reads the verified state", async () => {
    const { pem, publicKey } = await p8Key();
    const tx = transaction({ revocationDate: 1 });
    const requests: Request[] = [];
    const client = appStoreServerApi(
      { issuerId: "issuer-1", keyId: "KEY1", privateKey: pem, bundleId: "app.commoncam.CommonCam", environment: "Sandbox", rootCertB64: env.APPLE_ROOT_CA_G3 },
      (async (input: RequestInfo, init?: RequestInit) => {
        requests.push(new Request(input, init));
        return Response.json({ signedTransactionInfo: await signed(tx) });
      }) as typeof fetch,
    );

    expect(await client.isRevoked(tx.transactionId)).toBe(true);

    const [scheme, jwt] = requests[0].headers.get("Authorization")!.split(" ");
    expect(scheme).toBe("Bearer");
    const [header, claims, signature] = jwt.split(".").map((part) => Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)));
    expect(JSON.parse(new TextDecoder().decode(header))).toEqual({ alg: "ES256", kid: "KEY1", typ: "JWT" });
    expect(JSON.parse(new TextDecoder().decode(claims))).toMatchObject({ iss: "issuer-1", aud: "appstoreconnect-v1", bid: "app.commoncam.CommonCam" });
    const signingInput = new TextEncoder().encode(jwt.split(".").slice(0, 2).join("."));
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, signature, signingInput)).toBe(true);
  });

  it("treats errors and unverifiable answers as unavailable", async () => {
    const { pem } = await p8Key();
    const config = { issuerId: "i", keyId: "k", privateKey: pem, bundleId: "app.commoncam.CommonCam", environment: "Sandbox", rootCertB64: env.APPLE_ROOT_CA_G3 };
    const answering = (response: () => Response) => appStoreServerApi(config, (async () => response()) as typeof fetch);

    await expect(answering(() => new Response("", { status: 401 })).isRevoked("1")).rejects.toBeInstanceOf(AppStoreUnavailable);
    await expect(answering(() => Response.json({ signedTransactionInfo: "forged" })).isRevoked("1")).rejects.toBeInstanceOf(AppStoreUnavailable);
  });
});
