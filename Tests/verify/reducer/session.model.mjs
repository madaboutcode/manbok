// Order model of the T1081 reducer design (design-v2.md section 6 overrides earlier sections). MIRRORED, not linked to code.
// Variant via env MODEL_VARIANT:
//   fix | no-a3 | a3-leak | excl-nosess | gaphold | flag | p5union | stale | rowsess | excl-late | excl-ignore | timer | nostep2 | ticks | nofallback | excl-dropnosess
// Env: MODEL_FINDINGS=1 adds the rules that are expected to break (P1s, P5s, Slow), MODEL_EDGE=true|false pins the 4 s tie, MODEL_UCAP = max unhealthy count, MODEL_NOSLEEP=1 removes the sleep event, MODEL_TOT = fault budget, MODEL_TIMERS=1 adds latency counters (P3, Plat), MODEL_EXAPPS = how many apps can be excluded, MODEL_APPS (default 2), MODEL_DEVS (default 2), MODEL_BSTOP (default 8), MODEL_BEX (default 6),
//      MODEL_NSW/NBL/NVAN/NFAIL/NSLP/NEXC = event budgets.
// Time: seconds. Poll every 2 s. Events happen at 1 s steps (offset 0 or 1 after a poll). G = 5 s drain deadline checked on poll.
const VARIANT = process.env.MODEL_VARIANT ?? "fix";
const V = (...n) => n.includes(VARIANT);
const SRC = "Sources/ManbokPlatform/Capture/";
const NAPPS = +(process.env.MODEL_APPS ?? 2);
const DEVS = (+(process.env.MODEL_DEVS ?? 2) === 1) ? [1] : [1, 2];
const UCAP = +(process.env.MODEL_UCAP ?? 3);   // unhealthy-count cap: delay = 2^unh s, so the longest delay is 2^UCAP s (real cap 30 s)
const SCAP = 1 << UCAP;
const FAST = process.env.MODEL_FAST === "1";   // switches never take longer than the 4 s audio-evidence window (so A3 can be told apart from the slow-switch finding)
const G = 5;            // drain deadline, seconds
const GTICKS = 3;       // `ticks` variant: drain counted in step calls (5 s / 2 s poll rounded up)
const BSTOP = +(process.env.MODEL_BSTOP ?? 8);   // P3 / Plat bound, seconds
const BEX = +(process.env.MODEL_BEX ?? 8);       // Excl bound, seconds (grace 5 s + one poll, plus the 1 s event grid)
const TIMERS = process.env.MODEL_TIMERS === "1";   // latency counters (P3, Plat) only in the latency runs: they multiply the state space
const TOT = +(process.env.MODEL_TOT ?? 3);   // total fault budget: switches, list blips, mic vanishes, start failures, sleeps, exclusion toggles together
const IDX = [...Array(NAPPS).keys()];
const EXAPPS = +(process.env.MODEL_EXAPPS ?? 1);   // only the first EXAPPS apps can be excluded (state-space bound)

