import { handleApproval } from "./approval";
import { handleDeleteItem } from "./deleteItem";
import { handleHostControls } from "./hostControls";
import { handleJoin, handlePublic } from "./join";
import { handlePin } from "./pin";
import { handleMedia, handleSignedMedia } from "./media";
import { TIERS } from "./tiers";

export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  MEDIA_SIGNING_KEY: string;
}

const DAY_MS = 24 * 60 * 60 * 1000;

export interface GroupRow {
  id: string;
  tier: string;
  state: string;
  people_cap: number;
  storage_cap_bytes: number;
  storage_used_bytes: number;
  starts_at: string;
  ends_at: string;
}

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
      const body = await request.json<{ tier?: string }>().catch(() => ({ tier: undefined }));
      if (body.tier !== "taster") {
        return new Response("Only the free Taster tier can be created without a purchase", { status: 400 });
      }
      const tier = TIERS.taster;
      const startsAt = new Date();
      const row: GroupRow = {
        id: crypto.randomUUID(),
        tier: "taster",
        state: "Active",
        people_cap: tier.peopleCap,
        storage_cap_bytes: tier.storageCapBytes,
        storage_used_bytes: 0,
        starts_at: startsAt.toISOString(),
        ends_at: new Date(startsAt.getTime() + tier.days * DAY_MS).toISOString(),
      };
      await env.DB.prepare(
        `INSERT INTO groups (id, host_device_id, tier, people_cap, storage_cap_bytes, starts_at, ends_at, state)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
        .bind(row.id, deviceId, row.tier, row.people_cap, row.storage_cap_bytes, row.starts_at, row.ends_at, row.state)
        .run();
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

export function toJson(row: GroupRow) {
  return {
    id: row.id,
    tier: row.tier,
    state: row.state,
    peopleCap: row.people_cap,
    storageCapBytes: row.storage_cap_bytes,
    storageUsedBytes: row.storage_used_bytes,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
  };
}

// The device token is a bearer secret, so only its hash is stored.
async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
