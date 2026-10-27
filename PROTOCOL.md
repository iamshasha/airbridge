# AirBridge wire protocol v1

This document is the contract every AirBridge implementation (macOS, iOS, Windows) must follow.
Everything here uses only primitives available in CryptoKit and .NET 8 (`ECDsa`, `ECDiffieHellman`,
`HKDF`, `AesGcm`), so ports do not need third-party crypto.

## 1. Discovery

| Channel | What it covers | Details |
|---|---|---|
| Bonjour / mDNS `_airbridge._tcp` | Same LAN (Wi-Fi or Ethernet) | Service **name** = device id (UUID string). TXT: `id`, `n` (display name), `fp` (fingerprint), `pl` (platform: `mac`/`ios`/`win`), `v` (`1`). |
| Apple peer-to-peer Wi-Fi (AWDL) | Apple devices with no shared network | Same Bonjour service, published and browsed with `includePeerToPeer = true`. |
| Bluetooth LE | Any device in radio range, also when multicast is blocked | Service UUID `5A1B0001-6A3F-4E8E-9D2C-A1B2C3D4E5F6`, read characteristic `5A1B0002-6A3F-4E8E-9D2C-A1B2C3D4E5F6` returns JSON `{"id","n","fp","pl","p":port,"a":["ip",...]}`. The client then connects over TCP to one of the addresses. |
| Manual | Routed networks, VPNs (Tailscale, WireGuard), the internet | User enters `host:port`. Default port **47820**. |

## 2. Transport

TCP, `TCP_NODELAY`. Every connection begins with a handshake and then carries encrypted frames.
One **control** connection per operation, plus up to N parallel **stream** connections for bulk data
(the client — the side that opened the control connection — always opens the streams).

### 2.1 Plain frames (handshake only)

`u32 big-endian length || bytes`

### 2.2 Handshake

1. Both sides send a plain frame containing `Hello` JSON:
   ```json
   {"v":1,"id":"<uuid>","name":"Alice's Mac","platform":"mac","port":47820,
    "sigKey":"<base64 64-byte raw P-256 public key X||Y>",
    "ephKey":"<base64 64-byte raw P-256 public key X||Y>",
    "nonce":"<base64 32 random bytes>"}
   ```
   `sigKey` is the long-term identity key. `ephKey` is a fresh ECDH key for this connection only.
2. `transcript = SHA256("AirBridge/1" || u32be(len(helloClient)) || helloClient || u32be(len(helloServer)) || helloServer)`
   using the exact bytes that went over the wire.
3. Both sides send a plain frame: `{"sig":"<base64 64-byte r||s>"}` = ECDSA-P256-SHA256 over `transcript`
   (IEEE P1363 format). Each side verifies the peer's signature with the peer's `sigKey`.
4. `shared = ECDH(ephPriv, peerEph)` (raw X coordinate).
   `kC2S = HKDF-SHA256(ikm: shared, salt: transcript, info: "AirBridge/1 c2s", 32)`
   `kS2C = HKDF-SHA256(ikm: shared, salt: transcript, info: "AirBridge/1 s2c", 32)`
5. **Fingerprint** of a device = first 16 bytes of `SHA256(sigKey)` as lowercase hex.
6. **Pairing code (SAS)** = `u32be(SHA256("AirBridge/SAS" || transcript)[0..4]) mod 1_000_000`, 6 digits, zero-padded.
   Both users see the same code only if there is no man-in-the-middle.

### 2.3 Encrypted frames

`u32be(len) || ciphertext || tag(16)`; AES-256-GCM, nonce = `00 00 00 00 || u64be(counter)`,
counter starts at 0 and increments per frame, separately per direction. No AAD.

Plaintext = `u8 type || payload`:

| type | payload |
|---|---|
| `0x01` | Control message, UTF-8 JSON |
| `0x02` | Data chunk: `u32be fileIndex || u64be offset || bytes` |

## 3. Control messages

All control messages are a single flat JSON object with a `t` field (unused fields omitted):

| `t` | Direction | Fields | Meaning |
|---|---|---|---|
| `offer` | sender → receiver | `transferId`, `items[{i,path,size,dir}]`, `total`, `sync` | Proposes a transfer. `path` is relative, `/`-separated. |
| `accept` | receiver → sender | `transferId`, `streams` | Accepted; the client opens `streams` stream connections. |
| `decline` | receiver → sender | `transferId`, `reason` | |
| `stream` | client → server (on a stream connection) | `transferId` | Binds this connection to a transfer. The sender then writes chunks on it. |
| `complete` | receiver → sender | `transferId` | All bytes received and files finalized. |
| `text` | client → server | `text` | Text / link / clipboard. Reply `ok`. |
| `pair` | client → server | | Pairing request; both UIs show the SAS. Reply `pairAccepted` or `pairDeclined`. |
| `list` | client → server | `path` | Browse the server's shared folder. Reply `listing{entries[{name,size,dir}]}` (trusted peers only). |
| `pull` | client → server | `paths` | Download from the shared folder. The server answers with an `offer` on the same connection; the rest proceeds as a normal transfer with the server as sender. |
| `unpair` | client → server | | The client removed its trust in the server. The server drops its trust in the client too (if the fingerprint matches) and replies `ok`. Clients retry undelivered notices when the device is next reachable. |
| `notPaired` | server → client | `reason` | Reply to `list`, `pull` or a `sync` offer from a device the server does not trust. The client drops its stale pairing. |
| `ok` / `error` | either | `reason` | |

## 4. Trust

A device is trusted when its fingerprint was confirmed through pairing. Trusted peers can be set to
auto-accept transfers (auto download), browse/pull from the shared folder, and receive sync-folder
pushes (auto upload). A known id presenting a different fingerprint is treated as untrusted.
