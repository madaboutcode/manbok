// Order model of manbok's CaptureSupervisor executor (T1081 V1-supmodel), mirrored by hand.
// Composition: restart budget (CaptureRestartPolicy), silence ladder (SilenceRecoveryPolicy), stall watchdog,
// environment-signal mailbox, and the wasFlowing value recorded when a worker ends and consumed once by the next start (FIX-A), with a fake worker.
//
// Env switches (read at load):
//   MODEL_VARIANT     base | m-clear-on-release (release records "not flowing") | m-not-consumed (a start does not clear
//                     the recorded value) | m-never-reset | m-stall-lastdata-only | m-ladder-skip |
//                     m-leak-empty | m-gaphold | m-uncapped-delay
//   MODEL_RESTRICT    "switch": only app-list changes, chunks always flow, no start failure, no signals
//   MODEL_DEFER_MAX   Rdefer bound: polls a candidate device may wait on the restart budget (default 99 = off)
//   MODEL_SUSTAIN     1: track sustained flow (rule R3e)
//   MODEL_RECOV_MAX   R8 bound: consecutive recovery restarts (default 99 = off)
//   MODEL_MAX, MODEL_SIL   override maxDelay / silence threshold (time units, scaled runs)
//
// Time unit: one poll = 20 units (2 s). Watchdog 40, baseDelay 10, maxDelay 300, silence 100. A chunk "just
// before the poll" has age 1 (epsilon). Ages are stored relative to "now" and capped at the largest value the
// code compares them with, so the state space is finite without a depth limit.
const VARIANT = process.env.MODEL_VARIANT ?? "base";
const RESTRICT = process.env.MODEL_RESTRICT === "switch";
const DEFER_MAX = +(process.env.MODEL_DEFER_MAX ?? 99);
const SUSTAIN = process.env.MODEL_SUSTAIN === "1";
const RECOV_MAX = +(process.env.MODEL_RECOV_MAX ?? 99);
const IDS = +(process.env.MODEL_IDS ?? 1), MICS = +(process.env.MODEL_MICS ?? 2);
const P = 20, WD = 40, BASE = 10;
const MAXD = +(process.env.MODEL_MAX ?? 300);
const SIL = +(process.env.MODEL_SIL ?? 100);
const SRC = "Sources/ManbokPlatform/Capture/";
const SUSTAIN_POLLS = Math.ceil(MAXD / P);
const CMAX = 6;
const LACAP = 40;    // last-byte age is only compared with watchdogThreshold

export const meta = {
  title: `manbok CaptureSupervisor executor [${VARIANT}]`,
  covers: [
    { file: SRC + "CaptureSupervisor.swift", fn: "apply", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "restart", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "startWorker", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "recordWorkerEnd", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "releaseWorker", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "abandonWorker", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "stop", mirrored: true },
    { file: SRC + "CaptureRestartPolicy.swift", mirrored: true },
    { file: SRC + "SilenceRecoveryPolicy.swift", mirrored: true },
  ],
  notModeled: [
    "device choice: the resolved target (CaptureDevicePolicy tie-break) is a free input each poll, 2 mics",
    "the demand reducer and sessions (other model); one app in demand, with 2 ids so an id change can occur",
    "real chunk timing: each 2 s interval is one of four modes (flowing, digital silence, none, flowing then stops mid-interval); a chunk just before a poll has age 1",
    "stale chunks from a stopped worker (H4)",
    "defaultInputChanged signal (inert in the code); the enum case restartInPlace (evaluate never returns it)",
    "sleep/wake and wall-clock jumps (Date() is wall clock; no handler exists)",
    "thread interleaving of stop() on the socket thread (EXPECTS says apply and stop are serialized)",
    "health enum and log lines; only isHolding is kept",
    "restart count saturates at 6 (delay is at maxDelay from 5)",
  ],
  assumptions: [
    "poll = 2 s; watchdogThreshold 4 s, baseDelay 1 s, maxDelay 30 s, silenceThreshold 10 s, maxSilentRestarts 2 (code defaults)",
    "a signal arrives between polls and is consumed at the next apply; one pending signal is enough",
    "a start can fail at any attempt (device busy)",
    "the environment may change the app list, the chunk mode and signals at any time between polls",
  ],
  variant: VARIANT,
};
export const bounds = { pollUnits: P, watchdog: WD, baseDelay: BASE, maxDelay: MAXD, silence: SIL, mics: MICS, demandIds: IDS, restartCountSat: CMAX, variant: VARIANT, restrict: RESTRICT ? "switch" : "none", deferMax: DEFER_MAX };

