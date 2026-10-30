import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  b64url,
  chainOf,
  createCert,
  createFakeAppStore,
  markers,
  signTransaction,
  trustedIssuer,
} from "./support/fakeAppStore";

const DAY_MS = 24 * 60 * 60 * 1000;
const GB = 1_073_741_824;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers });
}

let nextTransactionId = 2_000_000_000;

function transaction(overrides: Record<string, unknown> = {}) {
  const id = String(nextTransactionId++);
  return {
    transactionId: id,
    originalTransactionId: id,
    bundleId: "app.commoncam.CommonCam",
    productId: "app.commoncam.tier.party",
    purchaseDate: Date.now(),
    signedDate: Date.now(),
    type: "Consumable",
    environment: "Sandbox",
    price: 9990,
    currency: "USD",
    ...overrides,
  };
}

async function signedByTestApple(payload: object) {
  const pki = env.TEST_APPLE_PKI;
  const key = await crypto.subtle.importKey("jwk", pki.leafKey, { name: "ECDSA", namedCurve: "P-256" }, false, [
    "sign",
  ]);
  return signTransaction(payload, pki.chain, key);
}

function buy(tier: string, signedTransaction: string, token = `host-${crypto.randomUUID()}`) {
  return api("/groups", { method: "POST", token, body: JSON.stringify({ tier, signedTransaction }) });
}

