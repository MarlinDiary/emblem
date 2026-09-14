import { DurableObject } from "cloudflare:workers";
import {
  accountKey,
  decodePubSubMessage,
  normalizeEmail,
  parseBearer,
  sha256Hex,
  timingSafeEqualText,
  validAccountKey,
  validChannelToken,
  validDeviceID,
  verifyGoogleJWT,
} from "./security.mjs";

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
function response(status, code) { return Response.json({ error: code }, { status, headers: jsonHeaders }); }
function bodyAllowed(request) {
  const length = Number(request.headers.get("content-length") ?? 0);
  return Number.isFinite(length) && length <= 32_768 && (request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json");
}
async function jsonBody(request) {
  if (!bodyAllowed(request)) throw new Error("invalid body");
  const reader = request.body?.getReader();
  if (!reader) throw new Error("invalid body");
  const chunks = []; let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 32_768) { await reader.cancel(); throw new Error("invalid body"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const data = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
}

export class AccountChannel extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS devices (
          device_id TEXT PRIMARY KEY,
          token_hash TEXT NOT NULL,
          expires_at INTEGER NOT NULL,
          registered_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS devices_expiry ON devices(expires_at);
      `);
    });
  }

  async register(deviceID, tokenHash, expiresAt, registeredAt) {
    this.ctx.storage.sql.exec("DELETE FROM devices WHERE expires_at <= ?", registeredAt);
    const existing = this.ctx.storage.sql.exec("SELECT device_id FROM devices WHERE device_id = ?", deviceID).toArray();
    const count = this.ctx.storage.sql.exec("SELECT COUNT(*) AS count FROM devices").one().count;
    if (existing.length === 0 && count >= 10) throw new Error("device limit");
    this.ctx.storage.sql.exec(
      "INSERT INTO devices(device_id,token_hash,expires_at,registered_at) VALUES(?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET token_hash=excluded.token_hash,expires_at=excluded.expires_at,registered_at=excluded.registered_at",
      deviceID, tokenHash, expiresAt, registeredAt,
    );
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (attachment?.deviceID === deviceID) {
        if (attachment.tokenHash !== tokenHash) socket.close(1008, "replaced");
        else socket.serializeAttachment({ ...attachment, expiresAt });
      }
    }
    await this.scheduleExpiry();
  }

  async scheduleExpiry() {
    const row = this.ctx.storage.sql.exec("SELECT MIN(expires_at) AS expiry FROM devices").one();
    if (row.expiry !== null) await this.ctx.storage.setAlarm(row.expiry);
    else await this.ctx.storage.deleteAlarm();
  }

  async alarm() {
    this.ctx.storage.sql.exec("DELETE FROM devices WHERE expires_at <= ?", Date.now());
    for (const socket of this.ctx.getWebSockets()) {
      if ((socket.deserializeAttachment()?.expiresAt ?? 0) <= Date.now()) socket.close(1008, "expired");
    }
    await this.scheduleExpiry();
  }

  verify(deviceID, tokenHash, now) {
    const rows = this.ctx.storage.sql.exec("SELECT token_hash,expires_at FROM devices WHERE device_id = ?", deviceID).toArray();
    return rows.length === 1 && rows[0].expires_at > now && timingSafeEqualText(rows[0].token_hash, tokenHash);
  }

  async unregister(deviceID, tokenHash) {
    if (!this.verify(deviceID, tokenHash, Date.now())) return false;
    this.ctx.storage.sql.exec("DELETE FROM devices WHERE device_id = ?", deviceID);
    for (const socket of this.ctx.getWebSockets()) {
      if (socket.deserializeAttachment()?.deviceID === deviceID) socket.close(1008, "unregistered");
    }
    await this.scheduleExpiry();
    return true;
  }

  publish(historyID, receivedAt) {
    const payload = JSON.stringify({ type: "gmail-history", historyId: historyID, receivedAt });
    let delivered = 0;
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (!attachment || attachment.expiresAt <= Date.now()) { socket.close(1008, "expired"); continue; }
      try { socket.send(payload); delivered += 1; } catch { socket.close(1011, "delivery"); }
    }
    return delivered;
  }

  async fetch(request) {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return response(426, "websocket_required");
    const deviceID = request.headers.get("x-emblem-device"), tokenHash = request.headers.get("x-emblem-token-hash");
    if (!validDeviceID(deviceID) || typeof tokenHash !== "string" || !(await this.verify(deviceID, tokenHash, Date.now()))) return response(401, "unauthorized");
    const rows = this.ctx.storage.sql.exec("SELECT expires_at FROM devices WHERE device_id = ?", deviceID).toArray();
    // Allow only the brief foreground/helper overlap per registered Mac.
    const previous = this.ctx.getWebSockets().filter(socket => socket.deserializeAttachment()?.deviceID === deviceID);
    for (const socket of previous.slice(0, Math.max(0, previous.length - 1))) socket.close(1008, "reconnected");
    const pair = new WebSocketPair(), [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ deviceID, tokenHash, expiresAt: rows[0].expires_at });
    // A connection/reconnection always asks the Mac to replay its own cursor.
    // No history ID is stored at the relay and missed offline hints are harmless.
    server.send(JSON.stringify({ type: "gmail-history", historyId: "0", reason: "connected" }));
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket, message) {
    if (typeof message !== "string" || message.length > 1_024) { socket.close(1009, "message size"); return; }
    if (message === "ping") socket.send("pong");
  }
  webSocketClose(socket, code, reason) { socket.close(code, reason); }
}

async function register(request, env) {
  const bearer = parseBearer(request.headers.get("authorization"));
  if (!bearer) return response(401, "unauthorized");
  let body;
  try { body = await jsonBody(request); } catch { return response(400, "invalid_request"); }
  if (!validDeviceID(body.deviceId) || !validChannelToken(body.channelToken)) return response(400, "invalid_request");
  let email;
  try {
    email = normalizeEmail(body.email);
    await verifyGoogleJWT(bearer, { audience: env.GOOGLE_CLIENT_ID, email });
  } catch { return response(401, "unauthorized"); }
  const key = await accountKey(email, env.HMAC_SECRET), tokenHash = await sha256Hex(body.channelToken);
  const now = Date.now(), expiresAt = now + 180 * 86_400_000;
  try { await env.ACCOUNT_CHANNEL.getByName(key).register(body.deviceId, tokenHash, expiresAt, now); }
  catch { return response(429, "device_limit"); }
  return Response.json({ accountKey: key, expiresAt }, { headers: jsonHeaders });
}

async function unregister(request, env) {
  const bearer = parseBearer(request.headers.get("authorization"));
  if (!bearer) return response(401, "unauthorized");
  let body;
  try { body = await jsonBody(request); } catch { return response(400, "invalid_request"); }
  if (!validAccountKey(body.accountKey) || !validDeviceID(body.deviceId) || !validChannelToken(bearer)) return response(400, "invalid_request");
  const tokenHash = await sha256Hex(bearer), room = env.ACCOUNT_CHANNEL.getByName(body.accountKey);
  return await room.unregister(body.deviceId, tokenHash) ? new Response(null, { status: 204 }) : response(401, "unauthorized");
}

async function connect(request, env, url) {
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") return response(426, "websocket_required");
  const bearer = parseBearer(request.headers.get("authorization"));
  const key = url.searchParams.get("accountKey"), deviceID = url.searchParams.get("deviceId");
  if (!bearer || !validChannelToken(bearer) || !validAccountKey(key) || !validDeviceID(deviceID)) return response(401, "unauthorized");
  const tokenHash = await sha256Hex(bearer), room = env.ACCOUNT_CHANNEL.getByName(key);
  if (!(await room.verify(deviceID, tokenHash, Date.now()))) return response(401, "unauthorized");
  const headers = new Headers(request.headers);
  headers.delete("authorization"); headers.set("x-emblem-device", deviceID); headers.set("x-emblem-token-hash", tokenHash);
  return room.fetch(new Request(request, { headers }));
}

async function googlePush(request, env) {
  const bearer = parseBearer(request.headers.get("authorization"));
  if (!bearer) return response(401, "unauthorized");
  try {
    const identity = await verifyGoogleJWT(bearer, { audience: env.PUBSUB_AUDIENCE, email: env.PUBSUB_SERVICE_ACCOUNT });
    if (identity.email !== normalizeEmail(env.PUBSUB_SERVICE_ACCOUNT)) return response(401, "unauthorized");
  } catch { return response(401, "unauthorized"); }
  let event;
  try { event = decodePubSubMessage(await jsonBody(request)); } catch { return response(400, "invalid_notification"); }
  const key = await accountKey(event.emailAddress, env.HMAC_SECRET);
  await env.ACCOUNT_CHANNEL.getByName(key).publish(event.historyId, Date.now());
  return new Response(null, { status: 204 });
}

function configured(env) {
  return typeof env.HMAC_SECRET === "string" && env.HMAC_SECRET.length >= 32
    && typeof env.GOOGLE_CLIENT_ID === "string" && env.GOOGLE_CLIENT_ID.endsWith(".apps.googleusercontent.com")
    && typeof env.PUBSUB_AUDIENCE === "string" && env.PUBSUB_AUDIENCE.startsWith("https://")
    && typeof env.PUBSUB_SERVICE_ACCOUNT === "string" && env.PUBSUB_SERVICE_ACCOUNT.endsWith(".iam.gserviceaccount.com");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return Response.json({ status: "ok" }, { headers: jsonHeaders });
    if (request.method === "GET" && url.pathname === "/ready") {
      return Response.json({ ready: configured(env) }, { status: configured(env) ? 200 : 503, headers: jsonHeaders });
    }
    if (url.pathname.startsWith("/v1/") && !configured(env)) return response(503, "not_configured");
    if (request.method === "POST" && url.pathname === "/v1/register") {
      const { success } = await env.REGISTRATION_LIMIT.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" });
      if (!success) return response(429, "retry_later");
      return register(request, env);
    }
    if (request.method === "POST" && url.pathname === "/v1/unregister") return unregister(request, env);
    if (request.method === "GET" && url.pathname === "/v1/connect") return connect(request, env, url);
    if (request.method === "POST" && url.pathname === "/v1/google-push") return googlePush(request, env);
    return response(404, "not_found");
  },
};
