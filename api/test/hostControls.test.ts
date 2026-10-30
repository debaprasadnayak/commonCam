import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(`https://api.test${path}`, { ...init, headers, redirect: "manual" });
}

async function createGroup(host: string) {
  const res = await api("/groups", { method: "POST", token: host, body: JSON.stringify({ tier: "taster" }) });
  return res.json<any>();
}

async function inviteFor(caller: string, groupId: string) {
  return (await api(`/groups/${groupId}/invite`, { token: caller })).json<any>();
}

function join(guest: string, qrToken: string) {
  return api("/join", {
    method: "POST",
    token: guest,
    body: JSON.stringify({ qrToken, displayName: "Dancing Otter", colour: "#FF8800", consent: true }),
  });
}

function setPaused(caller: string, groupId: string, paused: boolean) {
  return api(`/groups/${groupId}/joining`, { method: "PUT", token: caller, body: JSON.stringify({ paused }) });
}

describe("pausing joins", () => {
  it("rejects joins while paused and accepts them again once resumed", async () => {
    const group = await createGroup("host-pause");
    const { qrToken } = await inviteFor("host-pause", group.id);

    const paused = await setPaused("host-pause", group.id, true);
    expect(paused.status).toBe(200);
    expect(await paused.json()).toEqual({ joiningPaused: true });
    expect((await inviteFor("host-pause", group.id)).joiningPaused).toBe(true);
    expect((await join("guest-pause", qrToken)).status).toBe(403);

    await setPaused("host-pause", group.id, false);
    expect((await join("guest-pause", qrToken)).status).toBe(201);
  });

  it("still lets an existing member rescan while paused", async () => {
    const group = await createGroup("host-pause-rescan");
    const { qrToken } = await inviteFor("host-pause-rescan", group.id);
    await join("guest-pause-rescan", qrToken);
    await setPaused("host-pause-rescan", group.id, true);

    expect((await join("guest-pause-rescan", qrToken)).status).toBe(200);
  });

  it("is refused to guests and strangers", async () => {
    const group = await createGroup("host-pause-guard");
    const { qrToken } = await inviteFor("host-pause-guard", group.id);
    await join("guest-pause-guard", qrToken);

    expect((await setPaused("guest-pause-guard", group.id, true)).status).toBe(404);
    expect((await setPaused("stranger-pause-guard", group.id, true)).status).toBe(404);
    expect((await setPaused("host-pause-guard", group.id, "yes" as any)).status).toBe(400);
  });
});

describe("rotating the QR", () => {
  it("issues a new token and the old one stops working", async () => {
    const group = await createGroup("host-rotate");
    const old = await inviteFor("host-rotate", group.id);

    const res = await api(`/groups/${group.id}/invite/rotate`, { method: "POST", token: "host-rotate" });

    expect(res.status).toBe(200);
    const rotated = await res.json<any>();
    expect(rotated.qrToken).toMatch(/^[A-Za-z0-9_-]{43,}$/);
    expect(rotated.qrToken).not.toBe(old.qrToken);
    expect(rotated.joinUrl).toBe(`https://api.test/join/${rotated.qrToken}`);
    expect(await inviteFor("host-rotate", group.id)).toEqual(rotated);
    expect((await join("guest-rotate-old", old.qrToken)).status).toBe(404);
    expect((await join("guest-rotate-new", rotated.qrToken)).status).toBe(201);
  });

  it("is refused to guests", async () => {
    const group = await createGroup("host-rotate-guard");
    const { qrToken } = await inviteFor("host-rotate-guard", group.id);
    await join("guest-rotate-guard", qrToken);

    const res = await api(`/groups/${group.id}/invite/rotate`, { method: "POST", token: "guest-rotate-guard" });

    expect(res.status).toBe(404);
    expect((await inviteFor("host-rotate-guard", group.id)).qrToken).toBe(qrToken);
  });
});

async function joinedMember(host: string, guest: string) {
  const group = await createGroup(host);
  const { qrToken } = await inviteFor(host, group.id);
  const { member } = await (await join(guest, qrToken)).json<any>();
  return { group, qrToken, member };
}

function act(caller: string, groupId: string, memberId: string, action: "remove" | "ban" | "co-host") {
  return api(`/groups/${groupId}/members/${memberId}/${action}`, { method: "POST", token: caller });
}

async function memberNames(caller: string, groupId: string) {
  return (await (await api(`/groups/${groupId}/members`, { token: caller })).json<any[]>()).map((m) => m.displayName);
}