describe("POST /groups with a paid tier", () => {
  it("activates a Party group with Party limits from a valid App Store transaction", async () => {
    const res = await buy("party", await signedByTestApple(transaction()));

    expect(res.status).toBe(201);
    const group = await res.json<any>();
    expect(group).toMatchObject({ tier: "party", state: "Active", peopleCap: 25, storageCapBytes: 25 * GB });
    expect(Date.parse(group.endsAt) - Date.parse(group.startsAt)).toBe(5 * DAY_MS);
  });

  it.each([
    ["pocket", 10, 2, 5],
    ["festival", 75, 10, 100],
  ])("activates %s with its own limits", async (tier, people, days, gb) => {
    const res = await buy(tier, await signedByTestApple(transaction({ productId: `app.commoncam.tier.${tier}` })));

    expect(res.status).toBe(201);
    const group = await res.json<any>();
    expect(group).toMatchObject({ tier, peopleCap: people, storageCapBytes: gb * GB });
    expect(Date.parse(group.endsAt) - Date.parse(group.startsAt)).toBe(days * DAY_MS);
  });

  it("lists the paid group among the host's groups", async () => {
    const token = `host-${crypto.randomUUID()}`;
    const created = await (await buy("party", await signedByTestApple(transaction()), token)).json();

    expect(await (await api("/groups", { token })).json()).toEqual([created]);
  });

  it("records the order against the group", async () => {
    const tx = transaction();
    const group = await (await buy("party", await signedByTestApple(tx))).json<any>();

    const order = await env.DB.prepare("SELECT * FROM orders WHERE apple_transaction_id = ?").bind(tx.transactionId).first();
    expect(order).toMatchObject({
      group_id: group.id,
      sku: "app.commoncam.tier.party",
      amount_milliunits: 9990,
      currency: "USD",
      credit_applied: 0,
    });
  });

  it("rejects a replayed transaction and creates no second group", async () => {
    const jws = await signedByTestApple(transaction());
    await buy("party", jws);

    const thief = `host-${crypto.randomUUID()}`;
    const res = await buy("party", jws, thief);

    expect(res.status).toBe(409);
    expect(await (await api("/groups", { token: thief })).json()).toEqual([]);
  });

  it("rejects a transaction for a different tier than requested", async () => {
    const res = await buy("festival", await signedByTestApple(transaction({ productId: "app.commoncam.tier.pocket" })));
    expect(res.status).toBe(400);
  });

  it("requires a signed transaction", async () => {
    const res = await api("/groups", { method: "POST", token: "t", body: JSON.stringify({ tier: "party" }) });
    expect(res.status).toBe(400);
  });

  describe("rejects forged transactions", () => {
    it("signed by a chain that does not end in the trusted root", async () => {
      const forger = await createFakeAppStore();
      const jws = await signTransaction(
        transaction(),
        chainOf(forger.leaf, forger.intermediate, forger.root),
        forger.leaf.keys.privateKey,
      );
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("whose leaf was not issued by the trusted intermediate", async () => {
      const forger = await createFakeAppStore();
      const [, trustedIntermediate, trustedRoot] = env.TEST_APPLE_PKI.chain;
      const jws = await signTransaction(
        transaction(),
        [chainOf(forger.leaf)[0], trustedIntermediate, trustedRoot],
        forger.leaf.keys.privateKey,
      );
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("whose intermediate was not issued by the trusted root", async () => {
      const forger = await createFakeAppStore();
      const [, , trustedRoot] = env.TEST_APPLE_PKI.chain;
      const jws = await signTransaction(
        transaction(),
        [...chainOf(forger.leaf, forger.intermediate), trustedRoot],
        forger.leaf.keys.privateKey,
      );
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("whose intermediate lacks Apple's intermediate marker", async () => {
      const root = await trustedIssuer(env.TEST_APPLE_PKI, "root");
      const unmarkedIntermediate = await createCert({ name: "Some CA", curve: "P-384", issuer: root });
      const leaf = await createCert({ name: "Leaf", curve: "P-256", issuer: unmarkedIntermediate, marker: markers.leaf });
      const jws = await signTransaction(transaction(), chainOf(leaf, unmarkedIntermediate, root), leaf.keys.privateKey);
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("whose payload was altered after signing", async () => {
      const [header, , signature] = (await signedByTestApple(transaction({ productId: "app.commoncam.tier.pocket" }))).split(".");
      const upgraded = b64url(new TextEncoder().encode(JSON.stringify(transaction())));
      expect((await buy("party", `${header}.${upgraded}.${signature}`)).status).toBe(403);
    });

    it("signed by a certificate without Apple's App Store marker", async () => {
      const unmarkedLeaf = await createCert({
        name: "Some leaf",
        curve: "P-256",
        issuer: await trustedIssuer(env.TEST_APPLE_PKI, "intermediate"),
      });
      const [, intermediate, root] = env.TEST_APPLE_PKI.chain;
      const jws = await signTransaction(
        transaction(),
        [chainOf(unmarkedLeaf)[0], intermediate, root],
        unmarkedLeaf.keys.privateKey,
      );
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("signed by an expired certificate", async () => {
      const expiredLeaf = await createCert({
        name: "Expired leaf",
        curve: "P-256",
        issuer: await trustedIssuer(env.TEST_APPLE_PKI, "intermediate"),
        marker: markers.leaf,
        notBefore: new Date(Date.now() - 10 * DAY_MS),
        notAfter: new Date(Date.now() - DAY_MS),
      });
      const [, intermediate, root] = env.TEST_APPLE_PKI.chain;
      const jws = await signTransaction(transaction(), [chainOf(expiredLeaf)[0], intermediate, root], expiredLeaf.keys.privateKey);
      expect((await buy("party", jws)).status).toBe(403);
    });

    it("for another app", async () => {
      const res = await buy("party", await signedByTestApple(transaction({ bundleId: "com.example.other" })));
      expect(res.status).toBe(403);
    });

    it("that Apple has revoked (refunded)", async () => {
      const res = await buy("party", await signedByTestApple(transaction({ revocationDate: Date.now() })));
      expect(res.status).toBe(403);
    });

    it("that is not a JWS at all", async () => {
      expect((await buy("party", "not-a-jws")).status).toBe(403);
    });
  });
});

describe("free Taster groups", () => {
  it("are limited to one per device", async () => {
    const token = `host-${crypto.randomUUID()}`;
    const taster = () => api("/groups", { method: "POST", token, body: JSON.stringify({ tier: "taster" }) });

    expect((await taster()).status).toBe(201);
    expect((await taster()).status).toBe(403);
    expect(await (await api("/groups", { token })).json()).toHaveLength(1);
  });

  it("do not count against other devices", async () => {
    await api("/groups", { method: "POST", token: `host-${crypto.randomUUID()}`, body: JSON.stringify({ tier: "taster" }) });

    const res = await api("/groups", { method: "POST", token: `host-${crypto.randomUUID()}`, body: JSON.stringify({ tier: "taster" }) });
    expect(res.status).toBe(201);
  });

  it("do not block buying a paid tier", async () => {
    const token = `host-${crypto.randomUUID()}`;
    await api("/groups", { method: "POST", token, body: JSON.stringify({ tier: "taster" }) });

    expect((await buy("party", await signedByTestApple(transaction()), token)).status).toBe(201);
  });
});
