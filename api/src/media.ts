import { parseFilterRecipe } from "./filterRecipe";
import type { Env } from "./index";

const UPLOAD_URL_TTL_S = 15 * 60;
const DOWNLOAD_URL_TTL_S = 15 * 60;
const CONTENT_TYPES: Record<string, "photo"> = { "image/heic": "photo", "image/jpeg": "photo" };
// The host has no members row, so their items are labelled like this in the gallery.
const HOST_CONTRIBUTOR = { displayName: "Host", colour: "#8E8E93" };

interface Caller {
  group: { id: string; state: string; ends_at: string; storage_cap_bytes: number; storage_used_bytes: number };
  memberId: string | null;
}

interface ItemRow {
  id: string;
  member_id: string | null;
  type: string;
  content_type: string;
  bytes: number;
  object_key: string;
  created_at: string;
  filter_recipe: string | null;
  display_name: string | null;
  colour: string | null;
}

/**
 * Routes authorised by a signed URL instead of a device token: the media byte stream itself.
 *
 * shortcut: the Worker proxies bytes to/from R2 behind its own HMAC-signed URLs because there is no
 * Cloudflare account to mint R2 S3-API presigned URLs locally. Production should hand out R2 presigned
 * PUT/GET URLs (same scoping and TTLs) so media bytes bypass the Worker.
 */
export async function handleSignedMedia(request: Request, url: URL, env: Env): Promise<Response | null> {
  if (!url.pathname.startsWith("/media/")) return null;
  const key = decodeURIComponent(url.pathname.slice("/media/".length));
  const exp = url.searchParams.get("exp") ?? "";
  const sig = url.searchParams.get("sig") ?? "";
  const bytes = url.searchParams.get("bytes") ?? "";
  const type = url.searchParams.get("type") ?? "";
  const method = request.method === "PUT" ? "PUT" : request.method === "GET" ? "GET" : null;
  if (!method) return new Response("Method not allowed", { status: 405 });
  if (!(Number(exp) * 1000 > Date.now()) || !(await verify(env, sig, method, key, exp, bytes, type))) {
    return new Response("Invalid or expired link", { status: 403 });
  }

  if (method === "GET") {
    const object = await env.MEDIA.get(key);
    if (!object) return new Response("Not found", { status: 404 });
    const headers = new Headers({ "Cache-Control": "private, max-age=300" });
    object.writeHttpMetadata(headers);
    return new Response(object.body, { headers });
  }

  if (request.headers.get("Content-Length") !== bytes || !request.body) {
    return new Response("Body must be exactly the announced size", { status: 400 });
  }
  await env.MEDIA.put(key, request.body, { httpMetadata: { contentType: type } });
  return new Response(null, { status: 200 });
}

export async function handleMedia(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/(uploads|items)$/);
  if (!route) return null;
  const [, groupId, resource] = route;
  if (resource === "uploads" && request.method === "POST") return requestUpload(request, url, env, groupId, deviceId);
  if (resource === "items" && request.method === "POST") return confirmItem(request, env, groupId, deviceId);
  if (resource === "items" && request.method === "GET") return gallery(url, env, groupId, deviceId);
  return null;
}

async function requestUpload(request: Request, url: URL, env: Env, groupId: string, deviceId: string) {
  const caller = await findCaller(env, groupId, deviceId);
  if (!caller) return new Response("Not found", { status: 404 });
  if (!isOpen(caller.group)) return new Response("This group is no longer open", { status: 410 });

  const body = await request.json<{ bytes?: unknown; contentType?: unknown }>().catch(() => ({}) as Record<string, unknown>);
  const bytes = body.bytes;
  const contentType = typeof body.contentType === "string" ? body.contentType : "";
  if (typeof bytes !== "number" || !Number.isSafeInteger(bytes) || bytes <= 0) {
    return new Response("Invalid size", { status: 400 });
  }
  if (!CONTENT_TYPES[contentType]) return new Response("Unsupported content type", { status: 400 });
  if (caller.group.storage_used_bytes + bytes > caller.group.storage_cap_bytes) {
    return new Response("This group's storage is full", { status: 413 });
  }

  const itemId = crypto.randomUUID();
  const objectKey = `groups/${groupId}/${itemId}`;
  await env.DB.prepare(
    `INSERT INTO items (id, group_id, member_id, contributor_device_id, type, content_type, bytes, object_key, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)`,
  )
    .bind(itemId, groupId, caller.memberId, deviceId, CONTENT_TYPES[contentType], contentType, bytes, objectKey, new Date().toISOString())
    .run();

  const exp = String(Math.floor(Date.now() / 1000) + UPLOAD_URL_TTL_S);
  const uploadUrl = await signedUrl(env, url.origin, "PUT", objectKey, exp, String(bytes), contentType);
  return Response.json({ itemId, uploadUrl, expiresAt: new Date(Number(exp) * 1000).toISOString() }, { status: 201 });
}

