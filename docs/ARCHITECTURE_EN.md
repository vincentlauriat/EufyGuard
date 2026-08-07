# EufyGuard — Architecture

EufyGuard is a two-process system running entirely on the user's Mac:

1. **EufyGuard.app** — a native SwiftUI application (macOS 14+). All UI/UX:
   dashboard, live view, event timeline, AI chat, settings, notifications.
2. **The bridge** (`bridge/`) — a local Node/TypeScript engine built on
   [`eufy-security-client`](https://github.com/bropat/eufy-security-client).
   It owns the connection to the Eufy cloud and stations (P2P), detects
   events, captures snapshots, runs the Claude analysis, and exposes an HTTP +
   WebSocket API on `127.0.0.1:8791`.

Rationale: the Eufy P2P protocol only has a mature open-source implementation
in Node.js. Rather than reimplementing it in Swift, the native app embeds a
local Node engine and keeps everything user-facing native.

![EufyGuard app — dashboard (illustrative mockup)](assets/screenshots/dashboard.svg)

```
┌───────────────────────────────┐          ┌───────────────────────────────┐
│ EufyGuard.app (SwiftUI)       │          │ Bridge (Node/TypeScript)      │
│                               │          │                               │
│ BridgeProcess ──── spawns ────┼─────────►│ index.ts (entry)              │
│ BridgeClient  ◄── HTTP/JSON ──┼──────────┤ server.ts (Express + ws)      │
│               ◄── WS /ws ─────┤          │ eufy.ts   (EufySecurity)      │
│ LiveStream    ◄── WS /stream ─┤          │ agent.ts  (Claude)            │
│ VideoToolbox decode           │          │ store.ts  (events.json)       │
└───────────────────────────────┘          └───────────────┬───────────────┘
                                                           │ HTTPS (account)
                                                           │ P2P (streams)
                                                    Eufy stations & cameras
```

The bridge binds to `127.0.0.1` exclusively and is never reachable from the
network. The app's Info.plist enables `NSAllowsLocalNetworking` for this
loopback traffic.

## Bridge supervision

`BridgeProcess.swift` launches and supervises the engine:

- On app start, it probes `GET /api/status` (2 s timeout). If a bridge is
  already running, it reuses it; otherwise it spawns
  `node <bridge>/dist/index.js`.
- The Node binary is looked up at `/opt/homebrew/bin/node`,
  `/usr/local/bin/node`, then `/usr/bin/node`.
- The bridge directory defaults to the development checkout and can be
  overridden with the `bridgePath` user default
  (`defaults write fr.lauriat.EufyGuard bridgePath …`).
- If the process exits, it is relaunched after 5 seconds.
- The bridge is deliberately **not** killed when the app quits: surveillance,
  event capture and AI analysis keep running in the background. As a fallback
  when the app is closed, the bridge itself posts a macOS notification via
  `osascript` for `alerte`-level events.

## Connection state machine

`eufy.ts` exposes a small state machine, mirrored in the app's status bar and
Settings sheet:

`unconfigured → connecting → (captcha | tfa)* → connected | error`

Captcha requests carry a base64 image displayed in Settings; 2FA requests
prompt for the emailed/SMS code. Both are submitted back through the API and
resume the login (`connect()` with `captcha`/`verifyCode` options).

## Event flow (detection → notification)

1. `eufy-security-client` receives a push notification from Eufy and emits a
   device event. The bridge listens to 11 detection events (motion, person,
   stranger, pet, vehicle, dog, sound, crying, ring, package delivered,
   package taken) and normalizes them into a `kind` string (rising edge only).
2. `index.ts` creates an `EventRecord`, persists it in the store
   (`bridge/data/events.json`, capped at 1000 events, debounced writes) and
   broadcasts `{type:"event"}` on `/ws` — the timeline updates instantly.
3. After a 3-second delay (the camera picture property is refreshed by Eufy
   push notifications, so the snapshot needs a moment to match the event), the
   bridge reads `DevicePicture` and saves the JPEG to
   `bridge/data/snapshots/<eventId>.jpg`.
4. If the AI agent is configured, the snapshot is sent to Claude
   (`claude-opus-5`, vision) with a **structured output JSON schema**
   (low effort): `resume`, `personnes`, `vehicules`, `animaux`, `colis`,
   `niveau_alerte` (`info` | `attention` | `alerte`).
5. The updated record is broadcast as `{type:"event_updated"}`. The app posts
   a native notification: `🚨 ALERTE` for `alerte`, `⚠️` for `attention`,
   or a plain event notification when no analysis is available. `info` events
   stay silent.

## Livestream flow (P2P → WebSocket → VideoToolbox)

Live video never touches ffmpeg or any transcoder; the raw elementary stream
is relayed as-is and decoded in hardware on the Mac.

1. The app opens `ws://127.0.0.1:8791/stream/<serial>`. The first viewer on a
   serial triggers `startStationLivestream()`; the last viewer disconnecting
   stops it.
2. `eufy-security-client` establishes the P2P session and emits a video
   stream. The bridge captures its metadata (codec H.264 or H.265, dimensions,
   fps) and sends it to viewers as a JSON text frame
   (`{type:"metadata", codec, width, height, fps}`), then relays every video
   chunk as a **binary** WebSocket frame (raw Annex-B elementary stream).
   Slow viewers (> 4 MB buffered) skip chunks instead of building latency.
   Audio is drained and not relayed yet (Phase 3).
3. Eufy stations cut streams after a fixed duration; the bridge auto-restarts
   the stream (800 ms later) while viewers remain connected. A stream dying
   within 3 seconds of starting is treated as a camera-unreachable error.
4. In the app, `NALUStreamDecoder` parses the Annex-B stream: it extracts
   SPS/PPS (and VPS for H.265) to build a `CMVideoFormatDescription`, converts
   each frame NAL to AVCC/HVCC framing (4-byte length prefix) and produces
   `CMSampleBuffer`s tagged `DisplayImmediately`.
5. `AVSampleBufferDisplayLayer` (VideoToolbox) decodes and displays the
   samples in hardware. On motorized cameras a PTZ pad is overlaid (buttons,
   arrow keys, `R` for a 360° sweep) and calls the bridge's PTZ endpoint.

## AI agent

- Model: **`claude-opus-5`** (Anthropic SDK), configured with the user's API
  key. When no key is set, `agentEnabled` is false and everything else keeps
  working.
- **Vision analysis**: one image + context (camera name, event kind), JSON
  schema output at `effort: "low"` — cheap, fast, deterministic shape.
- **Chat**: the system prompt embeds a compact text journal of the last 60
  events (with their analyses) and the current date/time; the last 12 chat
  turns are replayed. Answers in French.
- **Digest**: `POST /api/digest` reuses the chat path with a fixed report
  prompt over the last 300 events, for a period of up to 168 hours
  (default 24).

## Guard modes and PTZ

- Guard mode is read/written per station through the
  `StationGuardMode` property. The app exposes four modes: Home (1),
  Away (0), Schedule (2), Disarmed (63).
- PTZ maps `left/right/up/down/rotate360` to `PanTiltDirection` commands,
  guarded by a `DevicePanAndTilt` capability check.

## Swift components (app/Sources)

| File | Role |
|---|---|
| `EufyGuardApp.swift` | Entry point; starts `BridgeProcess` and `BridgeClient`. |
| `ContentView.swift` | Sidebar (sections + camera list with battery), status bar, dashboard grid (`CameraCard`, `SnapshotImage`), events timeline, guard-mode menu. |
| `ChatView.swift` | AI chat panel (messages, digest button). |
| `SettingsView.swift` | Eufy credentials, Anthropic key, captcha image + code, 2FA code, error display. |
| `BridgeClient.swift` | HTTP client + `/ws` WebSocket; publishes status, devices, stations, events, chat; 15 s polling refresh; triggers notifications. |
| `BridgeProcess.swift` | Spawns and supervises the Node bridge (see above). |
| `NotificationManager.swift` | UserNotifications authorization + posting. |
| `Models.swift` | Codable mirrors of the bridge payloads (`BridgeStatus`, `DeviceInfo`, `StationInfo`, `EventRecord`, `Analysis`). |
| `Live/LiveStreamController.swift` | `/stream/<sn>` WebSocket client; connection state; feeds the decoder. |
| `Live/VideoDecoder.swift` | `NALUStreamDecoder` — Annex-B parsing, format description, `CMSampleBuffer` construction. |
| `Live/LivePlayerView.swift` | `AVSampleBufferDisplayLayer` host view, full live sheet, PTZ pad. |

## TypeScript modules (bridge/src)

| Module | Role |
|---|---|
| `index.ts` | Entry point; wires store, agent, bridge, server; detection pipeline (snapshot → analysis → broadcast); `osascript` fallback notification. |
| `server.ts` | Express HTTP API + two WebSocket servers (`/ws` events, `/stream/<sn>` video); viewer refcounting and stream auto-restart. |
| `eufy.ts` | `EufySecurity` wrapper: login (captcha/2FA), state machine, device/station listing, guard mode, PTZ, snapshots, livestream events. |
| `agent.ts` | Anthropic client: structured vision analysis and grounded chat (`claude-opus-5`). |
| `store.ts` | Event persistence (`events.json`, max 1000, debounced saves) and the text `contextSummary` fed to the chat agent. |
| `config.ts` | `config.json` load/save (mode `0600`), data directories (`data/`, `data/snapshots/`, `data/eufy/`). |

## Data on disk (`bridge/data/`, git-ignored)

| Path | Content |
|---|---|
| `config.json` | Eufy credentials, country, Anthropic API key. |
| `events.json` | Last 1000 event records with analyses. |
| `snapshots/*.jpg` | One JPEG per event. |
| `eufy/` | `eufy-security-client` persistent state (tokens, device cache). |
