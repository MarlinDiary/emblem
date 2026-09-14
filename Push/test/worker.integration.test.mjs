import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { env, exports } from "cloudflare:workers";
import { evictDurableObject, reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import worker from "../src/index.mjs";
import { sha256Hex } from "../src/security.mjs";

let pair, publicJWK;
const deviceID = "123e4567-e89b-42d3-a456-426614174000";
const token = "fixture_channel_token_abcdefghijklmnopqrstuvwxyz0123456789";
const encode = value => btoa(JSON.stringify(value)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
async function identity(audience, email, overrides = {}) {
  const now = Math.floor(Date.now() / 1_000);
  const content = `${encode({ alg: "RS256", kid: "integration-key" })}.${encode({
    iss: "https://accounts.google.com", aud: audience, email, email_verified: true,
    sub: "integration-subject", iat: now, exp: now + 3_600, ...overrides,
  })}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, new TextEncoder().encode(content));
  return `${content}.${btoa(String.fromCharCode(...new Uint8Array(signature))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")}`;
}
function post(path, bearer, body) {
  return new Request(`https://fixture${path}`, {
    method: "POST", headers: { "content-type": "application/json", Authorization: `Bearer ${bearer}`, "cf-connecting-ip": "192.0.2.11" },
    body: JSON.stringify(body),
  });
}
function nextEvent(socket, type) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { socket.removeEventListener(type, listener); reject(new Error(`Missing ${type}`)); }, 2_000);
    const listener = event => { clearTimeout(timer); resolve(event); };
    socket.addEventListener(type, listener, { once: true });
  });
}
async function connect(key, channelToken = token) {
  return exports.default.fetch(new Request(`https://fixture/v1/connect?accountKey=${key}&deviceId=${deviceID}`, {
    headers: { Upgrade: "websocket", Authorization: `Bearer ${channelToken}` },
  }));
}
beforeAll(async () => {
  pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
  publicJWK = await crypto.subtle.exportKey("jwk", pair.publicKey);
  Object.assign(publicJWK, { kid: "integration-key", alg: "RS256", use: "sig" });
});
afterEach(async () => { vi.restoreAllMocks(); await reset(); });

describe("Emblem Push Worker", () => {
  it("separates liveness from configured readiness and rejects unauthenticated registration", async () => {
    const health = await exports.default.fetch(new Request("https://fixture/health"));
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ status: "ok" });
    expect((await exports.default.fetch(new Request("https://fixture/ready"))).status).toBe(200);
    const unconfigured = await worker.fetch(new Request("https://fixture/ready"), {});
    expect(unconfigured.status).toBe(503);
    expect(await unconfigured.json()).toEqual({ ready: false });
    const denied = await exports.default.fetch(post("/v1/register", "fixture-token-long-enough", {}));
    expect(denied.status).toBe(400);
    expect((await exports.default.fetch(new Request("https://fixture/v1/register", { method: "POST" }))).status).toBe(401);
  });

  it("verifies Google identity, delivers authenticated Pub/Sub across hibernation and revokes the socket", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation(async url => {
      if (url !== "https://www.googleapis.com/oauth2/v3/certs") throw new Error("Unexpected external request");
      return Response.json({ keys: [publicJWK] });
    });
    const email = "sender@gmail.com", idToken = await identity(env.GOOGLE_CLIENT_ID, email);
    const body = { email, deviceId: deviceID, channelToken: token };
    const mismatch = await exports.default.fetch(post("/v1/register", idToken, { ...body, email: "other@gmail.com" }));
    expect(mismatch.status).toBe(401);
    const registered = await exports.default.fetch(post("/v1/register", idToken, body));
    expect(registered.status).toBe(200);
    const { accountKey: key, expiresAt } = await registered.json();
    expect(key).toMatch(/^[a-f0-9]{64}$/);
    expect(expiresAt).toBeGreaterThan(Date.now());
    const room = env.ACCOUNT_CHANNEL.getByName(key);
    expect((await connect(key, token + "wrong")).status).toBe(401);
    const connected = await connect(key);
    expect(connected.status).toBe(101);
    const socket = connected.webSocket, ready = nextEvent(socket, "message"); socket.accept();
    expect(JSON.parse((await ready).data)).toEqual({ type: "gmail-history", historyId: "0", reason: "connected" });
    await evictDurableObject(room);
    const data = btoa(JSON.stringify({ emailAddress: email, historyId: "9001" }));
    const notification = { message: { data, messageId: "fixture-message" } };
    expect((await exports.default.fetch(post("/v1/google-push", idToken, notification))).status).toBe(401);
    const pushToken = await identity(env.PUBSUB_AUDIENCE, env.PUBSUB_SERVICE_ACCOUNT);
    const received = nextEvent(socket, "message");
    expect((await exports.default.fetch(post("/v1/google-push", pushToken, notification))).status).toBe(204);
    const hint = JSON.parse((await received).data);
    expect(hint.type).toBe("gmail-history"); expect(hint.historyId).toBe("9001");
    expect(Object.keys(hint).sort()).toEqual(["historyId", "receivedAt", "type"]);
    const closed = nextEvent(socket, "close");
    expect((await exports.default.fetch(post("/v1/unregister", token, { accountKey: key, deviceId: deviceID }))).status).toBe(204);
    expect((await closed).code).toBe(1008);
    expect((await connect(key)).status).toBe(401);
  });

  it("expires device rows with durable alarms", async () => {
    const room = env.ACCOUNT_CHANNEL.getByName("b".repeat(64));
    const hash = await sha256Hex(token);
    await room.register(deviceID, hash, Date.now() + 60_000, Date.now());
    // Keep the alarm scheduled in the future so workerd cannot race the test
    // by automatically executing an already-due alarm before the assertion.
    await runInDurableObject(room, (_, state) => {
      state.storage.sql.exec("UPDATE devices SET expires_at = 1 WHERE device_id = ?", deviceID);
    });
    expect(await runDurableObjectAlarm(room)).toBe(true);
    expect(await room.verify(deviceID, hash, Date.now())).toBe(false);
    expect(await runDurableObjectAlarm(room)).toBe(false);
  });

  it("closes the prior connection when its channel token rotates", async () => {
    const key = "c".repeat(64), room = env.ACCOUNT_CHANNEL.getByName(key);
    await room.register(deviceID, await sha256Hex(token), Date.now() + 60_000, Date.now());
    const connected = await connect(key), socket = connected.webSocket;
    const ready = nextEvent(socket, "message"); socket.accept(); await ready;
    const closed = nextEvent(socket, "close");
    await room.register(deviceID, await sha256Hex(token + "rotated"), Date.now() + 60_000, Date.now());
    expect((await closed).code).toBe(1008);
    expect((await connect(key)).status).toBe(401);
  });
});
