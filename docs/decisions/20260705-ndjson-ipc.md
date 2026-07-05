# IPC responses switch to NDJSON with a version discriminator

**Date:** 2026-07-05 · **Cycle:** tasks/2026-07-04-menubar-app/ · **Altitude:** plan (build altitude preflight)
**Made with stakeholder** (one-way door: protocol / public contract amendment).

## Considered

1. **Keep line protocol** (shipped behavior): `LISTENING ring_bytes=N`, `SESSIONS count=2 s1=id:1,bytes:…,app:Zoom s2=…`.
   Responses are ad-hoc `key:value,key:value` tokens split on `,`; consumers do string-prefix matching
   to recover error semantics (e.g. `CommandRouter.explainDumpFailure` matches
   `message.hasPrefix(ListenerError.emptyBuffer.message)`).
2. **Full JSON envelope both directions:** `{"type":"status"}` request + `{"v":1,"type":"status",…}` response.
   Symmetric, but every CLI subcommand would have to JSON-serialize just to send `PING`.
3. **Bare-verb requests + NDJSON responses with `v:1` + `type` discriminator:** `STATUS\n` →
   `{"v":1,"type":"status","phase":"watching","ring":{"filled_bytes":0,"seconds":0}}`.

## Chosen

**Option 3.** Requests stay bare verbs (`PING`, `STATUS`, `SESSIONS`, `STOP`, `DUMP …`). Responses
become newline-delimited JSON objects, each carrying `v:1` (protocol version) and a `type`
discriminator (`pong`, `status`, `sessions`, `ok`, `ok_path`, `error`). Verbs themselves are
unchanged; only the response serialization moves to JSON.

Error responses change from `.err(String)` to `.error(code: String, message: String)` so consumers
match on `code` instead of message-prefix match. `ListenerError` gains a `code: String` property.

## Why

- **Brittleness lives in response parsing, not request issuing.** The shipped line protocol parses
  session tokens by splitting on `,` and `:`; app names or messages containing those characters
  silently corrupt the parse. JSON eliminates the entire class.
- **Stable, addressable protocol.** `v:1` makes a future `v:2` a deliberate intent change, not a
  silent drift — exactly the "more stable protocol" property asked for.
- **Bare-verb requests stay debuggable.** `PING\n` from a raw socket or shell one-liner is still
  possible; the user-facing verbs don't carry load that JSON would simplify.
- **Symmetric envelopes (option 2) add ceremony without removing brittleness.** The win is in
  response parsing; making requests JSON too buys nothing.
- **Structured `code` is the win the popover UI will want anyway.** When the menu bar app renders
  an inline error, it wants `code: "empty_buffer"` to map to a row-state transition, not a
  substring search on a human message.

## Limitations

- **Visible API rename inside Core/Platform/CLI.** `IPCResponse.err(String)` →
  `.error(code:, message:)`; `IPCResponse.line` → `IPCResponse.jsonLine`. No external callers
  (in-repo only), but every error emission site touches.
- **Existing IPC and socket tests assert on line shapes; rewritten** against JSON. The
  UnixSocketIPCTests' "GARBAGE RESPONSE" path stays valid (still an unparseable line); the
  IPCTests session/status round-trips get new expected wires.
- **`ListenerError` gains a `code: String` property** — every error case names a stable string
  code (`not_listening`, `empty_buffer`, `session_not_found`). Consumers switch from message
  string matching to code matching.
- **The "wire compat" claim in `implementation-plan.md` §MUST NOT CHANGE breaks deliberately**
  for `status` / `dump`. That section is patched in the same artifact set as this decision.
- **Root `CLAUDE.md` IPC convention line** ("IPC: Line protocol — PING, STATUS, STOP, DUMP") is
  true about *current* code and must not be patched until the implementation commit lands —
  otherwise the living doc would describe code that doesn't exist yet. The commit that ships JSON
  IPC also patches CLAUDE.md and writes `docs/specs/interfaces/ipc.md` (Phase 0 of the plan).
- **One-way door:** any external tooling that parses the line protocol breaks. Acceptable: the
  product is local-build, personal-use (decision `20260704-menubar-app-process-model`); no
  external consumers known.

## Reversal

`v:1` makes a future `v:2` addressable as a deliberate intent change. If JSON responses prove
heavier than needed for some hypothetical minimal consumer, the bare-verb request side is
already the minimal surface; the response side per-type serialization is independently revisable
without another protocol amendment (the discriminator + version let a future reader branch on type
and version).

## Living docs to update with the implementation commit (not before)

- Root `CLAUDE.md` — "IPC: Line protocol" line → "IPC: NDJSON responses, bare-verb requests"
- `Sources/ManbokCore/CLAUDE.md` — IPC layout row mentions parser/serializer; reflect JSON
- `docs/specs/interfaces/ipc.md` (Phase 0 of the implementation plan) — becomes the formal spec