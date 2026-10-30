import type { Env } from "./index";
import { findCaller } from "./media";

/** SPEC.md section 8: the host is warned from this share of the cap; at 100% uploads pause. */
export const STORAGE_WARNING_FRACTION = 0.8;

export type StorageLevel = "ok" | "nearlyFull" | "full";

/** How full a group's storage is. #19's push notifications should fire when this changes level. */
export function storageLevel(usedBytes: number, capBytes: number): StorageLevel {
  if (usedBytes >= capBytes) return "full";
  return usedBytes >= capBytes * STORAGE_WARNING_FRACTION ? "nearlyFull" : "ok";
}

export function storageJson(group: { storage_used_bytes: number; storage_cap_bytes: number }) {
  return {
    storageUsedBytes: group.storage_used_bytes,
    storageCapBytes: group.storage_cap_bytes,
    storageLevel: storageLevel(group.storage_used_bytes, group.storage_cap_bytes),
  };
}

/** `GET /groups/:id/storage` (host or active member): lets guests' queues see when a full group has room again. */
export async function handleStorageCap(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const match = url.pathname.match(/^\/groups\/([^/]+)\/storage$/);
  if (!match || request.method !== "GET") return null;
  const caller = await findCaller(env, match[1], deviceId);
  if (!caller) return new Response("Not found", { status: 404 });
  return Response.json(storageJson(caller.group));
}
