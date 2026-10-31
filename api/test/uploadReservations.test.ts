import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const HOUR_MS = 60 * 60 * 1000;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function cronAt(at: number) {
  await exports.default.scheduled({ scheduledTime: new Date(at), cron: "0 * * * *" });
}

/** A Taster group whose storage cap is `capBytes`, running long enough for the time-travelling cron runs below. */
async function groupWithCap(host: string, capBytes: number) {
  const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
  await env.DB.prepare("UPDATE groups SET storage_cap_bytes = ?, ends_at = ? WHERE id = ?")
    .bind(capBytes, new Date(Date.now() + 7 * 24 * HOUR_MS).toISOString(), group.id)
    .run();
  return group;
}

function ticket(token: string, groupId: string, bytes: number) {
  return api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes, contentType: "image/heic" }) });
}

function startMultipart(token: string, groupId: string, bytes: number) {
  return api(`/groups/${groupId}/multipart`, { method: "POST", token, body: JSON.stringify({ bytes, contentType: "image/heic" }) });
}

function plan(token: string, groupId: string, itemId: string) {
  return api(`/groups/${groupId}/multipart/${itemId}/parts`, { method: "POST", token });
}

function complete(token: string, groupId: string, itemId: string) {
  return api(`/groups/${groupId}/multipart/${itemId}/complete`, { method: "POST", token });
}

function confirm(token: string, groupId: string, itemId: string) {
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId }) });
}

async function storage(token: string, groupId: string) {
  return (await api(`/groups/${groupId}/storage`, { token })).json<any>();
}

async function storedBytes(groupId: string) {
  const { objects } = await env.MEDIA.list({ prefix: `groups/${groupId}/` });
  return objects.reduce((sum, object) => sum + object.size, 0);
}

describe("upload reservations: single-PUT uploads", () => {
  it("counts unconfirmed tickets against the cap, so pending plus ready bytes never exceed it", async () => {
    const host = "reserve-single";
    const group = await groupWithCap(host, 100);

    expect((await ticket(host, group.id, 60)).status).toBe(201);
    expect((await ticket(host, group.id, 41)).status).toBe(413);
    expect((await ticket(host, group.id, 40)).status).toBe(201);
    expect((await ticket(host, group.id, 1)).status).toBe(413);
  });

  it("admits at most the cap under a burst of concurrent ticket requests", async () => {
    const host = "reserve-race";
    const group = await groupWithCap(host, 8);

    const responses = await Promise.all(Array.from({ length: 32 }, () => ticket(host, group.id, 1)));
    const issued = responses.filter((r) => r.status === 201);
    expect(issued).toHaveLength(8);
    expect(responses.every((r) => [201, 413].includes(r.status))).toBe(true);

    const tickets = await Promise.all(issued.map((r) => r.json<any>()));
    await Promise.all(tickets.map((t) => api(t.uploadUrl, { method: "PUT", body: new Uint8Array([1]) })));
    const confirms = await Promise.all(tickets.map((t) => confirm(host, group.id, t.itemId)));
    expect(confirms.every((r) => r.status === 201)).toBe(true);
    expect((await storage(host, group.id)).storageUsedBytes).toBe(8);
    expect(await storedBytes(group.id)).toBe(8);
  });

  it("refuses the PUT once the reservation has expired, and re-PUTs over a confirmed item", async () => {
    const host = "reserve-put";
    const group = await groupWithCap(host, 100);
    const expiring = await (await ticket(host, group.id, 10)).json<any>();
    const confirmed = await (await ticket(host, group.id, 10)).json<any>();
    expect((await api(confirmed.uploadUrl, { method: "PUT", body: new Uint8Array(10) })).status).toBe(200);
    expect((await confirm(host, group.id, confirmed.itemId)).status).toBe(201);

    await cronAt(Date.now() + 2 * HOUR_MS);

    expect((await api(expiring.uploadUrl, { method: "PUT", body: new Uint8Array(10) })).status).toBe(410);
    expect((await api(confirmed.uploadUrl, { method: "PUT", body: new Uint8Array(10).fill(9) })).status).toBe(410);
    expect(await storedBytes(group.id)).toBe(10);
  });

  it("expires abandoned uploads hourly: deletes their bytes and releases the reservation", async () => {
    const host = "reserve-cleanup";
    const group = await groupWithCap(host, 10);
    const abandoned = await (await ticket(host, group.id, 10)).json<any>();
    expect((await api(abandoned.uploadUrl, { method: "PUT", body: new Uint8Array(10) })).status).toBe(200);
    expect((await ticket(host, group.id, 1)).status).toBe(413);
    expect((await storage(host, group.id)).storageLevel).toBe("full");

    await cronAt(Date.now() + 30 * 60 * 1000);
    expect(await storedBytes(group.id)).toBe(10);

    await cronAt(Date.now() + 2 * HOUR_MS);

    expect(await storedBytes(group.id)).toBe(0);
    expect((await confirm(host, group.id, abandoned.itemId)).status).toBe(404);
    expect(await storage(host, group.id)).toMatchObject({ storageUsedBytes: 0, storageLevel: "ok" });
    expect((await ticket(host, group.id, 10)).status).toBe(201);
  });
});

