import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

interface Group {
  id: string;
  peopleCap: number;
  storageUsedBytes: number;
}

interface Ticket {
  itemId: string;
  uploadUrl: string;
}

function api(path: string, token: string, method = "GET", body?: string | Uint8Array, ip?: string) {
  const headers = new Headers({ Authorization: `Bearer ${token}` });
  if (ip) headers.set("CF-Connecting-IP", ip);
  return exports.default.fetch(path.startsWith("https:") ? path : `https://api.test${path}`, {
    method, headers, body,
  });
}

async function group(host: string) {
  const response = await api("/groups", host, "POST", JSON.stringify({ tier: "taster" }));
  expect(response.status).toBe(201);
  return response.json<Group>();
}

async function parallel<T>(count: number, concurrency: number, action: (index: number) => Promise<T>) {
  const results: T[] = [];
  for (let start = 0; start < count; start += concurrency) {
    results.push(...await Promise.all(
      Array.from({ length: Math.min(concurrency, count - start) }, (_, offset) => action(start + offset)),
    ));
  }
  return results;
}

function statuses(values: number[]) {
  return Object.fromEntries([...new Set(values)].sort().map((status) => [
    status, values.filter((value) => value === status).length,
  ]));
}

function record(scenario: string, evidence: object) {
  console.log(`AUDIT ${JSON.stringify({ scenario, ...evidence })}`);
}

async function ticket(host: string, groupId: string) {
  const response = await api(`/groups/${groupId}/uploads`, host, "POST",
    JSON.stringify({ bytes: 1, contentType: "image/heic" }));
  expect(response.status).toBe(201);
  return response.json<Ticket>();
}

