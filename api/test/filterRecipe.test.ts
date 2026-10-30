import { exports } from "cloudflare:workers";
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

/** Requests an upload URL and PUTs the original; returns the item id, ready to confirm. */
async function upload(token: string, groupId: string, photo: Uint8Array) {
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, {
      method: "POST",
      token,
      body: JSON.stringify({ bytes: photo.byteLength, contentType: "image/heic" }),
    })
  ).json<any>();
  expect((await api(ticket.uploadUrl, { method: "PUT", body: photo })).status).toBe(200);
  return ticket.itemId as string;
}

function confirm(token: string, groupId: string, body: Record<string, unknown>) {
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify(body) });
}

const photo = Uint8Array.from({ length: 512 }, (_, i) => (i * 13 + 5) % 256);
const goldenHour = { id: "golden-hour", version: 1, params: { intensity: 0.8 } };

describe("filter recipe on confirm", () => {
  it("is stored with the item and shown in the gallery, while the original stays byte-for-byte", async () => {
    const { group, host, guest } = await groupWithGuest("recipe");
    const itemId = await upload(guest, group.id, photo);

    const confirmed = await confirm(guest, group.id, { itemId, filterRecipe: goldenHour });

    expect(confirmed.status).toBe(201);
    expect((await confirmed.json<any>()).filterRecipe).toEqual(goldenHour);
    const [item] = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();
    expect(item.filterRecipe).toEqual(goldenHour);
    expect(new Uint8Array(await (await api(item.downloadUrl)).arrayBuffer())).toEqual(photo);
  });

  it("is null when the photo was shot without a filter", async () => {
    const { group, guest } = await groupWithGuest("norecipe");
    const itemId = await upload(guest, group.id, photo);

    expect((await confirm(guest, group.id, { itemId })).status).toBe(201);

    const [item] = await (await api(`/groups/${group.id}/items`, { token: guest })).json<any[]>();
    expect(item.filterRecipe).toBeNull();
  });

  it("cannot be changed by a retried confirm", async () => {
    const { group, guest } = await groupWithGuest("recipe-retry");
    const itemId = await upload(guest, group.id, photo);
    await confirm(guest, group.id, { itemId, filterRecipe: goldenHour });

    const retry = await confirm(guest, group.id, { itemId, filterRecipe: { id: "ink", version: 1, params: {} } });

    expect(retry.status).toBe(200);
    expect((await retry.json<any>()).filterRecipe).toEqual(goldenHour);
  });

  it.each([
    ["a non-object", "golden-hour"],
    ["a missing id", { version: 1, params: {} }],
    ["an id with odd characters", { id: "Golden Hour!", version: 1, params: {} }],
    ["a non-integer version", { id: "ink", version: 1.5, params: {} }],
    ["a zero version", { id: "ink", version: 0, params: {} }],
    ["non-numeric params", { id: "ink", version: 1, params: { intensity: "high" } }],
    ["non-finite params", { id: "ink", version: 1, params: { intensity: null } }],
    ["too many params", { id: "ink", version: 1, params: Object.fromEntries(Array.from({ length: 17 }, (_, i) => [`p${i}`, i])) }],
  ])("rejects a recipe with %s and leaves the item unconfirmed", async (_, filterRecipe) => {
    const { group, guest } = await groupWithGuest(`badrecipe-${String(_).replace(/\W/g, "")}`);
    const itemId = await upload(guest, group.id, photo);

    expect((await confirm(guest, group.id, { itemId, filterRecipe })).status).toBe(400);

    expect(await (await api(`/groups/${group.id}/items`, { token: guest })).json<any[]>()).toEqual([]);
    expect((await confirm(guest, group.id, { itemId, filterRecipe: goldenHour })).status).toBe(201);
  });
});
