// Order model of manbok's IPC server (T1081 M9): one serialized accept loop with 1 s receive / send timeouts.
// Time is in ticks of 1 s. Variant via env MODEL_VARIANT:
//   current           mirrors UnixSocketServer at fix/T1081-reliability (kinds: ping, idle, nonreading, early-pre, early-post, trickle, flood, stop; one total deadline per request line)
//   current-pre-fix   the server before commit a13a11c: the 1 s receive timeout restarts on every received byte (finding F2: PingBound breaks)
//   limit             adds a slow DUMP client (H24, the documented KNOWN LIMIT) and drops the "behind a slow handler" exemption
//   m-no-timeouts     mutant: no SO_RCVTIMEO / SO_SNDTIMEO (the pre-B3 server, H23)
//   m-no-send-timeout mutant: receive timeout kept, send timeout removed
//   m-no-nosigpipe    mutant: SO_NOSIGPIPE not set on accepted sockets (H25)
//   m-shared-response mutant: the reply is read from one slot shared by all connections (the last handler result) instead of a per-request value
const VARIANT = process.env.MODEL_VARIANT ?? "current";
const SRC = "Sources/ManbokPlatform/IPC/UnixSocketServer.swift";
const TMAX = Number(process.env.MODEL_TICKS ?? 7);  // model time horizon in ticks
const TB = Number(process.env.MODEL_TRICKLE ?? 4);  // abstract size of the 4096-byte request cap, in bytes (1 byte per tick)
const NCL = Number(process.env.MODEL_CLIENTS ?? 3);
const RCV = VARIANT === "m-no-timeouts" ? 99 : 1;   // SO_RCVTIMEO in ticks (99 = never)
const SND = (VARIANT === "m-no-timeouts" || VARIANT === "m-no-send-timeout") ? 99 : 1;
const NOSIGPIPE = VARIANT !== "m-no-nosigpipe";
const KINDS = ["ping", "idle", "nonreading", "early-pre", "early-post", "trickle", "flood", "stop", ...(VARIANT === "limit" ? ["slowdump"] : [])];
const HANDLER = { ping: 0, idle: 0, nonreading: 0, "early-pre": 0, "early-post": 0, trickle: 0, flood: 0, stop: 2, slowdump: 3 }; // handler ticks (stop: 2 s shutdown budget)

export const meta = {
  title: `manbok IPC server: serialized accept loop with timeouts [${VARIANT}]`,
  covers: [
    { file: SRC, fn: "run", mirrored: true },
    { file: SRC, fn: "serveConnection", mirrored: true },
    { file: SRC, fn: "readLine", mirrored: true },
    { file: SRC, fn: "writeLine", mirrored: true },
    { file: SRC, fn: "configureClientSocket", mirrored: true },
  ],
  notModeled: [
    "the listen backlog of 8: at most 3 clients exist in the model",
    "request content other than the verb class: a PING-class reply is small (fits the socket buffer), a 'nonreading' client asks for a reply larger than the socket buffer (e.g. SESSIONS with many sessions); with a small reply a non-reading client does not block the server at all",
    "client-side timeouts (the CLI client has none unless asked; SingleInstance PING uses 2 s)",
    "the DUMP/SESSIONS handler contents (and the reply value itself: a reply is one tag per connection); handler duration is a constant per kind (stop 2 ticks, slow dump 3 ticks)",
    "malformed requests (bad_command is answered like PING), requests that arrive in several chunks within the timeout other than the trickle kind",
    "a client that gives up and closes while the server is blocked on it (worst case: nobody ever closes)",
    "clients beyond 3, STOP's real effects (modelled as: answered, then the process exits)",
  ],
  assumptions: [
    "SO_SNDTIMEO applies per write() call. The request line is read with poll() against one 1 s deadline measured from the start of the read, so received bytes do not restart it (pre-fix: SO_RCVTIMEO per read(), where any byte that arrives restarts the timeout).",
    "readLine stops after 4096 bytes without a newline; the model scales that to TB bytes at one byte per tick.",
    "an early-close client that closed before accept makes setsockopt fail (EINVAL on macOS) and is dropped at once; one that closes after sending its request is detected when the reply is written.",
    "without SO_NOSIGPIPE a write to a closed peer raises SIGPIPE, whose default action ends the process (H25 saw this).",
  ],
  variant: VARIANT,
};
export const bounds = { clients: NCL, ticks: TMAX, trickleBytes: TB, variant: VARIANT };

const clone = (o) => JSON.parse(JSON.stringify(o));
export const init = { t: 0, cl: [], q: [], cur: null, ph: null, w: 0, tb: 0, slot: -1, dead: false, exited: false };

// An instantaneous server step is enabled: the clock may not advance until it was taken (maximal progress).
function instant(s) {
  if (s.dead || s.exited) return false;
  if (s.cur === null) return s.q.length > 0;
  const c = s.cl[s.cur];
  if (s.ph === "dropped") return true;
  if (s.ph === "read") {
    if (c.kind === "idle") return s.w >= RCV;
    if (c.kind === "trickle") return s.tb >= TB || s.w >= RCV;
    return true;
  }
  if (s.ph === "handle") return s.w >= HANDLER[c.kind];
  if (s.ph === "write") return c.kind === "nonreading" ? s.w >= SND : true;
  return false;
}

