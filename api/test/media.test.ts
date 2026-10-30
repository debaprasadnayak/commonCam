import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

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

function requestUpload(token: string, groupId: string, bytes: number, contentType = "image/heic") {
  return api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes, contentType }) });
}

function confirm(token: string, groupId: string, itemId: string) {
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId }) });
}

async function share(token: string, groupId: string, photo: Uint8Array) {
  const ticket = await (await requestUpload(token, groupId, photo.byteLength)).json<any>();
  const put = await api(ticket.uploadUrl, { method: "PUT", body: photo });
  expect(put.status).toBe(200);
  return confirm(token, groupId, ticket.itemId);
}

function fakeHeic(size: number) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 31 + 7) % 256);
}

describe("photo upload → shared gallery", () => {
  it("stores the original byte-for-byte and shows it to every member tagged with the contributor", async () => {
    const { group, host, guest } = await groupWithGuest("roundtrip");
    const photo = fakeHeic(4096);

    const confirmed = await share(guest, group.id, photo);

    expect(confirmed.status).toBe(201);
    const gallery = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();
    expect(gallery).toHaveLength(1);
    expect(gallery[0]).toMatchObject({
      type: "photo",
      contentType: "image/heic",
      bytes: 4096,
      contributor: { displayName: "Dancing Otter", colour: "#FF8800" },
    });
    const download = await api(gallery[0].downloadUrl);
    expect(download.status).toBe(200);
    expect(download.headers.get("Content-Type")).toBe("image/heic");
    expect(new Uint8Array(await download.arrayBuffer())).toEqual(photo);
  });
});

describe("POST /groups/:id/uploads", () => {
  it("lets the host contribute too, labelled as the host", async () => {
    const { group, host, guest } = await groupWithGuest("hostshot");

    expect((await share(host, group.id, fakeHeic(10))).status).toBe(201);

    const [item] = await (await api(`/groups/${group.id}/items`, { token: guest })).json<any[]>();
    expect(item.contributor).toEqual({ memberId: null, displayName: "Host", colour: "#8E8E93" });
  });

  it("refuses devices that are not active members of the group", async () => {
    const { group, guest } = await groupWithGuest("outsider");
    await env.DB.prepare("UPDATE members SET status = 'removed' WHERE device_id IS NOT NULL AND group_id = ?").bind(group.id).run();

    expect((await requestUpload("stranger", group.id, 10)).status).toBe(404);
    expect((await requestUpload(guest, group.id, 10)).status).toBe(404);
  });

  it("refuses once the group is no longer Active", async () => {
    const { group, guest } = await groupWithGuest("ended");
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?").bind(new Date(Date.now() - 1000).toISOString(), group.id).run();

    expect((await requestUpload(guest, group.id, 10)).status).toBe(410);
  });

  it("refuses an upload that would exceed the group's storage cap", async () => {
    const { group, guest } = await groupWithGuest("full");
    await env.DB.prepare("UPDATE groups SET storage_used_bytes = storage_cap_bytes - 100 WHERE id = ?").bind(group.id).run();

    expect((await requestUpload(guest, group.id, 101)).status).toBe(413);
    expect((await requestUpload(guest, group.id, 100)).status).toBe(201);
  });

  it("refuses sizes and content types it cannot store", async () => {
    const { group, guest } = await groupWithGuest("badupload");

    expect((await requestUpload(guest, group.id, 0)).status).toBe(400);
    expect((await requestUpload(guest, group.id, 10, "application/zip")).status).toBe(400);
  });
});

describe("signed media URLs", () => {
  it("reject a tampered or expired link and a body that is not the announced size", async () => {
    const { group, guest } = await groupWithGuest("tamper");
    const { uploadUrl } = await (await requestUpload(guest, group.id, 10)).json<any>();

    const tampered = uploadUrl.replace("bytes=10", "bytes=11");
    expect((await api(tampered, { method: "PUT", body: fakeHeic(11) })).status).toBe(403);
    const expired = new URL(uploadUrl);
    expired.searchParams.set("exp", "1");
    expect((await api(expired.toString(), { method: "PUT", body: fakeHeic(10) })).status).toBe(403);
    expect((await api(uploadUrl, { method: "PUT", body: fakeHeic(9) })).status).toBe(400);
  });

  it("cannot be turned from an upload link into a download link", async () => {
    const { group, guest } = await groupWithGuest("swap");
    const { uploadUrl } = await (await requestUpload(guest, group.id, 10)).json<any>();
    await api(uploadUrl, { method: "PUT", body: fakeHeic(10) });

    expect((await api(uploadUrl)).status).toBe(403);
  });
});

