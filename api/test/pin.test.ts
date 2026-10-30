import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, init: RequestInit & { token?: string; ip?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  if (init.ip) headers.set("CF-Connecting-IP", init.ip);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers, redirect: "manual" });
}

async function createGroup(host: string) {
  const res = await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) });
  return res.json<any>();
}

function pinFor(host: string, groupId: string) {
  return api(`/groups/${groupId}/pin`, { token: host });
}

function enablePin(host: string, groupId: string) {
  return api(`/groups/${groupId}/pin`, { method: "POST", token: host });
}

describe("GET /groups/:id/pin", () => {
  it("is off by default", async () => {
    const group = await createGroup("host-pin-default");

    const res = await pinFor("host-pin-default", group.id);

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ pin: null });
  });
});

describe("POST /groups/:id/pin", () => {
  it("turns the PIN on with 6 characters that have no look-alikes", async () => {
    const group = await createGroup("host-pin-on");

    const res = await enablePin("host-pin-on", group.id);

    expect(res.status).toBe(200);
    const { pin } = await res.json<any>();
    expect(pin).toMatch(/^[A-HJKMNP-Z2-9]{6}$/);
    expect(await (await pinFor("host-pin-on", group.id)).json()).toEqual({ pin });
  });

  it("is only for the host", async () => {
    const group = await createGroup("host-pin-private");

    expect((await enablePin("someone-else", group.id)).status).toBe(404);
    expect((await pinFor("someone-else", group.id)).status).toBe(404);
  });

  it("is also for a co-host the host promoted, but not for other guests", async () => {
    const group = await createGroup("host-pin-cohost");
    const { qrToken } = await (await api(`/groups/${group.id}/invite`, { token: "host-pin-cohost" })).json<any>();
    const join = (token: string) =>
      api("/join", { method: "POST", token, body: JSON.stringify({ qrToken, ...consentingGuest }) }).then((r) => r.json<any>());
    const { member } = await join("cohost-pin");
    await join("guest-pin");
    await api(`/groups/${group.id}/members/${member.id}/co-host`, { method: "POST", token: "host-pin-cohost" });

    const res = await enablePin("cohost-pin", group.id);

    expect(res.status).toBe(200);
    expect(await (await pinFor("host-pin-cohost", group.id)).json()).toEqual(await res.json());
    expect((await pinFor("guest-pin", group.id)).status).toBe(404);
  });
});

function join(guest: string, body: object, ip = "203.0.113.50") {
  return api("/join", { method: "POST", token: guest, ip, body: JSON.stringify(body) });
}

const consentingGuest = { displayName: "Sleepy Panda", colour: "#3DDC84", consent: true };

async function groupWithPin(host: string) {
  const group = await createGroup(host);
  const { pin } = await (await enablePin(host, group.id)).json<any>();
  return { group, pin: pin as string };
}

describe("POST /join with a PIN", () => {
  it("makes a consenting guest a member, however they type the PIN", async () => {
    const { group, pin } = await groupWithPin("host-pin-join");
    const typed = `${pin.slice(0, 3).toLowerCase()} ${pin.slice(3)}`;

    const res = await join("guest-pin-join", { pin: typed, ...consentingGuest });

    expect(res.status).toBe(201);
    const body = await res.json<any>();
    expect(body.group).toEqual(group);
    expect(body.member).toMatchObject({ displayName: "Sleepy Panda", role: "guest" });
  });
});

describe("rotating and turning off the PIN", () => {
  it("rotating gives a new PIN and the old one stops working", async () => {
    const { group, pin: oldPin } = await groupWithPin("host-pin-rotate");

    const { pin: newPin } = await (await enablePin("host-pin-rotate", group.id)).json<any>();

    expect(newPin).not.toBe(oldPin);
    expect((await join("guest-old-pin", { pin: oldPin, ...consentingGuest })).status).toBe(404);
    expect((await join("guest-new-pin", { pin: newPin, ...consentingGuest })).status).toBe(201);
  });
});

describe("DELETE /groups/:id/pin", () => {
  it("turns the PIN off so it no longer lets anyone in", async () => {
    const { group, pin } = await groupWithPin("host-pin-off");

    const res = await api(`/groups/${group.id}/pin`, { method: "DELETE", token: "host-pin-off" });

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ pin: null });
    expect(await (await pinFor("host-pin-off", group.id)).json()).toEqual({ pin: null });
    expect((await join("guest-pin-off", { pin, ...consentingGuest })).status).toBe(404);
  });
});

describe("PIN join uses the same safeguards as QR", () => {
  it("rate-limits PIN guessing from one network, even across device tokens", async () => {
    const ip = "192.0.2.140";
    for (let i = 0; i < 10; i++) {
      expect((await join(`pin-guesser-${i}`, { pin: "ZZZZZ" + i, ...consentingGuest }, ip)).status).toBe(404);
    }
    const { pin } = await groupWithPin("host-pin-ratelimit");

    const res = await join("pin-guesser-final", { pin, ...consentingGuest }, ip);

    expect(res.status).toBe(429);
  });

  it("enforces the tier's people cap", async () => {
    const { pin } = await groupWithPin("host-pin-cap");
    for (const guest of ["pin-cap-1", "pin-cap-2", "pin-cap-3"]) {
      expect((await join(guest, { pin, ...consentingGuest })).status).toBe(201);
    }

    expect((await join("pin-cap-4", { pin, ...consentingGuest })).status).toBe(409);
  });

  it("only works while the group is Active", async () => {
    const { group, pin } = await groupWithPin("host-pin-expired");
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 1000).toISOString(), group.id)
      .run();

    expect((await join("guest-pin-late", { pin, ...consentingGuest })).status).toBe(410);
  });

  it("still requires consent", async () => {
    const { pin } = await groupWithPin("host-pin-consent");

    expect((await join("guest-pin-noconsent", { pin, ...consentingGuest, consent: false })).status).toBe(400);
  });
});

describe("PIN join respects host controls and approval", () => {
  it("is rejected while joining is paused", async () => {
    const { group, pin } = await groupWithPin("host-pin-paused");
    const paused = await api(`/groups/${group.id}/joining`, {
      method: "PUT",
      token: "host-pin-paused",
      body: JSON.stringify({ paused: true }),
    });
    expect(paused.status).toBe(200);

    expect((await join("guest-pin-paused", { pin, ...consentingGuest })).status).toBe(403);
  });

  it("rejects a banned device", async () => {
    const { group, pin } = await groupWithPin("host-pin-ban");
    const { member } = await (await join("guest-pin-ban", { pin, ...consentingGuest })).json<any>();
    expect(
      (await api(`/groups/${group.id}/members/${member.id}/ban`, { method: "POST", token: "host-pin-ban" })).status,
    ).toBe(204);

    expect((await join("guest-pin-ban", { pin, ...consentingGuest })).status).toBe(403);
  });

  it("leaves the guest pending when approval is on", async () => {
    const { group, pin } = await groupWithPin("host-pin-approval");
    const approval = await api(`/groups/${group.id}/approval`, {
      method: "PUT",
      token: "host-pin-approval",
      body: JSON.stringify({ approvalRequired: true }),
    });
    expect(approval.status).toBe(200);

    const res = await join("guest-pin-approval", { pin, ...consentingGuest });

    expect(res.status).toBe(202);
    expect((await res.json<any>()).member.status).toBe("pending");
  });
});
