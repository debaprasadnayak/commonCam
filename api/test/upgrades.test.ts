import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { signTransaction } from "./support/fakeAppStore";

const DAY_MS = 24 * 60 * 60 * 1000;
const GB = 1_073_741_824;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers });
}

let nextTransactionId = 3_000_000_000;

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

async function signed(payload: object) {
  const pki = env.TEST_APPLE_PKI;
  const key = await crypto.subtle.importKey("jwk", pki.leafKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return signTransaction(payload, pki.chain, key);
}

const TIER_PRICES = { pocket: 4990, party: 9990, festival: 24990 } as const;

async function paidGroup(tier: keyof typeof TIER_PRICES, host = `host-${crypto.randomUUID()}`) {
  const jws = await signed(transaction({ productId: `app.commoncam.tier.${tier}`, price: TIER_PRICES[tier] }));
  const res = await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier, signedTransaction: jws }) });
  expect(res.status).toBe(201);
  return { host, group: await res.json<any>() };
}

async function tasterGroup(host = `host-${crypto.randomUUID()}`) {
  const res = await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) });
  return { host, group: await res.json<any>() };
}

function purchase(caller: string, groupId: string, signedTransaction: unknown) {
  return api(`/groups/${groupId}/purchases`, { method: "POST", token: caller, body: JSON.stringify({ signedTransaction }) });
}

/** A signed upgrade/add-on bound to the group via StoreKit's appAccountToken, as the app sends it. */
async function forGroup(groupId: string, productId: string, price: number, overrides: Record<string, unknown> = {}) {
  return signed(transaction({ productId, price, appAccountToken: groupId, ...overrides }));
}

function orderFor(transactionId: string) {
  return env.DB.prepare("SELECT * FROM orders WHERE apple_transaction_id = ?").bind(transactionId).first<any>();
}

describe("upgrading a group mid-event", () => {
  it("moves a Pocket group to Party limits for the difference and records the credit applied", async () => {
    const { host, group } = await paidGroup("pocket");
    const tx = transaction({ productId: "app.commoncam.upgrade.pocket.party", price: 5000, appAccountToken: group.id });

    const res = await purchase(host, group.id, await signed(tx));

    expect(res.status).toBe(200);
    const upgraded = await res.json<any>();
    expect(upgraded).toMatchObject({ id: group.id, tier: "party", peopleCap: 25, storageCapBytes: 25 * GB });
    expect(upgraded.startsAt).toBe(group.startsAt);
    expect(Date.parse(upgraded.endsAt) - Date.parse(upgraded.startsAt)).toBe(5 * DAY_MS);
    expect(await orderFor(tx.transactionId)).toMatchObject({
      group_id: group.id,
      sku: "app.commoncam.upgrade.pocket.party",
      amount_milliunits: 5000,
      credit_applied: 4990,
    });
  });
});

describe("upgrade credit", () => {
  it("upgrades a free Taster for the full Pocket price with no credit", async () => {
    const { host, group } = await tasterGroup();
    const tx = transaction({ productId: "app.commoncam.upgrade.taster.pocket", price: 4990, appAccountToken: group.id });

    const res = await purchase(host, group.id, await signed(tx));

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ tier: "pocket", peopleCap: 10, storageCapBytes: 5 * GB });
    expect(await orderFor(tx.transactionId)).toMatchObject({ amount_milliunits: 4990, credit_applied: 0 });
  });

  it("credits everything already paid towards the tier, but not add-ons", async () => {
    const { host, group } = await paidGroup("pocket");
    await purchase(host, group.id, await forGroup(group.id, "app.commoncam.upgrade.pocket.party", 5000));
    await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.day", 1990));
    const tx = transaction({ productId: "app.commoncam.upgrade.party.festival", price: 15000, appAccountToken: group.id });

    const res = await purchase(host, group.id, await signed(tx));

    expect(res.status).toBe(200);
    expect((await orderFor(tx.transactionId)).credit_applied).toBe(9990);
  });

  it("keeps earlier add-ons on top of the new tier's limits", async () => {
    const { host, group } = await paidGroup("party");
    await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.people", 1990));

    const res = await purchase(host, group.id, await forGroup(group.id, "app.commoncam.upgrade.party.festival", 15000));

    expect((await res.json<any>()).peopleCap).toBe(85);
  });

  it("refuses an upgrade product for a tier the group is not on", async () => {
    const { host, group } = await paidGroup("party");

    const res = await purchase(host, group.id, await forGroup(group.id, "app.commoncam.upgrade.pocket.festival", 20000));

    expect(res.status).toBe(400);
    expect(await (await api("/groups", { token: host })).json()).toMatchObject([{ tier: "party", peopleCap: 25 }]);
  });

  it("does not recognise downgrades", async () => {
    const { host, group } = await paidGroup("festival");
    expect((await purchase(host, group.id, await forGroup(group.id, "app.commoncam.upgrade.festival.party", 1))).status).toBe(400);
  });
});

