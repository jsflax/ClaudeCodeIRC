// ClaudeCodeIRC public room directory.
//
// Zero-knowledge phonebook. Hosts advertise room metadata into a
// per-`groupId` bucket (where `groupId = base64url(sha256(secret))`
// for group-scoped rooms, or the well-known string `"public"` for
// rooms anyone can browse). Peers `GET /list?group=<id>` to enumerate
// rooms in a bucket.
//
// The Worker NEVER sees the raw group secret or the per-room join
// code (the WS Bearer token). It only sees `groupId` (a hash) and
// `wssURL` (where to connect). Compromise of this Worker leaks "room
// names + host handles + tunnel URLs grouped by opaque hash" — no
// secrets, no joinable credentials.
//
// Storage:
//   `room:${groupId}:${roomId}` → JSON `RoomEntry`. TTL 180s.
//   `hb:${roomId}`              → ms timestamp. TTL 60s. Rate-limit fence.
//
// TTL > heartbeat (180 vs 30) gives a 5x slack window against KV's
// ~60s global eventual-consistency propagation.

export interface Env {
  LOBBY: KVNamespace;
}

interface RoomEntry {
  version: number;
  roomId: string;
  name: string;
  hostHandle: string;
  wssURL: string;
  groupId: string;          // "public" if no group
  publishVersion: number;   // monotonic, host-side
  publishedAt: number;      // server-set, ms epoch
}

const TTL_SECONDS = 180;
const MIN_HEARTBEAT_INTERVAL_MS = 25_000;
const MAX_BODY_BYTES = 4096;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);

    if (req.method === "POST" && url.pathname === "/publish") {
      return handlePublish(req, env);
    }
    if (req.method === "DELETE" && url.pathname.startsWith("/publish/")) {
      return handleDelete(req, env, url.pathname.slice("/publish/".length));
    }
    if (req.method === "GET" && url.pathname === "/list") {
      return handleList(env, url.searchParams.get("group") ?? "public");
    }

    return json({ error: "not_found" }, 404);
  },
};

async function handlePublish(req: Request, env: Env): Promise<Response> {
  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) {
    return json({ error: "payload_too_large" }, 413);
  }

  let body: Partial<RoomEntry>;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const required = [
    "version", "roomId", "name", "hostHandle",
    "wssURL", "groupId", "publishVersion",
  ] as const;
  for (const k of required) {
    if (body[k] === undefined || body[k] === null) {
      return json({ error: "missing_field", field: k }, 400);
    }
  }
  if (body.version !== 1) {
    return json({ error: "unsupported_version", knownVersions: [1] }, 400);
  }
  if (!/^wss:\/\//.test(body.wssURL!)) {
    return json({ error: "invalid_wss" }, 400);
  }
  if (body.roomId!.length > 64 || body.groupId!.length > 128) {
    return json({ error: "field_too_long" }, 400);
  }

  // Rate limit per roomId — independent of NAT/IP. A single host
  // re-publishing within the heartbeat window is a bug; many hosts
  // sharing a NAT (corporate, university) all advertising distinct
  // roomIds is fine.
  const hbKey = `hb:${body.roomId}`;
  const lastHb = await env.LOBBY.get(hbKey);
  if (lastHb && Date.now() - Number(lastHb) < MIN_HEARTBEAT_INTERVAL_MS) {
    return json({
      error: "rate_limited",
      retryAfterMs: MIN_HEARTBEAT_INTERVAL_MS,
    }, 429);
  }

  // Last-writer-wins on `publishVersion`. During host handoff (or a
  // misbehaving client), two writers compete for the same `roomId`;
  // the higher version wins. The Worker doesn't trust monotonicity
  // beyond comparing values, so a forged high version is possible —
  // we accept that, since this layer is only the directory, not the
  // entry credential.
  const roomKey = `room:${body.groupId}:${body.roomId}`;
  const existing = await env.LOBBY.get(roomKey, "json") as RoomEntry | null;
  if (existing && existing.publishVersion > body.publishVersion!) {
    return json({
      error: "stale_publish_version",
      current: existing.publishVersion,
    }, 409);
  }

  const entry: RoomEntry = {
    version: 1,
    roomId: body.roomId!,
    name: body.name!,
    hostHandle: body.hostHandle!,
    wssURL: body.wssURL!,
    groupId: body.groupId!,
    publishVersion: body.publishVersion!,
    publishedAt: Date.now(),
  };

  await env.LOBBY.put(roomKey, JSON.stringify(entry), {
    expirationTtl: TTL_SECONDS,
  });
  await env.LOBBY.put(hbKey, String(Date.now()), { expirationTtl: 60 });

  return json({
    ok: true,
    ttlRemaining: TTL_SECONDS,
    knownVersions: [1],
  });
}

async function handleDelete(req: Request, env: Env, roomId: string): Promise<Response> {
  let body: { groupId?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (!body.groupId) {
    return json({ error: "missing_groupId" }, 400);
  }

  await env.LOBBY.delete(`room:${body.groupId}:${roomId}`);
  await env.LOBBY.delete(`hb:${roomId}`);
  return json({ ok: true });
}

async function handleList(env: Env, groupId: string): Promise<Response> {
  if (groupId.length > 128) {
    return json({ error: "invalid_group" }, 400);
  }
  const list = await env.LOBBY.list({
    prefix: `room:${groupId}:`,
    limit: 100,
  });
  const rooms: any[] = [];
  for (const k of list.keys) {
    const entry = await env.LOBBY.get(k.name, "json") as RoomEntry | null;
    if (!entry) continue;
    rooms.push({
      roomId: entry.roomId,
      name: entry.name,
      hostHandle: entry.hostHandle,
      wssURL: entry.wssURL,
      lastSeenAge: Math.floor((Date.now() - entry.publishedAt) / 1000),
    });
  }
  return json({ version: 1, rooms });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
