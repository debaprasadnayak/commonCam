import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { syncStorageWarnings, type Push } from "../src/push";
import { signTransaction } from "./support/fakeAppStore";

const DAY_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

// Pushes the real APNs sender posted; tests stub Apple's reply with `apnsReply`.
let sent: Push[];
let apnsReply: () => Response;
beforeEach(() => {
  sent = [];
  apnsReply = () => new Response(null, { status: 200 });
  const realFetch = globalThis.fetch;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.host !== "api.sandbox.push.apple.com") return realFetch(input, init);
    const body = await request.json<{ aps: { alert: { title: string; body: string } }; groupId: string; kind: Push["kind"] }>();
    sent.push({ deviceToken: url.pathname.split("/").pop()!, groupId: body.groupId, kind: body.kind, ...body.aps.alert });
    return apnsReply();
  });
});
afterEach(() => vi.restoreAllMocks());

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function cronAt(at: number) {
  await exports.default.scheduled({ scheduledTime: new Date(at), cron: "0 * * * *" });
}

function registerPush(token: string, apnsToken: string) {
  return api("/devices/push-token", { method: "PUT", token, body: JSON.stringify({ token: apnsToken }) });
}

let nextTransactionId = 4_000_000_000;
async function signed(productId: string, appAccountToken?: string) {
  const id = String(nextTransactionId++);
  const pki = env.TEST_APPLE_PKI;
  const key = await crypto.subtle.importKey("jwk", pki.leafKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const payload = {
    transactionId: id,
    originalTransactionId: id,
    bundleId: "app.commoncam.CommonCam",
    productId,
    purchaseDate: Date.now(),
    signedDate: Date.now(),
    type: "Consumable",
    environment: "Sandbox",
    price: 2990,
    currency: "USD",
    appAccountToken,
  };
  return signTransaction(payload, pki.chain, key);
}

async function newPartyGroup(host: string) {
  const signedTransaction = await signed("app.commoncam.tier.party");
  return (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "party", signedTransaction }) })).json<any>();
}

async function join(token: string, groupId: string, host: string) {
  const { qrToken } = await (await api(`/groups/${groupId}/invite`, { token: host })).json<any>();
  const res = await api("/join", {
    method: "POST",
    token,
    body: JSON.stringify({ qrToken, displayName: "Guest", colour: "#FF8800", consent: true }),
  });
  return (await res.json<any>()).member;
}

async function share(token: string, groupId: string, size: number) {
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes: size, contentType: "image/heic" }) })
  ).json<any>();
  await api(ticket.uploadUrl, { method: "PUT", body: new Uint8Array(size).fill(7) });
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId: ticket.itemId }) });
}

/** Moves the group's paid period end to `endsAt` (tests don't wait days). */
async function endAt(groupId: string, endsAt: number) {
  await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(endsAt).toISOString(), groupId).run();
}

const sentTo = (apnsToken: string) => sent.filter((p) => p.deviceToken === apnsToken).map((p) => p.kind);

describe("PUT /devices/push-token", () => {
  it("rejects a missing or malformed APNs token", async () => {
    expect((await registerPush("dev-bad", "")).status).toBe(400);
    expect((await registerPush("dev-bad", "not hex!")).status).toBe(400);
    expect((await api("/devices/push-token", { method: "PUT", token: "dev-bad", body: "{" })).status).toBe(400);
  });

  it("ties tokens to the caller's device identity (204); one identity may have several phones", async () => {
    expect((await registerPush("dev-reg", "aa".repeat(32))).status).toBe(204);
    expect((await registerPush("dev-reg", "BB".repeat(32))).status).toBe(204);
    expect((await registerPush("dev-reg", "bb".repeat(32))).status).toBe(204);
    // A phone whose identity changed (new token in the Keychain) moves its APNs token along.
    expect((await registerPush("dev-other", "cc".repeat(32))).status).toBe(204);
    expect((await registerPush("dev-reg", "cc".repeat(32))).status).toBe(204);
    const group = await newPartyGroup("dev-reg");
    await endAt(group.id, Date.now() - HOUR_MS);
    await cronAt(Date.now());
    expect(sentTo("aa".repeat(32))).toEqual(["expired"]);
    expect(sentTo("bb".repeat(32))).toEqual(["expired"]);
    expect(sentTo("cc".repeat(32))).toEqual(["expired"]);
    expect(sent).toHaveLength(3);
  });

  it("needs a device token", async () => {
    expect((await api("/devices/push-token", { method: "PUT", body: JSON.stringify({ token: "aa".repeat(32) }) })).status).toBe(401);
  });
});

