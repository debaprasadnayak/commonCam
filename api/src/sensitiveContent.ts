import type { Env } from "./index";

/** Reason on the report filed for an item the uploader's device flagged; the owner reviews it like any other report. */
export const SENSITIVE_REASON = "Flagged as possibly sensitive by on-device analysis";

/**
 * Statements that hide a just-confirmed item and open a report on it when the uploader's device
 * (Apple's Sensitive Content Analysis) flagged it, via `sensitive: true` on the confirm. Empty otherwise.
 * They act only while the item is 'confirming': run them in the confirm batch (media.ts) before it is made ready,
 * so it is never visible to members in between.
 */
export function flagIfSensitive(env: Env, sensitive: unknown, groupId: string, itemId: string, deviceId: string): D1PreparedStatement[] {
  if (sensitive !== true) return [];
  return [
    env.DB.prepare("UPDATE items SET hidden = 1 WHERE id = ? AND status = 'confirming'").bind(itemId),
    env.DB.prepare(
      `INSERT INTO reports (id, group_id, item_id, member_id, reporter_device_id, reason, status, created_at)
       SELECT ?1, ?2, ?3, NULL, ?4, ?5, 'open', ?6 WHERE EXISTS (SELECT 1 FROM items WHERE id = ?3 AND status = 'confirming')`,
    ).bind(crypto.randomUUID(), groupId, itemId, deviceId, SENSITIVE_REASON, new Date().toISOString()),
  ];
}
