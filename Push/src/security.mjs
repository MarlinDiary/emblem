const encoder = new TextEncoder();
let cachedJWKS = null;
let cachedJWKSUntil = 0;
let lastJWKSFetch = 0;
let pendingJWKS = null;

export function normalizeEmail(value) {
  if (typeof value !== "string") throw new Error("invalid email");
  const email = value.trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error("invalid email");
  return email;
}

function bytesToHex(bytes) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(value) {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

export async function accountKey(email, secret) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(normalizeEmail(email)));
  return bytesToHex(new Uint8Array(digest));
}

export function parseBearer(value) {
  if (typeof value !== "string") return null;
  const match = /^Bearer ([A-Za-z0-9._~-]{16,8192})$/.exec(value);
  return match?.[1] ?? null;
}

export function timingSafeEqualText(left, right) {
  if (typeof left !== "string" || typeof right !== "string") return false;
  const a = encoder.encode(left), b = encoder.encode(right);
  const length = Math.max(a.length, b.length), difference = a.length ^ b.length;
  let result = difference;
  for (let i = 0; i < length; i += 1) result |= (a[i % Math.max(a.length, 1)] ?? 0) ^ (b[i % Math.max(b.length, 1)] ?? 0);
  return result === 0;
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length > 65_536 || value.length % 4 === 1 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error("invalid base64");
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}

function decodeBase64URL(value) {
  if (typeof value !== "string" || value.length > 16_384 || !/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid jwt");
  let standard = value.replaceAll("-", "+").replaceAll("_", "/");
  standard += "=".repeat((4 - (standard.length % 4)) % 4);
  return decodeBase64(standard);
}

function base64URLBytes(value) {
  let standard = value.replaceAll("-", "+").replaceAll("_", "/");
  standard += "=".repeat((4 - (standard.length % 4)) % 4);
  const binary = atob(standard);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function decodePubSubMessage(envelope) {
  if (!envelope || typeof envelope !== "object" || !envelope.message || typeof envelope.message !== "object") throw new Error("invalid envelope");
  const decoded = JSON.parse(decodeBase64(envelope.message.data));
  const emailAddress = normalizeEmail(decoded.emailAddress);
  const historyId = decoded.historyId;
  if (typeof historyId !== "string" || !/^[0-9]{1,32}$/.test(historyId)) throw new Error("invalid history id");
  return { emailAddress, historyId };
}

async function googleJWKS(fetcher = fetch, force = false) {
  if (cachedJWKS && ((!force && Date.now() < cachedJWKSUntil) || (force && Date.now() - lastJWKSFetch < 60_000))) return cachedJWKS;
  if (pendingJWKS) return pendingJWKS;
  // Unknown IDs share the refresh; a forged JWT cannot trigger one Google
  // request per attempt. A failed fetch also has a short retry boundary.
  if (Date.now() - lastJWKSFetch < 10_000) throw new Error("identity keys retry later");
  lastJWKSFetch = Date.now();
  pendingJWKS = (async () => {
    const response = await fetcher("https://www.googleapis.com/oauth2/v3/certs", {
      headers: { Accept: "application/json" }, signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error("identity keys unavailable");
    const text = await response.text();
    if (text.length > 65_536) throw new Error("invalid identity keys");
    const value = JSON.parse(text);
    if (!value || !Array.isArray(value.keys) || value.keys.length > 20) throw new Error("invalid identity keys");
    cachedJWKS = value; cachedJWKSUntil = Date.now() + 3_600_000;
    return value;
  })();
  try { return await pendingJWKS; } finally { pendingJWKS = null; }
}

export async function verifyGoogleJWT(token, options) {
  if (typeof token !== "string" || token.length > 16_384) throw new Error("invalid identity token");
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("invalid identity token");
  const header = JSON.parse(decodeBase64URL(parts[0]));
  const claims = JSON.parse(decodeBase64URL(parts[1]));
  if (header.alg !== "RS256" || typeof header.kid !== "string" || header.kid.length > 256) throw new Error("invalid identity algorithm");
  let jwks = options.jwks ?? await googleJWKS(options.fetcher);
  let jwk = jwks.keys.find((candidate) => candidate.kid === header.kid && candidate.kty === "RSA" && candidate.alg === "RS256");
  if (!jwk && !options.jwks) {
    jwks = await googleJWKS(options.fetcher, true);
    jwk = jwks.keys.find((candidate) => candidate.kid === header.kid && candidate.kty === "RSA" && candidate.alg === "RS256");
  }
  if (!jwk) throw new Error("unknown identity key");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, base64URLBytes(parts[2]), encoder.encode(`${parts[0]}.${parts[1]}`));
  if (!valid) throw new Error("invalid identity signature");
  const now = options.now ?? Math.floor(Date.now() / 1_000);
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(options.audience) || !["accounts.google.com", "https://accounts.google.com"].includes(claims.iss)) throw new Error("invalid identity audience");
  if (!Number.isFinite(claims.exp) || claims.exp < now - 30 || !Number.isFinite(claims.iat) || claims.iat > now + 300) throw new Error("expired identity token");
  if (claims.email_verified !== true && claims.email_verified !== "true") throw new Error("unverified identity email");
  if (typeof claims.sub !== "string" || claims.sub.length < 1 || claims.sub.length > 255) throw new Error("invalid identity subject");
  const email = normalizeEmail(claims.email);
  if (options.email && email !== normalizeEmail(options.email)) throw new Error("identity email mismatch");
  return { email, subject: claims.sub };
}

export function validAccountKey(value) { return typeof value === "string" && /^[a-f0-9]{64}$/.test(value); }
export function validDeviceID(value) { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value); }
export function validChannelToken(value) { return typeof value === "string" && /^[A-Za-z0-9_-]{40,128}$/.test(value); }