export const meta = {
  title: `manbok demand reducer + supervisor budget [${VARIANT}]`,
  covers: [
    { file: "Sources/ManbokCore/Application/DemandReducer.swift", fn: "step", mirrored: true },
    { file: SRC + "SessionLifecycleController.swift", fn: "tick", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "apply", mirrored: true },
    { file: SRC + "CaptureSupervisor.swift", fn: "startWorker", mirrored: true },
    { file: SRC + "CaptureRestartPolicy.swift", fn: "recordRestart", mirrored: true },
    { file: SRC + "CaptureRestartPolicy.swift", fn: "mayRestart", mirrored: true },
  ],
  notModeled: [
    "MIRRORED: the model follows DemandReducer.step/stop, SessionLifecycleController.tick, CaptureSupervisor.apply and CaptureRestartPolicy at branch A head 889608f. Linked to the code only by the XCTest replays in Tests/ManbokPlatformTests/ReducerModelReplayTests.swift (see README): the reducer and executor rules run through the real SessionLifecycleController with a model-mirroring fake supervisor, and the A3/Slow restart budget runs through the real CaptureSupervisor. The other supervisor paths (stall/silence watchdogs, restart backoff beyond the budget abstraction) are not replayed.",
    "restart-policy delay is capped at 2^UCAP = "+(1<<UCAP)+" s (unhealthy count saturates at UCAP="+UCAP+"); real cap is 30 s (unhealthy count unbounded); real base delay 1 s as modeled",
    "stall and silence watchdogs, environment signals; a start failure is a free choice at any start/restart (at most NFAIL per run)",
    "sleep: clock jump of 6 s; real events during sleep are not modeled; sleep time is not counted toward P3/Plat/Excl (awake seconds)",
    "device pick tie-break abstracted to keep-current-else-lowest-id; one device per app (pdv# sets are singletons)",
    "first-sight blip; list blips longer than one poll; several processes per bundle ID; permission, ring, dump; VPIO; device-less flag holders other than `tap`",
    "fault budget: at most " + TOT + " of {mic switch, list blip, mic vanish, start failure, sleep, exclusion toggle} per run, in any mix",
    "apps are alive from the start; launch/quit is the same as input start/stop for the reducer",
  ],
  assumptions: [
    "poll every 2 s; one snapshot per poll; settings change (exclusion toggle) triggers an immediate extra poll",
    "executor order: step(isCapturing=before) -> apply -> if capture status changed: step again with the same snapshot",
    "reducer time is monotonic and continues across sleep (A5); stale hold: P3 is measured in awake seconds",
    "wasFlowing = seconds since the last audio byte < 4; a gap of exactly 4 grid seconds is a tie decided by timer jitter, both outcomes explored (Branch A: lastDataAt survives a no-device release; cleared when demand empties, by restart(), and by sleep). Bytes flow each second while the worker exists and its mic exists",
    "A3 = that kept lastDataAt. Variant no-a3 forgets it at abandon (HEAD); variant a3-leak does not clear it when demand empties",
    "abandon for nil target keeps the audio-flow evidence (see above)",
    "tainted episode: after a start failure and before demand empties, P1 excuses backoff deferrals and P1b does not count them",
  ],
  variant: VARIANT,
};
export const bounds = { timers: TIMERS, apps: NAPPS, devices: DEVS.length, G, pollSec: 2, BSTOP, BEX, variant: VARIANT, TOT };

const app0 = { kind: "none", dev: 0, blip: false, lastObs: 0, ever: false, sess: 0, dl: 0, last: 0, open: false, excl: false, exAge: 0, idleA: 0, stale: false, dEx: false };
export const init = {
  a: IDX.map(() => app0), ex: DEVS.map(() => true),
  worker: false, wdev: 0, failed: false, deferred: false, polled: true, due: false, ph: 0, stopped: false, nodev: false,
  unh: 0, hasLast: false, since: SCAP, dgap: 5, abFlow: false, leak: false, slowGrew: false, a3Grew: false, taint: false,
  off: 0, lostSess: false, cad: true, imm: false, idle: 0, badClose: false, newEx: false,
  nf: 0,
};

const flagOf = (p) => (p.kind === "rec" || p.kind === "tap") ? 1 : 0;
const devObs = (p) => (p.blip ? 0 : p.dev);
const truth = (p) => p.kind === "rec";                     // really records on a mic
const trueHolder = (p) => truth(p) && !p.excl;             // a holder the promise covers
const anyHolder = (s) => s.a.some(trueHolder);

function pickTarget(set, wdev) { // abstract CaptureDevicePolicy.resolve
  if (set.length === 0) return 0;
  return set.includes(wdev) ? wdev : Math.min(...set);
}

