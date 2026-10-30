import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { signTransaction } from "./support/fakeAppStore";
import { TIERS } from "../src/tiers";
import reportSql from "../reports/analytics.sql?raw";

function api(path: string, init: RequestInit & { token?: string } = {}) {
  const headers = new Headers(init.headers);
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  return exports.default.fetch(path.startsWith("http") ? path : `https://api.test${path}`, { ...init, headers });
}

async function report() {
  const { results } = await env.DB.prepare(reportSql).all<any>();
  return Object.fromEntries(results.map((row) => [row.tier, row]));
}

function taster(token = `host-${crypto.randomUUID()}`) {
  return api("/groups", { method: "POST", token, body: JSON.stringify({ tier: "taster" }) });
}

let nextTransactionId = 3_000_000_000;

async function buy(tier: string, token = `host-${crypto.randomUUID()}`, transactionId = String(nextTransactionId++)) {
  const pki = env.TEST_APPLE_PKI;
  const key = await crypto.subtle.importKey("jwk", pki.leafKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signedTransaction = await signTransaction(
    {
      transactionId,
      originalTransactionId: transactionId,
      bundleId: "app.commoncam.CommonCam",
      productId: `app.commoncam.tier.${tier}`,
      purchaseDate: Date.now(),
      signedDate: Date.now(),
      type: "Consumable",
      environment: "Sandbox",
    },
    pki.chain,
    key,
  );
  return api("/groups", { method: "POST", token, body: JSON.stringify({ tier, signedTransaction }) });
}

async function share(token: string, groupId: string, bytes: number) {
  const ticket = await (
    await api(`/groups/${groupId}/uploads`, { method: "POST", token, body: JSON.stringify({ bytes, contentType: "image/jpeg" }) })
  ).json<any>();
  expect((await api(ticket.uploadUrl, { method: "PUT", body: new Uint8Array(bytes) })).status).toBe(200);
  return api(`/groups/${groupId}/items`, { method: "POST", token, body: JSON.stringify({ itemId: ticket.itemId }) });
}

beforeEach(async () => {
  await env.DB.prepare("DELETE FROM daily_stats").run();
});

describe("analytics report (api/reports/analytics.sql)", () => {
  it("counts groups created per tier", async () => {
    expect((await taster()).status).toBe(201);
    expect((await buy("party")).status).toBe(201);
    expect((await buy("party")).status).toBe(201);

    const rows = await report();
    expect(rows.taster.groups_created).toBe(1);
    expect(rows.party.groups_created).toBe(2);
    expect(rows.all.groups_created).toBe(3);
  });

  it("does not count refused group creations", async () => {
    const token = `host-${crypto.randomUUID()}`;
    await taster(token);
    expect((await taster(token)).status).toBe(403);
    await buy("pocket", undefined, "3999999999");
    expect((await buy("pocket", undefined, "3999999999")).status).toBe(409);

    const rows = await report();
    expect(rows.taster.groups_created).toBe(1);
    expect(rows.pocket.groups_created).toBe(1);
  });

  it("counts confirmed uploads and their bytes once, even when the confirm is retried", async () => {
    const host = `host-${crypto.randomUUID()}`;
    const group = await (await buy("party", host)).json<any>();
    const first = await share(host, group.id, 1000);
    await share(host, group.id, 500);
    const itemId = (await first.json<any>()).id;
    await api(`/groups/${group.id}/items`, { method: "POST", token: host, body: JSON.stringify({ itemId }) });

    const rows = await report();
    expect(rows.party).toMatchObject({ uploads: 2, upload_bytes: 1500 });
    expect(rows.all).toMatchObject({ uploads: 2, upload_bytes: 1500 });
  });

  it("reports conversion as the share of created groups that were paid", async () => {
    await taster();
    await buy("pocket");
    await buy("party");
    await buy("festival");

    const rows = await report();
    expect(rows.all.conversion_pct).toBe(75);
    expect(rows.taster.conversion_pct).toBeNull();
  });

  it("estimates cost per group from stored bytes and uploads at COST_MODEL.md's R2 prices", async () => {
    const GiB = 1024 ** 3;
    await env.DB.batch([
      env.DB.prepare("INSERT INTO daily_stats VALUES ('2026-10-01', 'party', 2, 1000, ?)").bind(10 * GiB),
      env.DB.prepare("INSERT INTO daily_stats VALUES ('2026-10-02', 'taster', 1, 10, ?)").bind(GiB),
    ]);

    const rows = await report();
    // Party: 10 GB × $0.015/GB-month × (5 + 14 grace days)/30 + 1000 × $4.50/M + 2 × $0.03 fixed = $0.1595 for 2 groups.
    expect(rows.party.est_cost_per_group_usd).toBeCloseTo(0.07975, 4);
    // Taster: 1 GB × $0.015 × (1 + 14)/30 + 10 × $4.50/M + $0.03 = $0.037545.
    expect(rows.taster.est_cost_per_group_usd).toBeCloseTo(0.037545, 4);
    expect(rows.all.est_cost_per_group_usd).toBeCloseTo((0.1595 + 0.037545) / 3, 4);
  });

  it("keeps the report's retention days in step with tiers.ts", () => {
    for (const [tier, { days }] of Object.entries(TIERS)) expect(reportSql).toContain(`WHEN '${tier}' THEN ${days} `);
  });

  it("keeps counts after the group is deleted (#18)", async () => {
    const host = `host-${crypto.randomUUID()}`;
    const group = await (await buy("pocket", host)).json<any>();
    await share(host, group.id, 100);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM items WHERE group_id = ?").bind(group.id),
      env.DB.prepare("DELETE FROM orders WHERE group_id = ?").bind(group.id),
      env.DB.prepare("DELETE FROM groups WHERE id = ?").bind(group.id),
    ]);

    expect((await report()).pocket).toMatchObject({ groups_created: 1, uploads: 1, upload_bytes: 100 });
  });

  it("stores only day, tier and counters: no device, member or group identifiers", async () => {
    const { results } = await env.DB.prepare("PRAGMA table_info(daily_stats)").all<{ name: string }>();
    expect(results.map((c) => c.name).sort()).toEqual(["day", "groups_created", "tier", "upload_bytes", "uploads"]);
  });
});
