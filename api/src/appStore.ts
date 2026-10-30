// Verifies App Store signed transactions (StoreKit 2 `jwsRepresentation`) without any network call:
// the JWS must be ES256-signed by a leaf certificate that chains, via Apple's intermediate, to the
// pinned Apple Root CA - G3. Mirrors what Apple's App Store Server Library does offline.
//
// shortcut: no OCSP/CRL revocation check of the chain; Apple's library does this online. Needs
// outbound calls to Apple's OCSP responder and real Apple-signed transactions to test.
// shortcut: only exercised with locally generated test certificates; never against a real
// Sandbox/Production transaction (no App Store Connect account yet). The parser was checked by hand
// against Apple's real Root CA - G3 and WWDR G6 intermediate.
// shortcut: Xcode-environment transactions (local .storekit testing) are self-signed by Xcode and
// are rejected; transaction `environment` (Sandbox vs Production) is recorded but not enforced.

export class InvalidTransaction extends Error {}

export interface AppStoreTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  environment?: string;
  price?: number;
  currency?: string;
  revocationDate?: number;
}

export interface AppStoreTrust {
  /** DER of the trusted root, base64. */
  rootCertB64: string;
  bundleId: string;
  now?: Date;
}

const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  ecdsaWithSha384: "1.2.840.10045.4.3.3",
  appleIntermediateMarker: "1.2.840.113635.100.6.2.1",
  appleLeafMarker: "1.2.840.113635.100.6.11.1",
};

export async function verifySignedTransaction(jws: string, trust: AppStoreTrust): Promise<AppStoreTransaction> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new InvalidTransaction("Not a compact JWS");
  const [headerPart, payloadPart, signaturePart] = parts;
  const header = parseJson(base64UrlDecode(headerPart));
  if (header.alg !== "ES256") throw new InvalidTransaction("Unexpected JWS algorithm");
  if (!Array.isArray(header.x5c) || header.x5c.length !== 3) throw new InvalidTransaction("Expected a 3-certificate x5c chain");

  const [leafDer, intermediateDer, rootDer] = header.x5c.map((c: unknown) => {
    if (typeof c !== "string") throw new InvalidTransaction("Bad x5c entry");
    return base64Decode(c);
  });
  if (!bytesEqual(rootDer, base64Decode(trust.rootCertB64))) throw new InvalidTransaction("Untrusted root certificate");

  const root = parseCertificate(rootDer);
  const intermediate = parseCertificate(intermediateDer);
  const leaf = parseCertificate(leafDer);
  if (!intermediate.extensionOids.includes(OID.appleIntermediateMarker)) throw new InvalidTransaction("Not an Apple intermediate");
  if (!leaf.extensionOids.includes(OID.appleLeafMarker)) throw new InvalidTransaction("Not an App Store signing certificate");

  const now = trust.now ?? new Date();
  for (const cert of [leaf, intermediate, root]) {
    if (now < cert.notBefore || now > cert.notAfter) throw new InvalidTransaction("Certificate outside its validity period");
  }
  await verifyIssuedBy(intermediate, root);
  await verifyIssuedBy(leaf, intermediate);

  if (leaf.curve !== "P-256") throw new InvalidTransaction("ES256 needs a P-256 key");
  const leafKey = await importKey(leaf);
  const jwsValid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    base64UrlDecode(signaturePart),
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!jwsValid) throw new InvalidTransaction("Bad JWS signature");

  const payload = parseJson(base64UrlDecode(payloadPart)) as AppStoreTransaction;
  if (payload.bundleId !== trust.bundleId) throw new InvalidTransaction("Transaction is for another app");
  if (typeof payload.transactionId !== "string" || typeof payload.productId !== "string") {
    throw new InvalidTransaction("Transaction is missing ids");
  }
  if (payload.revocationDate !== undefined) throw new InvalidTransaction("Transaction was refunded or revoked");
  return payload;
}

interface Certificate {
  tbs: Uint8Array;
  signatureHash: "SHA-256" | "SHA-384";
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  notBefore: Date;
  notAfter: Date;
  extensionOids: string[];
}

async function verifyIssuedBy(cert: Certificate, issuer: Certificate) {
  if (!bytesEqual(cert.issuer, issuer.subject)) throw new InvalidTransaction("Certificate chain is out of order");
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: cert.signatureHash },
    await importKey(issuer),
    derSignatureToRaw(cert.signature, issuer.curve === "P-384" ? 48 : 32),
    cert.tbs,
  );
  if (!valid) throw new InvalidTransaction("Certificate not signed by its issuer");
}

function importKey(cert: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: cert.curve }, false, ["verify"]);
}

