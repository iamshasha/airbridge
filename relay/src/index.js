// AirBridge internet relay.
//
// Pairs exactly two WebSockets per room ("host" and "join") and pipes binary messages between them.
// Payloads are AirBridge frames that are already end-to-end encrypted and authenticated (PROTOCOL.md),
// so the relay never sees file contents or keys. Rooms are unguessable 128-bit ids, valid for one pairing.

const ROOM_RE = /^[A-Za-z0-9_-]{16,64}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);

    if (parts[0] === "room" && ROOM_RE.test(parts[1] ?? "")) {
      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response("Expected WebSocket", { status: 426 });
      }
      const role = url.searchParams.get("role");
      if (role !== "host" && role !== "join") return new Response("Bad role", { status: 400 });
      return env.ROOMS.get(env.ROOMS.idFromName(parts[1])).fetch(request);
    }

    if (parts[0] === "r" && ROOM_RE.test(parts[1] ?? "")) {
      return new Response(landingPage(parts[1], url.host), {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    return new Response("AirBridge relay is running.\n", { headers: { "content-type": "text/plain" } });
  },
};

export class Room {
  constructor(ctx) {
    this.ctx = ctx;
  }

  async fetch(request) {
    const role = new URL(request.url).searchParams.get("role");
    if (this.ctx.getWebSockets(role).length > 0) {
      return new Response("Room already has a " + role, { status: 409 });
    }
    const [client, server] = Object.values(new WebSocketPair());
    // Hibernation API: the object can sleep between messages without dropping sockets.
    this.ctx.acceptWebSocket(server, [role]);
    const other = this.ctx.getWebSockets(role === "host" ? "join" : "host")[0];
    if (other) {
      other.send("ready");
      server.send("ready");
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  peerOf(ws) {
    const role = this.ctx.getTags(ws)[0];
    return this.ctx.getWebSockets(role === "host" ? "join" : "host")[0];
  }

  async webSocketMessage(ws, message) {
    const peer = this.peerOf(ws);
    if (peer && typeof message !== "string") peer.send(message);
  }

  async webSocketClose(ws, code) {
    const peer = this.peerOf(ws);
    if (peer) peer.close(1000, "peer left");
    try { ws.close(1000, "bye"); } catch {}
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws, 1011);
  }
}

function landingPage(room, host) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AirBridge transfer</title>
<style>
  :root { color-scheme: light dark; --bg:#f5f5f7; --card:#fff; --fg:#1d1d1f; --muted:#6e6e73; --accent:#0071e3; }
  @media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --fg:#f5f5f7; --muted:#a1a1a6; --accent:#2997ff; } }
  body { margin:0; min-height:100vh; display:grid; place-items:center; background:var(--bg); color:var(--fg);
         font:16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; padding:16px; box-sizing:border-box; }
  .card { background:var(--card); border-radius:20px; padding:32px; max-width:420px; width:100%; text-align:center;
          box-shadow:0 10px 40px rgba(0,0,0,.08); }
  h1 { font-size:22px; margin:0 0 8px; }
  p { color:var(--muted); margin:0 0 24px; }
  a.btn { display:inline-block; background:var(--accent); color:#fff; text-decoration:none; padding:12px 24px;
          border-radius:12px; font-weight:600; }
  code { font-size:12px; color:var(--muted); word-break:break-all; }
</style>
</head>
<body>
<div class="card">
  <h1>Someone is sending you files</h1>
  <p>Open this link in AirBridge to receive them. The transfer is end-to-end encrypted.</p>
  <a class="btn" id="open" href="#">Open in AirBridge</a>
  <p style="margin-top:24px">Or paste this link into AirBridge → Receive from link:<br><code id="link"></code></p>
</div>
<script>
  const fp = location.hash.slice(1);
  const deep = "airbridge://join/${room}?relay=" + encodeURIComponent("${host}") + (fp ? "#" + fp : "");
  document.getElementById("open").href = deep;
  document.getElementById("link").textContent = location.href;
</script>
</body>
</html>`;
}