const EV0 = { polled: false, empty: false, trig: null, ok: null, startFailed: false, blocked: false, flowedPrev: false, stallLegit: null,
  cBefore: 0, cAfter: 0, ladBefore: 0, ladAfter: 0, ladRestart: false, holdEnter: false, silentNilEval: false, external: false,
  arrivalTf: false, lhPrev: false };
export const init = {
  stopped: false, w: false, wt: 0, sa: null, la: null, ss: null, c: 0, lr: null, lad: 0, lprt: 0, hold: false,
  pids: 0, pt: 0, pend: false, mode: "F", inp: { id: 0, tgt: 0 },
  wf: null, tf: false, defer: 0, recov: 0, fr: 0, lh: false, ev: EV0,
};

const delayOf = (c) => VARIANT === "m-uncapped-delay" ? BASE * 2 ** c : Math.min(BASE * 2 ** c, MAXD);
const mayRestart = (s) => s.lr === null || s.lr >= delayOf(s.c);
const flowing = (s) => s.la !== null && s.la < WD;                  // bytesFlowing(now)

function record(s, wasFlowing) {                                      // CaptureRestartPolicy.recordRestart
  const c = VARIANT === "m-never-reset" ? Math.min(s.c + (s.lr !== null ? 1 : 0), CMAX)
    : (s.lr !== null && !wasFlowing ? Math.min(s.c + 1, CMAX) : 0);
  return { ...s, c, lr: 0 };
}
function startWorker(s, target, wasFlowing, fails) {                  // startWorker: success and (optionally) throw
  const out = [{ st: { ...record(s, wasFlowing), w: true, wt: target, sa: 0, hold: false, fr: 0, lh: false }, ok: true }];
  if (fails) out.push({ st: { ...record(s, false), w: false, wt: 0, sa: null }, ok: false });
  return out;
}
function restartW(s, target, fails) {                                 // restart(): evidence, clear, stop, start
  const wasFlowing = flowing(s);                                      // recordWorkerEnd: flow at the moment this worker ends
  return startWorker({ ...s, la: null, ss: null, w: false, wt: 0, sa: null }, target, wasFlowing, fails).map((b) => ({ ...b, wasFlowing }));
}
function noteRestart(s, target) {                                     // SilenceRecoveryPolicy.noteRestart
  let { lad, lprt } = s;
  if (VARIANT === "m-ladder-skip") { if (lad === 0) lad = 2; lprt = target; }
  else if (lad === 0) { lad = 1; lprt = target; }
  else if (lad === 1) { if (lprt !== 0 && lprt !== target) lprt = target; else { lad = 2; lprt = target; } }
  else lprt = target;
  return { ...s, lad, lprt };
}

function advance(s) {                                                 // 2 s pass: ages grow, the worker's chunks arrive
  const A = (v, m) => (v === null ? null : Math.min(v + P, m));
  let la = A(s.la, LACAP), ss = A(s.ss, SIL), sa = A(s.sa, SIL), lr = A(s.lr, delayOf(s.c)), fr = s.fr, lh = s.lh;
  if (s.w) {
    if (s.mode === "F") { la = 1; ss = null; fr = Math.min(fr + 1, SUSTAIN_POLLS); }
    else if (s.mode === "S") { la = 1; ss = ss === null ? 19 : ss; fr = 0; }
    else if (s.mode === "FN") { la = 10; ss = null; fr = 0; }
    else fr = 0;
    if (SUSTAIN && fr >= SUSTAIN_POLLS) lh = true;
  }
  return { ...s, la, ss, sa, lr, fr: SUSTAIN ? fr : 0, lh: SUSTAIN ? lh : false, mode: s.mode === "FN" ? "N" : s.mode };
}

const ev = (st, f) => ({ ...st, ev: { ...st.ev, ...f(st.ev) } });

