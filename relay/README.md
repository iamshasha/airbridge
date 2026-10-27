# AirBridge relay (internet links)

A tiny Cloudflare Worker that lets two AirBridge apps reach each other over the internet using a link.
It only pipes already-encrypted bytes between two WebSockets, so it never sees file contents or keys.

## Deploy (free)

You need a free Cloudflare account. Durable Objects are available on the Workers Free plan.

```bash
cd relay
npm install
npx wrangler login
npx wrangler deploy
```

Wrangler prints a URL such as `https://airbridge-relay.<your-subdomain>.workers.dev`.
Paste it into **AirBridge → Settings → Internet → Relay URL** on each device.

Local testing: `npx wrangler dev` serves the relay on `http://localhost:8787`, which also works as a relay URL.

## How a link works

1. The sender picks files → **Share via link**. The app creates a random 128-bit room and waits on
   `wss://<relay>/room/<room>?role=host`.
2. The link is `https://<relay>/r/<room>#<sender fingerprint>`. The fragment never reaches the server.
3. The recipient opens it (or pastes it into the app). The app joins as `role=join`, the relay sends `ready`
   to both sides, and the normal AirBridge handshake runs. The recipient checks that the sender's
   fingerprint matches the one in the link, so a relay cannot impersonate the sender.

## Limits

Free plan: 100,000 Worker requests per day. WebSocket messages count at 20:1, and the app sends 256 KiB
messages, so a 1 GB file is about 200 billed requests. Throughput depends on both internet connections.

## Alternative for your own devices: Tailscale

For always-on access between your own trusted devices, install [Tailscale](https://tailscale.com)
(free personal plan) on each one. Then use **Add device by address** with the device's Tailscale IP and port
47820. Traffic goes peer-to-peer over WireGuard when possible, at full speed, with no relay needed.
