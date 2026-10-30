import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { signTransaction } from "./support/fakeAppStore";

const DAY_MS = 24 * 60 * 60 * 1000;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

/** Runs the cron job as if it fired at `at`. */
async function cronAt(at: number) {
  await exports.default.scheduled({ scheduledTime: new Date(at), cron: "0 * * * *" });
}

let nextTransactionId = 3_000_000_000;

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

/** The extension bought for `groupId` (StoreKit appAccountToken), as the app sends it. */
function extensionFor(groupId: string) {
  return signed("app.commoncam.extension", groupId);
}

function extend(token: string, groupId: string, signedTransaction: unknown) {
  return api(`/groups/${groupId}/extend`, { method: "POST", token, body: JSON.stringify({ signedTransaction }) });
}

async function newGroup(host: string) {
  return (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
}

async function hostedGroup(host: string, groupId: string) {
  return (await (await api("/groups", { token: host })).json<any[]>()).find((g) => g.id === groupId);
}

async function share(token: string, groupId: string, size: number) {
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes: size, contentType: "image/heic" }) })
  ).json<any>();
  await api(ticket.uploadUrl, { method: "PUT", body: new Uint8Array(size).fill(7) });
  return (await api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId: ticket.itemId }) })).json<any>();
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

async function objectKeys(prefix: string) {
  return (await env.MEDIA.list({ prefix })).objects.map((o) => o.key);
}

async function rowsFor(groupId: string) {
  const count = async (sql: string) => (await env.DB.prepare(sql).bind(groupId).first<{ n: number }>())!.n;
  return {
    items: await count("SELECT COUNT(*) AS n FROM items WHERE group_id = ?"),
    members: await count("SELECT COUNT(*) AS n FROM members WHERE group_id = ?"),
    reports: await count("SELECT COUNT(*) AS n FROM reports WHERE group_id = ?"),
    blocks: await count("SELECT COUNT(*) AS n FROM blocks WHERE group_id = ?"),
    multipartUploads: await count(
      "SELECT COUNT(*) AS n FROM multipart_uploads WHERE item_id IN (SELECT id FROM items WHERE group_id = ?)",
    ),
    multipartParts: await count(
      "SELECT COUNT(*) AS n FROM multipart_parts WHERE item_id IN (SELECT id FROM items WHERE group_id = ?)",
    ),
  };
}

/** A group with a guest, two shared photos, a report, a block and a half-finished multipart upload. */
async function busyGroup(prefix: string) {
  const host = `${prefix}-host-${crypto.randomUUID()}`;
  const guest = `${prefix}-guest-${crypto.randomUUID()}`;
  const group = await newGroup(host);
  const member = await join(guest, group.id, host);
  const hostItem = await share(host, group.id, 40);
  await share(guest, group.id, 60);
  await api(`/groups/${group.id}/items/${hostItem.id}/report`, { method: "POST", token: guest, body: JSON.stringify({ reason: "Nope" }) });
  await api(`/groups/${group.id}/members/${member.id}/block`, { method: "POST", token: host });
  const multipart = await (
    await api(`/groups/${group.id}/multipart`, { method: "POST", token: guest, body: JSON.stringify({ bytes: 10, contentType: "image/heic" }) })
  ).json<any>();
  const plan = await (await api(`/groups/${group.id}/multipart/${multipart.itemId}/parts`, { method: "POST", token: guest })).json<any>();
  expect((await api(plan.parts[0].url, { method: "PUT", body: new Uint8Array(10) })).status).toBe(200);
  return { host, guest, group };
}