describe("bounded local stress audit", () => {
  for (const concurrency of [1, 8, 32, 64, 128]) {
    const count = concurrency === 128 ? 1024 : 128;
    it(`serves ${count} group reads at concurrency ${concurrency}`, async () => {
      const host = `stress-read-${concurrency}`;
      await group(host);
      const started = performance.now();
      const samples = await parallel(count, concurrency, async () => {
        const start = performance.now();
        const response = await api("/groups", host);
        const body = await response.json<Group[]>();
        return { status: response.status, count: body.length, ms: performance.now() - start };
      });
      const elapsedMs = performance.now() - started;
      const sorted = samples.map((sample) => sample.ms).sort((a, b) => a - b);
      record("group-reads", {
        concurrency, requests: samples.length, elapsedMs,
        requestsPerSecond: samples.length * 1000 / elapsedMs,
        p50Ms: sorted[Math.ceil(sorted.length * 0.5) - 1],
        p95Ms: sorted[Math.ceil(sorted.length * 0.95) - 1],
        p99Ms: sorted[Math.ceil(sorted.length * 0.99) - 1],
        statuses: statuses(samples.map((sample) => sample.status)),
      });
      expect(samples.every((sample) => sample.status === 200 && sample.count === 1)).toBe(true);
    });
  }

  it("bounds same-device free-group creation during a 64-request burst", async () => {
    const responses = await parallel(64, 32, () =>
      api("/groups", "stress-create", "POST", JSON.stringify({ tier: "taster" })));
    const listed = await (await api("/groups", "stress-create")).json<Group[]>();
    record("same-device-group-burst", { requests: 64, statuses: statuses(responses.map((r) => r.status)), groups: listed.length });
    expect(responses.every((response) => [201, 403].includes(response.status))).toBe(true);
    expect(listed.length).toBeLessThan(64);
  });

  for (let attempt = 0; attempt < 3; attempt++) {
    it(`keeps the people cap under 24 concurrent joins, attempt ${attempt + 1}`, async () => {
      const host = `stress-join-host-${attempt}`;
      const created = await group(host);
      const { qrToken } = await (await api(`/groups/${created.id}/invite`, host)).json<{ qrToken: string }>();
      const responses = await parallel(24, 24, (index) => api("/join", `stress-guest-${attempt}-${index}`, "POST",
        JSON.stringify({ qrToken, displayName: "Stress Guest", colour: "#FF8800", consent: true }),
        `192.0.2.${attempt * 24 + index + 1}`));
      const members = await env.DB.prepare("SELECT COUNT(*) AS count FROM members WHERE group_id = ? AND status = 'active'")
        .bind(created.id).first<{ count: number }>();
      record("concurrent-join-cap", { attempt, requests: 24, statuses: statuses(responses.map((r) => r.status)),
        activeGuests: members?.count, peopleCap: created.peopleCap });
      expect(responses.every((r) => [201, 409].includes(r.status))).toBe(true);
      expect((members?.count ?? 0) + 1).toBeLessThanOrEqual(created.peopleCap);
    });
  }

  it("rate-limits a burst of 32 invite guesses from one IP", async () => {
    const responses = await parallel(32, 32, (index) => api("/join", `stress-guesser-${index}`, "POST",
      JSON.stringify({ qrToken: `invalid-${index}`, displayName: "Guest", colour: "#FF8800", consent: true }),
      "198.51.100.230"));
    const allowed = responses.filter((r) => r.status !== 429).length;
    record("concurrent-invite-guessing", { requests: 32, statuses: statuses(responses.map((r) => r.status)), allowed });
    expect(allowed).toBeLessThanOrEqual(10);
    expect(responses.every((r) => [404, 429].includes(r.status))).toBe(true);
  });

  it("rate-limits the sequential control of 32 invite guesses", async () => {
    const responses = await parallel(32, 1, (index) => api("/join", `stress-control-${index}`, "POST",
      JSON.stringify({ qrToken: `invalid-control-${index}`, displayName: "Guest", colour: "#FF8800", consent: true }),
      "198.51.100.231"));
    record("sequential-invite-control", { requests: 32, statuses: statuses(responses.map((r) => r.status)) });
    expect(responses.filter((r) => r.status === 404)).toHaveLength(10);
    expect(responses.filter((r) => r.status === 429)).toHaveLength(22);
  });

  it("does not store pending media beyond a group cap", async () => {
    const host = "stress-storage";
    const created = await group(host);
    await env.DB.prepare("UPDATE groups SET storage_cap_bytes = 8 WHERE id = ?").bind(created.id).run();
    // Tickets beyond the cap are now refused up front (413): the bytes are reserved before a ticket is issued.
    const requests = await parallel(32, 32, () => api(`/groups/${created.id}/uploads`, host, "POST",
      JSON.stringify({ bytes: 1, contentType: "image/heic" })));
    expect(requests.every((response) => [201, 413].includes(response.status))).toBe(true);
    const tickets = await Promise.all(requests.filter((r) => r.status === 201).map((r) => r.json<Ticket>()));
    expect(tickets.length).toBeLessThanOrEqual(8);
    const puts = await parallel(tickets.length, 32, (index) =>
      api(tickets[index].uploadUrl, host, "PUT", new Uint8Array([index])));
    const objects = await env.MEDIA.list({ prefix: `groups/${created.id}/` });
    const storedBytes = objects.objects.reduce((sum, object) => sum + object.size, 0);
    const confirmations = await parallel(tickets.length, 32, (index) =>
      api(`/groups/${created.id}/items`, host, "POST", JSON.stringify({ itemId: tickets[index].itemId })));
    const [listed] = await (await api("/groups", host)).json<Group[]>();
    record("pending-media-cap", { requests: 32, capBytes: 8, storedBytes,
      ticketStatuses: statuses(requests.map((r) => r.status)),
      putStatuses: statuses(puts.map((r) => r.status)),
      confirmStatuses: statuses(confirmations.map((r) => r.status)), accountedBytes: listed.storageUsedBytes });
    expect(listed.storageUsedBytes).toBeLessThanOrEqual(8);
    expect(storedBytes).toBeLessThanOrEqual(8);
  });

  it("accounts for one upload once under 24 simultaneous confirmations", async () => {
    const host = "stress-confirm";
    const created = await group(host);
    const upload = await ticket(host, created.id);
    expect((await api(upload.uploadUrl, host, "PUT", new Uint8Array([1]))).status).toBe(200);
    const responses = await parallel(24, 24, () =>
      api(`/groups/${created.id}/items`, host, "POST", JSON.stringify({ itemId: upload.itemId })));
    const [listed] = await (await api("/groups", host)).json<Group[]>();
    const gallery = await (await api(`/groups/${created.id}/items`, host)).json<unknown[]>();
    record("same-item-confirmation", { requests: 24, statuses: statuses(responses.map((r) => r.status)),
      accountedBytes: listed.storageUsedBytes, galleryItems: gallery.length });
    expect(responses.every((r) => [200, 201].includes(r.status))).toBe(true);
    expect(listed.storageUsedBytes).toBe(1);
    expect(gallery).toHaveLength(1);
  });

  it("round-trips 8 MiB of concurrent media and consumes 16 MiB of downloads", async () => {
    const host = "stress-media-stream";
    const created = await group(host);
    const bytes = 256 * 1024;
    const payload = new Uint8Array(bytes).fill(73);
    const started = performance.now();
    const uploads = await parallel(32, 8, async () => {
      const response = await api(`/groups/${created.id}/uploads`, host, "POST",
        JSON.stringify({ bytes, contentType: "image/heic" }));
      expect(response.status).toBe(201);
      const upload = await response.json<Ticket>();
      expect((await api(upload.uploadUrl, host, "PUT", payload)).status).toBe(200);
      return (await api(`/groups/${created.id}/items`, host, "POST", JSON.stringify({ itemId: upload.itemId }))).status;
    });
    const gallery = await (await api(`/groups/${created.id}/items`, host)).json<{ downloadUrl: string }[]>();
    expect(gallery).toHaveLength(32);
    const downloads = await parallel(64, 16, async (index) => {
      const response = await api(gallery[index % gallery.length].downloadUrl, host);
      const data = new Uint8Array(await response.arrayBuffer());
      return { status: response.status, bytes: data.byteLength,
        intact: data.byteLength === bytes && data.every((value) => value === 73) };
    });
    const [listed] = await (await api("/groups", host)).json<Group[]>();
    record("media-streams", { uploadCount: 32, downloadCount: 64, uploadConcurrency: 8, downloadConcurrency: 16,
      bytesPerObject: bytes, uploadBytes: 32 * bytes, downloadBytes: 64 * bytes,
      elapsedMs: performance.now() - started, uploadStatuses: statuses(uploads),
      downloadStatuses: statuses(downloads.map((r) => r.status)), accountedBytes: listed.storageUsedBytes });
    expect(uploads.every((status) => status === 201)).toBe(true);
    expect(downloads.every((result) => result.status === 200 && result.intact)).toBe(true);
    expect(listed.storageUsedBytes).toBe(32 * bytes);
  });

  it("returns client errors rather than server failures for malformed JSON shapes", async () => {
    const host = "stress-invalid";
    const created = await group(host);
    const paths = ["/groups", "/join", `/groups/${created.id}/uploads`, `/groups/${created.id}/items`,
      `/groups/${created.id}/multipart`, "/devices/push-token"];
    const bodies = ["null", "[]", "true", "42", "\"text\"", "{", "{}"];
    const cases = paths.flatMap((path) => bodies.map((body) => ({ path, body })));
    const results = await parallel(cases.length, 8, async (index) => {
      const { path, body } = cases[index];
      try {
        const response = await api(path, host, path === "/devices/push-token" ? "PUT" : "POST", body,
          `203.0.113.${index + 1}`);
        await response.text();
        return { path, body, status: response.status, exception: null };
      } catch (error) {
        return { path, body, status: null, exception: error instanceof Error ? error.message : String(error) };
      }
    });
    const failures = results.filter((r) => r.exception !== null || (r.status !== null && r.status >= 500));
    record("invalid-json-shapes", { requests: results.length,
      statuses: statuses(results.flatMap((r) => r.status === null ? [] : [r.status])), failures });
    expect(failures).toEqual([]);
    expect(results.every((r) => r.status !== null && r.status >= 400 && r.status < 500)).toBe(true);
  });
});
