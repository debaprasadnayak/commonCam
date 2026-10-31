import { readJsonObject } from "./body";
import type { Env } from "./index";
import { invite } from "./join";

/** True if the caller hosts the group or is an active co-host of it. */
export async function isHostOrCoHost(env: Env, groupId: string, deviceId: string): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT 1 FROM groups WHERE id = ?1 AND (host_device_id = ?2 OR EXISTS
       (SELECT 1 FROM members WHERE group_id = ?1 AND device_id = ?2 AND status = 'active' AND role = 'co-host'))`,
  )
    .bind(groupId, deviceId)
    .first();
  return row !== null;
}

/** Why a device without an active membership may not join, or null if it may. */
export async function joinRefusal(env: Env, groupId: string, memberStatus: string | undefined): Promise<Response | null> {
  if (memberStatus === "banned") return new Response("You can't join this group", { status: 403 });
  if (await isJoiningPaused(env, groupId)) return new Response("Joining is paused", { status: 403 });
  return null;
}

export async function isJoiningPaused(env: Env, groupId: string): Promise<boolean> {
  const paused = await env.DB.prepare("SELECT joining_paused FROM groups WHERE id = ?").bind(groupId).first<number>("joining_paused");
  return paused === 1;
}

export async function handleHostControls(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const joining = url.pathname.match(/^\/groups\/([^/]+)\/joining$/);
  if (joining && request.method === "PUT") return setJoiningPaused(request, env, joining[1], deviceId);
  const rotate = url.pathname.match(/^\/groups\/([^/]+)\/invite\/rotate$/);
  if (rotate && request.method === "POST") return rotateInvite(env, url, rotate[1], deviceId);
  const memberAction = url.pathname.match(/^\/groups\/([^/]+)\/members\/([^/]+)\/(remove|ban|co-host)$/);
  if (memberAction && request.method === "POST") {
    const [, groupId, memberId, action] = memberAction;
    return updateMember(env, groupId, memberId, deviceId, action as keyof typeof MEMBER_UPDATES);
  }
  return null;
}

// Removed members may rejoin with the QR; banned devices may not. Rows are kept so their content stays attributable.
const MEMBER_UPDATES = {
  remove: "status = 'removed', role = 'guest' WHERE status = 'active'",
  ban: "status = 'banned', role = 'guest' WHERE status IN ('active', 'removed')",
  "co-host": "role = 'co-host' WHERE status = 'active'",
} as const;

async function updateMember(
  env: Env,
  groupId: string,
  memberId: string,
  deviceId: string,
  action: keyof typeof MEMBER_UPDATES,
): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const { meta } = await env.DB.prepare(`UPDATE members SET ${MEMBER_UPDATES[action]} AND id = ? AND group_id = ?`)
    .bind(memberId, groupId)
    .run();
  return new Response(null, { status: meta.changes === 0 ? 404 : 204 });
}

// Clearing the token makes invite() mint a fresh one; the old token no longer matches any group.
async function rotateInvite(env: Env, url: URL, groupId: string, deviceId: string): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  await env.DB.prepare("UPDATE groups SET qr_token = NULL WHERE id = ?").bind(groupId).run();
  return invite(env, url, groupId, deviceId);
}

async function setJoiningPaused(request: Request, env: Env, groupId: string, deviceId: string): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const body = await readJsonObject(request);
  if (body instanceof Response) return body;
  if (typeof body.paused !== "boolean") return new Response("paused must be true or false", { status: 400 });
  await env.DB.prepare("UPDATE groups SET joining_paused = ? WHERE id = ?").bind(body.paused ? 1 : 0, groupId).run();
  return Response.json({ joiningPaused: body.paused });
}
