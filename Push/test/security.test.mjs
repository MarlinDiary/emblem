import test from "node:test";
import assert from "node:assert/strict";
import {
  accountKey,
  decodePubSubMessage,
  parseBearer,
  timingSafeEqualText,
  verifyGoogleJWT,
} from "../src/security.mjs";

test("account keys are deterministic HMACs without address disclosure", async () => {
  const a = await accountKey("Sender@GMAIL.com ", "fixture-secret");
  const b = await accountKey("sender@gmail.com", "fixture-secret");
  assert.equal(a, b);
  assert.match(a, /^[a-f0-9]{64}$/);
  assert.equal(a.includes("gmail"), false);
});

test("Pub/Sub decoder validates and normalizes the Gmail envelope", () => {
  const data = Buffer.from(JSON.stringify({ emailAddress: "Sender@GMAIL.com", historyId: "9001" })).toString("base64");
  assert.deepEqual(decodePubSubMessage({ message: { data, messageId: "fixture" } }), {
    emailAddress: "sender@gmail.com",
    historyId: "9001",
  });
  assert.throws(() => decodePubSubMessage({ message: { data: "!!!" } }));
  assert.throws(() => decodePubSubMessage({ message: { data: Buffer.from("{}").toString("base64") } }));
});

test("bearer parsing and constant-time comparison reject malformed input", () => {
  const token = "fixture-token-long-enough";
  assert.equal(parseBearer(`Bearer ${token}`), token);
  assert.equal(parseBearer(`Basic ${token}`), null);
  assert.equal(timingSafeEqualText("same", "same"), true);
  assert.equal(timingSafeEqualText("same", "different"), false);
});

test("Google JWT verification checks signature, audience, issuer, time and email", async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const publicJWK = await crypto.subtle.exportKey("jwk", pair.publicKey);
  Object.assign(publicJWK, { kid: "fixture-key", alg: "RS256", use: "sig" });
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const issue = async (overrides = {}) => {
    const header = encode({ alg: "RS256", kid: "fixture-key", typ: "JWT" });
    const claims = encode({
      iss: "https://accounts.google.com",
      aud: "fixture-audience",
      sub: "fixture-subject",
      email: "sender@gmail.com",
      email_verified: true,
      iat: 1_000,
      exp: 2_000,
      ...overrides,
    });
    const content = `${header}.${claims}`;
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(content));
    return `${content}.${Buffer.from(signature).toString("base64url")}`;
  };
  const options = { audience: "fixture-audience", email: "sender@gmail.com", now: 1_500, jwks: { keys: [publicJWK] } };
  assert.deepEqual(await verifyGoogleJWT(await issue(), options), { email: "sender@gmail.com", subject: "fixture-subject" });
  await assert.rejects(verifyGoogleJWT(await issue({ aud: "wrong" }), options));
  await assert.rejects(verifyGoogleJWT(await issue({ exp: 1_000 }), options));
  await assert.rejects(verifyGoogleJWT(`${await issue()}changed`, options));
});
