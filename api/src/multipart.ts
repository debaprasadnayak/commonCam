import type { Env } from "./index";
import { createPendingItem, findCaller, isOpen, sign, verify } from "./media";

// R2's minimum size for every part but the last. Smaller parts mean less to redo after an interruption.
export const PART_SIZE = 5 * 1024 * 1024;
const PART_URL_TTL_S = 15 * 60;

interface UploadRow {
  item_id: string;
  object_key: string;
  bytes: number;
  upload_id: string;
  part_size: number;
  part_count: number;
  completed: number;
}

/**
 * Signed part uploads, authorised by the URL instead of a device token.
 *
 * shortcut: like #3's /media/ URLs, the Worker proxies each part into R2's multipart API behind its own
 * HMAC-signed URL. Production should hand out R2 presigned UploadPart URLs (same scope and TTL).
 */
export async function handleSignedParts(request: Request, url: URL, env: Env): Promise<Response | null> {
  const route = url.pathname.match(/^\/media-parts\/([^/]+)\/(\d+)$/);
  if (!route) return null;
  if (request.method !== "PUT") return new Response("Method not allowed", { status: 405 });
  const [, itemId, partNumber] = route;
  const exp = url.searchParams.get("exp") ?? "";
  const bytes = url.searchParams.get("bytes") ?? "";
  const sig = url.searchParams.get("sig") ?? "";
  if (!(Number(exp) * 1000 > Date.now()) || !(await verify(env, sig, "PART", `${itemId}/${partNumber}`, exp, bytes, ""))) {
    return new Response("Invalid or expired link", { status: 403 });
  }
  const upload = await findUpload(env, "i.id = ?", itemId);
  if (!upload || upload.completed) return new Response("This upload is already complete", { status: 409 });
  if (request.headers.get("Content-Length") !== bytes || !request.body) {
    return new Response("Body must be exactly the announced size", { status: 400 });
  }

  const part = await env.MEDIA.resumeMultipartUpload(upload.object_key, upload.upload_id).uploadPart(Number(partNumber), request.body);
  await env.DB.prepare("INSERT OR REPLACE INTO multipart_parts (item_id, part_number, etag) VALUES (?, ?, ?)")
    .bind(itemId, part.partNumber, part.etag)
    .run();
  return new Response(null, { status: 200 });
}

export async function handleMultipart(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  if (request.method !== "POST") return null;
  const startRoute = url.pathname.match(/^\/groups\/([^/]+)\/multipart$/);
  if (startRoute) return start(request, env, startRoute[1], deviceId);
  const route = url.pathname.match(/^\/groups\/([^/]+)\/multipart\/([^/]+)\/(parts|complete)$/);
  if (!route) return null;
  const [, groupId, itemId, action] = route;

  const caller = await findCaller(env, groupId, deviceId);
  const upload = caller
    ? await findUpload(env, "i.id = ? AND i.group_id = ? AND i.contributor_device_id = ?", itemId, groupId, deviceId)
    : null;
  if (!caller || !upload) return new Response("Unknown upload", { status: 404 });
  if (!isOpen(caller.group)) return new Response("This group is no longer open", { status: 410 });
  return action === "parts" ? plan(env, url.origin, upload) : complete(env, upload);
}

async function start(request: Request, env: Env, groupId: string, deviceId: string) {
  const item = await createPendingItem(request, env, groupId, deviceId);
  if (item instanceof Response) return item;
  const multipart = await env.MEDIA.createMultipartUpload(item.objectKey, { httpMetadata: { contentType: item.contentType } });
  const partCount = Math.ceil(item.bytes / PART_SIZE);
  await env.DB.prepare("INSERT INTO multipart_uploads (item_id, upload_id, part_size, part_count) VALUES (?, ?, ?, ?)")
    .bind(item.itemId, multipart.uploadId, PART_SIZE, partCount)
    .run();
  return Response.json({ itemId: item.itemId, partSize: PART_SIZE, partCount }, { status: 201 });
}

/** Which parts R2 already has, plus fresh signed URLs for the rest. Call again to resume or to renew expired URLs. */
async function plan(env: Env, origin: string, upload: UploadRow) {
  const uploadedParts = await storedParts(env, upload);
  const exp = String(Math.floor(Date.now() / 1000) + PART_URL_TTL_S);
  const parts = [];
  for (let partNumber = 1; partNumber <= upload.part_count && !upload.completed; partNumber++) {
    if (uploadedParts.includes(partNumber)) continue;
    const bytes = String(Math.min(upload.part_size, upload.bytes - (partNumber - 1) * upload.part_size));
    const url = new URL(`/media-parts/${upload.item_id}/${partNumber}`, origin);
    url.searchParams.set("exp", exp);
    url.searchParams.set("bytes", bytes);
    url.searchParams.set("sig", await sign(env, "PART", `${upload.item_id}/${partNumber}`, exp, bytes, ""));
    parts.push({ partNumber, url: url.toString() });
  }
  return Response.json({ uploadedParts, parts, expiresAt: new Date(Number(exp) * 1000).toISOString() });
}

async function complete(env: Env, upload: UploadRow) {
  if (upload.completed) return new Response(null, { status: 204 });
  const { results } = await env.DB.prepare("SELECT part_number, etag FROM multipart_parts WHERE item_id = ? ORDER BY part_number")
    .bind(upload.item_id)
    .all<{ part_number: number; etag: string }>();
  if (results.length !== upload.part_count) return new Response("Some parts are still missing", { status: 409 });
  try {
    await env.MEDIA.resumeMultipartUpload(upload.object_key, upload.upload_id).complete(
      results.map((row) => ({ partNumber: row.part_number, etag: row.etag })),
    );
  } catch (error) {
    // A concurrent complete may already have assembled the object.
    const stored = await env.MEDIA.head(upload.object_key);
    if (stored?.size !== upload.bytes) throw error;
  }
  await env.DB.prepare("UPDATE multipart_uploads SET completed = 1 WHERE item_id = ?").bind(upload.item_id).run();
  return new Response(null, { status: 204 });
}

async function storedParts(env: Env, upload: UploadRow) {
  if (upload.completed) return Array.from({ length: upload.part_count }, (_, i) => i + 1);
  const { results } = await env.DB.prepare("SELECT part_number FROM multipart_parts WHERE item_id = ? ORDER BY part_number")
    .bind(upload.item_id)
    .all<{ part_number: number }>();
  return results.map((row) => row.part_number);
}

function findUpload(env: Env, where: string, ...values: string[]) {
  return env.DB.prepare(
    `SELECT i.id AS item_id, i.object_key, i.bytes, u.upload_id, u.part_size, u.part_count, u.completed
     FROM items i JOIN multipart_uploads u ON u.item_id = i.id WHERE ${where}`,
  )
    .bind(...values)
    .first<UploadRow>();
}
