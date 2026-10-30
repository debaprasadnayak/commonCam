import type { Env } from "./index";
import { insertReport } from "./moderation";

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
    insertReport(
      env.DB,
      groupId,
      deviceId,
      { id: crypto.randomUUID(), item_id: itemId, member_id: null, reason: SENSITIVE_REASON, status: "open", created_at: new Date().toISOString() },
      "confirming",
    ),
  ];
}
