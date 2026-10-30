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

function gallery(token: string, groupId: string) {
  return api(`/groups/${groupId}/items`, { token }).then((r) => r.json<any[]>());
}

function reportItem(token: string, groupId: string, itemId: string, reason: unknown = "Offensive") {
  return api(`/groups/${groupId}/items/${itemId}/report`, { method: "POST", token, body: JSON.stringify({ reason }) });
}

describe("reporting an item", () => {
  it("records the report with its reason and hides the item from non-owners until reviewed", async () => {
    const { group, host, guest } = await groupWithGuest("rep-item");
    const item = await (await share(host, group.id, fakeHeic(10))).json<any>();

    const res = await reportItem(guest, group.id, item.id, "Not appropriate");

    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ itemId: item.id, memberId: null, reason: "Not appropriate", status: "open" });
    expect(await gallery(guest, group.id)).toEqual([]);
    const ownerView = await gallery(host, group.id);
    expect(ownerView).toHaveLength(1);
    expect(ownerView[0]).toMatchObject({ id: item.id, hidden: true });
  });
});

async function memberId(token: string, groupId: string, displayName = "Dancing Otter") {
  const members = await (await api(`/groups/${groupId}/members`, { token })).json<any[]>();
  return members.find((m) => m.displayName === displayName).id as string;
}

async function addGuest(groupId: string, host: string, guest: string, displayName: string) {
  const { qrToken } = await (await api(`/groups/${groupId}/invite`, { token: host })).json<any>();
  await api("/join", { method: "POST", token: guest, body: JSON.stringify({ qrToken, displayName, colour: "#00AAFF", consent: true }) });
}

describe("report validation", () => {
  it("requires a reason", async () => {
    const { group, host, guest } = await groupWithGuest("rep-noreason");
    const item = await (await share(host, group.id, fakeHeic(10))).json<any>();

    expect((await reportItem(guest, group.id, item.id, "  ")).status).toBe(400);
    expect((await reportItem(guest, group.id, item.id, 42)).status).toBe(400);
    expect((await reportItem(guest, group.id, item.id, "x".repeat(501))).status).toBe(400);
    expect(await gallery(guest, group.id)).toHaveLength(1);
  });

  it("refuses outsiders and unknown items", async () => {
    const { group, host, guest } = await groupWithGuest("rep-outsider");
    const item = await (await share(host, group.id, fakeHeic(10))).json<any>();

    expect((await reportItem("stranger", group.id, item.id)).status).toBe(404);
    expect((await reportItem(guest, group.id, "no-such-item")).status).toBe(404);
  });
});

describe("reporting a member", () => {
  it("records the report with its reason without hiding their items", async () => {
    const { group, host, guest } = await groupWithGuest("rep-member");
    await share(guest, group.id, fakeHeic(10));
    const otterId = await memberId(host, group.id);

    const res = await api(`/groups/${group.id}/members/${otterId}/report`, {
      method: "POST",
      token: host,
      body: JSON.stringify({ reason: "Spamming" }),
    });

    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ itemId: null, memberId: otterId, reason: "Spamming", status: "open" });
    expect(await gallery(guest, group.id)).toHaveLength(1);
  });
});

describe("blocking a member", () => {
  it("hides that member's items for the blocker only, until unblocked", async () => {
    const { group, host, guest } = await groupWithGuest("block");
    await addGuest(group.id, host, "block-other", "Quiet Heron");
    await share(guest, group.id, fakeHeic(10));
    await share(host, group.id, fakeHeic(10));
    const otterId = await memberId(host, group.id);

    const blocked = await api(`/groups/${group.id}/members/${otterId}/block`, { method: "POST", token: "block-other" });

    expect(blocked.status).toBe(204);
    const blockerView = await gallery("block-other", group.id);
    expect(blockerView.map((i) => i.contributor.displayName)).toEqual(["Host"]);
    expect(await gallery(host, group.id)).toHaveLength(2);
    expect(await gallery(guest, group.id)).toHaveLength(2);

    const unblocked = await api(`/groups/${group.id}/members/${otterId}/block`, { method: "DELETE", token: "block-other" });

    expect(unblocked.status).toBe(204);
    expect(await gallery("block-other", group.id)).toHaveLength(2);
  });

  it("refuses outsiders, unknown members and blocking yourself", async () => {
    const { group, host, guest } = await groupWithGuest("block-bad");
    const otterId = await memberId(host, group.id);

    expect((await api(`/groups/${group.id}/members/${otterId}/block`, { method: "POST", token: "stranger" })).status).toBe(404);
    expect((await api(`/groups/${group.id}/members/nobody/block`, { method: "POST", token: host })).status).toBe(404);
    expect((await api(`/groups/${group.id}/members/${otterId}/block`, { method: "POST", token: guest })).status).toBe(400);
  });
});

