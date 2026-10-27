# AirBridge

Fast, encrypted file sharing between your devices: on the local network, peer-to-peer without a network,
found over Bluetooth, and across the internet with a link. macOS is first; Windows and iPhone follow
using the same wire protocol ([PROTOCOL.md](PROTOCOL.md)).

## What it does

- **Discovery**: Bonjour on Wi-Fi/Ethernet, Apple peer-to-peer Wi-Fi (AWDL) when there's no shared
  network, and **Bluetooth LE** contact cards for networks that block multicast.
- **Speed**: raw TCP with up to 8 parallel streams per transfer, 1 MiB chunks, work-stealing across
  streams, zero-copy reads into the send buffer, AES-256-GCM (hardware-accelerated). Loopback
  benchmark: **~1.9 GB/s (15 Gbit/s) end-to-end encrypted**, so Wi-Fi is always the limit.
- **Trust**: pairing with a 6-digit code derived from the handshake, so a man-in-the-middle gets caught.
  Trusted devices can:
  - auto-accept incoming files (auto download)
  - browse and pull from your shared folder
  - receive **auto-upload folders**: new or changed files are pushed automatically
  - put received text straight on the clipboard
- **More than one-to-one**: send to several devices at once, send text or the clipboard, and pull from
  another device's shared folder.
- **Internet**: one-time **share links** through a free Cloudflare relay ([relay/](relay/README.md)),
  still end-to-end encrypted. You can also add any device by address, which suits Tailscale and other VPNs.
- **AirDrop**: sends to Apple devices without AirBridge through the system AirDrop service.
- **Adapter probe**: Wi-Fi bands, AWDL, Bluetooth LE state, Ethernet, VPN tunnels (This Mac page).

## Build and run (macOS 14+)

```bash
./scripts/bundle.sh
```

```bash
open build/AirBridge.app
```

On first launch, allow Bluetooth and Local Network access when macOS asks.

Headless CLI and benchmark:

```bash
swift run -c release airbridge-cli bench 2048
```

```bash
swift test
```

## iPhone and iPad (iOS 18+)

Open `iOS/AirBridge.xcodeproj` in Xcode, choose your team under Signing for both targets (the app and
ShareExtension share the `group.app.airbridge` app group), and run. Features:

- Devices tab: a split view on iPad and wide windows that collapses to push navigation on iPhone.
  Send Photos & Videos, Files, the clipboard, or text. Pair, browse shared folders, and set automation per device.
- **Share extension**: "AirBridge" in the system share sheet, from any app.
- Transfers with Quick Look preview and Share/Save. AirDrop through the system share sheet.
- Received files appear in Files › On My iPhone › AirBridge › Received.
- Haptics for arrivals, requests, pairing, success and failure; confirmation toasts; Dynamic Type up to
  the largest accessibility sizes; light and dark mode; Reduce Motion respected.

To install on a connected device from the command line:

```bash
FREE=1 scripts/install-ios-device.sh <TEAM_ID>
```

`FREE=1` is for a free Personal Team. Those can't use App Groups (the share extension then keeps its own
identity) and allow only 3 sideloaded apps per device.

## Layout

| Path | What |
|---|---|
| `Sources/AirBridgeCore/Crypto` | Identity keys, handshake, encrypted frames |
| `Sources/AirBridgeCore/Wire` | TCP/WebSocket byte stream, control messages |
| `Sources/AirBridgeCore/Net` | Bonjour/AWDL, Bluetooth LE, adapter capabilities |
| `Sources/AirBridgeCore/Engine` | `Node` (all flows), chunked parallel file I/O, sync |
| `Sources/AirBridge` | SwiftUI macOS app (window, menu bar, settings) |
| `iOS/` | iPhone/iPad app and share extension (Xcode project using `AirBridgeCore`) |
| `Sources/airbridge-cli` | CLI: bench, receive, send, text, share, open |
| `relay/` | Cloudflare Worker relay for internet links |

## Roadmap

- **Windows**: a .NET 8 / WinUI 3 app implementing PROTOCOL.md (`ECDsa`, `ECDiffieHellman`, `HKDF`,
  `AesGcm` match CryptoKit byte for byte). It discovers over mDNS and Windows BLE APIs.
- **AirDrop client on Windows**: this needs AWDL emulation (OpenDrop/OWL-style), which only works with
  Wi-Fi adapters that support monitor mode and frame injection, and only reaches devices set to
  "Everyone". The Windows adapter probe will report whether the installed adapter qualifies.
