import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers });
}

async function groupWithApproval(host: string) {
  const group = await (await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) })).json<any>();
  const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: host })).json<any>();
  const res = await api(`/groups/${group.id}/approval`, {
    method: "PUT",
    token: host,
    body: JSON.stringify({ approvalRequired: true }),
  });
  expect(res.status).toBe(200);
  return { group, qrToken };
}

function join(guest: string, qrToken: string, displayName = "Dancing Otter") {
  return api("/join", {
    method: "POST",
    token: guest,
    body: JSON.stringify({ qrToken, displayName, colour: "#FF8800", consent: true }),
  });
}

describe("approve-new-members toggle", () => {
  it("makes a new join pending, and a pending guest cannot see the group", async () => {
    const { group, qrToken } = await groupWithApproval("host-pending");

    const res = await join("guest-pending", qrToken);

    expect(res.status).toBe(202);
    expect((await res.json<any>()).member).toMatchObject({ displayName: "Dancing Otter", status: "pending" });
    expect((await api(`/groups/${group.id}/members`, { token: "guest-pending" })).status).toBe(404);
    expect(await (await api(`/groups/${group.id}/members`, { token: "host-pending" })).json()).toEqual([]);
  });

  it("keeps a pending guest pending when they scan again", async () => {
    const { qrToken } = await groupWithApproval("host-repeat");
    const first = await (await join("guest-repeat", qrToken)).json<any>();

    const again = await join("guest-repeat", qrToken);

    expect(again.status).toBe(202);
    expect((await again.json<any>()).member).toEqual(first.member);
  });

  it("lets the host see pending requests and approve one into the group", async () => {
    const { group, qrToken } = await groupWithApproval("host-approve");
    await join("guest-approve", qrToken, "Brave Llama");

    const pending = await (await api(`/groups/${group.id}/pending`, { token: "host-approve" })).json<any[]>();
    expect(pending.map((m) => m.displayName)).toEqual(["Brave Llama"]);

    const res = await api(`/groups/${group.id}/members/${pending[0].id}/approve`, { method: "POST", token: "host-approve" });

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ displayName: "Brave Llama", status: "active" });
    expect(await (await api(`/groups/${group.id}/pending`, { token: "host-approve" })).json()).toEqual([]);
    expect((await api(`/groups/${group.id}/members`, { token: "guest-approve" })).status).toBe(200);
    expect((await join("guest-approve", qrToken)).status).toBe(200);
  });

  it("lets the host reject a request, which the guest cannot repeat", async () => {
    const { group, qrToken } = await groupWithApproval("host-reject");
    const { member } = await (await join("guest-reject", qrToken)).json<any>();

    const res = await api(`/groups/${group.id}/members/${member.id}/reject`, { method: "POST", token: "host-reject" });

    expect(res.status).toBe(204);
    expect(await (await api(`/groups/${group.id}/pending`, { token: "host-reject" })).json()).toEqual([]);
    expect((await join("guest-reject", qrToken)).status).toBe(403);
    expect((await api(`/groups/${group.id}/members/${member.id}/approve`, { method: "POST", token: "host-reject" })).status).toBe(404);
  });

  it("does not approve past the people cap", async () => {
    const { group, qrToken } = await groupWithApproval("host-full");
    const requests = [];
    for (const guest of ["full-1", "full-2", "full-3", "full-4"]) {
      requests.push((await (await join(guest, qrToken)).json<any>()).member);
    }
    const decide = (id: string) => api(`/groups/${group.id}/members/${id}/approve`, { method: "POST", token: "host-full" });
    for (const m of requests.slice(0, 3)) expect((await decide(m.id)).status).toBe(200);

    expect((await decide(requests[3].id)).status).toBe(409);
  });

  it("is off by default, and turning it off admits new guests immediately", async () => {
    const { group, qrToken } = await groupWithApproval("host-off");
    const toggle = `/groups/${group.id}/approval`;

    const off = await api(toggle, { method: "PUT", token: "host-off", body: JSON.stringify({ approvalRequired: false }) });

    expect(await off.json()).toEqual({ approvalRequired: false });
    expect((await join("guest-off", qrToken)).status).toBe(201);
    const fresh = await (await api("/groups", { method: "POST", token: "host-off", body: JSON.stringify({ tier: "taster" }) })).json<any>();
    expect(await (await api(`/groups/${fresh.id}/approval`, { token: "host-off" })).json()).toEqual({ approvalRequired: false });
  });

  it("lets an active co-host act on requests too", async () => {
    const { group, qrToken } = await groupWithApproval("host-cohost");
    const { member: helper } = await (await join("guest-cohost", qrToken)).json<any>();
    await api(`/groups/${group.id}/members/${helper.id}/approve`, { method: "POST", token: "host-cohost" });
    const promoted = await api(`/groups/${group.id}/members/${helper.id}/co-host`, { method: "POST", token: "host-cohost" });
    expect(promoted.status).toBe(204);
    const { member } = await (await join("guest-for-cohost", qrToken)).json<any>();

    const res = await api(`/groups/${group.id}/members/${member.id}/approve`, { method: "POST", token: "guest-cohost" });

    expect(res.status).toBe(200);
  });

  it("keeps the toggle and pending requests away from guests and strangers", async () => {
    const { group, qrToken } = await groupWithApproval("host-guarded");
    const { member } = await (await join("guest-guarded", qrToken)).json<any>();

    for (const token of ["guest-guarded", "stranger"]) {
      expect((await api(`/groups/${group.id}/approval`, { token })).status).toBe(404);
      expect((await api(`/groups/${group.id}/approval`, { method: "PUT", token, body: '{"approvalRequired":false}' })).status).toBe(404);
      expect((await api(`/groups/${group.id}/pending`, { token })).status).toBe(404);
      expect((await api(`/groups/${group.id}/members/${member.id}/approve`, { method: "POST", token })).status).toBe(404);
    }
  });
});
