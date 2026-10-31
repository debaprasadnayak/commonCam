/** A compact ES256 JWT signed with a P-256 PKCS#8 PEM key (Apple .p8 keys: APNs, App Store Server API). */
export async function signEs256Jwt(privateKeyPem: string, header: object, claims: object): Promise<string> {
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(privateKeyPem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signingInput = `${base64url(JSON.stringify({ alg: "ES256", ...header }))}.${base64url(JSON.stringify(claims))}`;
  // Web Crypto's ECDSA signature is raw r||s, which is exactly what JWS ES256 wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

function pemBytes(pem: string): Uint8Array {
  const base64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function base64url(data: string | Uint8Array): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
