import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const MiB = 1024 * 1024;
const PART_SIZE = 5 * MiB;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function groupWithGuest(prefix: string) {
  const host = `${prefix}-host`;
  const guest = `${prefix}-guest`;
  const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
  const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: host })).json<any>();
  await api("/join", {
    method: "POST",
    token: guest,
    body: JSON.stringify({ qrToken, displayName: "Dancing Otter", colour: "#FF8800", consent: true }),
  });
  return { group, host, guest };
}

function start(token: string, groupId: string, bytes: number, contentType = "image/heic") {
  return api(`/groups/${groupId}/multipart`, { method: "POST", token, body: JSON.stringify({ bytes, contentType }) });
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

function fakePhoto(size: number) {
  const photo = new Uint8Array(size);
  for (let i = 0; i < size; i++) photo[i] = (i * 31 + 7) % 256;
  return photo;
}

async function sha256(bytes: ArrayBuffer | Uint8Array) {
  return btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))));
}

function slice(photo: Uint8Array, partNumber: number) {
  return photo.slice((partNumber - 1) * PART_SIZE, partNumber * PART_SIZE);
}

// Parts are at least 5 MiB, which is slow to push through workerd when other suites run in parallel.
describe("multipart upload", { timeout: 30_000 }, () => {
  it("uploads an original in parts and confirms it into the gallery byte-for-byte", async () => {
    const { group, host, guest } = await groupWithGuest("mp-roundtrip");
    const photo = fakePhoto(PART_SIZE + 1000);

    const started = await start(guest, group.id, photo.byteLength);
    expect(started.status).toBe(201);
    const upload = await started.json<any>();
    expect(upload).toMatchObject({ partSize: PART_SIZE, partCount: 2 });

    const { uploadedParts, parts } = await (await plan(guest, group.id, upload.itemId)).json<any>();
    expect(uploadedParts).toEqual([]);
    expect(parts.map((p: any) => p.partNumber)).toEqual([1, 2]);
    for (const part of parts) {
      expect((await api(part.url, { method: "PUT", body: slice(photo, part.partNumber) })).status).toBe(200);
    }

    expect((await complete(guest, group.id, upload.itemId)).status).toBe(204);
    expect((await confirm(guest, group.id, upload.itemId)).status).toBe(201);

    const [item] = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();
    expect(item).toMatchObject({ id: upload.itemId, bytes: photo.byteLength, contributor: { displayName: "Dancing Otter" } });
    const downloaded = await (await api(item.downloadUrl)).arrayBuffer();
    expect(await sha256(downloaded)).toBe(await sha256(photo));
  });

  it("resumes: a fresh plan reports the parts already stored and only signs the missing ones", async () => {
    const { group, guest } = await groupWithGuest("mp-resume");
    const photo = fakePhoto(2 * PART_SIZE + 10);
    const { itemId, partCount } = await (await start(guest, group.id, photo.byteLength)).json<any>();
    expect(partCount).toBe(3);
    const first = await (await plan(guest, group.id, itemId)).json<any>();
    await api(first.parts[0].url, { method: "PUT", body: slice(photo, 1) });
    await api(first.parts[2].url, { method: "PUT", body: slice(photo, 3) });

    const resumed = await (await plan(guest, group.id, itemId)).json<any>();

    expect(resumed.uploadedParts).toEqual([1, 3]);
    expect(resumed.parts.map((p: any) => p.partNumber)).toEqual([2]);
  });

  it("re-uploading a stored part is harmless", async () => {
    const { group, guest } = await groupWithGuest("mp-retry");
    const photo = fakePhoto(100);
    const { itemId } = await (await start(guest, group.id, photo.byteLength)).json<any>();
    const { parts } = await (await plan(guest, group.id, itemId)).json<any>();

    expect((await api(parts[0].url, { method: "PUT", body: photo })).status).toBe(200);
    expect((await api(parts[0].url, { method: "PUT", body: photo })).status).toBe(200);
    expect((await complete(guest, group.id, itemId)).status).toBe(204);
    expect((await complete(guest, group.id, itemId)).status).toBe(204);
    expect((await confirm(guest, group.id, itemId)).status).toBe(201);
  });

  it("refuses to complete while parts are missing", async () => {
    const { group, guest } = await groupWithGuest("mp-missing");
    const photo = fakePhoto(PART_SIZE + 1);
    const { itemId } = await (await start(guest, group.id, photo.byteLength)).json<any>();
    const { parts } = await (await plan(guest, group.id, itemId)).json<any>();
    await api(parts[0].url, { method: "PUT", body: slice(photo, 1) });

    expect((await complete(guest, group.id, itemId)).status).toBe(409);
    expect((await confirm(guest, group.id, itemId)).status).toBe(409);
  });

  it("only lets the host or an active member start, plan or complete", async () => {
    const { group, guest } = await groupWithGuest("mp-outsider");
    const { itemId } = await (await start(guest, group.id, 10)).json<any>();
    await env.DB.prepare("UPDATE members SET status = 'pending' WHERE group_id = ?").bind(group.id).run();

    expect((await start("stranger", group.id, 10)).status).toBe(404);
    expect((await start(guest, group.id, 10)).status).toBe(404);
    expect((await plan(guest, group.id, itemId)).status).toBe(404);
    expect((await complete(guest, group.id, itemId)).status).toBe(404);
  });

  it("does not let another member drive someone else's upload", async () => {
    const { group, host, guest } = await groupWithGuest("mp-others");
    const { itemId } = await (await start(guest, group.id, 10)).json<any>();

    expect((await plan(host, group.id, itemId)).status).toBe(404);
    expect((await complete(host, group.id, itemId)).status).toBe(404);
  });

  it("refuses ended groups, full storage and unsupported uploads", async () => {
    const { group, guest } = await groupWithGuest("mp-refuse");
    expect((await start(guest, group.id, 0)).status).toBe(400);
    expect((await start(guest, group.id, 10, "application/zip")).status).toBe(400);

    await env.DB.prepare("UPDATE groups SET storage_used_bytes = storage_cap_bytes - 100 WHERE id = ?").bind(group.id).run();
    expect((await start(guest, group.id, 101)).status).toBe(413);
    const { itemId } = await (await start(guest, group.id, 100)).json<any>();

    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(Date.now() - 1000).toISOString(), group.id).run();
    expect((await start(guest, group.id, 10)).status).toBe(410);
    expect((await plan(guest, group.id, itemId)).status).toBe(410);
  });
});

describe("signed part URLs", { timeout: 30_000 }, () => {
  it("reject tampering, expiry, a wrong body size and a finished upload", async () => {
    const { group, guest } = await groupWithGuest("mp-tamper");
    const photo = fakePhoto(10);
    const { itemId } = await (await start(guest, group.id, photo.byteLength)).json<any>();
    const { parts } = await (await plan(guest, group.id, itemId)).json<any>();
    const url = new URL(parts[0].url);

    const tampered = new URL(url);
    tampered.searchParams.set("bytes", "11");
    expect((await api(tampered.toString(), { method: "PUT", body: fakePhoto(11) })).status).toBe(403);
    const expired = new URL(url);
    expired.searchParams.set("exp", "1");
    expect((await api(expired.toString(), { method: "PUT", body: photo })).status).toBe(403);
    expect((await api(url.toString(), { method: "GET" })).status).toBe(405);
    expect((await api(url.toString(), { method: "PUT", body: fakePhoto(9) })).status).toBe(400);

    await api(url.toString(), { method: "PUT", body: photo });
    await complete(guest, group.id, itemId);
    expect((await api(url.toString(), { method: "PUT", body: photo })).status).toBe(409);
  });
});