// ---- the pure reducer step (mirrors DemandReducer.step) ----
// input: apps (with kind/dev/blip/excl as the executor sees them), isCap. Returns new apps + flags.
export function stepApps(apps, isCap) {
  let badClose = false, newEx = false;
  const out = apps.map(p => {
    const d = devObs(p);
    const holdsObs = V("flag") ? flagOf(p) === 1 : V("gaphold") ? (flagOf(p) === 1 || d !== 0) : d !== 0;
    let h = holdsObs && !p.excl;
    if (V("excl-ignore")) h = holdsObs;
    if (V("excl-late")) h = holdsObs && (p.sess !== 0 || !p.excl);   // exclusion only blocks new arrivals
    let q = { ...p };
    if (q.sess === 0) { if (h) { q.sess = 1; q.dl = 0; q.last = d; } }
    else if (q.sess === 1) { if (h) q.last = d; else { q.sess = 2; q.dl = V("ticks") ? 0 : G; q.stale = false; q.dEx = p.excl; } }
    else { // draining
      if (h) { q.stale = V("timer") && q.dl <= 0; q.sess = 1; q.dl = 0; q.last = d; }
      else if (V("timer")) { /* closes only when the separate timer fires */ }
      else if (V("ticks")) { q.dl = p.dl + 1; if (q.dl >= GTICKS) { q.sess = 0; } }
      else if (q.dl <= 0) { q.sess = 0; }
      if (V("excl-dropnosess") && q.sess === 2 && !q.open) q.sess = 0;
    }
    if (q.sess === 0 && p.sess !== 0) { if (truth(p) && !p.excl && !p.dEx) badClose = badClose || true; }   // a drain that the exclusion itself started may end the session even if the user un-excluded in its last second
    if (q.sess === 0) { q.last = 0; q.open = false; q.dl = 0; q.stale = false; }
    // session rule (stated once): every non-absent app without a session gets one iff capture runs
    const needs = V("rowsess") ? q.sess === 1 : q.sess !== 0;
    if (V("excl-nosess") && q.excl) { /* candidate fix: reducer is told the app is excluded and never opens a session for it */ }
    else if (needs && isCap && !q.open) { q.open = true; if (q.excl) newEx = true; }
    return q;
  });
  return { a: out, badClose, newEx };
}

// ---- candidates (mirrors DemandReducer.candidateDevices) ----
function candidates(a, ex) {
  const holdingDevs = a.filter(p => p.sess === 1 && p.last).map(p => p.last);
  const keepDev = (d) => V("stale") ? true : ex[d - 1];
  const drainDevs = a.filter(p => p.sess === 2 && p.last).map(p => p.last).filter(keepDev);
  let cand;
  if (V("p5union")) cand = [...new Set([...holdingDevs, ...drainDevs])];
  else if (V("nofallback")) cand = [...new Set(holdingDevs)];
  else cand = holdingDevs.length ? [...new Set(holdingDevs)] : [...new Set(drainDevs)];
  const noKnown = holdingDevs.length === 0 && !a.some(p => p.sess === 2 && p.last && ex[p.last - 1]);
  return { cand, noKnown };
}

