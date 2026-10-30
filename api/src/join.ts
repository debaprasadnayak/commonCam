import { isHostOrCoHost, isJoiningPaused, joinRefusal } from "./hostControls";
import { type Env, type GroupRow, toJson } from "./index";

// Placeholders until the app is in App Store Connect and has an Apple team (see notes).
const APP_STORE_URL = "https://apps.apple.com/app/commoncam/id0000000000";
const APPLE_APP_ID = "TEAMID0000.app.commoncam.CommonCam";

const MAX_FAILURES = 10;
const FAILURE_WINDOW_MS = 10 * 60 * 1000;

interface MemberRow {
  id: string;
  display_name: string;
  colour: string;
  role: string;
  consent_accepted_at: string;
  joined_at: string;
}

const MEMBER_COLUMNS = "id, display_name, colour, role, consent_accepted_at, joined_at";
const GROUP_COLUMNS = "id, tier, state, people_cap, storage_cap_bytes, starts_at, ends_at";

/** Routes reachable without a device token: what a phone without the app sees after scanning. */
export function handlePublic(url: URL): Response | null {
  if (url.pathname === "/.well-known/apple-app-site-association") {
    return Response.json({
      applinks: { details: [{ appIDs: [APPLE_APP_ID], components: [{ "/": "/join/*" }] }] },
    });
  }
  // Only reached when the app is not installed; otherwise iOS opens the universal link in the app.
  if (url.pathname.startsWith("/join/")) {
    return Response.redirect(APP_STORE_URL, 302);
  }
  return null;
}

export async function handleJoin(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const groupRoute = url.pathname.match(/^\/groups\/([^/]+)\/(invite|members)$/);
  if (groupRoute && request.method === "GET") {
    const [, groupId, resource] = groupRoute;
    return resource === "invite" ? invite(env, url, groupId, deviceId) : members(env, groupId, deviceId);
  }
  if (url.pathname === "/join" && request.method === "POST") {
    return join(request, env, deviceId);
  }
  return null;
}

export async function invite(env: Env, url: URL, groupId: string, deviceId: string): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const group = (await env.DB.prepare("SELECT qr_token FROM groups WHERE id = ?").bind(groupId).first<{ qr_token: string | null }>())!;

  let qrToken = group.qr_token;
  if (!qrToken) {
    await env.DB.prepare("UPDATE groups SET qr_token = ? WHERE id = ? AND qr_token IS NULL")
      .bind(randomToken(), groupId)
      .run();
    qrToken = (await env.DB.prepare("SELECT qr_token FROM groups WHERE id = ?").bind(groupId).first<string>("qr_token"))!;
  }
  return Response.json({ qrToken, joinUrl: `${url.origin}/join/${qrToken}`, joiningPaused: await isJoiningPaused(env, groupId) });
}

async function members(env: Env, groupId: string, deviceId: string): Promise<Response> {
  const allowed = await env.DB.prepare(
    `SELECT 1 FROM groups WHERE id = ?1 AND (host_device_id = ?2 OR EXISTS
       (SELECT 1 FROM members WHERE group_id = ?1 AND device_id = ?2 AND status = 'active'))`,
  )
    .bind(groupId, deviceId)
    .first();
  if (!allowed) return new Response("Not found", { status: 404 });

  const { results } = await env.DB.prepare(
    `SELECT ${MEMBER_COLUMNS} FROM members WHERE group_id = ? AND status = 'active' ORDER BY joined_at, rowid`,
  )
    .bind(groupId)
    .all<MemberRow>();
  return Response.json(results.map(memberJson));
}

