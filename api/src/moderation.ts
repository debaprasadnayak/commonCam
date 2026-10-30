import { isHostOrCoHost } from "./hostControls";
import type { Env } from "./index";
import { MEMBER_COLUMNS, memberJson, type MemberRow } from "./join";
import { findCaller, ITEM_SELECT, itemJson, type ItemRow } from "./media";

const MAX_REASON_LENGTH = 500;

/**
 * Gallery filter for `items i`, bound as ?2 = viewer device hash, ?3 = 1 if the viewer is host or co-host.
 * Hidden (reported, unreviewed) items are shown only to owners; blocked members' items never to their blocker.
 */
export const VISIBLE_TO_VIEWER = `(i.hidden = 0 OR ?3 = 1) AND NOT EXISTS
  (SELECT 1 FROM blocks b WHERE b.group_id = i.group_id AND b.blocker_device_id = ?2 AND b.blocked_member_id = i.member_id)`;

interface ReportRow {
  id: string;
  item_id: string | null;
  member_id: string | null;
  reason: string;
  status: string;
  created_at: string;
}

export async function handleModeration(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const report = url.pathname.match(/^\/groups\/([^/]+)\/(items|members)\/([^/]+)\/report$/);
  if (report && request.method === "POST") {
    const [, groupId, kind, targetId] = report;
    return createReport(request, env, groupId, kind as "items" | "members", targetId, deviceId);
  }
  const block = url.pathname.match(/^\/groups\/([^/]+)\/members\/([^/]+)\/block$/);
  if (block && (request.method === "POST" || request.method === "DELETE")) {
    return setBlocked(env, block[1], block[2], deviceId, request.method === "POST");
  }
  const list = url.pathname.match(/^\/groups\/([^/]+)\/reports$/);
  if (list && request.method === "GET") return listReports(env, url, list[1], deviceId);
  const reviewed = url.pathname.match(/^\/groups\/([^/]+)\/reports\/([^/]+)\/(restore|delete)$/);
  if (reviewed && request.method === "POST") {
    const [, groupId, reportId, action] = reviewed;
    return reviewReport(env, groupId, reportId, deviceId, action as "restore" | "delete");
  }
  return null;
}

async function listReports(env: Env, url: URL, groupId: string, deviceId: string): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const { results } = await env.DB.prepare(
    `SELECT ${REPORT_COLUMNS} FROM reports WHERE group_id = ? AND status = 'open' ORDER BY created_at DESC, rowid DESC`,
  )
    .bind(groupId)
    .all<ReportRow>();
  return Response.json(
    await Promise.all(
      results.map(async (row) => {
        if (row.item_id) {
          const item = await env.DB.prepare(`${ITEM_SELECT} WHERE i.id = ?`).bind(row.item_id).first<ItemRow>();
          return { ...reportJson(row), item: item && (await itemJson(env, item, url.origin)) };
        }
        const member = await env.DB.prepare(`SELECT ${MEMBER_COLUMNS} FROM members WHERE id = ?`).bind(row.member_id).first<MemberRow>();
        return { ...reportJson(row), member: member && memberJson(member) };
      }),
    ),
  );
}

/**
 * Restore unhides the item (or dismisses a member report); delete removes the item for everyone.
 * Either way every open report on the same item is closed with the same outcome.
 *
 * shortcut: delete is a minimal, report-only path written alongside #11 (owner deletes items);
 * reconcile with #11's delete when both are merged.
 */
