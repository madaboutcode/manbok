# IPC — Unix socket control protocol

**Spec ID:** ipc
**Lifecycle:** living (interface spec). Source of truth for the socket boundary.
**Implementation surface:** `Sources/ManbokCore/IPC/`, `Sources/ManbokPlatform/IPC/`,
`Sources/ManbokPlatform/Runtime/`.
**Decision record:** `docs/decisions/20260705-ndjson-ipc.md` (wire-format amendment from line
protocol to NDJSON; design §15 amendment 6).
**Spec moment status:** Written at Phase 0 of the menubar-app cycle ahead of implementation;
update with the code, not before.

---

## 1. Transport

- **Address:** Unix domain stream socket at `~/.manbok/run.sock` (one daemon per machine;
  single-user assumption).
- **Connection model:** one request per connection. Client connects, sends one request line,
  reads one response line, closes. Server closes the connection after writing the response.
- **Encoding:** UTF-8. Lines terminated by `\n`.
- **Request shape:** bare verb + optional whitespace-separated arguments. Verb is
  case-insensitive (`PING` ≡ `ping`).
  Examples: `STATUS`, `DUMP 5`, `DUMP SESSION 7`.
- **Response shape:** one NDJSON object per line (Newline-Delimited JSON — one JSON object,
  terminated by `\n`). Every response object carries:
  - `"v": 1` — protocol version (currently 1).
  - `"type": "<discriminator>"` — one of `pong`, `status`, `sessions`, `ok`, `ok_path`,
    `error`.
- **Max request size:** 4096 bytes. Requests longer than this, or unparseable as a verb,
  are treated as malformed (`bad_command` — see §3).
- **No streaming:** audio is never sent over the socket. `DUMP` writes a file and returns a
  path (see §2.5).

## 2. Verbs

### 2.1 PING

**Request:** `PING`

**Response:**
```json
{"v":1,"type":"pong"}
```

**Purpose:** liveness check. CLI uses it to detect a running daemon without side effects.

### 2.2 STATUS

**Request:** `STATUS`

**Response:**
```json
{"v":1,"type":"status","phase":"watching|listening|stopped",
 "ring":{"filled_bytes":N,"seconds":D}}
```

- `phase` — daemon state, one of three strings:
  - `"watching"` — no app currently holding the mic.
  - `"listening"` — capture engine active; one or more apps hold the mic.
  - `"stopped"` — process is shutting down (sent in response to `STOP` before exit).
  Note: `phase` is a daemon-global state; it does NOT indicate the user-facing Recording
  state. During a session's drain grace, `phase` may be `"watching"` while the session is
  still open. Use `SESSIONS` `open:1` count for the Recording signal (see overview R6).
- `ring.filled_bytes` — non-negative integer; PCM bytes currently in the ring.
- `ring.seconds` — non-negative float; `filled_bytes / 32000` (canonical 16 kHz mono s16le =
  32000 bytes/sec). May be `0.0`.

### 2.3 SESSIONS

**Request:** `SESSIONS`

**Response:**
```json
{"v":1,"type":"sessions","sessions":[
  {"id":<UInt64>,"app":"Zoom","bytes":N,"dur_sec":D,
   "start_ago_sec":D,"end_ago_sec":D,"open":0},
  {"id":<UInt64>,"app":"OBS","bytes":N,"dur_sec":D,
   "start_ago_sec":D,"end_ago_sec":null,"open":1}
]}
```

- `id` — UInt64 stable session id. Monotonic across the daemon's lifetime; never reused.
- `app` — single app display name (string; always present; never null). One session = one app;
  when apps overlap, multiple sessions exist (see §4). Always non-empty.
- `bytes` — non-negative integer; PCM bytes captured for this session.
- `dur_sec` — non-negative float; `bytes / 32000`.
- `start_ago_sec` — non-negative float; seconds between session start and response time.
- `end_ago_sec` — non-negative float for closed sessions; `null` for open sessions.
- `open` — `1` if currently capturing, `0` if closed.

**Ordering:** newest-start-first. Expired sessions (overwritten by ring wrap) are silently
omitted — `SESSIONS` only returns sessions whose start offset is still inside the ring.

### 2.4 STOP

**Request:** `STOP`

**Response:**
```json
{"v":1,"type":"ok"}
```

**Side effect:** daemon stops capture (if any), closes the socket, removes its pid file, and
exits the process. The response is written before the process exits.

### 2.5 DUMP

**Request variants:**
- `DUMP` — newest session (per `DumpSessionSelector` "last" semantics).
- `DUMP <minutes>` — last N minutes of the ring (raw span; not session-scoped). N is a
  non-negative integer.
- `DUMP SESSION <stableId>` — bytes for one session by stable id. `<stableId>` is a UInt64.

**Response (success):**
```json
{"v":1,"type":"ok_path","path":"/absolute/path/to/manbok-zoom-20260705-143022.wav"}
```

**Response (failure):** see §3.

**Filename convention:**
- Session dumps (`DUMP SESSION`):
  `manbok-<slug>-YYYYMMDD-HHMMSS.wav`
  - `<slug>` = lowercased, alphanumeric+hyphen form of the session's single-app display name
    (e.g. `Zoom` → `zoom`, `Audio Hijack` → `audio-hijack`).
  - Timestamp = session start time, local timezone, `yyyyMMdd-HHmmss`.
  - Collision: append `-2`, `-3`, … (never silent overwrite).