describe("expiry: Active → Grace", () => {
  it("moves a group whose paid period has ended into Grace for 14 days; it stays readable but takes no uploads", async () => {
    const host = `grace-${crypto.randomUUID()}`;
    const group = await newGroup(host);
    const item = await share(host, group.id, 50);
    const late = await (
      await api(`/groups/${group.id}/uploads`, { method: "POST", token: host, body: JSON.stringify({ bytes: 5, contentType: "image/heic" }) })
    ).json<any>();
    await api(late.uploadUrl, { method: "PUT", body: new Uint8Array(5) });

    await cronAt(Date.parse(group.endsAt) + 60_000);

    const after = await hostedGroup(host, group.id);
    expect(after.state).toBe("Grace");
    expect(after.graceEndsAt).toBe(new Date(Date.parse(group.endsAt) + 14 * DAY_MS).toISOString());

    const gallery = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();
    expect(gallery.map((i) => i.id)).toEqual([item.id]);
    expect((await api(gallery[0].downloadUrl)).status).toBe(200);

    const upload = await api(`/groups/${group.id}/uploads`, {
      method: "POST",
      token: host,
      body: JSON.stringify({ bytes: 10, contentType: "image/heic" }),
    });
    expect(upload.status).toBe(410);
    const multipart = await api(`/groups/${group.id}/multipart`, {
      method: "POST",
      token: host,
      body: JSON.stringify({ bytes: 10, contentType: "image/heic" }),
    });
    expect(multipart.status).toBe(410);
    const confirm = await api(`/groups/${group.id}/items`, { method: "POST", token: host, body: JSON.stringify({ itemId: late.itemId }) });
    expect(confirm.status).toBe(410);
  });

  it("leaves groups whose paid period has not ended alone", async () => {
    const host = `active-${crypto.randomUUID()}`;
    const group = await newGroup(host);

    await cronAt(Date.parse(group.endsAt) - 60_000);

    expect(await hostedGroup(host, group.id)).toMatchObject({ state: "Active", graceEndsAt: null });
  });
});

describe("end of grace: Grace → Deleted", () => {
  it("permanently deletes the group's media and data, and records a verifiable deletion", async () => {
    const { host, guest, group } = await busyGroup("delete");
    const bystanderHost = `bystander-${crypto.randomUUID()}`;
    const bystander = await newPartyGroup(bystanderHost);
    await share(bystanderHost, bystander.id, 30);
    expect(await objectKeys(`groups/${group.id}/`)).toHaveLength(2);
    expect(await rowsFor(group.id)).toEqual({ items: 3, members: 1, reports: 1, blocks: 1, multipartUploads: 1, multipartParts: 1 });

    const statsSql = "SELECT tier, SUM(groups_created) AS groups, SUM(uploads) AS uploads, SUM(upload_bytes) AS bytes FROM daily_stats GROUP BY tier ORDER BY tier";
    const statsBefore = (await env.DB.prepare(statsSql).all()).results;
    expect(statsBefore).toContainEqual(expect.objectContaining({ tier: "taster" }));

    await cronAt(Date.parse(group.endsAt) + 60_000);
    const graceEndsAt = Date.parse((await hostedGroup(host, group.id)).graceEndsAt);
    await cronAt(graceEndsAt - 60_000);
    expect((await hostedGroup(host, group.id)).state).toBe("Grace");
    await cronAt(graceEndsAt + 60_000);

    expect((await hostedGroup(host, group.id)).state).toBe("Deleted");
    expect(await objectKeys(`groups/${group.id}/`)).toEqual([]);
    expect(await rowsFor(group.id)).toEqual({ items: 0, members: 0, reports: 0, blocks: 0, multipartUploads: 0, multipartParts: 0 });
    const record = await env.DB.prepare("SELECT * FROM deletions WHERE group_id = ?").bind(group.id).first<any>();
    expect(record).toMatchObject({ objects_deleted: 2, objects_remaining: 0, items_deleted: 3 });
    expect(Date.parse(record.deleted_at)).not.toBeNaN();

    expect(await (await api(`/groups/${group.id}/items`, { token: guest })).status).toBe(404);
    expect(await (await api(`/groups/${group.id}/items`, { token: host })).json()).toEqual([]);

    // Anonymous analytics are not tied to the group, so they survive its deletion.
    expect((await env.DB.prepare(statsSql).all()).results).toEqual(statsBefore);

    // A group whose paid period runs longer (Party: 5 days) keeps its media.
    expect(await objectKeys(`groups/${bystander.id}/`)).toHaveLength(1);
  });

  it("is idempotent: a later run neither fails nor writes a second record", async () => {
    const { host, group } = await busyGroup("again");
    await cronAt(Date.parse(group.endsAt) + 60_000);
    const graceEndsAt = Date.parse((await hostedGroup(host, group.id)).graceEndsAt);
    await cronAt(graceEndsAt + 60_000);
    await cronAt(graceEndsAt + 2 * 60 * 60_000);

    const { results } = await env.DB.prepare("SELECT objects_deleted FROM deletions WHERE group_id = ?").bind(group.id).all();
    expect(results).toEqual([{ objects_deleted: 2 }]);
  });
});