// One apply() call (mirrors CaptureSupervisor.apply). Returns next states (start success / throw branches).
function apply(s0) {
  const fails = !RESTRICT;
  const inp = s0.inp;
  let s = { ...s0, ev: { ...EV0, polled: true, cBefore: s0.c, ladBefore: s0.lad, lhPrev: s0.lh } };
  if (inp.id === 0) {                                                // empty demand: abandonWorker + reset
    const f = flowing(s);                                              // abandonWorker records flow at the end, then the policy is reset
    return [{ ...s, w: false, wt: 0, sa: null, ss: null, la: VARIANT === "m-leak-empty" ? s.la : null, pend: false,
      c: 0, lr: null, lad: 0, lprt: 0, hold: false, pids: 0, pt: 0, wf: f, tf: f,
      ev: { ...s.ev, empty: true } }];
  }
  const pendEnv = s.pend;
  s = { ...s, pend: false };
  const target = inp.tgt;
  const external = inp.id !== s.pids || target !== s.pt;
  s = { ...s, ev: { ...s.ev, external } };
  let outs = [s];
  if (target !== 0) {
    if (!s.w) {
      if (mayRestart(s)) {
        const wasFlowing = s.wf === true;                             // the start reads the recorded value once; it never looks at byte age
        const oracle = s.tf;                                           // history copy of the value recorded at the last end (variants never touch it)
        outs = startWorker({ ...s, la: null, wf: VARIANT === "m-not-consumed" ? s.wf : null, tf: false }, target, wasFlowing, fails).map((b) => ev(b.st, () => ({
          trig: "arrival", ok: b.ok, startFailed: !b.ok, flowedPrev: wasFlowing, arrivalTf: oracle })));
      } else outs = [ev(s, () => ({ blocked: true }))];
    } else {
      const stage = (list, f) => list.flatMap((st) => (st.ev.trig ? [st] : f(st)));   // `!restartHappened` guards
      const withRestart = (st, trig, extra) => restartW(st, target, fails).map((b) => ({ b, trig, extra }));
      // 1. target mismatch
      outs = stage(outs, (st) => {
        if (st.wt === target) return [st];
        if (!mayRestart(st)) return [ev(st, () => ({ blocked: true }))];
        return restartW(st, target, fails).map((b) => ev(b.st, () => ({ trig: "switch", ok: b.ok, startFailed: !b.ok, flowedPrev: b.wasFlowing })));
      });
      // 2. byte-flow watchdog: isStalled(lastDataAt, captureStartedAt)
      outs = stage(outs, (st) => {
        const lastEvidenceAge = Math.min(st.la === null ? 999 : st.la, st.sa);
        const stalled = VARIANT === "m-stall-lastdata-only" ? (st.la === null || st.la >= WD) : lastEvidenceAge >= WD;
        if (!stalled) return [st];
        if (!mayRestart(st)) return [ev(st, () => ({ blocked: true }))];
        const legit = st.sa >= WD && (st.la === null || st.la >= WD);
        return restartW(st, target, fails).map((b) => ev(b.st, () => ({ trig: "stall", ok: b.ok, startFailed: !b.ok, flowedPrev: b.wasFlowing, stallLegit: legit })));
      });
      // 3. digital-silence watchdog: silencePolicy.evaluate
      outs = stage(outs, (st) => {
        if (st.ss === null) return [ev({ ...st, lad: 0, lprt: 0, hold: false }, () => ({ silentNilEval: true }))];
        if (st.lad === 3) return [st];
        const expired = Math.min(st.ss, st.sa) >= SIL;              // now - max(silentSince, startedAt) >= threshold
        if (!expired) return [st];
        if (st.lad === 2) return [ev({ ...st, lad: 3, hold: true }, () => ({ holdEnter: true }))];
        if (!mayRestart(st)) return [ev(st, () => ({ blocked: true }))];
        return restartW(st, target, fails).map((b) => ev(noteRestart(b.st, target), () => ({ trig: "silence", ok: b.ok, startFailed: !b.ok, flowedPrev: b.wasFlowing, ladRestart: true })));
      });
      // 4. environment signals (captureDisturbed)
      if (pendEnv) outs = stage(outs, (st) => {
        if (!mayRestart(st)) return [ev(st, () => ({ blocked: true }))];
        return restartW(st, target, fails).map((b) => ev(b.st, () => ({ trig: "signal", ok: b.ok, startFailed: !b.ok, flowedPrev: b.wasFlowing })));
      });
    }
  } else if (s.w) {                                                   // releaseWorker: recordWorkerEnd
    const f = flowing(s);
    outs = [VARIANT === "m-gaphold" ? s : { ...s, w: false, wt: 0, sa: null, ss: null, pend: false,
      la: null, wf: VARIANT === "m-clear-on-release" ? false : f, tf: f }];
  }
  return outs.map((st) => {
    if (external && !st.ev.ladRestart) st = { ...st, lad: 0, lprt: 0 };  // noteExternalChange
    return { ...st, pids: inp.id, pt: target, ev: { ...st.ev, ladAfter: st.lad, cAfter: st.c } };
  });
}