function reports(token: string, groupId: string) {
  return api(`/groups/${groupId}/reports`, { token });
}

function review(token: string, groupId: string, reportId: string, action: "restore" | "delete") {
  return api(`/groups/${groupId}/reports/${reportId}/${action}`, { method: "POST", token });
}

describe("owner review", () => {
  it("lists open reports, with the reported item, to the host only", async () => {
    const { group, host, guest } = await groupWithGuest("review-list");
    const item = await (await share(guest, group.id, fakeHeic(10))).json<any>();
    const report = await (await reportItem(guest, group.id, item.id, "Blurry face")).json<any>();

    const res = await reports(host, group.id);

    expect(res.status).toBe(200);
    const list = await res.json<any[]>();
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: report.id, reason: "Blurry face", status: "open", item: { id: item.id, hidden: true } });
    expect((await api(list[0].item.downloadUrl)).status).toBe(200);
    expect((await reports(guest, group.id)).status).toBe(404);
  });

  it("restore makes the item visible again and closes every open report on it", async () => {
    const { group, host, guest } = await groupWithGuest("review-restore");
    const item = await (await share(host, group.id, fakeHeic(10))).json<any>();
    const first = await (await reportItem(guest, group.id, item.id, "One")).json<any>();
    await reportItem(guest, group.id, item.id, "Two");

    const res = await review(host, group.id, first.id, "restore");

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id: first.id, status: "restored" });
    expect(await gallery(guest, group.id)).toMatchObject([{ id: item.id, hidden: false }]);
    expect(await (await reports(host, group.id)).json()).toEqual([]);
    expect((await review(host, group.id, first.id, "restore")).status).toBe(409);
  });

  it("delete removes the item for everyone and frees its storage", async () => {
    const { group, host, guest } = await groupWithGuest("review-delete");
    const item = await (await share(guest, group.id, fakeHeic(100))).json<any>();
    const report = await (await reportItem(guest, group.id, item.id)).json<any>();

    const res = await review(host, group.id, report.id, "delete");

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id: report.id, status: "deleted" });
    expect(await gallery(host, group.id)).toEqual([]);
    expect((await api(item.downloadUrl)).status).toBe(404);
    const [hosted] = await (await api("/groups", { token: host })).json<any[]>();
    expect(hosted.storageUsedBytes).toBe(0);
  });

  it("member reports can be dismissed with restore but not deleted", async () => {
    const { group, host } = await groupWithGuest("review-member");
    const otterId = await memberId(host, group.id);
    const report = await (
      await api(`/groups/${group.id}/members/${otterId}/report`, { method: "POST", token: host, body: JSON.stringify({ reason: "Rude" }) })
    ).json<any>();

    const listed = await (await reports(host, group.id)).json<any[]>();
    expect(listed[0]).toMatchObject({ memberId: otterId, member: { id: otterId, displayName: "Dancing Otter" } });
    expect((await review(host, group.id, report.id, "delete")).status).toBe(400);
    expect((await review(host, group.id, report.id, "restore")).status).toBe(200);
  });

  it("is open to co-hosts but not guests", async () => {
    const { group, host, guest } = await groupWithGuest("review-cohost");
    await addGuest(group.id, host, "review-cohost-2", "Quiet Heron");
    await api(`/groups/${group.id}/members/${await memberId(host, group.id, "Quiet Heron")}/co-host`, { method: "POST", token: host });
    const item = await (await share(host, group.id, fakeHeic(10))).json<any>();
    const report = await (await reportItem(guest, group.id, item.id)).json<any>();

    expect(await gallery("review-cohost-2", group.id)).toMatchObject([{ hidden: true }]);
    expect((await review(guest, group.id, report.id, "restore")).status).toBe(404);
    expect((await review("review-cohost-2", group.id, report.id, "restore")).status).toBe(200);
  });
});