describe("add-ons", () => {
  it.each([
    ["day", { peopleCap: 25, storageCapBytes: 25 * GB }, 6],
    ["storage", { peopleCap: 25, storageCapBytes: 35 * GB }, 5],
    ["people", { peopleCap: 35, storageCapBytes: 25 * GB }, 5],
  ])("+%s raises only its own limit", async (addOn, limits, days) => {
    const { host, group } = await paidGroup("party");
    const tx = transaction({ productId: `app.commoncam.addon.${addOn}`, price: 1990, appAccountToken: group.id });

    const res = await purchase(host, group.id, await signed(tx));

    expect(res.status).toBe(200);
    const raised = await res.json<any>();
    expect(raised).toMatchObject({ tier: "party", ...limits });
    expect(Date.parse(raised.endsAt) - Date.parse(raised.startsAt)).toBe(days * DAY_MS);
    expect(await orderFor(tx.transactionId)).toMatchObject({ sku: `app.commoncam.addon.${addOn}`, credit_applied: 0 });
  });

  it("stack when bought more than once", async () => {
    const { host, group } = await paidGroup("pocket");
    await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.storage", 1990));

    const res = await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.storage", 1990));

    expect((await res.json<any>()).storageCapBytes).toBe(25 * GB);
  });

  it("are not sold for a free Taster group", async () => {
    const { host, group } = await tasterGroup();
    expect((await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.people", 1990))).status).toBe(400);
  });

  it("take effect immediately: a +10 people add-on lets a full group admit more guests", async () => {
    const { host, group } = await paidGroup("pocket");
    const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: host })).json<any>();
    const join = (guest: string) =>
      api("/join", {
        method: "POST",
        token: guest,
        body: JSON.stringify({ qrToken, displayName: "Dancing Otter", colour: "#FF8800", consent: true }),
      });
    for (let i = 0; i < 9; i++) expect((await join(`guest-${group.id}-${i}`)).status).toBe(201);
    expect((await join(`guest-${group.id}-late`)).status).toBe(409);

    await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.people", 1990));

    expect((await join(`guest-${group.id}-late`)).status).toBe(201);
  });
});

describe("purchases are validated", () => {
  it("rejects a replayed transaction and raises limits only once", async () => {
    const { host, group } = await paidGroup("party");
    const jws = await forGroup(group.id, "app.commoncam.addon.people", 1990);
    await purchase(host, group.id, jws);

    const res = await purchase(host, group.id, jws);

    expect(res.status).toBe(409);
    expect(await (await api("/groups", { token: host })).json()).toMatchObject([{ peopleCap: 35 }]);
  });

  it("rejects a transaction that already activated a group", async () => {
    const { host, group } = await paidGroup("party");
    const tierTx = transaction({ productId: "app.commoncam.tier.party", appAccountToken: group.id });
    await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "party", signedTransaction: await signed(tierTx) }) });
    const reused = await signed({ ...tierTx, productId: "app.commoncam.addon.people" });

    expect((await purchase(host, group.id, reused)).status).toBe(409);
  });

  it("rejects a transaction bought for another group", async () => {
    const { host, group } = await paidGroup("party");
    const other = await paidGroup("party", host);
    const jws = await forGroup(other.group.id, "app.commoncam.addon.day", 1990);

    expect((await purchase(host, group.id, jws)).status).toBe(400);
  });

  it("rejects products that are neither upgrades nor add-ons", async () => {
    const { host, group } = await paidGroup("party");
    expect((await purchase(host, group.id, await forGroup(group.id, "app.commoncam.tier.festival", 24990))).status).toBe(400);
  });

  it("rejects forged transactions and missing ones", async () => {
    const { host, group } = await paidGroup("party");
    expect((await purchase(host, group.id, "not-a-jws")).status).toBe(403);
    expect((await purchase(host, group.id, undefined)).status).toBe(400);
  });

  it("refuses groups that have ended", async () => {
    const { host, group } = await paidGroup("party");
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(Date.now() - 1000).toISOString(), group.id).run();

    expect((await purchase(host, group.id, await forGroup(group.id, "app.commoncam.addon.day", 1990))).status).toBe(410);
  });
});

describe("who may buy", () => {
  async function joinedGuest(host: string, groupId: string) {
    const guest = `guest-${crypto.randomUUID()}`;
    const { qrToken } = await (await api(`/groups/${groupId}/invite`, { token: host })).json<any>();
    const res = await api("/join", {
      method: "POST",
      token: guest,
      body: JSON.stringify({ qrToken, displayName: "Dancing Otter", colour: "#FF8800", consent: true }),
    });
    return { guest, memberId: (await res.json<any>()).member.id };
  }

  it("lets an active co-host buy an add-on", async () => {
    const { host, group } = await paidGroup("party");
    const { guest, memberId } = await joinedGuest(host, group.id);
    await api(`/groups/${group.id}/members/${memberId}/co-host`, { method: "POST", token: host });

    expect((await purchase(guest, group.id, await forGroup(group.id, "app.commoncam.addon.day", 1990))).status).toBe(200);
  });

  it("hides the endpoint from plain guests and outsiders", async () => {
    const { host, group } = await paidGroup("party");
    const { guest } = await joinedGuest(host, group.id);

    expect((await purchase(guest, group.id, await forGroup(group.id, "app.commoncam.addon.day", 1990))).status).toBe(404);
    expect((await purchase("outsider", group.id, await forGroup(group.id, "app.commoncam.addon.day", 1990))).status).toBe(404);
  });
});