describe("grace reminders (SPEC.md section 9)", () => {
  it("at expiry, 7 days and 1 day before deletion: each exactly once, to the host and active members", async () => {
    const [hostToken, guestToken, removedToken] = ["01".repeat(32), "02".repeat(32), "03".repeat(32)];
    const group = await newPartyGroup("dev-host-r");
    await registerPush("dev-host-r", hostToken);
    await join("dev-guest-r", group.id, "dev-host-r");
    await registerPush("dev-guest-r", guestToken);
    await join("dev-silent-r", group.id, "dev-host-r"); // never granted push permission: simply skipped
    const removed = await join("dev-removed-r", group.id, "dev-host-r");
    await registerPush("dev-removed-r", removedToken);
    await api(`/groups/${group.id}/members/${removed.id}/remove`, { method: "POST", token: "dev-host-r" });

    const ended = Date.now() - HOUR_MS;
    await endAt(group.id, ended);
    await cronAt(ended + HOUR_MS); // enters Grace (14 days)
    await cronAt(ended + 2 * HOUR_MS);
    expect(sentTo(hostToken)).toEqual(["expired"]);
    expect(sentTo(guestToken)).toEqual(["expired"]);

    await cronAt(ended + 7 * DAY_MS - HOUR_MS);
    expect(sentTo(hostToken)).toEqual(["expired"]);
    await cronAt(ended + 7 * DAY_MS);
    await cronAt(ended + 7 * DAY_MS + HOUR_MS);
    expect(sentTo(hostToken)).toEqual(["expired", "grace7Days"]);

    await cronAt(ended + 13 * DAY_MS);
    await cronAt(ended + 13 * DAY_MS + HOUR_MS);
    expect(sentTo(hostToken)).toEqual(["expired", "grace7Days", "grace1Day"]);
    expect(sentTo(guestToken)).toEqual(["expired", "grace7Days", "grace1Day"]);
    expect(sentTo(removedToken)).toEqual([]);
    const mine = sent.filter((p) => p.deviceToken === hostToken);
    expect(mine.every((p) => p.groupId === group.id && p.title.length > 0 && p.body.length > 0)).toBe(true);

    await cronAt(ended + 14 * DAY_MS); // deleted, along with its notification records
    expect(await env.DB.prepare("SELECT state FROM groups WHERE id = ?").bind(group.id).first("state")).toBe("Deleted");
    const { results } = await env.DB.prepare("SELECT 1 FROM notifications_sent WHERE group_id = ?").bind(group.id).all();
    expect(results).toEqual([]);
    expect(sentTo(hostToken)).toHaveLength(3);
  });

  it("only the most urgent reminder when several are due at once (cron missed runs)", async () => {
    const token = "04".repeat(32);
    const group = await newPartyGroup("dev-late");
    await registerPush("dev-late", token);
    const ended = Date.now() - HOUR_MS;
    await endAt(group.id, ended);
    await cronAt(ended + 10 * DAY_MS);
    expect(sentTo(token)).toEqual(["grace7Days"]);
  });

  it("fires again after a paid extension once the group expires a second time", async () => {
    const token = "05".repeat(32);
    const group = await newPartyGroup("dev-ext");
    await registerPush("dev-ext", token);
    await endAt(group.id, Date.now() - HOUR_MS);
    await cronAt(Date.now());
    const res = await api(`/groups/${group.id}/extend`, {
      method: "POST",
      token: "dev-ext",
      body: JSON.stringify({ signedTransaction: await signed("app.commoncam.extension", group.id) }),
    });
    expect(res.status).toBe(200);
    await endAt(group.id, Date.now() - HOUR_MS);
    await cronAt(Date.now());
    expect(sentTo(token)).toEqual(["expired", "expired"]);
  });

  it("a failing push does not stop the lifecycle job", async () => {
    apnsReply = () => new Response('{"reason":"InternalServerError"}', { status: 500 });
    const group = await newPartyGroup("dev-fail");
    await registerPush("dev-fail", "06".repeat(32));
    await endAt(group.id, Date.now() - HOUR_MS);
    await cronAt(Date.now());
    expect(await env.DB.prepare("SELECT state FROM groups WHERE id = ?").bind(group.id).first("state")).toBe("Grace");
  });
});