describe("POST /groups/:id/items (confirm)", () => {
  it("adds the item's size to the group's storage usage", async () => {
    const { group, host, guest } = await groupWithGuest("usage");

    await share(guest, group.id, fakeHeic(300));
    await share(host, group.id, fakeHeic(200));

    const [mine] = await (await api("/groups", { token: host })).json<any[]>();
    expect(mine.storageUsedBytes).toBe(500);
  });

  it("is idempotent, so a retried confirm does not count the item twice", async () => {
    const { group, host, guest } = await groupWithGuest("retry");
    const ticket = await (await requestUpload(guest, group.id, 300)).json<any>();
    await api(ticket.uploadUrl, { method: "PUT", body: fakeHeic(300) });

    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(201);
    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(200);

    const [mine] = await (await api("/groups", { token: host })).json<any[]>();
    expect(mine.storageUsedBytes).toBe(300);
    expect(await (await api(`/groups/${group.id}/items`, { token: guest })).json<any[]>()).toHaveLength(1);
  });

  it("refuses to confirm before the bytes are uploaded, or someone else's item", async () => {
    const { group, host, guest } = await groupWithGuest("early");
    const ticket = await (await requestUpload(guest, group.id, 10)).json<any>();

    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(409);
    await api(ticket.uploadUrl, { method: "PUT", body: fakeHeic(10) });
    expect((await confirm(host, group.id, ticket.itemId)).status).toBe(404);
    expect(await (await api(`/groups/${group.id}/items`, { token: guest })).json<any[]>()).toEqual([]);
  });

  it("refuses when other uploads filled the group in the meantime", async () => {
    const { group, guest } = await groupWithGuest("race");
    const ticket = await (await requestUpload(guest, group.id, 100)).json<any>();
    await api(ticket.uploadUrl, { method: "PUT", body: fakeHeic(100) });
    await env.DB.prepare("UPDATE groups SET storage_used_bytes = storage_cap_bytes - 50 WHERE id = ?").bind(group.id).run();

    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(413);
  });

  it("leaves nothing half-done when a confirm fails midway, so a retry succeeds and charges once", async () => {
    const { group, host, guest } = await groupWithGuest("midway");
    const ticket = await (await requestUpload(guest, group.id, 300)).json<any>();
    await api(ticket.uploadUrl, { method: "PUT", body: fakeHeic(300) });
    // Simulates the Worker or D1 failing as the item is made ready.
    await env.DB.prepare(
      "CREATE TRIGGER fail_ready BEFORE UPDATE OF status ON items WHEN NEW.status = 'ready' BEGIN SELECT RAISE(ABORT, 'boom'); END",
    ).run();
    try {
      await expect(confirm(guest, group.id, ticket.itemId)).rejects.toThrow();
    } finally {
      await env.DB.prepare("DROP TRIGGER fail_ready").run();
    }

    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(201);
    const [mine] = await (await api("/groups", { token: host })).json<any[]>();
    expect(mine.storageUsedBytes).toBe(300);
  });
});

describe("GET /groups/:id/items", () => {
  it("is hidden from non-members", async () => {
    const { group } = await groupWithGuest("private");

    expect((await api(`/groups/${group.id}/items`, { token: "stranger" })).status).toBe(404);
  });
});

describe("media access follows member status", () => {
  it("refuses uploads and the gallery to a guest awaiting approval", async () => {
    const host = "pending-media-host";
    const guest = "pending-media-guest";
    const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
    const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: host })).json<any>();
    const approval = await api(`/groups/${group.id}/approval`, {
      method: "PUT",
      token: host,
      body: JSON.stringify({ approvalRequired: true }),
    });
    expect(approval.status).toBe(200);
    const joined = await api("/join", {
      method: "POST",
      token: guest,
      body: JSON.stringify({ qrToken, displayName: "Waiting Owl", colour: "#123456", consent: true }),
    });
    expect(joined.status).toBe(202);

    expect((await requestUpload(guest, group.id, 10)).status).toBe(404);
    expect((await api(`/groups/${group.id}/items`, { token: guest })).status).toBe(404);
  });

  it("refuses uploads, confirms and the gallery to a banned guest", async () => {
    const { group, host, guest } = await groupWithGuest("banned-media");
    const ticket = await (await requestUpload(guest, group.id, 10)).json<any>();
    expect((await api(ticket.uploadUrl, { method: "PUT", body: fakeHeic(10) })).status).toBe(200);
    const [member] = await (await api(`/groups/${group.id}/members`, { token: host })).json<any[]>();
    expect((await api(`/groups/${group.id}/members/${member.id}/ban`, { method: "POST", token: host })).status).toBe(204);

    expect((await confirm(guest, group.id, ticket.itemId)).status).toBe(404);
    expect((await requestUpload(guest, group.id, 10)).status).toBe(404);
    expect((await api(`/groups/${group.id}/items`, { token: guest })).status).toBe(404);
  });
});
