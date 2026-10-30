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

async function inviteFor(host: string, groupId: string) {
  return (await api(`/groups/${groupId}/invite`, { token: host })).json<any>();
}

function join(guest: string, body: object, ip = "203.0.113.1") {
  return api("/join", { method: "POST", token: guest, ip, body: JSON.stringify(body) });
}

const consentingGuest = { displayName: "Dancing Otter", colour: "#FF8800", consent: true };

describe("GET /groups/:id/invite", () => {
  it("gives the host a long random QR token and a join link that stays stable", async () => {
    const group = await createGroup("host-invite");

    const res = await api(`/groups/${group.id}/invite`, { token: "host-invite" });

    expect(res.status).toBe(200);
    const invite = await res.json<any>();
    expect(invite.qrToken).toMatch(/^[A-Za-z0-9_-]{43,}$/);
    expect(invite.joinUrl).toBe(`https://api.test/join/${invite.qrToken}`);
    expect(await inviteFor("host-invite", group.id)).toEqual(invite);
  });

  it("is hidden from anyone but the host", async () => {
    const group = await createGroup("host-private");

    const res = await api(`/groups/${group.id}/invite`, { token: "someone-else" });

    expect(res.status).toBe(404);
  });
});

describe("POST /join", () => {
  it("makes a consenting guest a member with their fun name and colour", async () => {
    const group = await createGroup("host-join");
    const { qrToken } = await inviteFor("host-join", group.id);

    const res = await join("guest-join", { qrToken, ...consentingGuest });

    expect(res.status).toBe(201);
    const body = await res.json<any>();
    expect(body.group).toEqual(group);
    expect(body.member).toMatchObject({ displayName: "Dancing Otter", colour: "#FF8800", role: "guest" });
    expect(Date.parse(body.member.consentAcceptedAt)).not.toBeNaN();
  });

  it("refuses a guest who has not accepted the consent screen", async () => {
    const group = await createGroup("host-noconsent");
    const { qrToken } = await inviteFor("host-noconsent", group.id);

    const res = await join("guest-noconsent", { qrToken, ...consentingGuest, consent: false });

    expect(res.status).toBe(400);
  });

  it("refuses a blank display name or a colour that is not #RRGGBB", async () => {
    const group = await createGroup("host-badinput");
    const { qrToken } = await inviteFor("host-badinput", group.id);

    expect((await join("guest-bad-1", { qrToken, ...consentingGuest, displayName: "   " })).status).toBe(400);
    expect((await join("guest-bad-2", { qrToken, ...consentingGuest, colour: "red" })).status).toBe(400);
  });

  it("lets a member rescan without taking another seat", async () => {
    const group = await createGroup("host-rescan");
    const { qrToken } = await inviteFor("host-rescan", group.id);
    const first = await (await join("guest-rescan", { qrToken, ...consentingGuest })).json<any>();

    const again = await join("guest-rescan", { qrToken, ...consentingGuest, displayName: "New Name" });

    expect(again.status).toBe(200);
    expect((await again.json<any>()).member).toEqual(first.member);
  });

  it("enforces the tier's people cap, counting the host", async () => {
    const group = await createGroup("host-cap");
    const { qrToken } = await inviteFor("host-cap", group.id);
    for (const guest of ["cap-1", "cap-2", "cap-3"]) {
      expect((await join(guest, { qrToken, ...consentingGuest })).status).toBe(201);
    }

    const res = await join("cap-4", { qrToken, ...consentingGuest });

    expect(res.status).toBe(409);
  });

  it("rejects an unknown token", async () => {
    const res = await join("guest-unknown", { qrToken: "not-a-real-token", ...consentingGuest }, "198.51.100.7");
    expect(res.status).toBe(404);
  });

  it("only accepts the token while the group is Active", async () => {
    const group = await createGroup("host-expired");
    const { qrToken } = await inviteFor("host-expired", group.id);
    await env.DB.prepare("UPDATE groups SET ends_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 1000).toISOString(), group.id)
      .run();

    const res = await join("guest-late", { qrToken, ...consentingGuest });

    expect(res.status).toBe(410);
  });

  it("lets an existing member back in after the group ended (Grace), but no one new", async () => {
    const group = await createGroup("host-grace");
    const { qrToken } = await inviteFor("host-grace", group.id);
    await join("guest-grace", { qrToken, ...consentingGuest });
    await env.DB.prepare("UPDATE groups SET state = 'Grace', ends_at = ?, grace_ends_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 1000).toISOString(), new Date(Date.now() + 86_400_000).toISOString(), group.id)
      .run();

    const back = await join("guest-grace", { qrToken });

    expect(back.status).toBe(200);
    expect((await back.json<any>()).group).toMatchObject({ id: group.id, state: "Grace" });
    expect((await join("guest-new", { qrToken, ...consentingGuest })).status).toBe(410);
  });

  it("rate-limits repeated guessing from one network, even across device tokens", async () => {
    const ip = "192.0.2.99";
    for (let i = 0; i < 10; i++) {
      expect((await join(`guesser-${i}`, { qrToken: `guess-${i}`, ...consentingGuest }, ip)).status).toBe(404);
    }
    const group = await createGroup("host-ratelimit");
    const { qrToken } = await inviteFor("host-ratelimit", group.id);

    const res = await join("guesser-final", { qrToken, ...consentingGuest }, ip);

    expect(res.status).toBe(429);
  });

  it("rate-limits repeated guessing from one device, even across networks", async () => {
    for (let i = 0; i < 10; i++) {
      expect((await join("guessing-device", { qrToken: `guess-${i}` }, `10.0.0.${i}`)).status).toBe(404);
    }

    const res = await join("guessing-device", { qrToken: "guess-x" }, "10.0.1.1");

    expect(res.status).toBe(429);
  });
});

describe("GET /memberships", () => {
  it("lists the groups the device is an active member of, so the app can restore them at launch", async () => {
    const [ended, current, removedFrom] = [await createGroup("host-ms-1"), await createGroup("host-ms-2"), await createGroup("host-ms-3")];
    const joinAs = async (host: string, groupId: string, token: string) =>
      (await join(token, { qrToken: (await inviteFor(host, groupId)).qrToken, ...consentingGuest })).json<any>();
    const first = await joinAs("host-ms-1", ended.id, "guest-ms");
    const second = await joinAs("host-ms-2", current.id, "guest-ms");
    await api(`/groups/${current.id}/members/${second.member.id}/co-host`, { method: "POST", token: "host-ms-2" });
    const third = await joinAs("host-ms-3", removedFrom.id, "guest-ms");
    await api(`/groups/${removedFrom.id}/members/${third.member.id}/remove`, { method: "POST", token: "host-ms-3" });
    await env.DB.prepare("UPDATE groups SET state = 'Grace', grace_ends_at = ? WHERE id = ?")
      .bind(new Date(Date.now() + 86_400_000).toISOString(), ended.id)
      .run();

    const res = await api("/memberships", { token: "guest-ms" });

    expect(res.status).toBe(200);
    const memberships = await res.json<any[]>();
    expect(memberships.map((m) => [m.group.id, m.group.state, m.member.id, m.member.role])).toEqual([
      [current.id, "Active", second.member.id, "co-host"],
      [ended.id, "Grace", first.member.id, "guest"],
    ]);
    expect(await (await api("/memberships", { token: "host-ms-1" })).json()).toEqual([]);
  });
});

describe("GET /groups/:id/members", () => {
  it("shows the host who has joined, in join order", async () => {
    const group = await createGroup("host-members");
    const { qrToken } = await inviteFor("host-members", group.id);
    await join("member-a", { qrToken, ...consentingGuest, displayName: "Alpha" });
    await join("member-b", { qrToken, ...consentingGuest, displayName: "Bravo" });

    const res = await api(`/groups/${group.id}/members`, { token: "host-members" });

    expect(res.status).toBe(200);
    const members = await res.json<any[]>();
    expect(members.map((m) => m.displayName)).toEqual(["Alpha", "Bravo"]);
  });

  it("is visible to members but not to strangers", async () => {
    const group = await createGroup("host-visibility");
    const { qrToken } = await inviteFor("host-visibility", group.id);
    await join("member-visible", { qrToken, ...consentingGuest });

    expect((await api(`/groups/${group.id}/members`, { token: "member-visible" })).status).toBe(200);
    expect((await api(`/groups/${group.id}/members`, { token: "stranger" })).status).toBe(404);
  });
});

describe("GET /join/:token (QR scanned without the app)", () => {
  it("needs no device token and sends the visitor to the App Store", async () => {
    const res = await api("/join/some-token");

    expect(res.status).toBe(302);
    expect(res.headers.get("Location")).toMatch(/^https:\/\/apps\.apple\.com\//);
  });
});

describe("apple-app-site-association", () => {
  it("claims /join/* links for the app without a device token", async () => {
    const res = await api("/.well-known/apple-app-site-association");

    expect(res.status).toBe(200);
    const aasa = await res.json<any>();
    expect(aasa.applinks.details[0].components).toEqual([{ "/": "/join/*" }]);
  });
});
