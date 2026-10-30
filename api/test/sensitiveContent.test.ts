import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function groupWithGuests(prefix: string) {
  const host = `${prefix}-host`;
  const guest = `${prefix}-guest`;
  const other = `${prefix}-other`;
  const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
  const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: host })).json<any>();
  for (const [token, displayName] of [[guest, "Dancing Otter"], [other, "Quiet Heron"]]) {
    await api("/join", { method: "POST", token, body: JSON.stringify({ qrToken, displayName, colour: "#FF8800", consent: true }) });
  }
  return { group, host, guest, other };
}

async function upload(token: string, groupId: string) {
  const photo = Uint8Array.from({ length: 10 }, (_, i) => i);
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes: 10, contentType: "image/heic" }) })
  ).json<any>();
  expect((await api(ticket.uploadUrl, { method: "PUT", body: photo })).status).toBe(200);
  return ticket.itemId as string;
}

function confirm(token: string, groupId: string, body: Record<string, unknown>) {
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify(body) });
}

function gallery(token: string, groupId: string) {
  return api(`/groups/${groupId}/items`, { token }).then((r) => r.json<any[]>());
}

function reports(token: string, groupId: string) {
  return api(`/groups/${groupId}/reports`, { token }).then((r) => r.json<any[]>());
}

describe("confirming an item the uploader's device flagged as sensitive", () => {
  it("hides it from members, including the uploader, and puts it in the owner's report review", async () => {
    const { group, host, guest, other } = await groupWithGuests("sca-flag");
    const itemId = await upload(guest, group.id);

    const res = await confirm(guest, group.id, { itemId, sensitive: true });

    expect(res.status).toBe(201);
    expect(await res.json()).toMatchObject({ id: itemId, hidden: true });
    expect(await gallery(other, group.id)).toEqual([]);
    expect(await gallery(guest, group.id)).toEqual([]);
    expect(await gallery(host, group.id)).toMatchObject([{ id: itemId, hidden: true }]);
    expect(await reports(host, group.id)).toMatchObject([
      { itemId, status: "open", reason: "Flagged as possibly sensitive by on-device analysis", item: { id: itemId, hidden: true } },
    ]);
  });

  it("shows it to everyone once the owner restores it", async () => {
    const { group, host, other } = await groupWithGuests("sca-restore");
    const itemId = await upload(host, group.id);
    await confirm(host, group.id, { itemId, sensitive: true });
    const [report] = await reports(host, group.id);

    expect((await api(`/groups/${group.id}/reports/${report.id}/restore`, { method: "POST", token: host })).status).toBe(200);

    expect(await gallery(other, group.id)).toMatchObject([{ id: itemId, hidden: false }]);
  });

  it("files a single report when the confirm is retried", async () => {
    const { group, host, guest } = await groupWithGuests("sca-retry");
    const itemId = await upload(guest, group.id);

    await confirm(guest, group.id, { itemId, sensitive: true });
    const retry = await confirm(guest, group.id, { itemId, sensitive: true });

    expect(retry.status).toBe(200);
    expect(await reports(host, group.id)).toHaveLength(1);
  });

  it("leaves unflagged items visible and unreported", async () => {
    const { group, host, guest, other } = await groupWithGuests("sca-clean");
    const itemId = await upload(guest, group.id);

    await confirm(guest, group.id, { itemId, sensitive: false });

    expect(await gallery(other, group.id)).toMatchObject([{ id: itemId, hidden: false }]);
    expect(await reports(host, group.id)).toEqual([]);
  });
});