- Raw span dumps (`DUMP`, `DUMP N`):
  `manbok-YYYYMMDD-HHMMSS.wav` (no app slug; preserved for CLI compat).

## 3. Error responses

Every error response:
```json
{"v":1,"type":"error","code":"<stable>","message":"<human>"}
```

- `code` — stable string; consumers MUST match on `code`, not on `message`. New codes are
  additive; existing codes are never renamed (a rename is a versioned protocol change).
- `message` — human-readable explanation; may include hints (e.g. dump failure context).
  Consumers MAY display it; MUST NOT parse it for control flow.

**Defined codes:**
- `bad_command` — request verb not recognized, or argument syntax invalid.
- `internal` — daemon-side error; opaque (consult daemon logs at subsystem `ai.manbok.app`).
- `not_listening` — operation requires capture to be active, and it isn't.
- `empty_buffer` — `DUMP` called with empty ring (no PCM captured yet). Message distinguishes
  sub-context (watching / stopped / listening-with-no-PCM) for human readability.
- `session_not_found` — `DUMP SESSION` id is unknown, expired, or otherwise unreadable.
  Message names the id.
- `dump_io` — WAV file write failed (disk full, permission, etc.); message names the cause.

**Forward compatibility:** consumers MUST ignore unknown error codes (display the `message`,
do not crash). Unknown codes imply a daemon newer than the client.

## 4. Session identity model

- One session per app holding the mic. Multiple concurrent open sessions exist when apps
  overlap (e.g. Zoom + OBS both on mic → two sessions, two stable ids).
- Stable id assigned at session open: monotonic `UInt64`, never reused.
- When two apps hold the mic simultaneously, each session is a view over the same ring window;
  their byte ranges **overlap**. Dumping each produces a separate WAV containing the shared
  audio window from that session's start onward. The overlap region is the same mic signal
  captured once, viewable through two sessions — not duplicated bytes.
- An app that releases the mic is closed after a drain grace period (currently 5s); if the
  same app reclaims the mic within the grace, the session continues.
- Per-app identity is the process-identity mapping ProcessAudioMonitor already does (bundle
  IDs → display name, helper-process collapsing). Helper-process churn is absorbed by the
  per-app drain grace.

## 5. Versioning

- Current protocol version is `1`; every response includes `"v": 1`.
- A future `v:2` is a deliberate intent change, not silent drift. Consumers SHOULD branch on
  `v`; consumers receiving an unknown higher version SHOULD surface a "daemon newer than
  client" hint, not crash.
- Within `v:1`, fields may be ADDED to existing response types (additive, non-breaking).
  Consumers MUST ignore unknown fields. Fields are never removed or renamed within a version.

## 6. Out of scope (this spec)

- **Transport security** — local Unix socket; assumes single-user machine.
- **Audio streaming** — `DUMP` writes a file and returns a path; audio is never sent over the
  socket.
- **CLI stdout formatting** — user-facing CLI output for `status`/`dump`/`sessions` is
  preserved separately (one word, one path, ruled table). This spec covers the socket wire,
  not the CLI presentation.
- **Popover UI rendering** — the menu bar app's popover is a separate interface spec, written
  after the SK1 popover harness confirms the implementation model (per design §10 fallback
  rules). Not part of this spec.
- **Mic permission flow** — handled at app launch (first-launch permission request), not over
  IPC. The daemon refuses to start without authorization; the CLI surfaces this via the
  `authorize` subcommand, not via socket responses.
- **Settings window** — buffer duration preset and start-at-login live in the app process and
  call the registry directly (per design §15 amendment 1, the `RESIZE` wire verb was cut).
  Not exposed over IPC.

## 7. Testability

Every behavior is testable at the socket boundary. Concrete cases the spec supports:

- **Verb round-trips for each verb:** send `<verb>`, parse JSON, assert `type` and fields.
- **`bad_command`:** send `NOT_A_VERB` → `{"type":"error","code":"bad_command",…}`.
  Send `DUMP x` → `bad_command`. Send `DUMP SESSION 0` → `bad_command` (id must be ≥ 1).
- **`not_listening` from DUMP:** daemon stopped, ring non-empty, send `DUMP` →
  `not_listening` (or `empty_buffer` if ring empty — see below).
- **`empty_buffer` from DUMP:** ring empty, send `DUMP` → `empty_buffer`; message includes
  sub-context (watching / stopped / listening-with-no-PCM).
- **`session_not_found`:** send `DUMP SESSION 999` (no such id) → `session_not_found`;
  message names the id.
- **Stable id monotonicity:** open several sessions (mock or real), list via `SESSIONS`,
  verify `id` values strictly increase in open order.
- **Concurrent sessions:** simulate two apps holding the mic, list via `SESSIONS`, verify
  two open sessions with overlapping byte ranges (start_ago_sec both near now, both open:1,
  different app names).
- **Version field:** every response, regardless of type, includes `"v": 1`.
- **Filename collision:** write two dumps with identical timestamp (force clock collision in
  test), verify `-2` suffix on the second; verify `-3` on the third.
- **Forward compat:** send a response with an unknown `type` → consumer must not crash.
  Send a known `type` with an extra field → consumer must accept (extra field ignored).
- **NDJSON framing:** each response is exactly one JSON object followed by `\n`. Multiple
  objects on one line, or one object split across lines, MUST be rejected by the parser.