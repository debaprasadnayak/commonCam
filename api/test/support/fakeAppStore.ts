// Test-only stand-in for Apple's App Store signing PKI: a root CA, an intermediate and a leaf
// certificate carrying Apple's marker OIDs, plus a JWS signer. Runs in Node (vitest config) and workerd.

const OID = {
  commonName: "2.5.4.3",
  basicConstraints: "2.5.29.19",
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  ecdsaWithSha384: "1.2.840.10045.4.3.3",
  appleIntermediateMarker: "1.2.840.113635.100.6.2.1",
  appleLeafMarker: "1.2.840.113635.100.6.11.1",
};

export interface TestCert {
  der: Uint8Array;
  name: string;
  keys: CryptoKeyPair;
  hash: "SHA-256" | "SHA-384";
}

export interface FakeAppStore {
  root: TestCert;
  intermediate: TestCert;
  leaf: TestCert;
}

/** What vitest.config.ts hands to the tests as the `TEST_APPLE_PKI` binding. */
export interface SerializedFakeAppStore {
  chain: string[];
  leafKey: JsonWebKey;
  intermediateKey: JsonWebKey;
  rootKey: JsonWebKey;
}

const DAY_MS = 24 * 60 * 60 * 1000;
const ROOT_NAME = "Test Apple Root CA - G3";
const INTERMEDIATE_NAME = "Test Apple WWDR CA";

export async function createCert(opts: {
  name: string;
  curve: "P-256" | "P-384";
  issuer?: TestCert;
  marker?: string;
  notBefore?: Date;
  notAfter?: Date;
}): Promise<TestCert> {
  const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: opts.curve }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const hash = opts.curve === "P-384" ? "SHA-384" : "SHA-256";
  const signer = opts.issuer ?? { name: opts.name, keys, hash };
  const sigAlg = seq(oid(signer.hash === "SHA-384" ? OID.ecdsaWithSha384 : OID.ecdsaWithSha256));
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey));
  const isCA = opts.curve === "P-384";
  const extensions = [
    ...(isCA ? [seq(oid(OID.basicConstraints), bool(true), octetString(seq(bool(true))))] : []),
    ...(opts.marker ? [seq(oid(opts.marker), octetString(new Uint8Array([5, 0])))] : []),
  ];
  const tbs = seq(
    ctx(0, int(new Uint8Array([2]))),
    int(crypto.getRandomValues(new Uint8Array(8)).map((b, i) => (i === 0 ? (b & 0x7f) | 1 : b))),
    sigAlg,
    name(signer.name),
    seq(
      utcTime(opts.notBefore ?? new Date(Date.now() - DAY_MS)),
      utcTime(opts.notAfter ?? new Date(Date.now() + 365 * DAY_MS)),
    ),
    name(opts.name),
    spki,
    ...(extensions.length ? [ctx(3, seq(...extensions))] : []),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: signer.hash }, signer.keys.privateKey, tbs));
  const half = raw.length / 2;
  const signature = seq(int(raw.slice(0, half)), int(raw.slice(half)));
  const der = seq(tbs, sigAlg, bitString(signature));
  return { der, name: opts.name, keys, hash };
}

export async function createFakeAppStore(): Promise<FakeAppStore> {
  const root = await createCert({ name: ROOT_NAME, curve: "P-384" });
  const intermediate = await createCert({
    name: INTERMEDIATE_NAME,
    curve: "P-384",
    issuer: root,
    marker: OID.appleIntermediateMarker,
  });
  const leaf = await createCert({
    name: "Test App Store Receipt Signing",
    curve: "P-256",
    issuer: intermediate,
    marker: OID.appleLeafMarker,
  });
  return { root, intermediate, leaf };
}

export const markers = { intermediate: OID.appleIntermediateMarker, leaf: OID.appleLeafMarker };

export function chainOf(...certs: TestCert[]): string[] {
  return certs.map((c) => b64(c.der));
}

export async function serialize(store: FakeAppStore): Promise<SerializedFakeAppStore> {
  return {
    chain: chainOf(store.leaf, store.intermediate, store.root),
    leafKey: await crypto.subtle.exportKey("jwk", store.leaf.keys.privateKey),
    intermediateKey: await crypto.subtle.exportKey("jwk", store.intermediate.keys.privateKey),
    rootKey: await crypto.subtle.exportKey("jwk", store.root.keys.privateKey),
  };
}

/** A trusted test CA rebuilt from the binding, so tests can issue their own certificates under it. */
export async function trustedIssuer(pki: SerializedFakeAppStore, which: "root" | "intermediate"): Promise<TestCert> {
  const privateKey = await crypto.subtle.importKey(
    "jwk",
    which === "root" ? pki.rootKey : pki.intermediateKey,
    { name: "ECDSA", namedCurve: "P-384" },
    false,
    ["sign"],
  );
  return {
    der: Uint8Array.from(atob(pki.chain[which === "root" ? 2 : 1]), (c) => c.charCodeAt(0)),
    name: which === "root" ? ROOT_NAME : INTERMEDIATE_NAME,
    keys: { privateKey, publicKey: privateKey },
    hash: "SHA-384",
  };
}

/** Signs `payload` as an App Store JWS (ES256, x5c = leaf, intermediate, root). */
export async function signTransaction(payload: object, chain: string[], leafPrivateKey: CryptoKey): Promise<string> {
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", x5c: chain })));
  const body = b64url(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    leafPrivateKey,
    new TextEncoder().encode(`${header}.${body}`),
  );
  return `${header}.${body}.${b64url(new Uint8Array(signature))}`;
}

export function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

export function b64url(bytes: Uint8Array): string {
  return b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Minimal DER encoder.
function tlv(tag: number, content: Uint8Array): Uint8Array {
  const len = content.length;
  const lenBytes = len < 0x80 ? [len] : len < 0x100 ? [0x81, len] : [0x82, len >> 8, len & 0xff];
  const out = new Uint8Array(1 + lenBytes.length + len);
  out[0] = tag;
  out.set(lenBytes, 1);
  out.set(content, 1 + lenBytes.length);
  return out;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

const seq = (...items: Uint8Array[]) => tlv(0x30, concat(items));
const set = (...items: Uint8Array[]) => tlv(0x31, concat(items));
const ctx = (n: number, inner: Uint8Array) => tlv(0xa0 + n, inner);
const bool = (v: boolean) => tlv(0x01, new Uint8Array([v ? 0xff : 0]));
const octetString = (b: Uint8Array) => tlv(0x04, b);
const bitString = (b: Uint8Array) => tlv(0x03, concat([new Uint8Array([0]), b]));
const utf8 = (s: string) => tlv(0x0c, new TextEncoder().encode(s));
const utcTime = (d: Date) =>
  tlv(0x17, new TextEncoder().encode(d.toISOString().replace(/[-:T]/g, "").slice(2, 14) + "Z"));
const name = (cn: string) => seq(set(seq(oid(OID.commonName), utf8(cn))));

function int(bytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  const trimmed = bytes.slice(i);
  return tlv(0x02, trimmed[0] & 0x80 ? concat([new Uint8Array([0]), trimmed]) : trimmed);
}

function oid(dotted: string): Uint8Array {
  const [a, b, ...rest] = dotted.split(".").map(Number);
  const out = [a * 40 + b];
  for (const n of rest) {
    const chunk = [n & 0x7f];
    for (let v = Math.floor(n / 128); v > 0; v = Math.floor(v / 128)) chunk.unshift((v & 0x7f) | 0x80);
    out.push(...chunk);
  }
  return tlv(0x06, new Uint8Array(out));
}