describe("storage warnings (SPEC.md section 8)", () => {
  const GB = 1024 ** 3;

  async function fillTo(groupId: string, usedBytes: number) {
    await env.DB.prepare("UPDATE groups SET storage_used_bytes = ? WHERE id = ?").bind(usedBytes, groupId).run();
  }

  it("pushes to host and co-hosts (not guests) once when crossing into nearlyFull and into full", async () => {
    const [hostToken, coHostToken, guestToken] = ["11".repeat(32), "12".repeat(32), "13".repeat(32)];
    const group = await newPartyGroup("dev-host-s");
    await registerPush("dev-host-s", hostToken);
    const coHost = await join("dev-cohost-s", group.id, "dev-host-s");
    await api(`/groups/${group.id}/members/${coHost.id}/co-host`, { method: "POST", token: "dev-host-s" });
    await registerPush("dev-cohost-s", coHostToken);
    await join("dev-guest-s", group.id, "dev-host-s");
    await registerPush("dev-guest-s", guestToken);

    const cap = 25 * GB;
    await fillTo(group.id, cap * 0.8 - 20);
    expect((await share("dev-guest-s", group.id, 10)).status).toBe(201); // still ok
    expect(sent).toEqual([]);
    expect((await share("dev-guest-s", group.id, 10)).status).toBe(201); // exactly 80%
    expect((await share("dev-guest-s", group.id, 10)).status).toBe(201);
    expect(sentTo(hostToken)).toEqual(["storageNearlyFull"]);
    expect(sentTo(coHostToken)).toEqual(["storageNearlyFull"]);
    expect(sentTo(guestToken)).toEqual([]);

    await fillTo(group.id, cap - 10);
    expect((await share("dev-guest-s", group.id, 10)).status).toBe(201);
    expect(sentTo(hostToken)).toEqual(["storageNearlyFull", "storageFull"]);
    expect(sentTo(coHostToken)).toEqual(["storageNearlyFull", "storageFull"]);
  });

  it("re-arms after an upgrade brings the level back down", async () => {
    const token = "14".repeat(32);
    const group = await newPartyGroup("dev-up");
    await registerPush("dev-up", token);
    await fillTo(group.id, 25 * GB - 10);
    expect((await share("dev-up", group.id, 10)).status).toBe(201);
    expect(sentTo(token)).toEqual(["storageFull"]);

    const upgrade = await api(`/groups/${group.id}/purchases`, {
      method: "POST",
      token: "dev-up",
      body: JSON.stringify({ signedTransaction: await signed("app.commoncam.upgrade.party.festival", group.id) }),
    });
    expect(upgrade.status).toBe(200);
    expect((await upgrade.json<any>()).storageLevel).toBe("ok");

    await fillTo(group.id, 100 * GB - 10);
    expect((await share("dev-up", group.id, 10)).status).toBe(201);
    expect(sentTo(token)).toEqual(["storageFull", "storageFull"]);
  });

  it("re-arms when deletions bring the level back down, without pushing on the way down", async () => {
    const token = "15".repeat(32);
    const group = await newPartyGroup("dev-del");
    await registerPush("dev-del", token);
    await fillTo(group.id, 25 * GB * 0.8 - 10);
    const item = await (await share("dev-del", group.id, 10)).json<any>();
    expect(sentTo(token)).toEqual(["storageNearlyFull"]);
    expect((await api(`/groups/${group.id}/items/${item.id}`, { method: "DELETE", token: "dev-del" })).status).toBe(204);
    expect(sentTo(token)).toEqual(["storageNearlyFull"]);
    expect((await share("dev-del", group.id, 10)).status).toBe(201);
    expect(sentTo(token)).toEqual(["storageNearlyFull", "storageNearlyFull"]);
  });

  it("treats the group as full once an upload is refused for lack of room, until more storage is bought", async () => {
    const token = "17".repeat(32);
    const group = await newPartyGroup("dev-refused");
    await registerPush("dev-refused", token);
    await fillTo(group.id, 25 * GB - 5);
    const storage = async () => (await (await api(`/groups/${group.id}/storage`, { token: "dev-refused" })).json<any>()).storageLevel;
    const requestUpload = () =>
      api(`/groups/${group.id}/uploads`, { method: "POST", token: "dev-refused", body: JSON.stringify({ bytes: 10, contentType: "image/heic" }) });
    expect(await storage()).toBe("nearlyFull");

    expect((await requestUpload()).status).toBe(413);
    expect(await storage()).toBe("full");
    expect(sentTo(token)).toEqual(["storageFull"]);
    expect((await requestUpload()).status).toBe(413);
    expect(sentTo(token)).toEqual(["storageFull"]);

    const addOn = await api(`/groups/${group.id}/purchases`, {
      method: "POST",
      token: "dev-refused",
      body: JSON.stringify({ signedTransaction: await signed("app.commoncam.addon.storage", group.id) }),
    });
    expect((await addOn.json<any>()).storageLevel).toBe("ok");
    await fillTo(group.id, 35 * GB - 5);
    expect((await requestUpload()).status).toBe(413);
    expect(sentTo(token)).toEqual(["storageFull", "storageFull"]);
  });

  it("skips quietly while APNs isn't configured", async () => {
    const group = await newPartyGroup("dev-noapns");
    await registerPush("dev-noapns", "16".repeat(32));
    await fillTo(group.id, 25 * GB);
    await syncStorageWarnings({ ...env, APNS_PRIVATE_KEY: undefined }, group.id);
    expect(sent).toEqual([]);
  });
});
