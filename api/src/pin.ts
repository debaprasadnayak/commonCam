import type { Env } from "./index";

// No 0/O, 1/I/L: easy to read aloud and type. 31^6 ≈ 887M combinations, guarded by the join rate limit.
const PIN_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const PIN_LENGTH = 6;

/** What the guest typed, made comparable to a stored PIN (case and spacing don't matter). */
export function normalizePin(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const pin = value.replace(/[\s-]/g, "").toUpperCase();
  return pin.length === PIN_LENGTH ? pin : null;
}

/** Host-only: `GET` shows the PIN (null when off), `POST` turns it on or rotates it, `DELETE` turns it off. */
export async function handlePin(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  const route = url.pathname.match(/^\/groups\/([^/]+)\/pin$/);
  if (!route) return null;
  const groupId = route[1];
  const group = await env.DB.prepare("SELECT pin FROM groups WHERE id = ? AND host_device_id = ?")
    .bind(groupId, deviceId)
    .first<{ pin: string | null }>();
  if (!group) return new Response("Not found", { status: 404 });

  if (request.method === "GET") return Response.json({ pin: group.pin });
  if (request.method === "POST") return Response.json({ pin: await setNewPin(env, groupId) });
  if (request.method === "DELETE") {
    await env.DB.prepare("UPDATE groups SET pin = NULL WHERE id = ?").bind(groupId).run();
    return Response.json({ pin: null });
  }
  return null;
}

async function setNewPin(env: Env, groupId: string): Promise<string> {
  for (let attempt = 0; ; attempt++) {
    const pin = randomPin();
    try {
      // Never reissue the current PIN: rotating must invalidate the old one.
      const { meta } = await env.DB.prepare("UPDATE groups SET pin = ?1 WHERE id = ?2 AND pin IS NOT ?1")
        .bind(pin, groupId)
        .run();
      if (meta.changes === 1) return pin;
    } catch (error) {
      // Unique index clash with another group's PIN: draw again.
      if (attempt >= 4) throw error;
    }
  }
}

function randomPin(): string {
  let pin = "";
  while (pin.length < PIN_LENGTH) {
    for (const byte of crypto.getRandomValues(new Uint8Array(PIN_LENGTH))) {
      // Rejection sampling keeps every character equally likely.
      if (byte < 248 && pin.length < PIN_LENGTH) pin += PIN_ALPHABET[byte % PIN_ALPHABET.length];
    }
  }
  return pin;
}