describe("POST /groups/:id/extend (paid extension)", () => {
  it("returns a Grace group to Active for another 7 days from now, uploads work again", async () => {
    const host = `extend-${crypto.randomUUID()}`;
    const group = await newGroup(host);
    // Grace for real: the paid period has ended in wall-clock terms, not just in the cron's eyes.
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(Date.now() - DAY_MS).toISOString(), group.id).run();
    await cronAt(Date.now());
    expect((await hostedGroup(host, group.id)).state).toBe("Grace");

    const before = Date.now();
    const transaction = await extensionFor(group.id);
    const res = await extend(host, group.id, transaction);

    expect(res.status).toBe(200);
    const extended = await res.json<any>();
    expect(extended).toMatchObject({ id: group.id, state: "Active", graceEndsAt: null });
    expect(Date.parse(extended.endsAt)).toBeGreaterThanOrEqual(before + 7 * DAY_MS);
    expect(Date.parse(extended.endsAt)).toBeLessThanOrEqual(Date.now() + 7 * DAY_MS);
    expect(await hostedGroup(host, group.id)).toMatchObject({ state: "Active", endsAt: extended.endsAt });
    expect((await share(host, group.id, 10)).id).toBeTruthy();
    const order = await env.DB.prepare("SELECT sku, amount_milliunits, credit_applied FROM orders WHERE group_id = ?").bind(group.id).first();
    expect(order).toEqual({ sku: "app.commoncam.extension", amount_milliunits: 2990, credit_applied: 0 });

    // The extended period ends and the cycle starts again.
    await cronAt(Date.parse(extended.endsAt) + 60_000);
    expect((await hostedGroup(host, group.id)).state).toBe("Grace");
  });

  it("refuses wrong products, forged transactions, other groups' extensions, non-hosts, running and deleted groups", async () => {
    const host = `extend-no-${crypto.randomUUID()}`;
    const group = await newGroup(host);
    const guest = `extend-no-guest-${crypto.randomUUID()}`;
    await join(guest, group.id, host);
    // 400 (not 409) while running, so the app keeps the transaction unfinished and redeems it after expiry.
    expect((await extend(host, group.id, await extensionFor(group.id))).status).toBe(400);

    await cronAt(Date.parse(group.endsAt) + 60_000);
    expect((await extend(host, group.id, undefined)).status).toBe(400);
    expect((await extend(host, group.id, await signed("app.commoncam.tier.party", group.id))).status).toBe(400);
    expect((await extend(host, group.id, await extensionFor(crypto.randomUUID()))).status).toBe(400);
    expect((await extend(host, group.id, await signed("app.commoncam.extension"))).status).toBe(400);
    expect((await extend(host, group.id, "not.a.jws")).status).toBe(403);
    expect((await extend("someone-else", group.id, await extensionFor(group.id))).status).toBe(404);
    expect((await extend(guest, group.id, await extensionFor(group.id))).status).toBe(404);
    expect((await hostedGroup(host, group.id)).state).toBe("Grace");

    const graceEndsAt = Date.parse((await hostedGroup(host, group.id)).graceEndsAt);
    await cronAt(graceEndsAt + 60_000);
    expect((await extend(host, group.id, await extensionFor(group.id))).status).toBe(410);
    const { results: orders } = await env.DB.prepare("SELECT 1 FROM orders WHERE group_id = ?").bind(group.id).all();
    expect(orders).toEqual([]);
  });

  it("refuses to redeem the same transaction twice", async () => {
    const host = `extend-replay-${crypto.randomUUID()}`;
    const group = await newGroup(host);
    await cronAt(Date.parse(group.endsAt) + 60_000);
    const transaction = await extensionFor(group.id);
    const extended = await (await extend(host, group.id, transaction)).json<any>();

    // The extended period ends too; the old transaction cannot buy another one.
    await cronAt(Date.parse(extended.endsAt) + 60_000);
    expect((await extend(host, group.id, transaction)).status).toBe(409);
    expect(await hostedGroup(host, group.id)).toMatchObject({ state: "Grace", endsAt: extended.endsAt });
  });

  it("extends a paid group with its limits intact, from now even if it ended days ago", async () => {
    const host = `extend-party-${crypto.randomUUID()}`;
    const group = await newPartyGroup(host);
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(Date.now() - 10 * DAY_MS).toISOString(), group.id).run();
    await cronAt(Date.now());

    const before = Date.now();
    const extended = await (await extend(host, group.id, await extensionFor(group.id))).json<any>();

    expect(extended).toMatchObject({ state: "Active", tier: "party", peopleCap: group.peopleCap, storageCapBytes: group.storageCapBytes });
    expect(Date.parse(extended.endsAt)).toBeGreaterThanOrEqual(before + 7 * DAY_MS);
  });
});
