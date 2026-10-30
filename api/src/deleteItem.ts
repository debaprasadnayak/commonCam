import { isHostOrCoHost } from "./hostControls";
import type { Env } from "./index";

/** `DELETE /groups/:id/items/:itemId`: contributors delete their own items; the host and co-hosts delete any. */
export async function handleDeleteItem(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/items\/([^/]+)$/);
  if (!route || request.method !== "DELETE") return null;
  const [, groupId, itemId] = route;

  const moderator = await isHostOrCoHost(env, groupId, deviceId);
  if (!moderator && !(await isActiveMember(env, groupId, deviceId))) return new Response("Not found", { status: 404 });

  const item = await env.DB.prepare("SELECT contributor_device_id, object_key FROM items WHERE id = ? AND group_id = ? AND status = 'ready'")
    .bind(itemId, groupId)
    .first<{ contributor_device_id: string; object_key: string }>();
  // Already gone: a repeated delete succeeds without touching storage usage again.
  if (!item) return new Response(null, { status: 204 });
  if (!moderator && item.contributor_device_id !== deviceId) return new Response("Not your item", { status: 403 });

  // One transaction: usage drops only if this request is the one that removes the row, and never below zero.
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE groups SET storage_used_bytes = MAX(0, storage_used_bytes -
         (SELECT bytes FROM items WHERE id = ?2 AND group_id = ?1 AND status = 'ready'))
       WHERE id = ?1 AND EXISTS (SELECT 1 FROM items WHERE id = ?2 AND group_id = ?1 AND status = 'ready')`,
    ).bind(groupId, itemId),
    env.DB.prepare("DELETE FROM items WHERE id = ? AND group_id = ? AND status = 'ready'").bind(itemId, groupId),
  ]);
  // R2 delete is idempotent; if it fails after the row is gone the object is orphaned, never shown.
  await env.MEDIA.delete(item.object_key);
  return new Response(null, { status: 204 });
}

async function isActiveMember(env: Env, groupId: string, deviceId: string) {
  const row = await env.DB.prepare("SELECT 1 FROM members WHERE group_id = ? AND device_id = ? AND status = 'active'")
    .bind(groupId, deviceId)
    .first();
  return row !== null;
}
