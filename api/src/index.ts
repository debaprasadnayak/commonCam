import { handleApproval } from "./approval";
import { handleDeleteItem } from "./deleteItem";
import { insertTasterGroup, newGroupRow, toJson, type GroupRow } from "./groups";
import { handleHostControls } from "./hostControls";
import { handleJoin, handlePublic } from "./join";
import { handlePin } from "./pin";
import { handleMedia, handleSignedMedia } from "./media";
import { createPaidGroup } from "./purchases";
import { isPaidTier } from "./tiers";

export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  MEDIA_SIGNING_KEY: string;
  /** DER base64 of the root App Store transactions must chain to (Apple Root CA - G3). */
  APPLE_ROOT_CA_G3: string;
  APPLE_BUNDLE_ID: string;
}

export { toJson, type GroupRow } from "./groups";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const publicResponse = handlePublic(url);
    if (publicResponse) return publicResponse;
    const signedMediaResponse = await handleSignedMedia(request, url, env);
    if (signedMediaResponse) return signedMediaResponse;
    const deviceToken = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/)?.[1];
    if (!deviceToken) return new Response("Missing device token", { status: 401 });
    const deviceId = await sha256Hex(deviceToken);

    if (url.pathname === "/groups" && request.method === "POST") {
      const body = await request
        .json<{ tier?: string; signedTransaction?: unknown }>()
        .catch(() => ({ tier: undefined, signedTransaction: undefined }));
      if (isPaidTier(body.tier)) return createPaidGroup(env, deviceId, body.tier, body.signedTransaction);
      if (body.tier !== "taster") return new Response("Unknown tier", { status: 400 });
      const row = newGroupRow("taster");
      const { meta } = await insertTasterGroup(env.DB, deviceId, row).run();
      if (meta.changes === 0) return new Response("Free Taster limit reached for this device", { status: 403 });
      return Response.json(toJson(row), { status: 201 });
    }

    if (url.pathname === "/groups" && request.method === "GET") {
      const { results } = await env.DB.prepare(
        `SELECT id, tier, state, people_cap, storage_cap_bytes, storage_used_bytes, starts_at, ends_at
         FROM groups WHERE host_device_id = ? ORDER BY starts_at DESC`,
      )
        .bind(deviceId)
        .all<GroupRow>();
      return Response.json(results.map(toJson));
    }

    const approvalResponse = await handleApproval(request, url, env, deviceId);
    if (approvalResponse) return approvalResponse;

    const pinResponse = await handlePin(request, url, env, deviceId);
    if (pinResponse) return pinResponse;

    const joinResponse = await handleJoin(request, url, env, deviceId);
    if (joinResponse) return joinResponse;
    const hostControlsResponse = await handleHostControls(request, url, env, deviceId);
    if (hostControlsResponse) return hostControlsResponse;

    const mediaResponse = await handleMedia(request, url, env, deviceId);
    if (mediaResponse) return mediaResponse;
    const deleteItemResponse = await handleDeleteItem(request, url, env, deviceId);
    if (deleteItemResponse) return deleteItemResponse;

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;

// The device token is a bearer secret, so only its hash is stored.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