// ---- supervisor apply with the restart budget (mirrors CaptureSupervisor.apply + CaptureRestartPolicy) ----
// Branch A keeps lastDataAt across a no-device release: dgap = grid seconds since the last audio byte (5 = none / expired).
// wasFlowing = real gap < 4 s (watchdogThreshold): dgap <= 3 yes, dgap 4 either (tie), dgap 5 no. Variant no-a3: abandon forgets lastDataAt (HEAD behaviour). Variant a3-leak: empty demand does not forget it.
const mayRestart = (s) => !s.hasLast || s.since >= (1 << s.unh);
const record = (s, wasF) => ({ unh: (s.hasLast && !wasF) ? Math.min(UCAP, s.unh + 1) : 0, hasLast: true, since: 0 });
const SUPK = (s) => ({ worker: s.worker, wdev: s.wdev, unh: s.unh, hasLast: s.hasLast, since: s.since, dgap: s.dgap, abFlow: s.abFlow, taint: s.taint, nf: s.nf, failed: false, deferred: false, leak: s.leak, slowGrew: s.slowGrew, a3Grew: s.a3Grew });
function supApply(s, anyDemand, cand) {
  if (!anyDemand) return [{ ...SUPK(s), worker: false, wdev: 0, unh: 0, hasLast: false, dgap: V("a3-leak") ? s.dgap : 5, abFlow: false, taint: false }];
  const target = pickTarget(cand, s.wdev);
  if (!target) {
    if (V("gaphold")) return [SUPK(s)];
    const flowing = s.worker ? s.dgap <= 4 : s.abFlow;
    return [{ ...SUPK(s), worker: false, wdev: 0, dgap: s.dgap, abFlow: flowing }];
  }
  if (s.worker && s.wdev === target) return [SUPK(s)];
  if (!mayRestart(s)) return [{ ...SUPK(s), deferred: true }];
  const arrival = !s.worker;
  // Real test is (now - lastDataAt) < 4.0 s. The model grid is whole seconds, polls are 2 s apart: gap 4 is a tie that
  // timer jitter and the age of the last chunk decide, so both outcomes are explored (MODEL_EDGE=true|false pins one).
  const edge = process.env.MODEL_EDGE;
  const flowOpts = s.dgap <= 3 ? [true] : s.dgap === 4 ? (edge === "true" ? [true] : edge === "false" ? [false] : [true, false]) : [false];
  const outs = [];
  for (const truthF of flowOpts) {
    const wasF = (V("no-a3") && arrival) ? false : truthF;           // no-a3: HEAD's abandonWorker() cleared lastDataAt, so an arrival start never saw flow
    const cold = !s.hasLast;
    const base = { ...SUPK(s), leak: s.leak || (cold && wasF) };    // a cold start (no earlier attempt since idle) inherits a healthy flag
    const dg = 5;                                                     // restart() and the arrival path both set lastDataAt = nil before the new worker starts (CaptureSupervisor.swift:150, :347)
    const slow = arrival && s.abFlow && !truthF && s.hasLast && !s.taint; // audio at release, but the evidence expired before the start
    const a3 = arrival && s.abFlow && s.dgap <= 3 && s.hasLast && !s.taint; // audio within 3 s of the start (definitely < 4 s): the backoff must not grow
    const rec = record(s, wasF);
    outs.push({ ...base, worker: true, wdev: target, ...rec, dgap: dg, abFlow: false, slowGrew: s.slowGrew || (slow && rec.unh > s.unh), a3Grew: s.a3Grew || (a3 && rec.unh > s.unh) });
    if (s.nf < TOT) outs.push({ ...base, failed: true, worker: false, wdev: 0, ...record(s, false), dgap: dg, abFlow: false, taint: true, nf: s.nf + 1 });
  }
  return outs;
}

function pollAll(s) {
  const r1 = stepApps(s.a, s.worker);
  const { cand, noKnown } = candidates(r1.a, s.ex);
  const anyDemand = r1.a.some(p => p.sess !== 0);
  return supApply(s, anyDemand, cand).map(sp => {
    let a = r1.a, badClose = r1.badClose, newEx = r1.newEx;
    if (sp.worker !== s.worker && !V("nostep2")) {      // capture status changed: step again, same snapshot
      const r2 = stepApps(a, sp.worker);
      a = r2.a; badClose = badClose || r2.badClose; newEx = newEx || r2.newEx;
    }
    const nodev = !cand.length && noKnown;     // no known device: none listed by a holder, no draining kept device still exists
    const lost = nodev && s.a.some((p, i) => p.open && trueHolder(p) && !p.dEx && !a[i].open);
    const holder = a.some(trueHolder);
    const noteTaint = sp.taint;
    const off = sp.worker || !holder || sp.failed || noteTaint || sp.deferred ? 0 : (s.imm ? s.off : Math.min(s.off + 1, 2));   // off-cycle (settings) polls do not count as a poll period
    a = a.map(p => ({ ...p, blip: false, lastObs: devObs(p) }));
    return { ...s, a, badClose: s.badClose || badClose, newEx: s.newEx || newEx, worker: sp.worker, wdev: sp.wdev, failed: sp.failed, deferred: sp.deferred,
      unh: sp.unh, hasLast: sp.hasLast, since: sp.since, dgap: sp.dgap, abFlow: sp.abFlow, leak: sp.leak, slowGrew: sp.slowGrew, a3Grew: sp.a3Grew, taint: sp.taint, nf: sp.nf,
      nodev, lostSess: lost, off, polled: true, due: false, cad: !s.imm, imm: false };
  });
}

