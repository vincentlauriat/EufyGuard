# EufyGuard Bridge — API Reference

The bridge listens on `http://127.0.0.1:8791` (loopback only). The port can be
overridden with the `EUFY_BRIDGE_PORT` environment variable.

All HTTP endpoints accept/return JSON (`Content-Type: application/json`,
request bodies up to 2 MB), except the snapshot endpoints which return raw
JPEG. Errors are returned as `{"error": "<message>"}` with status `400`,
`404` or `500`.

Source of truth: `bridge/src/server.ts`.

## HTTP endpoints

### `GET /api/status`

Bridge and connection status.

```json
{
  "state": "connected",
  "configured": true,
  "agentEnabled": true,
  "lastError": null,
  "captcha": null
}
```

- `state`: `unconfigured` | `connecting` | `captcha` | `tfa` | `connected` | `error`
- `configured`: Eufy username and password are present in the config.
- `agentEnabled`: an Anthropic API key is configured.
- `lastError`: last connection error message, or `null`.
- `captcha`: `{ "id": string, "image": string }` (base64 image, possibly a
  data URL) when `state` is `captcha`, otherwise `null`.

### `POST /api/config`

Save the configuration and (re)start the Eufy connection. Written to
`bridge/data/config.json` (mode `0600`).

Request:

```json
{
  "username": "user@example.com",
  "password": "…",
  "country": "FR",
  "anthropicApiKey": "sk-ant-…"
}
```

`country` defaults to `FR`; `anthropicApiKey` is optional (AI disabled when
absent). Response: `{"ok": true}`. A `status` message is then pushed on `/ws`.

### `POST /api/captcha`

Submit the captcha code requested during login.

Request: `{"captchaId": "…", "code": "…"}` — `captchaId` comes from
`status.captcha.id`. Response: `{"ok": true}`.

### `POST /api/tfa`

Submit the two-factor verification code (email/SMS).

Request: `{"code": "…"}`. Response: `{"ok": true}`.

### `GET /api/devices`

List cameras (non-camera devices are filtered out). Empty array when not
connected.

```json
[
  {
    "serial": "T8410P…",
    "name": "Entrée",
    "model": "T8410",
    "stationSerial": "T8010…",
    "hasBattery": true,
    "battery": 87,
    "enabled": true,
    "canPanTilt": true
  }
]
```

`battery` is omitted when the device does not report it.

### `GET /api/devices/:sn/snapshot`

Latest camera snapshot (from the Eufy `DevicePicture` property, refreshed by
push notifications).

- `200` — binary image body, `Content-Type` as reported by Eufy
  (usually `image/jpeg`).
- `404` — `{"error": "Pas d'image disponible pour cette caméra"}`.

### `POST /api/devices/:sn/ptz`

Move a motorized (pan/tilt) camera.

Request: `{"direction": "left"}` — one of `left`, `right`, `up`, `down`,
`rotate360`.

- `200` — `{"ok": true}`.
- `400` — missing direction.
- `500` — unknown direction, non-motorized camera, or not connected.

### `GET /api/stations`

List stations with their current guard mode.

```json
[
  { "serial": "T8010…", "name": "Orsay", "model": "T8010", "guardMode": 1 }
]
```

`guardMode` is `-1` when unknown. Values used by the app: `1` Home, `0` Away,
`2` Schedule, `63` Disarmed.

### `POST /api/stations/:sn/guard`

Set a station's guard mode.

Request: `{"mode": 1}` (number or numeric string). Response: `{"ok": true}`;
`400` if the mode is not a finite number.

### `GET /api/events`

Recent events, newest first.

Query: `limit` (default `100`, capped at `500`).

```json
[
  {
    "id": "1754400000000-a1b2c3",
    "ts": 1754400000000,
    "deviceSn": "T8410P…",
    "deviceName": "Entrée",
    "kind": "personne",
    "snapshotFile": "1754400000000-a1b2c3.jpg",
    "analysis": {
      "resume": "Une personne s'approche de la porte d'entrée.",
      "personnes": 1,
      "vehicules": 0,
      "animaux": false,
      "colis": false,
      "niveau_alerte": "attention"
    },
    "analysisError": null
  }
]
```

- `ts` is a Unix timestamp in **milliseconds**.
- `kind` is a French label: `mouvement`, `personne`, `inconnu`, `animal`,
  `véhicule`, `chien`, `son`, `pleurs`, `sonnette`, `colis livré`,
  `colis pris`.
- `snapshotFile`, `analysis` and `analysisError` are optional; `analysis`
  appears only when the AI agent is enabled and succeeded,
  `analysisError` when it failed.
- `niveau_alerte`: `info` | `attention` | `alerte`.

### `GET /api/events/:id/snapshot`

JPEG snapshot captured for an event.

- `200` — `image/jpeg` body.
- `404` — event has no snapshot, or the file is missing on disk.

### `POST /api/chat`

Ask the AI agent a question, grounded on the recent event log. The
conversation history is kept server-side (last 12 turns are replayed).

Request: `{"message": "Qui est passé devant le garage aujourd'hui ?"}`.

- `200` — `{"answer": "…"}`.
- `400` — empty message.
- `500` — AI agent not configured (missing API key) or upstream error.

### `POST /api/chat/reset`

Clear the server-side chat history. Response: `{"ok": true}`.

### `POST /api/digest`

Generate a structured surveillance report over a period.

Request: `{"hours": 24}` (optional; number or numeric string; default `24`,
capped at `168`). Response: `{"answer": "…"}`. Uses the AI agent — same `500`
as `/api/chat` when it is not configured. Does not touch the chat history.

## WebSocket: `ws://127.0.0.1:8791/ws` (events & status push)

JSON text frames only, pushed by the bridge:

| Message | Payload | When |
|---|---|---|
| `{"type": "status", "status": {…}}` | Same shape as `GET /api/status` | Connection state change, config saved |
| `{"type": "event", "event": {…}}` | An `EventRecord` (see `/api/events`) | Detection just occurred (no snapshot/analysis yet) |
| `{"type": "event_updated", "event": {…}}` | The same record, enriched | After snapshot capture and (optional) AI analysis |
| `{"type": "devices_changed"}` | — | Device added/removed, guard mode changed — re-fetch `/api/devices` and `/api/stations` |

The bridge does not process incoming messages on this socket.

## WebSocket: `ws://127.0.0.1:8791/stream/<serial>` (live video)

Connecting registers a viewer for the camera `<serial>`:

- The **first** viewer starts the station livestream (P2P); the **last**
  viewer's disconnection stops it.
- Text frames are JSON control messages:
  - `{"type": "metadata", "codec": "h264" | "h265", "width": 1920, "height": 1080, "fps": 15}`
    — sent when the stream starts (and immediately on connect if the stream
    is already up). `width`/`height`/`fps` may be absent.
  - `{"type": "error", "message": "…"}` — stream failed to start, or died
    within 3 s of starting (camera likely unreachable).
- Binary frames are chunks of the raw H.264/H.265 **Annex-B elementary
  stream**, relayed unmodified from the Eufy P2P session. No container, no
  audio.
- If the station cuts the stream (fixed max duration on Eufy hardware), the
  bridge restarts it automatically about 800 ms later as long as viewers are
  connected; a new `metadata` message follows.
- Viewers with more than 4 MB of unsent buffered data skip chunks (frames are
  dropped rather than delayed).

Any other WebSocket path is rejected (socket destroyed).
