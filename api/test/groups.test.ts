import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

const DAY_MS = 24 * 60 * 60 * 1000;

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers });
}

describe("POST /groups", () => {
  it("creates an Active Taster group with Taster limits lasting one day", async () => {
    const res = await api("/groups", {
      method: "POST",
      token: "host-device-token",
      body: JSON.stringify({ tier: "taster" }),
    });

    expect(res.status).toBe(201);
    const group = await res.json<any>();
    expect(group).toMatchObject({
      tier: "taster",
      state: "Active",
      peopleCap: 4,
      storageCapBytes: 1_073_741_824,
    });
    expect(typeof group.id).toBe("string");
    expect(Date.parse(group.endsAt) - Date.parse(group.startsAt)).toBe(DAY_MS);
  });

  it("rejects paid tiers, which need a purchase", async () => {
    const res = await api("/groups", {
      method: "POST",
      token: "host-device-token",
      body: JSON.stringify({ tier: "party" }),
    });
    expect(res.status).toBe(400);
  });
});

describe("device token", () => {
  it("is required on every call", async () => {
    const res = await api("/groups", { method: "POST", body: JSON.stringify({ tier: "taster" }) });
    expect(res.status).toBe(401);
  });
});

describe("GET /groups", () => {
  it("lists the stored groups hosted by the calling device only", async () => {
    const created = await (
      await api("/groups", { method: "POST", token: "host-a", body: JSON.stringify({ tier: "taster" }) })
    ).json<any>();
    await api("/groups", { method: "POST", token: "host-b", body: JSON.stringify({ tier: "taster" }) });

    const res = await api("/groups", { token: "host-a" });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([created]);
  });
});
