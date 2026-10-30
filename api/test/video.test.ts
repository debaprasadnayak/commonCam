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

function fakeClip(size: number) {
  return Uint8Array.from({ length: size }, (_, i) => (i * 17 + 3) % 256);
}

/** Uploads a single-part clip through the multipart queue's endpoints and returns the confirm response. */
async function shareClip(token: string, groupId: string, clip: Uint8Array, confirmBody: Record<string, unknown> = {}) {
  const started = await api(`/groups/${groupId}/multipart`, {
    method: "POST",
    token,
    body: JSON.stringify({ bytes: clip.byteLength, contentType: "video/quicktime" }),
  });
  expect(started.status).toBe(201);
  const { itemId } = await started.json<any>();
  const { parts } = await (await api(`/groups/${groupId}/multipart/${itemId}/parts`, { method: "POST", token })).json<any>();
  expect((await api(parts[0].url, { method: "PUT", body: clip })).status).toBe(200);
  expect((await api(`/groups/${groupId}/multipart/${itemId}/complete`, { method: "POST", token })).status).toBe(204);
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId, ...confirmBody }) });
}

describe("video clips", () => {
  it("upload through the multipart queue and show in the gallery as video items", async () => {
    const { group, host, guest } = await groupWithGuest("video-share");
    const clip = fakeClip(2000);

    expect((await shareClip(guest, group.id, clip)).status).toBe(201);

    const [item] = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();
    expect(item).toMatchObject({ type: "video", contentType: "video/quicktime", bytes: 2000, filterRecipe: null });
    expect(new Uint8Array(await (await api(item.downloadUrl)).arrayBuffer())).toEqual(clip);
  });

  it("must use the resumable multipart upload, not a single PUT", async () => {
    const { group, guest } = await groupWithGuest("video-single");

    const single = await api(`/groups/${group.id}/uploads`, {
      method: "POST",
      token: guest,
      body: JSON.stringify({ bytes: 2000, contentType: "video/quicktime" }),
    });

    expect(single.status).toBe(400);
  });

  it("refuses a filter recipe: video filters are baked in at capture", async () => {
    const { group, guest } = await groupWithGuest("video-recipe");

    const confirmed = await shareClip(guest, group.id, fakeClip(100), {
      filterRecipe: { id: "pop", version: 1, params: { intensity: 1 } },
    });

    expect(confirmed.status).toBe(400);
  });

  it("can be streamed: the download link serves byte ranges so players can seek", async () => {
    const { group, host, guest } = await groupWithGuest("video-range");
    const clip = fakeClip(2000);
    await shareClip(guest, group.id, clip);
    const [item] = await (await api(`/groups/${group.id}/items`, { token: host })).json<any[]>();

    const ranged = await api(item.downloadUrl, { headers: { Range: "bytes=100-199" } });

    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("Content-Range")).toBe("bytes 100-199/2000");
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(clip.slice(100, 200));
    const whole = await api(item.downloadUrl);
    expect(whole.status).toBe(200);
    expect(whole.headers.get("Accept-Ranges")).toBe("bytes");
  });
});