async function join(request: Request, env: Env, deviceId: string): Promise<Response> {
  const keys = [`device:${deviceId}`];
  const ip = request.headers.get("CF-Connecting-IP");
  if (ip) keys.push(`ip:${ip}`);
  if (await isRateLimited(env, keys)) return new Response("Too many attempts, try again later", { status: 429 });

  const body = await request
    .json<{ qrToken?: unknown; displayName?: unknown; colour?: unknown; consent?: unknown }>()
    .catch(() => ({}) as Record<string, unknown>);
  const group =
    typeof body.qrToken === "string"
      ? await env.DB.prepare(`SELECT ${GROUP_COLUMNS} FROM groups WHERE qr_token = ?`).bind(body.qrToken).first<GroupRow>()
      : null;
  if (!group) {
    await recordFailure(env, keys);
    return new Response("Unknown QR code", { status: 404 });
  }
  if (group.state !== "Active" || Date.parse(group.ends_at) <= Date.now()) {
    return new Response("This group is no longer open", { status: 410 });
  }

  const existing = await env.DB.prepare(`SELECT ${MEMBER_COLUMNS}, status FROM members WHERE group_id = ? AND device_id = ?`)
    .bind(group.id, deviceId)
    .first<MemberRow & { status: string }>();
  if (existing && existing.status !== "removed" && existing.status !== "banned") {
    return Response.json({ group: toJson(group), member: memberJson(existing) });
  }
  const refusal = await joinRefusal(env, group.id, existing?.status);
  if (refusal) return refusal;

  const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";
  if (body.consent !== true) return new Response("Consent is required to join", { status: 400 });
  if (displayName.length < 1 || displayName.length > 30) return new Response("Invalid display name", { status: 400 });
  if (typeof body.colour !== "string" || !/^#[0-9A-Fa-f]{6}$/.test(body.colour)) {
    return new Response("Invalid colour", { status: 400 });
  }

  const now = new Date().toISOString();
  const member: MemberRow = {
    id: crypto.randomUUID(),
    display_name: displayName,
    colour: body.colour.toUpperCase(),
    role: "guest",
    consent_accepted_at: now,
    joined_at: now,
  };
  // Conditional insert so concurrent joins cannot overshoot the cap. The host takes one seat.
  // A removed member rejoining reuses their row (and id).
  const memberId = await env.DB.prepare(
    `INSERT INTO members (id, group_id, device_id, display_name, colour, role, status, consent_accepted_at, joined_at)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?8
     WHERE (SELECT COUNT(*) FROM members WHERE group_id = ?2 AND status = 'active') + 1 < ?9
     ON CONFLICT (group_id, device_id) DO UPDATE SET display_name = excluded.display_name, colour = excluded.colour,
       role = excluded.role, status = 'active', consent_accepted_at = excluded.consent_accepted_at,
       joined_at = excluded.joined_at
     WHERE members.status = 'removed'
     RETURNING id`,
  )
    .bind(member.id, group.id, deviceId, member.display_name, member.colour, member.role, now, now, group.people_cap)
    .first<string>("id");
  if (!memberId) return new Response("This group is full", { status: 409 });
  member.id = memberId;

  return Response.json({ group: toJson(group), member: memberJson(member) }, { status: 201 });
}

async function isRateLimited(env: Env, keys: string[]): Promise<boolean> {
  const since = new Date(Date.now() - FAILURE_WINDOW_MS).toISOString();
  for (const key of keys) {
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM join_failures WHERE key = ? AND failed_at > ?")
      .bind(key, since)
      .first<number>("n");
    if ((count ?? 0) >= MAX_FAILURES) return true;
  }
  return false;
}

async function recordFailure(env: Env, keys: string[]): Promise<void> {
  const now = new Date().toISOString();
  const insert = env.DB.prepare("INSERT INTO join_failures (key, failed_at) VALUES (?, ?)");
  await env.DB.batch(keys.map((key) => insert.bind(key, now)));
}

function memberJson(row: MemberRow) {
  return {
    id: row.id,
    displayName: row.display_name,
    colour: row.colour,
    role: row.role,
    consentAcceptedAt: row.consent_accepted_at,
    joinedAt: row.joined_at,
  };
}

// 32 random bytes, base64url: 43 characters, infeasible to guess.
function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
