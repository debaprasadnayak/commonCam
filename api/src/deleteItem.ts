import { isHostOrCoHost } from "./hostControls";
import type { Env } from "./index";

/** `DELETE /groups/:id/items/:itemId`: contributors delete their own items; the host and co-hosts delete any. */
export async function handleDeleteItem(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/items\/([^/]+)$/);
  if (!route || request.method !== "DELETE") return null;
  const [, groupId, itemId] = route;

  const moderator = await isHostOrCoHost(env, groupId, deviceId);
  if (!moderator && !(await isActiveMember(env, groupId, deviceId))) return new Response("Not found", { status: 404 });

  const item = await env.DB.prepare("SELECT contributor_device_id FROM items WHERE id = ? AND group_id = ? AND status = 'ready'")
    .bind(itemId, groupId)
    .first<{ contributor_device_id: string }>();
  // Already gone: a repeated delete succeeds without touching storage usage again.
  if (!item) return new Response(null, { status: 204 });
  if (!moderator && item.contributor_device_id !== deviceId) return new Response("Not your item", { status: 403 });

  await deleteItem(env, groupId, itemId);
  return new Response(null, { status: 204 });
}

/**
 * The one item delete, shared by owner/moderator deletes and report review (moderation.ts); callers check permissions.
 * Idempotent: a missing or already-deleted item is a no-op. Rows referencing the item (reports, multipart bookkeeping) go with it.
 */
export async function deleteItem(env: Env, groupId: string, itemId: string): Promise<void> {
  const item = await env.DB.prepare("SELECT object_key FROM items WHERE id = ? AND group_id = ? AND status = 'ready'")
    .bind(itemId, groupId)
    .first<{ object_key: string }>();
  if (!item) return;
  // One transaction: usage drops only if this request is the one that removes the row, and never below zero.
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE groups SET storage_used_bytes = MAX(0, storage_used_bytes -
         (SELECT bytes FROM items WHERE id = ?2 AND group_id = ?1 AND status = 'ready'))
       WHERE id = ?1 AND EXISTS (SELECT 1 FROM items WHERE id = ?2 AND group_id = ?1 AND status = 'ready')`,
    ).bind(groupId, itemId),
    ...["reports", "multipart_parts", "multipart_uploads"].map((table) =>
      env.DB.prepare(
        `DELETE FROM ${table} WHERE item_id = ?2 AND EXISTS (SELECT 1 FROM items WHERE id = ?2 AND group_id = ?1 AND status = 'ready')`,
      ).bind(groupId, itemId),
    ),
    env.DB.prepare("DELETE FROM items WHERE id = ? AND group_id = ? AND status = 'ready'").bind(itemId, groupId),
  ]);
  // R2 delete is idempotent; if it fails after the row is gone the object is orphaned, never shown.
  await env.MEDIA.delete(item.object_key);
}

async function isActiveMember(env: Env, groupId: string, deviceId: string) {
  const row = await env.DB.prepare("SELECT 1 FROM members WHERE group_id = ? AND device_id = ? AND status = 'active'")
    .bind(groupId, deviceId)
    .first();
  return row !== null;
}
