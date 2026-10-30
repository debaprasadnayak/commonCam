import type { Env } from "./index";
import { MEMBER_COLUMNS, type MemberRow, memberJson } from "./join";

/**
 * Approve-new-members toggle (#13). The join path (QR now, PIN later) asks `newMemberStatus`;
 * pending members are not 'active', so every active-only check keeps them out.
 */
export async function handleApproval(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const toggle = url.pathname.match(/^\/groups\/([^/]+)\/approval$/);
  if (toggle && (request.method === "GET" || request.method === "PUT")) {
    const groupId = toggle[1];
    if (!(await canManage(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
    if (request.method === "PUT") {
      const body = await request.json<{ approvalRequired?: unknown }>().catch(() => ({}) as Record<string, unknown>);
      if (typeof body.approvalRequired !== "boolean") return new Response("approvalRequired must be a boolean", { status: 400 });
      await env.DB.prepare("UPDATE groups SET approval_required = ? WHERE id = ?")
        .bind(body.approvalRequired ? 1 : 0, groupId)
        .run();
    }
    return Response.json({ approvalRequired: await approvalRequired(env, groupId) });
  }

  const pending = url.pathname.match(/^\/groups\/([^/]+)\/pending$/);
  if (pending && request.method === "GET") {
    const groupId = pending[1];
    if (!(await canManage(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
    const { results } = await env.DB.prepare(
      `SELECT ${MEMBER_COLUMNS} FROM members WHERE group_id = ? AND status = 'pending' ORDER BY joined_at, rowid`,
    )
      .bind(groupId)
      .all<MemberRow>();
    return Response.json(results.map(memberJson));
  }

  const decision = url.pathname.match(/^\/groups\/([^/]+)\/members\/([^/]+)\/(approve|reject)$/);
  if (decision && request.method === "POST") {
    const [, groupId, memberId, action] = decision;
    if (!(await canManage(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
    return action === "approve" ? approve(env, groupId, memberId) : reject(env, groupId, memberId);
  }
  return null;
}

/** Status a brand-new member gets when joining by any route. */
export async function newMemberStatus(env: Env, groupId: string): Promise<"pending" | "active"> {
  return (await approvalRequired(env, groupId)) ? "pending" : "active";
}

async function approvalRequired(env: Env, groupId: string): Promise<boolean> {
  const value = await env.DB.prepare("SELECT approval_required FROM groups WHERE id = ?")
    .bind(groupId)
    .first<number>("approval_required");
  return value === 1;
}

/** The host, or an active co-host of the group. */
async function canManage(env: Env, groupId: string, deviceId: string): Promise<boolean> {
  const row = await env.DB.prepare(
    `SELECT 1 FROM groups WHERE id = ?1 AND (host_device_id = ?2 OR EXISTS
       (SELECT 1 FROM members WHERE group_id = ?1 AND device_id = ?2 AND role = 'co-host' AND status = 'active'))`,
  )
    .bind(groupId, deviceId)
    .first();
  return row !== null;
}

async function approve(env: Env, groupId: string, memberId: string): Promise<Response> {
  // Same seat rule as joining: the host takes one seat, so active guests must stay below the cap.
  const { meta } = await env.DB.prepare(
    `UPDATE members SET status = 'active' WHERE id = ?1 AND group_id = ?2 AND status = 'pending'
       AND (SELECT COUNT(*) FROM members WHERE group_id = ?2 AND status = 'active') + 1
           < (SELECT people_cap FROM groups WHERE id = ?2)`,
  )
    .bind(memberId, groupId)
    .run();
  const member = await env.DB.prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE id = ? AND group_id = ?`)
    .bind(memberId, groupId)
    .first<MemberRow>();
  if (meta.changes === 0) {
    return member?.status === "pending"
      ? new Response("This group is full", { status: 409 })
      : new Response("No such pending request", { status: 404 });
  }
  return Response.json(memberJson(member!));
}

async function reject(env: Env, groupId: string, memberId: string): Promise<Response> {
  const { meta } = await env.DB.prepare(
    "UPDATE members SET status = 'rejected' WHERE id = ? AND group_id = ? AND status = 'pending'",
  )
    .bind(memberId, groupId)
    .run();
  if (meta.changes === 0) return new Response("No such pending request", { status: 404 });
  return new Response(null, { status: 204 });
}
