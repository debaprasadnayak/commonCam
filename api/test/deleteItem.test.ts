import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function joinAs(token: string, groupId: string, host: string) {
  const { qrToken } = await (await api(`/groups/${groupId}/invite`, { token: host })).json<any>();
  const res = await api("/join", {
    method: "POST",
    token,
    body: JSON.stringify({ qrToken, displayName: `Guest ${token}`, colour: "#FF8800", consent: true }),
  });
  return (await res.json<any>()).member;
}

async function groupWithGuests(prefix: string) {
  const host = `${prefix}-host`;
  const guest = `${prefix}-guest`;
  const other = `${prefix}-other`;
  const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
  const guestMember = await joinAs(guest, group.id, host);
  const otherMember = await joinAs(other, group.id, host);
  return { group, host, guest, other, guestMember, otherMember };
}

async function share(token: string, groupId: string, size: number) {
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes: size, contentType: "image/heic" }) })
  ).json<any>();
  await api(ticket.uploadUrl, { method: "PUT", body: new Uint8Array(size).fill(7) });
  return (await api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId: ticket.itemId }) })).json<any>();
}

function deleteItem(token: string, groupId: string, itemId: string) {
  return api(`/groups/${groupId}/items/${itemId}`, { method: "DELETE", token });
}

async function galleryIds(token: string, groupId: string) {
  return (await (await api(`/groups/${groupId}/items`, { token })).json<any[]>()).map((item) => item.id);
}

async function storageUsed(host: string, groupId: string) {
  const groups = await (await api("/groups", { token: host })).json<any[]>();
  return groups.find((g) => g.id === groupId).storageUsedBytes;
}

describe("gallery canDelete", () => {
  it("is true for the caller's own items, and for every item when the caller is host or co-host", async () => {
    const { group, host, guest, other, otherMember } = await groupWithGuests("flag");
    const hostItem = await share(host, group.id, 10);
    const guestItem = await share(guest, group.id, 10);
    expect(guestItem.canDelete).toBe(true);

    const flags = async (token: string) =>
      Object.fromEntries((await (await api(`/groups/${group.id}/items`, { token })).json<any[]>()).map((i) => [i.id, i.canDelete]));

    expect(await flags(guest)).toEqual({ [hostItem.id]: false, [guestItem.id]: true });
    expect(await flags(other)).toEqual({ [hostItem.id]: false, [guestItem.id]: false });
    expect(await flags(host)).toEqual({ [hostItem.id]: true, [guestItem.id]: true });
    await api(`/groups/${group.id}/members/${otherMember.id}/co-host`, { method: "POST", token: host });
    expect(await flags(other)).toEqual({ [hostItem.id]: true, [guestItem.id]: true });
  });
});

describe("DELETE /groups/:id/items/:itemId", () => {
  it("lets a contributor delete their own upload: gone for everyone, bytes removed, usage drops", async () => {
    const { group, host, guest, other } = await groupWithGuests("own");
    const kept = await share(host, group.id, 100);
    const item = await share(guest, group.id, 300);

    expect((await deleteItem(guest, group.id, item.id)).status).toBe(204);

    expect(await galleryIds(host, group.id)).toEqual([kept.id]);
    expect(await galleryIds(other, group.id)).toEqual([kept.id]);
    expect((await api(item.downloadUrl)).status).toBe(404);
    expect(await env.MEDIA.head(`groups/${group.id}/${item.id}`)).toBeNull();
    expect(await storageUsed(host, group.id)).toBe(100);
  });

  it("refuses other members' items to a guest, and everything to outsiders and inactive members", async () => {
    const { group, host, guest, other, otherMember } = await groupWithGuests("refuse");
    const hostItem = await share(host, group.id, 50);
    const guestItem = await share(guest, group.id, 60);
    const otherItem = await share(other, group.id, 70);

    expect((await deleteItem(guest, group.id, hostItem.id)).status).toBe(403);
    expect((await deleteItem(guest, group.id, otherItem.id)).status).toBe(403);
    expect((await deleteItem("stranger", group.id, guestItem.id)).status).toBe(404);
    await api(`/groups/${group.id}/members/${otherMember.id}/remove`, { method: "POST", token: host });
    expect((await deleteItem(other, group.id, otherItem.id)).status).toBe(404);

    expect(await galleryIds(host, group.id)).toHaveLength(3);
    expect(await storageUsed(host, group.id)).toBe(180);
  });

  it("lets the host and a co-host delete anyone's item", async () => {
    const { group, host, guest, other, otherMember } = await groupWithGuests("moderate");
    const first = await share(guest, group.id, 100);
    const second = await share(guest, group.id, 200);
    await api(`/groups/${group.id}/members/${otherMember.id}/co-host`, { method: "POST", token: host });

    expect((await deleteItem(host, group.id, first.id)).status).toBe(204);
    expect((await deleteItem(other, group.id, second.id)).status).toBe(204);

    expect(await galleryIds(guest, group.id)).toEqual([]);
    expect(await storageUsed(host, group.id)).toBe(0);
  });

  it("is safe to repeat: a second delete succeeds and does not lower usage again", async () => {
    const { group, host, guest } = await groupWithGuests("repeat");
    await share(host, group.id, 100);
    const item = await share(guest, group.id, 300);

    const responses = await Promise.all([deleteItem(guest, group.id, item.id), deleteItem(host, group.id, item.id)]);
    expect(responses.map((r) => r.status)).toEqual([204, 204]);
    expect((await deleteItem(guest, group.id, item.id)).status).toBe(204);

    expect(await storageUsed(host, group.id)).toBe(100);
  });

  it("never takes storage usage below zero", async () => {
    const { group, host, guest } = await groupWithGuests("floor");
    const item = await share(guest, group.id, 300);
    await env.DB.prepare("UPDATE groups SET storage_used_bytes = 100 WHERE id = ?").bind(group.id).run();

    expect((await deleteItem(guest, group.id, item.id)).status).toBe(204);

    expect(await storageUsed(host, group.id)).toBe(0);
  });

  it("does not delete an item through another group's URL", async () => {
    const a = await groupWithGuests("cross-a");
    const b = await groupWithGuests("cross-b");
    const item = await share(a.guest, a.group.id, 100);

    expect((await deleteItem(b.host, b.group.id, item.id)).status).toBe(204);

    expect(await galleryIds(a.host, a.group.id)).toEqual([item.id]);
    expect(await storageUsed(a.host, a.group.id)).toBe(100);
  });
});
