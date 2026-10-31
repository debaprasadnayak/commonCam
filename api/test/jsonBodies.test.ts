import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function api(path: string, method: string, token: string, body?: string) {
  return exports.default.fetch(`https://api.test${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}` },
    body,
  });
}

/** Bodies that parse as something other than a JSON object, or don't parse at all. */
const NOT_OBJECTS = ["null", "[]", "[{}]", "true", "42", '"text"', "{", "", "{\"a\":1}x"];

describe("JSON request bodies", () => {
  it("every JSON route answers 400 to malformed JSON, null, arrays and primitives", async () => {
    const host = `json-host-${crypto.randomUUID()}`;
    const group = await (await api("/groups", "POST", host, JSON.stringify({ tier: "taster" }))).json<any>();
    const endedHost = `json-ended-${crypto.randomUUID()}`;
    const ended = await (await api("/groups", "POST", endedHost, JSON.stringify({ tier: "taster" }))).json<any>();
    await env.DB.prepare("UPDATE groups SET state = 'Grace', ends_at = ?, grace_ends_at = ? WHERE id = ?")
      .bind(new Date(Date.now() - 1000).toISOString(), new Date(Date.now() + 86_400_000).toISOString(), ended.id)
      .run();

    // Each caller is allowed on its route, so the request gets as far as reading the body.
    const routes: { method: string; path: string; token?: string }[] = [
      { method: "POST", path: "/groups" },
      { method: "POST", path: "/join" },
      { method: "PUT", path: "/devices/push-token" },
      { method: "PUT", path: `/groups/${group.id}/approval` },
      { method: "PUT", path: `/groups/${group.id}/joining` },
      { method: "POST", path: `/groups/${group.id}/uploads` },
      { method: "POST", path: `/groups/${group.id}/items` },
      { method: "POST", path: `/groups/${group.id}/multipart` },
      { method: "POST", path: `/groups/${group.id}/items/some-item/report` },
      { method: "POST", path: `/groups/${group.id}/members/some-member/report` },
      { method: "POST", path: `/groups/${group.id}/purchases` },
      { method: "POST", path: `/groups/${ended.id}/extend`, token: endedHost },
      { method: "POST", path: "/app-store/notifications" },
    ];

    const failures: string[] = [];
    for (const route of routes) {
      for (const body of NOT_OBJECTS) {
        const token = route.token ?? (route.path === "/join" ? `json-joiner-${crypto.randomUUID()}` : host);
        let status: number | string;
        try {
          const response = await api(route.path, route.method, token, body);
          await response.text();
          status = response.status;
        } catch (error) {
          status = `threw ${error}`;
        }
        if (status !== 400) failures.push(`${route.method} ${route.path} ${JSON.stringify(body)} → ${status}`);
      }
    }
    expect(failures).toEqual([]);
  });
});
