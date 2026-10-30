import type { Env } from "./index";
import { findCaller } from "./media";
import { syncStorageWarnings } from "./push";

/** SPEC.md section 8: the host is warned from this share of the cap; at 100% uploads pause. */
export const STORAGE_WARNING_FRACTION = 0.8;

export type StorageLevel = "ok" | "nearlyFull" | "full";

/** How full a group's storage is. #19's push notifications should fire when this changes level. */
export function storageLevel(usedBytes: number, capBytes: number): StorageLevel {
  if (usedBytes >= capBytes) return "full";
  return usedBytes >= capBytes * STORAGE_WARNING_FRACTION ? "nearlyFull" : "ok";
}

export interface GroupStorage {
  storage_used_bytes: number;
  storage_cap_bytes: number;
  /** 1 after an upload was refused for lack of room (see refuseForStorage). */
  storage_full?: number;
}

/** The group's level: also full once an upload didn't fit, even if usage is below the cap. */
export function groupStorageLevel(group: GroupStorage): StorageLevel {
  return group.storage_full ? "full" : storageLevel(group.storage_used_bytes, group.storage_cap_bytes);
}

export function storageJson(group: GroupStorage) {
  return {
    storageUsedBytes: group.storage_used_bytes,
    storageCapBytes: group.storage_cap_bytes,
    storageLevel: groupStorageLevel(group),
  };
}

/**
 * The 413 for an upload that doesn't fit. Marks the group full (until the cap rises or an item is deleted)
 * so the host gets the 100% warning and push even when usage is just under the cap.
 */
export async function refuseForStorage(env: Env, groupId: string): Promise<Response> {
  await env.DB.prepare("UPDATE groups SET storage_full = 1 WHERE id = ?").bind(groupId).run();
  await syncStorageWarnings(env, groupId);
  return new Response("This group's storage is full", { status: 413 });
}

/** `GET /groups/:id/storage` (host or active member): lets guests' queues see when a full group has room again. */
export async function handleStorageCap(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const match = url.pathname.match(/^\/groups\/([^/]+)\/storage$/);
  if (!match || request.method !== "GET") return null;
  const caller = await findCaller(env, match[1], deviceId);
  if (!caller) return new Response("Not found", { status: 404 });
  return Response.json(storageJson(caller.group));
}
