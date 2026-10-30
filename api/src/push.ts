import { apnsSender, apnsConfig } from "./apns";
import type { Env } from "./index";
import { storageLevel } from "./storageCap";

/** SPEC.md section 9 (grace reminders) and section 8 (storage warnings). */
export type PushKind = "expired" | "grace7Days" | "grace1Day" | "storageNearlyFull" | "storageFull";

export interface Push {
  deviceToken: string;
  groupId: string;
  kind: PushKind;
  title: string;
  body: string;
}

/** "unregistered": APNs says the token is dead (app deleted, token rotated); it is then forgotten. */
export interface PushSender {
  send(push: Push): Promise<"unregistered" | void>;
}

function pushSender(env: Env): PushSender | null {
  const config = apnsConfig(env);
  return config && apnsSender(config);
}

/** `PUT /devices/push-token {token}`: the app's APNs device token (hex), tied to the caller's device. */
export async function handlePushToken(request: Request, url: URL, env: Env, deviceId: string): Promise<Response | null> {
  if (url.pathname !== "/devices/push-token" || request.method !== "PUT") return null;
  const body = await request.json<{ token?: unknown }>().catch(() => ({}) as { token?: unknown });
  const token = typeof body.token === "string" ? body.token.toLowerCase() : "";
  if (!/^(?:[0-9a-f]{2}){16,100}$/.test(token)) return new Response("Invalid APNs device token", { status: 400 });
  await env.DB.prepare(
    `INSERT INTO push_tokens (apns_token, device_id, updated_at) VALUES (?1, ?2, ?3)
     ON CONFLICT (apns_token) DO UPDATE SET device_id = ?2, updated_at = ?3`,
  )
    .bind(token, deviceId, new Date().toISOString())
    .run();
  return new Response(null, { status: 204 });
}

// Bounds one run's APNs calls (Workers subrequest limits); the hourly cron picks up the rest.
const REMINDER_GROUPS_PER_RUN = 25;

/**
 * Grace reminders, run by the hourly lifecycle job: when a group expires (enters Grace), 7 days and 1 day
 * before its media is deleted. Each fires once per grace period; if runs were missed and several are due,
 * only the most urgent goes out. Recipients: host and active members.
 */
export async function sendGraceReminders(env: Env, now: number): Promise<void> {
  const nowIso = new Date(now).toISOString();
  const { results } = await env.DB.prepare(
    `SELECT id, grace_ends_at, kind FROM (
       SELECT id, grace_ends_at,
              CASE WHEN grace_ends_at <= strftime('%Y-%m-%dT%H:%M:%fZ', ?1, '+1 day') THEN 'grace1Day'
                   WHEN grace_ends_at <= strftime('%Y-%m-%dT%H:%M:%fZ', ?1, '+7 days') THEN 'grace7Days'
                   ELSE 'expired' END AS kind
       FROM groups WHERE state = 'Grace' AND grace_ends_at > ?1
     ) due
     WHERE NOT EXISTS (SELECT 1 FROM notifications_sent n WHERE n.group_id = due.id AND n.kind = due.kind AND n.ref = due.grace_ends_at)
     ORDER BY grace_ends_at LIMIT ?2`,
  )
    .bind(nowIso, REMINDER_GROUPS_PER_RUN)
    .all<{ id: string; grace_ends_at: string; kind: PushKind }>();
  for (const group of results) {
    if (!(await claim(env, group.id, group.kind, group.grace_ends_at, nowIso))) continue;
    const daysLeft = Math.max(1, Math.round((Date.parse(group.grace_ends_at) - now) / (24 * 60 * 60 * 1000)));
    await notify(env, group.id, group.kind, reminderText(group.kind, daysLeft), MEMBERS);
  }
}

/**
 * Storage warnings to the host and co-hosts, called after anything that changes a group's storage use or cap.
 * Fires when the level rises into nearlyFull or full, once per level; dropping below a level (upgrade, add-on,
 * deletions) re-arms it.
 */