function post(s0, s) {                                                // history variables
  const e = s.ev;
  const waiting = s.inp.id !== 0 && s.inp.tgt !== 0 && !s.w && e.blocked && !e.startFailed;
  return { ...s,
    defer: waiting ? Math.min(s0.defer + 1, 16) : 0,
    recov: ["stall", "signal", "silence"].includes(e.trig) ? Math.min(s0.recov + 1, 7) : 0 };
}

export const actions = {};
const inputs = [{ id: 0, tgt: 0 }];
for (let id = 1; id <= IDS; id++) for (let tgt = 0; tgt <= MICS; tgt++) inputs.push({ id, tgt });
const inName = (i) => i.id === 0 ? "the app list is empty (no demand)" : i.tgt === 0 ? `app ${i.id} holds the mic but no mic device is listed` : `app ${i.id} holds the mic and lists mic ${i.tgt}`;
for (const i of inputs) {
  if (RESTRICT && i.id === 2) continue;
  actions[inName(i)] = (s) => !s.stopped && !(s.inp.id === i.id && s.inp.tgt === i.tgt) && { ...s, inp: i, ev: EV0 };
}
const modes = { F: "chunks flow normally", S: "chunks arrive but are digital silence", N: "no chunks arrive", FN: "chunks flow for part of the next 2 s, then stop" };
for (const [m, text] of Object.entries(modes)) {
  if (RESTRICT) continue;
  actions[text] = (s) => !s.stopped && s.mode !== m && { ...s, mode: m, ev: EV0 };
}
if (!RESTRICT) actions["a captureDisturbed signal arrives"] = (s) => !s.stopped && !s.pend && { ...s, pend: true, ev: EV0 };
actions["poll tick (2 s pass, apply runs)"] = (s) => !s.stopped && apply(advance(s)).map((x) => post(s, x));
actions["supervisor stop()"] = (s) => !s.stopped && ({ ...s, stopped: true, w: false, wt: 0, sa: null, la: null, ss: null, pend: false,
  c: 0, lr: null, lad: 0, lprt: 0, hold: false, pids: 0, pt: 0, wf: flowing(s), tf: flowing(s), ev: EV0 });

