import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { storageLevel } from "../src/storageCap";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers });
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

/** Sets usage and cap directly, as a purchase or deletion would (which also clears the refused-upload flag). */
async function setUsage(groupId: string, usedBytes: number, capBytes: number) {
  await env.DB.prepare("UPDATE groups SET storage_used_bytes = ?, storage_cap_bytes = ?, storage_full = 0 WHERE id = ?")
    .bind(usedBytes, capBytes, groupId)
    .run();
}

function requestUpload(token: string, groupId: string, path: "uploads" | "multipart", bytes = 1) {
  return api(`/groups/${groupId}/${path}`, { method: "POST", token, body: JSON.stringify({ bytes, contentType: "image/heic" }) });
}

describe("storageLevel", () => {
  it("warns from 80% and is full from 100%", () => {
    expect(storageLevel(0, 100)).toBe("ok");
    expect(storageLevel(79, 100)).toBe("ok");
    expect(storageLevel(80, 100)).toBe("nearlyFull");
    expect(storageLevel(99, 100)).toBe("nearlyFull");
    expect(storageLevel(100, 100)).toBe("full");
    expect(storageLevel(120, 100)).toBe("full");
  });

  it("treats a group without any storage as full", () => {
    expect(storageLevel(0, 0)).toBe("full");
  });
});

describe("group JSON", () => {
  it("tells the host how full storage is", async () => {
    const { group, host } = await groupWithGuest("level-host");
    expect(group.storageLevel).toBe("ok");

    await setUsage(group.id, 850, 1000);

    const [mine] = await (await api("/groups", { token: host })).json<any[]>();
    expect(mine).toMatchObject({ storageUsedBytes: 850, storageCapBytes: 1000, storageLevel: "nearlyFull" });
  });
});

describe("GET /groups/:id/storage", () => {
  it("shows guests and the host the group's usage, cap and level", async () => {
    const { group, host, guest } = await groupWithGuest("storage-get");
    await setUsage(group.id, 1000, 1000);

    for (const token of [host, guest]) {
      const response = await api(`/groups/${group.id}/storage`, { token });
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ storageUsedBytes: 1000, storageCapBytes: 1000, storageLevel: "full" });
    }
  });

  it("is hidden from outsiders and inactive members", async () => {
    const { group, guest } = await groupWithGuest("storage-outsider");
    expect((await api(`/groups/${group.id}/storage`, { token: "stranger" })).status).toBe(404);

    await env.DB.prepare("UPDATE members SET status = 'pending' WHERE group_id = ?").bind(group.id).run();
    expect((await api(`/groups/${group.id}/storage`, { token: guest })).status).toBe(404);
  });
});

describe("uploads at the storage cap", () => {
  it("refuses new upload URLs while full and accepts them again once the cap is raised", async () => {
    const { group, guest } = await groupWithGuest("cap-pause");
    await setUsage(group.id, 1000, 1000);

    expect((await requestUpload(guest, group.id, "uploads")).status).toBe(413);
    expect((await requestUpload(guest, group.id, "multipart")).status).toBe(413);

    await setUsage(group.id, 1000, 2000);

    expect((await requestUpload(guest, group.id, "uploads")).status).toBe(201);
    expect((await requestUpload(guest, group.id, "multipart")).status).toBe(201);
    expect(await (await api(`/groups/${group.id}/storage`, { token: guest })).json()).toMatchObject({ storageLevel: "ok" });
  });
});