async function confirmItem(request: Request, env: Env, groupId: string, deviceId: string) {
  const caller = await findCaller(env, groupId, deviceId);
  if (!caller) return new Response("Not found", { status: 404 });
  const body = await request.json<{ itemId?: unknown; filterRecipe?: unknown }>().catch(() => ({}) as Record<string, unknown>);
  const recipe = parseFilterRecipe(body.filterRecipe);
  if (recipe === undefined) return new Response("Invalid filter recipe", { status: 400 });
  const item = typeof body.itemId === "string"
    ? await env.DB.prepare(
        "SELECT id, bytes, object_key, status FROM items WHERE id = ? AND group_id = ? AND contributor_device_id = ?",
      )
        .bind(body.itemId, groupId, deviceId)
        .first<{ id: string; bytes: number; object_key: string; status: string }>()
    : null;
  if (!item) return new Response("Unknown item", { status: 404 });
  if (item.status === "ready") return Response.json(await itemJson(env, await findItem(env, item.id), new URL(request.url).origin));
  if (!isOpen(caller.group)) return new Response("This group is no longer open", { status: 410 });

  const stored = await env.MEDIA.head(item.object_key);
  if (!stored || stored.size !== item.bytes) return new Response("Upload not found", { status: 409 });

  // Claim the item, then charge storage only if it still fits; concurrent confirms cannot overshoot the cap.
  const claim = await env.DB.prepare("UPDATE items SET status = 'confirming' WHERE id = ? AND status = 'pending'")
    .bind(item.id)
    .run();
  if (claim.meta.changes === 0) return new Response("Already being confirmed", { status: 409 });
  const charge = await env.DB.prepare(
    `UPDATE groups SET storage_used_bytes = storage_used_bytes + ?1
     WHERE id = ?2 AND storage_used_bytes + ?1 <= storage_cap_bytes`,
  )
    .bind(item.bytes, groupId)
    .run();
  if (charge.meta.changes === 0) {
    await env.DB.prepare("UPDATE items SET status = 'pending' WHERE id = ?").bind(item.id).run();
    return new Response("This group's storage is full", { status: 413 });
  }
  await env.DB.prepare("UPDATE items SET status = 'ready', filter_recipe = ? WHERE id = ?")
    .bind(recipe && JSON.stringify(recipe), item.id)
    .run();
  return Response.json(await itemJson(env, await findItem(env, item.id), new URL(request.url).origin), { status: 201 });
}

async function gallery(url: URL, env: Env, groupId: string, deviceId: string) {
  if (!(await findCaller(env, groupId, deviceId))) return new Response("Not found", { status: 404 });
  const { results } = await env.DB.prepare(`${ITEM_SELECT} WHERE i.group_id = ? AND i.status = 'ready' ORDER BY i.created_at DESC, i.rowid DESC`)
    .bind(groupId)
    .all<ItemRow>();
  return Response.json(await Promise.all(results.map((row) => itemJson(env, row, url.origin))));
}

const ITEM_SELECT = `SELECT i.id, i.member_id, i.type, i.content_type, i.bytes, i.object_key, i.created_at, i.filter_recipe, m.display_name, m.colour
  FROM items i LEFT JOIN members m ON m.id = i.member_id`;

async function findItem(env: Env, itemId: string): Promise<ItemRow> {
  return (await env.DB.prepare(`${ITEM_SELECT} WHERE i.id = ?`).bind(itemId).first<ItemRow>())!;
}

/** The group, if the device is its host or an active member. `memberId` is null for the host. */
async function findCaller(env: Env, groupId: string, deviceId: string): Promise<Caller | null> {
  const row = await env.DB.prepare(
    `SELECT g.id, g.state, g.ends_at, g.storage_cap_bytes, g.storage_used_bytes, g.host_device_id, m.id AS member_id
     FROM groups g LEFT JOIN members m ON m.group_id = g.id AND m.device_id = ?2 AND m.status = 'active'
     WHERE g.id = ?1`,
  )
    .bind(groupId, deviceId)
    .first<Caller["group"] & { host_device_id: string; member_id: string | null }>();
  if (!row || (row.host_device_id !== deviceId && !row.member_id)) return null;
  return { group: row, memberId: row.host_device_id === deviceId ? null : row.member_id };
}

function isOpen(group: Caller["group"]) {
  return group.state === "Active" && Date.parse(group.ends_at) > Date.now();
}

async function itemJson(env: Env, row: ItemRow, origin: string) {
  const exp = String(Math.floor(Date.now() / 1000) + DOWNLOAD_URL_TTL_S);
  return {
    id: row.id,
    type: row.type,
    contentType: row.content_type,
    bytes: row.bytes,
    createdAt: row.created_at,
    filterRecipe: row.filter_recipe ? JSON.parse(row.filter_recipe) : null,
    contributor: row.member_id
      ? { memberId: row.member_id, displayName: row.display_name, colour: row.colour }
      : { memberId: null, ...HOST_CONTRIBUTOR },
    downloadUrl: await signedUrl(env, origin, "GET", row.object_key, exp, "", ""),
    downloadUrlExpiresAt: new Date(Number(exp) * 1000).toISOString(),
  };
}

async function signedUrl(env: Env, origin: string, method: string, key: string, exp: string, bytes: string, type: string) {
  const url = new URL(`/media/${key}`, origin);
  url.searchParams.set("exp", exp);
  if (bytes) url.searchParams.set("bytes", bytes);
  if (type) url.searchParams.set("type", type);
  url.searchParams.set("sig", await sign(env, method, key, exp, bytes, type));
  return url.toString();
}

async function verify(env: Env, sig: string, method: string, key: string, exp: string, bytes: string, type: string) {
  const expected = new TextEncoder().encode(await sign(env, method, key, exp, bytes, type));
  const given = new TextEncoder().encode(sig);
  return given.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(given, expected);
}

async function sign(env: Env, method: string, key: string, exp: string, bytes: string, type: string) {
  if (!env.MEDIA_SIGNING_KEY) throw new Error("MEDIA_SIGNING_KEY is not configured");
  const hmacKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.MEDIA_SIGNING_KEY),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", hmacKey, new TextEncoder().encode([method, key, exp, bytes, type].join("\n")));
  return btoa(String.fromCharCode(...new Uint8Array(mac))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