const slowBlock = (s) => FAST && !s.worker && s.abFlow && s.dgap + (s.ph === 0 ? 2 : 1) > 4;   // FAST: no start later than the evidence window
const W = (s) => !s.stopped;
const E = (s) => W(s) && !s.due;                 // environment events happen between polls, not at the poll instant
const upd = (s, i, f) => ({ ...s, a: s.a.map((p, j) => j === i ? { ...p, ...f(p) } : p), polled: false });
const norm = (s) => anyHolder(s) ? { ...s, idle: 0 } : s;
const normA = (s) => ({ ...s, a: s.a.map(p => trueHolder(p) ? { ...p, idleA: 0 } : p) });
const fin = (s) => normA(norm(s));

export const actions = {};
for (const i of IDX) {
  const n = `app ${i + 1}`;
  for (const d of DEVS) {
    actions[`${n} starts recording on mic ${d}`] = s => E(s) && s.ex[d - 1] && s.a[i].kind === "none" && !slowBlock(s) && fin(upd(s, i, () => ({ kind: "rec", dev: d, ever: true })));
    actions[`${n} switches to mic ${d}`] = s => E(s) && s.nf < TOT && s.ex[d - 1] && s.a[i].kind === "rec" && s.a[i].dev !== d && { ...upd(s, i, () => ({ dev: d })), nf: s.nf + 1 };
  }
  actions[`${n} starts tapping another app's output`] = s => E(s) && s.a[i].kind === "none" && upd(s, i, () => ({ kind: "tap" }));
  actions[`${n} stops its input (or quits)`] = s => E(s) && s.a[i].kind !== "none" && fin(upd(s, i, () => ({ kind: "none", dev: 0, blip: false })));
  actions[`${n} loses its mic from the device list for one poll`] = s => E(s) && s.nf < TOT && s.a[i].dev !== 0 && !s.a[i].blip && s.a[i].lastObs !== 0 && { ...upd(s, i, () => ({ blip: true })), nf: s.nf + 1 };
  if (i < EXAPPS) actions[`you exclude ${n}`] = s => E(s) && s.nf < TOT && !s.a[i].excl && fin({ ...upd(s, i, () => ({ excl: true, exAge: 0 })), nf: s.nf + 1, due: true, imm: true });
  if (i < EXAPPS) actions[`you un-exclude ${n}`] = s => E(s) && s.nf < TOT && s.a[i].excl && fin({ ...upd(s, i, () => ({ excl: false, exAge: 0 })), nf: s.nf + 1, due: true, imm: true });
}
for (const d of DEVS) {
  actions[`mic ${d} disappears (apps on it stop recording)`] = s => E(s) && s.nf < TOT && s.ex[d - 1] &&
    fin({ ...s, nf: s.nf + 1, ex: s.ex.map((e, k) => k === d - 1 ? false : e),
          a: s.a.map(p => p.dev === d ? { ...p, kind: "none", dev: 0, blip: false } : p), polled: false });
  actions[`mic ${d} comes back`] = s => E(s) && !s.ex[d - 1] && !slowBlock(s) && ({ ...s, ex: s.ex.map((e, k) => k === d - 1 ? true : e), polled: false });
}
actions["1 s passes"] = s => {
  if (!W(s) || s.due) return false;
  const ph = 1 - s.ph;
  const flowing = s.worker && s.ex[s.wdev - 1];
  const hold = anyHolder(s);
  return {
    ...s, ph, due: ph === 0, polled: false,
    a: s.a.map(p => ({ ...p,
      dl: (p.sess === 2 && !V("ticks")) ? Math.max(0, p.dl - 1) : p.dl,
      exAge: (p.excl && (p.sess !== 0 || p.open)) ? Math.min(p.exAge + 1, BEX + 1) : 0,
      idleA: (TIMERS && p.open && !trueHolder(p)) ? Math.min(p.idleA + 1, BSTOP + 1) : 0 })),
    since: Math.min(SCAP, s.since + 1),
    dgap: flowing ? 0 : Math.min(5, s.dgap + 1),
    idle: (TIMERS && s.worker && !hold) ? Math.min(s.idle + 1, BSTOP + 1) : 0,
  };
};
actions["machine sleeps and wakes (clock jumps 6 s)"] = s => E(s) && s.nf < TOT && ({
  ...s, nf: s.nf + 1, polled: false, since: SCAP, dgap: 5,
  a: s.a.map(p => ({ ...p, dl: (p.sess === 2 && !V("ticks")) ? Math.max(0, p.dl - 6) : p.dl })),
});
if (process.env.MODEL_NOSLEEP === "1") delete actions["machine sleeps and wakes (clock jumps 6 s)"];
actions["poll tick"] = s => W(s) && s.due && pollAll(s).map(x => fin(x));
// variant timer: separate drain timer
if (V("timer")) {
  actions["a drain timer fires"] = s => W(s) && s.a.some(p => p.sess === 2 && p.dl <= 0) &&
    s.a.map((p, i) => (p.sess === 2 && p.dl <= 0) ? i : -1).filter(i => i >= 0).map(i =>
      ({ ...s, polled: false, a: s.a.map((q, j) => j === i ? { ...q, sess: 0, open: false, last: 0, dl: 0, stale: false } : q) }));
  actions["a stale drain timer fires after the app came back"] = s => W(s) && s.a.some(p => p.stale && p.sess === 1) &&
    s.a.map((p, i) => (p.stale && p.sess === 1) ? i : -1).filter(i => i >= 0).map(i =>
      ({ ...s, polled: false, badClose: s.badClose || (truth(s.a[i]) && !s.a[i].excl), a: s.a.map((q, j) => j === i ? { ...q, sess: 0, open: false, last: 0, dl: 0, stale: false } : q) }));
}
actions["manbok stops"] = s => W(s) && ({ ...s, a: s.a.map(p => ({ ...p, sess: 0, open: false, dl: 0, last: 0, stale: false })), worker: false, wdev: 0, failed: false, dgap: 5, abFlow: false, stopped: true });

