import { insertTasterGroup, newGroupRow, toJson, type GroupRow } from "./groups";
import { createPaidGroup } from "./purchases";
import { isPaidTier } from "./tiers";

export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  /** DER base64 of the root App Store transactions must chain to (Apple Root CA - G3). */
  APPLE_ROOT_CA_G3: string;
  APPLE_BUNDLE_ID: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
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
        `SELECT id, tier, state, people_cap, storage_cap_bytes, starts_at, ends_at
         FROM groups WHERE host_device_id = ? ORDER BY starts_at DESC`,
      )
        .bind(deviceId)
        .all<GroupRow>();
      return Response.json(results.map(toJson));
    }

    return new Response("Not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;

// The device token is a bearer secret, so only its hash is stored.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