export async function syncStorageWarnings(env: Env, groupId: string): Promise<void> {
  const group = await env.DB.prepare("SELECT storage_used_bytes, storage_cap_bytes FROM groups WHERE id = ?")
    .bind(groupId)
    .first<{ storage_used_bytes: number; storage_cap_bytes: number }>();
  if (!group) return;
  const level = storageLevel(group.storage_used_bytes, group.storage_cap_bytes);
  const rearm: PushKind[] = level === "ok" ? ["storageNearlyFull", "storageFull"] : level === "nearlyFull" ? ["storageFull"] : [];
  if (rearm.length > 0) {
    await env.DB.prepare(`DELETE FROM notifications_sent WHERE group_id = ? AND kind IN (${rearm.map(() => "?").join(", ")})`)
      .bind(groupId, ...rearm)
      .run();
  }
  if (level === "ok") return;
  const kind: PushKind = level === "full" ? "storageFull" : "storageNearlyFull";
  if (await claim(env, groupId, kind, "", new Date().toISOString())) await notify(env, groupId, kind, STORAGE_TEXT[kind], HOSTS);
}

/** Records the notification as sent; false if it already was (so concurrent callers send it once). */
async function claim(env: Env, groupId: string, kind: PushKind, ref: string, nowIso: string): Promise<boolean> {
  const { meta } = await env.DB.prepare("INSERT OR IGNORE INTO notifications_sent (group_id, kind, ref, sent_at) VALUES (?, ?, ?, ?)")
    .bind(groupId, kind, ref, nowIso)
    .run();
  return meta.changes > 0;
}

// Recipient device ids of group ?1. Devices that never granted push permission have no push_tokens row.
const MEMBERS = `SELECT host_device_id FROM groups WHERE id = ?1
  UNION SELECT device_id FROM members WHERE group_id = ?1 AND status = 'active'`;
const HOSTS = `SELECT host_device_id FROM groups WHERE id = ?1
  UNION SELECT device_id FROM members WHERE group_id = ?1 AND status = 'active' AND role = 'co-host'`;

/** Sends to every registered phone of the recipients. Push failures are logged, never thrown (best effort). */
async function notify(env: Env, groupId: string, kind: PushKind, text: { title: string; body: string }, recipients: string) {
  const { results } = await env.DB.prepare(`SELECT apns_token FROM push_tokens WHERE device_id IN (${recipients})`)
    .bind(groupId)
    .all<{ apns_token: string }>();
  if (results.length === 0) return;
  const sender = pushSender(env);
  if (!sender) {
    // shortcut: no Apple .p8 key yet; set the APNS_* secrets/vars (README) to send for real.
    console.log(`push: APNs not configured; skipped ${kind} for group ${groupId} (${results.length} device(s))`);
    return;
  }
  await Promise.all(
    results.map(async ({ apns_token }) => {
      try {
        const outcome = await sender.send({ deviceToken: apns_token, groupId, kind, ...text });
        if (outcome === "unregistered") await env.DB.prepare("DELETE FROM push_tokens WHERE apns_token = ?").bind(apns_token).run();
      } catch (error) {
        console.error(`push: ${kind} for group ${groupId} failed: ${error}`);
      }
    }),
  );
}

function reminderText(kind: PushKind, daysLeft: number) {
  const save = "Save the photos and videos you want to keep before the album is permanently deleted.";
  if (kind === "grace1Day") return { title: "Album deleted tomorrow", body: save };
  if (kind === "grace7Days") return { title: "Album deleted in 7 days", body: save };
  return {
    title: "Your album has ended",
    body: `It's read-only now. Save your photos and videos within ${daysLeft} days; then the album is permanently deleted.`,
  };
}

const STORAGE_TEXT = {
  storageNearlyFull: {
    title: "Album storage almost full",
    body: "80% of the album's storage is used. Upgrade or add storage to keep everyone sharing.",
  },
  storageFull: {
    title: "Album storage full",
    body: "Uploads are paused. Guests' shots wait on their phones for 24 hours; upgrade or add storage to resume.",
  },
};