const draining = (s) => s.a.some(p => p.ever && p.sess !== 0);
const holderDevs = (s) => s.a.filter(p => p.sess === 1 && p.last).map(p => p.last);
const anyTruth = (s) => s.a.some(truth);

export const rules = {
  P1: { says: "after a regular (2 s) poll, while a non-excluded app holds a mic, capture runs after a poll, unless the start failed, the supervisor's restart budget defers the start, or no known device exists",
        holds: s => s.stopped || !(s.polled && s.cad && anyHolder(s) && !s.failed && !s.nodev && !s.deferred) || s.worker },
  P1b: { says: "in the no-known-device case (mic switch + list blip + old mic gone), capture is off for at most one poll, with the restart budget in force, and the open session stays open",
         holds: s => s.stopped || (s.off <= 1 && !s.lostSess) },
  P2a: { says: "an app that never held a mic never gets a session",
         holds: s => s.stopped || s.a.every(p => !p.open || p.ever) },
  P2b: { says: "after a poll, capture running means some app is holding a mic or is draining after holding",
         holds: s => s.stopped || !s.polled || !s.worker || anyTruth(s) || draining(s) },
  P3: { says: `capture stops within ${BSTOP} s of the last non-excluded holder really stopping (awake seconds)`,
        holds: s => s.stopped || !(s.idle > BSTOP && s.worker) },
  Plat: { says: `an app's session is closed within ${BSTOP} s of that app really stopping holding (awake seconds)`,
          holds: s => s.stopped || s.a.every(p => !(p.open && p.idleA > BSTOP)) },
  P4: { says: "while a non-excluded app that the reducer has seen holds a mic and capture runs, that app has an open session after a poll",
        holds: s => s.stopped || s.a.every(p => !(s.polled && trueHolder(p) && p.sess !== 0 && s.worker) || p.open) },
  P5: { says: "the reducer's choice of device (ignoring a restart deferred by the backoff) never favours a draining app's device over a holder's, and never picks a device that no longer exists",
         holds: s => s.stopped || !s.polled || !s.worker || s.deferred || (s.ex[s.wdev - 1] && (holderDevs(s).length === 0 || holderDevs(s).includes(s.wdev))) },
  Cold: { says: "a cold start after idle never inherits a healthy flag (inferred): the first start attempt after demand was empty uses wasFlowing=false",
          holds: s => !s.leak },
  A3: { says: "a mic switch through a no-device poll, restarted within 4 s of the last audio byte, with no start failure, never raises the restart backoff (the A3 promise)",
        holds: s => !s.a3Grew },
  Slow: { says: "a mic switch with no start failure never raises the restart backoff, even when more than 4 s pass between the last audio byte and the new worker start (inferred; the design promises this only for the 'one poll' case)",
          holds: s => !s.slowGrew },
  Cont: { says: "a session is never closed while its app really holds a mic and is not excluded",
          holds: s => !s.badClose },
  Excl: { says: `after an app is excluded, neither its session nor capture for it alone outlasts ${BEX} s`,
          holds: s => s.a.every(p => !(p.excl && p.exAge > BEX && (p.sess !== 0 || p.open))) },
  Idem: { says: "step is idempotent on an unchanged input (same snapshot, same isCapturing, same time)",
          holds: s => [false, true].every(c => {
            const x = stepApps(s.a, c), y = stepApps(x.a, c);
            return JSON.stringify(x.a) === JSON.stringify(y.a);
          }) },
};
// Findings: rules that are expected to break on branch A as written (budget behaviour owned by the supervisor). Off by default so the
// baseline run is a clean pass/fail on the reducer rules; MODEL_FINDINGS=1 adds them (run-findings-*.txt).
if (process.env.MODEL_FINDINGS === "1") {
  rules.ExclNew = { says: "FINDING (expected to break): after an app is excluded it gets no new session (a draining excluded app without a session is given one when capture comes up)", holds: s => !s.newEx };
  rules.P1s = { says: "FINDING (expected to break): P1 without the budget exemption: an arrival start is deferred only after a failed start",
                holds: s => s.stopped || !(s.polled && s.cad && anyHolder(s) && !s.failed && !s.nodev && !(s.deferred && s.taint)) || s.worker };
  rules.P5s = { says: "FINDING (expected to break): the running worker is never on a device that vanished or that only a draining app listed, even when the restart budget defers the switch",
                holds: s => s.stopped || !s.polled || !s.cad || !s.worker || (s.deferred && s.taint) ||
                            (s.ex[s.wdev - 1] && (holderDevs(s).length === 0 || holderDevs(s).includes(s.wdev))) };
} else { delete rules.Slow; }
if (!TIMERS) { delete rules.P3; delete rules.Plat; }
export const canReach = {
  CanIdle: { says: "from any point, capture can end up stopped", goal: s => !s.worker },
};
export const done = s => s.stopped;
export const label = s => s.stopped ? "Stopped" : s.worker ? "Capturing" : "Idle";