function parseCertificate(der: Uint8Array): Certificate {
  const [tbsNode, sigAlgNode, sigNode] = children(der, read(der, 0));
  const tbsFields = children(der, tbsNode);
  const fields = tbsFields[0].tag === 0xa0 ? tbsFields.slice(1) : tbsFields;
  const [, , issuerNode, validityNode, subjectNode, spkiNode, ...optional] = fields;

  const [notBefore, notAfter] = children(der, validityNode).map((n) => parseTime(der, n));
  const [spkiAlg] = children(der, spkiNode);
  const [keyType, curveOid] = children(der, spkiAlg).map((n) => parseOid(der, n));
  if (keyType !== OID.ecPublicKey) throw new InvalidTransaction("Unsupported key type");
  const curve = curveOid === OID.p256 ? "P-256" : curveOid === OID.p384 ? "P-384" : undefined;
  if (!curve) throw new InvalidTransaction("Unsupported curve");

  const sigAlg = parseOid(der, children(der, sigAlgNode)[0]);
  const signatureHash =
    sigAlg === OID.ecdsaWithSha256 ? "SHA-256" : sigAlg === OID.ecdsaWithSha384 ? "SHA-384" : undefined;
  if (!signatureHash) throw new InvalidTransaction("Unsupported signature algorithm");

  const extensionsNode = optional.find((n) => n.tag === 0xa3);
  const extensionOids = extensionsNode
    ? children(der, children(der, extensionsNode)[0]).map((ext) => parseOid(der, children(der, ext)[0]))
    : [];

  if (sigNode.tag !== 0x03) throw new InvalidTransaction("Malformed certificate signature");
  return {
    tbs: whole(der, tbsNode),
    signatureHash,
    signature: der.subarray(sigNode.contentStart + 1, sigNode.end),
    issuer: whole(der, issuerNode),
    subject: whole(der, subjectNode),
    spki: whole(der, spkiNode),
    curve,
    notBefore,
    notAfter,
    extensionOids,
  };
}

// Minimal DER reader; any structural surprise is treated as a forged transaction.
interface Node {
  tag: number;
  start: number;
  contentStart: number;
  end: number;
}

function read(buf: Uint8Array, pos: number): Node {
  if (pos + 2 > buf.length) throw new InvalidTransaction("Truncated DER");
  const tag = buf[pos];
  let length = buf[pos + 1];
  let contentStart = pos + 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    if (n === 0 || n > 3 || contentStart + n > buf.length) throw new InvalidTransaction("Bad DER length");
    length = 0;
    for (let i = 0; i < n; i++) length = (length << 8) | buf[contentStart + i];
    contentStart += n;
  }
  const end = contentStart + length;
  if (end > buf.length) throw new InvalidTransaction("Truncated DER");
  return { tag, start: pos, contentStart, end };
}

function children(buf: Uint8Array, node: Node | undefined): Node[] {
  if (!node || !(node.tag & 0x20)) throw new InvalidTransaction("Expected a constructed DER value");
  const out: Node[] = [];
  for (let pos = node.contentStart; pos < node.end; ) {
    const child = read(buf, pos);
    if (child.end > node.end) throw new InvalidTransaction("Bad DER nesting");
    out.push(child);
    pos = child.end;
  }
  return out;
}

const whole = (buf: Uint8Array, n: Node) => buf.subarray(n.start, n.end);
const content = (buf: Uint8Array, n: Node) => buf.subarray(n.contentStart, n.end);

function parseOid(buf: Uint8Array, node: Node | undefined): string {
  if (!node || node.tag !== 0x06) throw new InvalidTransaction("Expected an OID");
  const bytes = content(buf, node);
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (const b of bytes.subarray(1)) {
    value = value * 128 + (b & 0x7f);
    if (!(b & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function parseTime(buf: Uint8Array, node: Node): Date {
  let s = new TextDecoder().decode(content(buf, node));
  if (node.tag === 0x17) s = (Number(s.slice(0, 2)) < 50 ? "20" : "19") + s;
  else if (node.tag !== 0x18) throw new InvalidTransaction("Expected a time");
  const m = s.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
  if (!m) throw new InvalidTransaction("Bad certificate time");
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
}

// X.509 ECDSA signatures are DER SEQUENCE { r, s }; Web Crypto wants fixed-width r || s.
function derSignatureToRaw(der: Uint8Array, size: number): Uint8Array {
  const ints = children(der, read(der, 0));
  if (ints.length !== 2 || ints.some((n) => n.tag !== 0x02)) throw new InvalidTransaction("Bad ECDSA signature");
  const raw = new Uint8Array(size * 2);
  ints.forEach((n, i) => {
    let bytes = content(der, n);
    while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
    if (bytes.length > size) throw new InvalidTransaction("Bad ECDSA signature");
    raw.set(bytes, size * (i + 1) - bytes.length);
  });
  return raw;
}

function parseJson(bytes: Uint8Array): any {
  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (value && typeof value === "object") return value;
  } catch {}
  throw new InvalidTransaction("Bad JSON");
}

function base64Decode(s: string): Uint8Array {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    throw new InvalidTransaction("Bad base64");
  }
}

function base64UrlDecode(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  return base64Decode(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}