export const actions = {
  "a client connects": (s) => {
    if (s.cl.length >= NCL || s.dead || s.exited) return false;
    return KINDS.map((kind) => { const n = clone(s); n.cl.push({ kind, age: 0, ans: false, lat: -1, got: -1 }); n.q.push(n.cl.length - 1); return n; });
  },
  "the server accepts the next client": (s) => {
    if (s.dead || s.exited || s.cur !== null || s.q.length === 0) return false;
    const n = clone(s); n.cur = n.q.shift(); n.w = 0; n.tb = 0;
    n.ph = n.cl[n.cur].kind === "early-pre" ? "dropped" : "read";   // setsockopt fails on a peer that already left
    return n;
  },
  "the server drops a client that left before it was served": (s) => s.cur !== null && s.ph === "dropped" ? (() => { const n = clone(s); n.cur = null; n.ph = null; return n; })() : false,
  "the server reads the request": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "read") return false;
    const c = s.cl[s.cur];
    if (c.kind === "idle" || c.kind === "trickle") return false;
    const n = clone(s); n.ph = c.kind === "flood" ? "write" : "handle"; n.w = 0; return n;   // flood: 4096 bytes without a newline arrive at once; the cap answers bad_command, the handler is not called
  },
  "the receive timeout expires on a client that sent nothing": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "read" || s.cl[s.cur].kind !== "idle" || s.w < RCV) return false;
    const n = clone(s); n.cur = null; n.ph = null; return n;      // dropped, next client served
  },
  "the receive timeout expires on a client that stopped sending": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "read" || s.cl[s.cur].kind !== "trickle" || s.w < RCV) return false;
    const n = clone(s); n.cur = null; n.ph = null; return n;
  },
  "the request cap is reached: the server stops reading and answers bad_command": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "read" || s.cl[s.cur].kind !== "trickle" || s.tb < TB) return false;
    const n = clone(s); n.ph = "write"; n.w = 0; return n;
  },
  "the handler finishes": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "handle" || s.w < HANDLER[s.cl[s.cur].kind]) return false;
    const n = clone(s); n.ph = "write"; n.w = 0; n.slot = s.cur; return n;
  },
  "the server writes the reply": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "write") return false;
    const c = s.cl[s.cur];
    const n = clone(s);
    if (c.kind === "nonreading") return false;                                    // handled by the send-timeout action
    if (c.kind === "early-post") { if (NOSIGPIPE) { n.cur = null; n.ph = null; } else { n.dead = true; } return n; }
    const delivered = VARIANT === "m-shared-response" ? s.slot : s.cur;           // current: the reply is a local value of this connection; the handler is not called for bad_command
    n.cl[s.cur].got = delivered;
    if (c.kind === "trickle" || c.kind === "flood") { n.cur = null; n.ph = null; return n; }   // bad_command reply, small
    n.cl[s.cur].ans = true; n.cl[s.cur].lat = c.age; n.cur = null; n.ph = null;
    if (c.kind === "stop") n.exited = true;                                       // exit(0) 0.1 s after the reply
    return n;
  },
  "the send timeout expires on a client that does not read its reply": (s) => {
    if (s.dead || s.exited || s.cur === null || s.ph !== "write" || s.cl[s.cur].kind !== "nonreading" || s.w < SND) return false;
    const n = clone(s); n.cur = null; n.ph = null; return n;
  },
  "one tick passes": (s) => {
    if (s.t >= TMAX || s.dead || s.exited || instant(s)) return false;
    // a tick that changes nothing observable (no client waiting, server idle) is useless: require some activity
    if (s.cur === null && s.q.length === 0 && s.cl.every((c) => c.ans || c.kind !== "ping")) return false;
    const n = clone(s); n.t++;
    for (const c of n.cl) if (!c.ans) c.age++;
    if (n.cur !== null) {
      const c = n.cl[n.cur];
      if (n.ph === "read" && c.kind === "trickle") {
        n.tb++;
        n.w = VARIANT === "current-pre-fix" ? 0 : n.w + 1;            // pre-fix: a received byte restarts the per-read timeout; current: one total deadline
      } else n.w++;
    }
    return n;
  },
};

const ahead = (s, idx) => s.cl.slice(0, idx);
const exemptBehindHandler = (s, idx) => VARIANT !== "limit" && ahead(s, idx).some((c) => c.kind === "stop" || c.kind === "slowdump");
export const rules = {
  PingBound: { says: "a normal client's PING is answered within one tick (the 1 s socket timeout) per other client that connected before it, while any of them misbehaves (idle, not reading, closing early, trickling); a PING behind a STOP is exempt because the process exits",
    holds: (s) => s.cl.every((c, idx) => c.kind !== "ping" || ahead(s, idx).some((a) => a.kind === "stop") || exemptBehindHandler(s, idx) || (c.ans ? c.lat : c.age) <= ahead(s, idx).length) },
  ReplyOwn: { says: "a client that receives a reply receives the reply to its own request, never another client's",
    holds: (s) => s.cl.every((c, idx) => c.got === -1 || c.got === idx) },
  NoSigpipe: { says: "no client behaviour kills the manbok process with SIGPIPE",
    holds: (s) => !s.dead },
};
export const done = (s) => s.t >= TMAX || s.dead || s.exited || (s.cur === null && s.q.length === 0 && s.cl.length >= NCL);
export const label = (s) => `t=${s.t} cur=${s.cur === null ? "-" : s.cl[s.cur].kind + ":" + s.ph} q=${s.q.length} cl=${s.cl.map((c) => c.kind + (c.ans ? "+" : "") + c.age).join(",")}${s.dead ? " DEAD" : ""}`;