describe("upload reservations: multipart uploads", () => {
  it("counts started uploads against the cap, together with single-PUT tickets", async () => {
    const host = "reserve-mp";
    const group = await groupWithCap(host, 100);

    expect((await startMultipart(host, group.id, 70)).status).toBe(201);
    expect((await ticket(host, group.id, 31)).status).toBe(413);
    expect((await startMultipart(host, group.id, 31)).status).toBe(413);
    expect((await startMultipart(host, group.id, 30)).status).toBe(201);
  });

  it("keeps an upload for a day, then expires it and releases its reservation", async () => {
    const host = "reserve-mp-expiry";
    const group = await groupWithCap(host, 100);
    expect((await startMultipart(host, group.id, 80)).status).toBe(201);
    const abandoned = await (await startMultipart(host, group.id, 10)).json<any>();
    const { parts } = await (await plan(host, group.id, abandoned.itemId)).json<any>();
    expect((await api(parts[0].url, { method: "PUT", body: new Uint8Array(10) })).status).toBe(200);

    await cronAt(Date.now() + 2 * HOUR_MS);
    expect((await plan(host, group.id, abandoned.itemId)).status).toBe(200);

    await cronAt(Date.now() + 25 * HOUR_MS);

    expect((await plan(host, group.id, abandoned.itemId)).status).toBe(404);
    expect((await complete(host, group.id, abandoned.itemId)).status).toBe(404);
    expect((await api(parts[0].url, { method: "PUT", body: new Uint8Array(10) })).status).toBe(410);
    expect(await storedBytes(group.id)).toBe(0);
    expect((await startMultipart(host, group.id, 100)).status).toBe(201);
  });

  it("aborts the R2 multipart upload of an expired item", async () => {
    const host = "reserve-mp-abort";
    const group = await groupWithCap(host, 100);
    const upload = await (await startMultipart(host, group.id, 10)).json<any>();
    const { upload_id: uploadId, object_key: objectKey } = (await env.DB.prepare(
      "SELECT u.upload_id, i.object_key FROM multipart_uploads u JOIN items i ON i.id = u.item_id WHERE u.item_id = ?",
    )
      .bind(upload.itemId)
      .first<{ upload_id: string; object_key: string }>())!;

    await cronAt(Date.now() + 25 * HOUR_MS);

    const r2 = env.MEDIA.resumeMultipartUpload(objectKey, uploadId);
    await expect(r2.uploadPart(1, new Uint8Array(10))).rejects.toThrow();
  });

  it("releases the reservation when R2 cannot assemble the upload", async () => {
    const host = "reserve-mp-failed";
    const group = await groupWithCap(host, 10);
    const upload = await (await startMultipart(host, group.id, 10)).json<any>();
    const { parts } = await (await plan(host, group.id, upload.itemId)).json<any>();
    expect((await api(parts[0].url, { method: "PUT", body: new Uint8Array(10) })).status).toBe(200);
    await env.DB.prepare("UPDATE multipart_parts SET etag = 'not-an-etag' WHERE item_id = ?").bind(upload.itemId).run();

    expect((await complete(host, group.id, upload.itemId)).status).toBe(409);

    expect((await plan(host, group.id, upload.itemId)).status).toBe(404);
    expect(await storedBytes(group.id)).toBe(0);
    expect((await startMultipart(host, group.id, 10)).status).toBe(201);
  });
});
