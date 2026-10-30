import { describe, expect, it } from "vitest";
import { apnsSender, type ApnsConfig } from "../src/apns";
import type { Push } from "../src/push";
import { p8Key } from "./support/apnsKey";

const push: Push = { deviceToken: "ab".repeat(32), groupId: "g-1", kind: "grace1Day", title: "Album deleted tomorrow", body: "Save them." };

function fromBase64url(s: string) {
  return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
}

function recordingFetch(status = 200, body = "") {
  const requests: Request[] = [];
  const fetchFn = (async (input: RequestInfo, init?: RequestInit) => {
    requests.push(new Request(input, init));
    return new Response(body, { status });
  }) as typeof fetch;
  return { requests, fetchFn };
}

describe("APNs sender", () => {
  it("posts the alert with an ES256 provider token signed by the .p8 key", async () => {
    const { pem, publicKey } = await p8Key();
    const config: ApnsConfig = { keyId: "KEY123", teamId: "TEAM456", privateKey: pem, topic: "app.commoncam.CommonCam", sandbox: true };
    const { requests, fetchFn } = recordingFetch();
    const now = Date.UTC(2026, 10, 1);
    expect(await apnsSender(config, fetchFn, () => now).send(push)).toBeUndefined();

    const [request] = requests;
    expect(request.url).toBe(`https://api.sandbox.push.apple.com/3/device/${push.deviceToken}`);
    expect(request.method).toBe("POST");
    expect(request.headers.get("apns-topic")).toBe("app.commoncam.CommonCam");
    expect(request.headers.get("apns-push-type")).toBe("alert");
    expect(await request.json()).toEqual({
      aps: { alert: { title: "Album deleted tomorrow", body: "Save them." }, sound: "default" },
      groupId: "g-1",
      kind: "grace1Day",
    });

    const [scheme, jwt] = request.headers.get("authorization")!.split(" ");
    expect(scheme).toBe("bearer");
    const [header, claims, signature] = jwt.split(".");
    expect(JSON.parse(new TextDecoder().decode(fromBase64url(header)))).toEqual({ alg: "ES256", kid: "KEY123" });
    expect(JSON.parse(new TextDecoder().decode(fromBase64url(claims)))).toEqual({ iss: "TEAM456", iat: now / 1000 });
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      fromBase64url(signature),
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(valid).toBe(true);
  });

  it("uses production APNs when configured so", async () => {
    const { pem } = await p8Key();
    const { requests, fetchFn } = recordingFetch();
    await apnsSender({ keyId: "K2", teamId: "T", privateKey: pem, topic: "t", sandbox: false }, fetchFn).send(push);
    expect(new URL(requests[0].url).host).toBe("api.push.apple.com");
  });

  it("reports dead tokens as unregistered, and throws on other errors", async () => {
    const { pem } = await p8Key();
    const config: ApnsConfig = { keyId: "K3", teamId: "T", privateKey: pem, topic: "t", sandbox: true };
    expect(await apnsSender(config, recordingFetch(410, '{"reason":"Unregistered"}').fetchFn).send(push)).toBe("unregistered");
    expect(await apnsSender(config, recordingFetch(400, '{"reason":"BadDeviceToken"}').fetchFn).send(push)).toBe("unregistered");
    await expect(apnsSender(config, recordingFetch(500, '{"reason":"InternalServerError"}').fetchFn).send(push)).rejects.toThrow(
      "APNs 500 InternalServerError",
    );
  });
});