// ---------------- rules ----------------
const af = (s) => s.ev.polled && !s.stopped;                          // state right after a poll
export const rules = {
  R1_run: { says: "after a poll the worker runs only if demand has a candidate device; with a candidate device it runs unless the start failed or the restart budget blocked the attempt (CaptureSupervisor CONTRACT: worker runs iff demand non-empty and some entry lists a device, subject to restart budget)",
    holds: (s) => !af(s) || (s.ev.empty ? !s.w : ((!s.w || s.inp.tgt !== 0) && (s.inp.tgt === 0 || s.w || s.ev.startFailed || s.ev.blocked))) },
  R2_healthyRestart: { says: "a start or restart made while bytes were flowing within watchdogThreshold does not grow the backoff (CaptureRestartPolicy CONTRACT: resets on any restart of a working engine)",
    holds: (s) => !af(s) || !s.ev.trig || !s.ev.ok || !s.ev.flowedPrev || s.ev.cAfter === 0 },
  R2m_micSwitch: { says: "design-v2 A3 + advisor round 9 (Slow): a mic released for no device while bytes were flowing, then started on a candidate after ANY gap (no cap), does not grow the backoff",
    holds: (s) => !af(s) || !s.ev.arrivalTf || !s.ev.ok || s.ev.cAfter <= s.ev.cBefore },
  R2c_carry: { says: "ASSUMPTION: a start uses exactly the wasFlowing value recorded when the previous worker ended, once: a start after a failed start sees no older value",
    holds: (s) => !af(s) || s.ev.trig !== "arrival" || s.ev.flowedPrev === s.ev.arrivalTf },
  R3_bounded: { says: "the restart delay never exceeds maxDelay (CaptureRestartPolicy CONTRACT: capped at maxDelay)",
    holds: (s) => delayOf(s.c) <= MAXD },
  R3e_sustained: { says: SUSTAIN ? "ASSUMPTION: after one worker has flowed for maxDelay without a break, a later stall or signal restart starts from the base delay (count at most 1), not from an old count" : "(off: set MODEL_SUSTAIN=1)",
    holds: (s) => !SUSTAIN || !af(s) || !["stall", "signal"].includes(s.ev.trig) || !s.ev.ok || !s.ev.lhPrev || s.ev.cAfter <= 1 },
  R4_stall: { says: "the stall watchdog never restarts a worker before watchdogThreshold has passed since its start and since its last byte (CaptureRestartPolicy CONTRACT: a fresh engine gets watchdogThreshold to produce its first byte)",
    holds: (s) => !af(s) || s.ev.trig !== "stall" || s.ev.stallLegit === true },
  R5_ladderOrder: { says: "the silence ladder moves armed, re-resolving, retrying, holding one step at a time, or back to armed; a ladder restart starts only from armed or re-resolving, and holdEntered only from retrying (SilenceRecoveryPolicy CONTRACT)",
    holds: (s) => !af(s) || ([s.ev.ladBefore, s.ev.ladBefore + 1, 0].includes(s.ev.ladAfter) &&
      (s.ev.trig !== "silence" || s.ev.ladBefore <= 1) && (!s.ev.holdEnter || s.ev.ladBefore === 2)) },
  R5_ladderReset: { says: "a poll that sees real signal (no digital-silence run) or a demand/target change from outside the ladder leaves the ladder armed (SilenceRecoveryPolicy CONTRACT: evaluate with silentSince nil re-arms; noteExternalChange re-arms)",
    holds: (s) => !af(s) || ((!s.ev.silentNilEval || s.lad === 0) && (!(s.ev.external && !s.ev.ladRestart) || s.lad === 0)) },
  R5_holdHealth: { says: "health is 'holding silent' only while a worker is capturing (CaptureWaist CONTRACT: holdingSilent = capturing, silence ladder exhausted)",
    holds: (s) => !af(s) || !s.hold || (s.inp.tgt === 0 && !s.w) || s.w },
  R5_holdFlag: { says: "ASSUMPTION: the 'holding silent' flag is set only while the ladder is in holding (H7 in sm-inventory)",
    holds: (s) => !s.hold || s.lad === 3 },
  R6_lifetime: { says: "empty demand and stop() clear the byte clock, the restart budget, the ladder and the hold flag",
    holds: (s) => !(s.stopped || (af(s) && s.ev.empty)) || (!s.w && s.la === null && s.c === 0 && s.lr === null && s.lad === 0 && !s.hold) },
  R6b_noLeak: { says: "the recorded wasFlowing value exists only between a worker end and the next start attempt: it is cleared while a worker runs",
    holds: (s) => !s.w || s.wf === null },
  Rdefer: { says: `ASSUMPTION: with a candidate device and no start failure, the worker waits at most ${DEFER_MAX} poll(s) because of the restart budget`,
    holds: (s) => s.defer <= DEFER_MAX },
  R8_noStorm: { says: `ASSUMPTION (CaptureRestartPolicy CONTRACT: 'no flap loop'): recovery restarts (stall, signal, silence) do not happen in more than ${RECOV_MAX} polls in a row`,
    holds: (s) => s.recov <= RECOV_MAX },
};
export const canReach = {
  CanIdle: { says: "from any point, the worker can end up stopped", goal: (s) => !s.w },
};
export const done = (s) => s.stopped;
export const label = (s) => s.stopped ? "Stopped" : s.w ? "Capturing" : s.wf !== null ? "Released (flow value recorded)" : "Idle";

// ---------------- replay support (used by replay.mjs, not by the checker) ----------------
// Tokens: list:<id>:<mic> | empty | mode:F|S|N|FN | signal | poll | poll! (every start in this poll throws) | stop
export function replayStep(s, tok) {
  const [kind, a, b] = tok.split(":");
  if (kind === "list") return actions[inName({ id: +a, tgt: +b })](s) || s;
  if (kind === "empty") return actions[inName({ id: 0, tgt: 0 })](s) || s;
  if (kind === "mode") return actions[modes[a]](s) || s;
  if (kind === "signal") return actions["a captureDisturbed signal arrives"](s) || s;
  if (kind === "stop") return actions["supervisor stop()"](s);
  if (kind === "poll" || kind === "poll!") {
    const fail = kind === "poll!";
    const outs = apply(advance(s)).map((x) => post(s, x));
    let pick = outs.filter((x) => x.ev.startFailed === fail);
    if (!pick.length && fail) pick = outs.filter((x) => !x.ev.trig);   // poll!: a throw only matters if a start is attempted
    if (!pick.length) throw new Error(`${tok}: no outcome`);
    return pick[0];
  }
  throw new Error("unknown token " + tok);
}
export const observe = (s) => ({ capturing: s.w, target: s.wt, holding: s.hold && !(s.inp.tgt === 0 && !s.w) && s.inp.id !== 0,
  deferred: s.inp.id !== 0 && s.inp.tgt === 0 && !s.w, c: s.c });