describe("removing a member", () => {
  it("takes away their access and their seat, but they may rejoin", async () => {
    const { group, qrToken, member } = await joinedMember("host-remove", "guest-remove");

    expect((await act("host-remove", group.id, member.id, "remove")).status).toBe(204);

    expect(await memberNames("host-remove", group.id)).toEqual([]);
    expect((await api(`/groups/${group.id}/members`, { token: "guest-remove" })).status).toBe(404);
    const rejoin = await join("guest-remove", qrToken);
    expect(rejoin.status).toBe(201);
    expect((await rejoin.json<any>()).member.id).toBe(member.id);
    expect(await memberNames("host-remove", group.id)).toEqual(["Dancing Otter"]);
  });

  it("is refused to guests and for members of other groups", async () => {
    const { group, qrToken, member } = await joinedMember("host-remove-guard", "guest-remove-guard");
    await join("other-guest-remove-guard", qrToken);
    const other = await joinedMember("host-remove-other", "guest-remove-other");

    expect((await act("other-guest-remove-guard", group.id, member.id, "remove")).status).toBe(404);
    expect((await act("host-remove-guard", group.id, other.member.id, "remove")).status).toBe(404);
    expect(await memberNames("host-remove-guard", group.id)).toHaveLength(2);
  });
});

describe("banning a member", () => {
  it("takes away their access and stops that device rejoining, even with a new QR", async () => {
    const { group, qrToken, member } = await joinedMember("host-ban", "guest-ban");

    expect((await act("host-ban", group.id, member.id, "ban")).status).toBe(204);

    expect((await api(`/groups/${group.id}/members`, { token: "guest-ban" })).status).toBe(404);
    expect((await join("guest-ban", qrToken)).status).toBe(403);
    const rotated = await (await api(`/groups/${group.id}/invite/rotate`, { method: "POST", token: "host-ban" })).json<any>();
    expect((await join("guest-ban", rotated.qrToken)).status).toBe(403);
    expect((await join("guest-ban-friend", rotated.qrToken)).status).toBe(201);
  });

  it("also works on a member who was already removed", async () => {
    const { group, qrToken, member } = await joinedMember("host-ban-removed", "guest-ban-removed");
    await act("host-ban-removed", group.id, member.id, "remove");

    expect((await act("host-ban-removed", group.id, member.id, "ban")).status).toBe(204);
    expect((await join("guest-ban-removed", qrToken)).status).toBe(403);
  });
});

describe("co-host", () => {
  it("is shown as co-host and can perform every host control", async () => {
    const { group, qrToken, member } = await joinedMember("host-cohost", "cohost");
    const { member: guest } = await (await join("guest-cohost", qrToken)).json<any>();

    expect((await act("host-cohost", group.id, member.id, "co-host")).status).toBe(204);
    const roles = (await (await api(`/groups/${group.id}/members`, { token: "host-cohost" })).json<any[]>()).map((m) => m.role);
    expect(roles).toEqual(["co-host", "guest"]);

    expect((await inviteFor("cohost", group.id)).qrToken).toBe(qrToken);
    expect((await setPaused("cohost", group.id, true)).status).toBe(200);
    expect((await setPaused("cohost", group.id, false)).status).toBe(200);
    expect((await api(`/groups/${group.id}/invite/rotate`, { method: "POST", token: "cohost" })).status).toBe(200);
    expect((await act("cohost", group.id, guest.id, "remove")).status).toBe(204);
    expect((await act("cohost", group.id, guest.id, "ban")).status).toBe(204);
  });

  it("can only be granted by the host or a co-host", async () => {
    const { group, qrToken, member } = await joinedMember("host-cohost-guard", "guest-cohost-guard");
    await join("guest-cohost-guard-2", qrToken);

    expect((await act("guest-cohost-guard-2", group.id, member.id, "co-host")).status).toBe(404);
  });

  it("loses host powers when removed", async () => {
    const { group, qrToken, member } = await joinedMember("host-cohost-removed", "cohost-removed");
    await act("host-cohost-removed", group.id, member.id, "co-host");
    await act("host-cohost-removed", group.id, member.id, "remove");

    expect((await setPaused("cohost-removed", group.id, true)).status).toBe(404);
    const rejoin = await (await join("cohost-removed", qrToken)).json<any>();
    expect(rejoin.member.role).toBe("guest");
  });
});