async function reviewReport(
  env: Env,
  groupId: string,
  reportId: string,
  deviceId: string,
  action: "restore" | "delete",
): Promise<Response> {
  if (!(await isHostOrCoHost(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const report = await env.DB.prepare(`SELECT ${REPORT_COLUMNS} FROM reports WHERE id = ? AND group_id = ?`)
    .bind(reportId, groupId)
    .first<ReportRow>();
  if (!report) return new Response("Not found", { status: 404 });
  if (report.status !== "open") return new Response("This report has already been reviewed", { status: 409 });
  if (action === "delete" && !report.item_id) {
    return new Response("Only reported items can be deleted; remove or ban the member instead", { status: 400 });
  }
  const status = action === "restore" ? "restored" : "deleted";
  const closeReports = report.item_id
    ? env.DB.prepare("UPDATE reports SET status = ? WHERE item_id = ? AND status = 'open'").bind(status, report.item_id)
    : env.DB.prepare("UPDATE reports SET status = ? WHERE id = ?").bind(status, report.id);

  if (action === "restore") {
    const unhide = env.DB.prepare("UPDATE items SET hidden = 0 WHERE id = ?").bind(report.item_id);
    await env.DB.batch(report.item_id ? [unhide, closeReports] : [closeReports]);
  } else {
    const item = await env.DB.prepare("SELECT bytes, object_key FROM items WHERE id = ? AND status = 'ready'")
      .bind(report.item_id)
      .first<{ bytes: number; object_key: string }>();
    // Claim the item first so a concurrent delete cannot refund its storage twice.
    const claim = await env.DB.prepare("UPDATE items SET status = 'deleted', hidden = 0 WHERE id = ? AND status = 'ready'")
      .bind(report.item_id)
      .run();
    if (item && claim.meta.changes === 1) {
      await env.DB.batch([
        env.DB.prepare("UPDATE groups SET storage_used_bytes = MAX(0, storage_used_bytes - ?) WHERE id = ?").bind(item.bytes, groupId),
        closeReports,
      ]);
      await env.MEDIA.delete(item.object_key);
    } else {
      await closeReports.run();
    }
  }
  return Response.json(reportJson({ ...report, status }));
}

const REPORT_COLUMNS = "id, item_id, member_id, reason, status, created_at";

async function setBlocked(env: Env, groupId: string, memberId: string, deviceId: string, blocked: boolean): Promise<Response> {
  if (!(await findCaller(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const member = await env.DB.prepare("SELECT device_id FROM members WHERE id = ? AND group_id = ?")
    .bind(memberId, groupId)
    .first<{ device_id: string }>();
  if (!member) return new Response("Not found", { status: 404 });
  if (member.device_id === deviceId) return new Response("You can't block yourself", { status: 400 });
  await (blocked
    ? env.DB.prepare(
        `INSERT INTO blocks (group_id, blocker_device_id, blocked_member_id, created_at) VALUES (?, ?, ?, ?)
         ON CONFLICT DO NOTHING`,
      ).bind(groupId, deviceId, memberId, new Date().toISOString())
    : env.DB.prepare("DELETE FROM blocks WHERE group_id = ? AND blocker_device_id = ? AND blocked_member_id = ?").bind(
        groupId,
        deviceId,
        memberId,
      )
  ).run();
  return new Response(null, { status: 204 });
}

async function createReport(
  request: Request,
  env: Env,
  groupId: string,
  kind: "items" | "members",
  targetId: string,
  deviceId: string,
): Promise<Response> {
  if (!(await findCaller(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const body = await request.json<{ reason?: unknown }>().catch(() => ({}) as { reason?: unknown });
  const reason = typeof body.reason === "string" ? body.reason.trim() : "";
  if (!reason || reason.length > MAX_REASON_LENGTH) {
    return new Response(`reason must be 1–${MAX_REASON_LENGTH} characters`, { status: 400 });
  }
  const target = kind === "items"
    ? await env.DB.prepare("SELECT id FROM items WHERE id = ? AND group_id = ? AND status = 'ready'").bind(targetId, groupId).first()
    : await env.DB.prepare("SELECT id FROM members WHERE id = ? AND group_id = ?").bind(targetId, groupId).first();
  if (!target) return new Response("Not found", { status: 404 });

  const row: ReportRow = {
    id: crypto.randomUUID(),
    item_id: kind === "items" ? targetId : null,
    member_id: kind === "members" ? targetId : null,
    reason,
    status: "open",
    created_at: new Date().toISOString(),
  };
  const insert = env.DB.prepare(
    `INSERT INTO reports (id, group_id, item_id, member_id, reporter_device_id, reason, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(row.id, groupId, row.item_id, row.member_id, deviceId, row.reason, row.status, row.created_at);
  const hide = env.DB.prepare("UPDATE items SET hidden = 1 WHERE id = ?").bind(targetId);
  await env.DB.batch(kind === "items" ? [insert, hide] : [insert]);
  return Response.json(reportJson(row), { status: 201 });
}

function reportJson(row: ReportRow) {
  return {
    id: row.id,
    itemId: row.item_id,
    memberId: row.member_id,
    reason: row.reason,
    status: row.status,
    createdAt: row.created_at,
  };
}
