// Order model of manbok's checkpoint save/restore, single instance and shutdown (T1081 M8).
// Variant via env MODEL_VARIANT:
//   current            mirrors the code at fix/T1081-reliability (generations, lock, bounded stop, restore fsyncs the state directory)
//   m-rename-first     mutant: publish (rename) before the files are fsynced
//   m-inplace          mutant: replace ring.pcm / ring.json in place (the pre-B1 layout)
//   m-cleanup-first    mutant: restore deletes all but the highest generation BEFORE it validates and picks
//   m-clear-after-restore  mutant: launch deletes the restored checkpoint (the pre-Q4 behaviour, H18)
//   m-sock-unlink      mutant: a process that fails the lock still unlinks the socket (pre-B2 stale-socket logic)
//   m-nolock           mutant: a process that fails the lock carries on launching (no single instance)
//   m-stop-unbounded   mutant: shutdown waits for stop() with no budget before it saves
//   current-pre-fix    the code before commit 19bc2c8: restore does not fsync the state directory (breaks Q4Keep under power loss: finding F1)
const VARIANT = process.env.MODEL_VARIANT ?? "current";
const SRC = "Sources/ManbokPlatform/";
const MAXL = Number(process.env.MODEL_LAUNCHES ?? 3); // process launches over the whole run
const MAXN = Number(process.env.MODEL_SAVES ?? 3);    // saves started over the whole run (tags 1..MAXN)

export const meta = {
  title: `manbok checkpoint / restore / single instance / shutdown [${VARIANT}]`,
  covers: [
    { file: SRC + "IO/StatePersistenceService.swift", fn: "save", mirrored: true },
    { file: SRC + "IO/StatePersistenceService.swift", fn: "restore", mirrored: true },
    { file: SRC + "IO/StatePersistenceService.swift", fn: "stage", mirrored: true },
    { file: SRC + "Process/SingleInstance.swift", fn: "claim", mirrored: true },
    { file: SRC + "Process/SingleInstance.swift", fn: "acquire", mirrored: true },
    { file: SRC + "Runtime/AppShutdown.swift", fn: "perform", mirrored: true },
  ],
  notModeled: [
    "legacy root files (ring.pcm / ring.json at the state root): covered by unit tests only",
    "file sizes: every non-empty PCM has the size the manifest states (ring full). So the size check cannot tell two saves apart (worst case, H19). Real PCM sizes differ when the ring is not full, which only helps detection",
    "fine-grained power-loss outcomes: per power loss one data outcome (persist / lose = PCM and manifest empty / garbage = PCM garbage, manifest intact) and one name outcome (persist / revert) for ALL unsynced items together. Other mixes (for example PCM intact with manifest lost, which the code detects) are not enumerated",
    "garbage MANIFEST content: a manifest that is empty or garbage fails to decode and is detected, so only PCM garbage is modelled as undetectable",
    "SessionRegistry, the ring and capture (the data is a tag per save); ManbokApp wiring beyond the order claim, restore, bind",
    "IPC protocol (see ../ipc model): the PING answer of a holder is abstracted away, a process that fails the lock exits either way",
    "the 0.1 s delay before exit(0) after STOP: modelled as exit at any time after a perform has finished (crash is possible at every step anyway)",
    "directory mtime, clocks, disk-full beyond one 'write fails' step, permission errors",
    "migration (MigrationService) between claim and restore",
  ],
  assumptions: [
    "kill -9 or a crash keeps everything written (OS page cache survives); only power loss / kernel panic loses unsynced data and unsynced directory operations.",
    "power loss: file data not fsynced is lost (empty files, detected) or the PCM is garbage of the right size while the manifest survives (not detected); renames and unlinks not followed by fsync(dir) are undone together (renamed directory goes back to its tmp name, deleted entries reappear). Both outcomes are possible on APFS; the model takes the worst case.",
    "fsync(file) makes that file's data durable; fsync(dir) makes the directory's names (renames, unlinks) durable.",
    "the stop() inside AppShutdown may hang for ever (H11); the 2 s budget then expires.",
    "a second launch (P1) can happen at any time while the first process (P0) is alive, also while it is starting or shutting down. P0 may restart at any time after it is gone. (P1 is not started when P0 is off: that is P0 starting.)",
    "outside damage to a stored generation never happens between a launch taking the lock and its restore pick (the oracle for the Newest rule is read at the lock).",
  ],
  variant: VARIANT,
};
const RESTORE_FSYNCS = VARIANT !== "current-pre-fix";
export const bounds = { processes: 2, launches: MAXL, saves: MAXN, powerLosses: 1, damage: 1, shutdownRequestsPerProcess: 2, variant: VARIANT };

const clone = (o) => JSON.parse(JSON.stringify(o));
const proc0 = { pc: "off", perf: [], sv: null, req: 0, ch: -1, exp0: 0 };
// fs entry: { k:"g"|"t", seq, tg (tag of the save that created it), pcm, man (0 = empty/missing, else tag), pb (pcm content bad),
//             ps, ms (data fsynced), nd (name durable) }
export const init = {
  fs: [], gh: [], sock: null, holder: null, pr: [proc0, proc0],
  n: 0, launches: 0, powers: 0, damaged: 0, committed: 0, last: -1, startedAt: -1, rx: null, viol: false,
};

const canonFs = (s) => { s.fs.sort((a, b) => JSON.stringify(a) < JSON.stringify(b) ? -1 : 1); s.gh.sort((a, b) => JSON.stringify(a) < JSON.stringify(b) ? -1 : 1); return s; };
const gens = (s) => s.fs.filter((e) => e.k === "g").sort((a, b) => b.seq - a.seq);
const codeValid = (e) => e.pcm > 0 && e.man > 0;                                // what the code can check: both files present, sizes match
const complete = (e) => e.pcm > 0 && e.man > 0 && e.pcm === e.man && !e.pb;    // what the user needs: one save, good bytes
const note = (s, i) => { if (s.holder !== i) s.viol = true; };                  // any state-changing step by a process without the lock
const del = (s, e) => { const idx = s.fs.findIndex((x) => JSON.stringify(x) === JSON.stringify(e)); const [g] = s.fs.splice(idx, 1); if (g.k === "g") s.gh.push(g); return s; };
const delTmp = (s, e) => { const idx = s.fs.findIndex((x) => JSON.stringify(x) === JSON.stringify(e)); s.fs.splice(idx, 1); return s; };

const CLEAN_FIRST = VARIANT === "m-cleanup-first";
const ORDER = VARIANT === "m-inplace" ? ["snap", "wpcm", "wman", "done"]
  : VARIANT === "m-rename-first" ? ["snap", "mkdir", "wpcm", "wman", "rename", "fsyncf", "fsyncd", "del", "done"]
  : ["snap", "mkdir", "wpcm", "wman", "fsyncf", "rename", "fsyncd", "del", "done"];

// Entries a restore removes after it chose `chosenSeq` (null = none chosen): older generations (newest first), then temp dirs.
function stale(s, chosenSeq) {
  const out = [];
  if (chosenSeq !== null) for (const g of gens(s)) if (g.seq < chosenSeq) out.push(g);
  for (const t of s.fs) if (t.k === "t") out.push(t);
  if (VARIANT === "m-clear-after-restore" && chosenSeq !== null) for (const g of gens(s)) if (g.seq === chosenSeq) out.push(g);
  return out;
}

function pick(s, i) {          // StatePersistenceService.restore: newest generation whose files look valid
  const p = s.pr[i];
  const chosen = gens(s).find(codeValid) ?? null;
  const tag = chosen ? chosen.man : 0;
  s.rx = { none: !chosen, pt: chosen ? chosen.pcm : 0, mt: tag, pb: chosen ? chosen.pb : false, exp: p.exp0,
           comm: s.committed, dam: s.damaged > 0, same: s.n === s.startedAt, last: s.last };
  p.ch = chosen ? chosen.seq : null;
  s.last = tag; s.startedAt = s.n;
  if (RESTORE_FSYNCS) { for (const e of s.fs) e.nd = true; s.gh = []; }
  p.pc = CLEAN_FIRST ? "bind" : "clean";
  return s;
}

const actions = {};
for (const i of [0, 1]) {
  const P = `P${i}`;
  const mod = (s, f) => { const n = clone(s); f(n, n.pr[i]); return canonFs(n); };

  actions[`${P} starts`] = (s) => s.pr[i].pc === "off" && s.launches < MAXL && (i === 0 || s.pr[0].pc !== "off")
    ? mod(s, (n, p) => { n.launches++; n.pr[i] = { ...proc0, pc: "claim" }; }) : false;

  actions[`${P} takes the instance lock`] = (s) => s.pr[i].pc === "claim" && s.holder === null
    ? mod(s, (n, p) => { n.holder = i; p.exp0 = Math.max(0, ...n.fs.filter((e) => e.k === "g" && complete(e)).map((e) => e.man)); p.pc = CLEAN_FIRST ? "cleanfirst" : "pick"; }) : false;

  actions[`${P} finds the lock held`] = (s) => {
    if (s.pr[i].pc !== "claim" || s.holder === null) return false;
    if (VARIANT === "m-nolock") return mod(s, (n, p) => { p.exp0 = Math.max(0, ...n.fs.filter((e) => e.k === "g" && complete(e)).map((e) => e.man)); p.pc = CLEAN_FIRST ? "cleanfirst" : "pick"; });
    if (VARIANT === "m-sock-unlink") return mod(s, (n, p) => { note(n, i); n.sock = null; p.pc = "off"; });
    return mod(s, (n, p) => { p.pc = "off"; });  // PING the holder, then exit(0); nothing is touched
  };

  actions[`${P} (cleanup first) removes all but the newest generation`] = (s) => {
    if (s.pr[i].pc !== "cleanfirst") return false;
    return mod(s, (n, p) => {
      note(n, i);
      const gs = gens(n);
      const victim = gs.slice(1)[0] ?? n.fs.find((e) => e.k === "t");
      if (victim) { if (victim.k === "g") del(n, victim); else delTmp(n, victim); } else p.pc = "pick";
    });
  };

  actions[`${P} restores: picks the newest valid generation`] = (s) => s.pr[i].pc === "pick" ? mod(s, (n, p) => { pick(n, i); }) : false;

  actions[`${P} deletes one stale entry after restore`] = (s) => {
    if (s.pr[i].pc !== "clean") return false;
    return mod(s, (n, p) => {
      note(n, i);
      const st = stale(n, p.ch);
      if (st.length === 0) { p.pc = "bind"; return; }
      const v = st[0]; if (v.k === "g") del(n, v); else delTmp(n, v);
    });
  };

  actions[`${P} binds the socket`] = (s) => {
    if (s.pr[i].pc !== "bind") return false;
    return mod(s, (n, p) => {
      note(n, i); n.sock = i;
      if (CLEAN_FIRST) { p.pc = "pickafter"; } else p.pc = "run";
    });
  };
  // m-cleanup-first only: the pick happens after the cleanup, still before the process runs
  actions[`${P} restores after cleanup (cleanup-first)`] = (s) => s.pr[i].pc === "pickafter" ? mod(s, (n, p) => { pick(n, i); p.pc = "run"; }) : false;

  // ---- shutdown: STOP (IPC) or Quit, each is one AppShutdown.perform ----
  actions[`${P} receives a shutdown request`] = (s) => {
    const p = s.pr[i];
    if (p.pc !== "run" || p.perf.length >= 2) return false;
    return [false, true].map((hang) => mod(s, (n, q) => { q.perf.push({ ph: "stop", hang }); }));
  };
  for (const k of [0, 1]) {
    actions[`${P} perform ${k}: stop() returns`] = (s) => s.pr[i].perf[k]?.ph === "stop" && !s.pr[i].perf[k].hang ? mod(s, (n, p) => { p.perf[k].ph = "ready"; }) : false;
    if (VARIANT !== "m-stop-unbounded")
      actions[`${P} perform ${k}: 2 s stop budget expires`] = (s) => s.pr[i].perf[k]?.ph === "stop" ? mod(s, (n, p) => { p.perf[k].ph = "ready"; }) : false;
    actions[`${P} perform ${k}: takes the save lock`] = (s) => {
      const p = s.pr[i];
      if (p.perf[k]?.ph !== "ready" || p.perf.some((x) => x.ph === "saving")) return false;
      return mod(s, (n, q) => { q.perf[k].ph = "saving"; q.sv = { st: 0, tag: 0, seq: 0, k }; });
    };
  }
  actions[`${P} save: next step`] = (s) => {
    const p = s.pr[i];
    if (!p.sv) return false;
    const step = ORDER[p.sv.st];
    const outs = [];
    const adv = (f) => mod(s, (n, q) => { note(n, i); f(n, q); if (q.sv) q.sv.st++; });
    const tmpOf = (n, q) => n.fs.find((e) => e.k === "t" && e.tg === q.sv.tag);
    if (["wpcm", "wman", "fsyncf", "rename"].includes(step) && VARIANT !== "m-inplace" && !s.fs.some((e) => e.tg === p.sv.tag)) {
      // another process's restore removed this save's temporary directory: the next file operation fails, save() throws
      return mod(s, (n, q) => { note(n, i); q.perf[q.sv.k].ph = "done"; q.sv = null; });
    }
    switch (step) {
      case "snap": outs.push(adv((n, q) => { q.sv.tag = ++n.n; q.sv.seq = (gens(n)[0]?.seq ?? 0) + 1; })); break;
      case "mkdir": outs.push(adv((n, q) => { n.fs.push({ k: "t", seq: q.sv.seq, tg: q.sv.tag, pcm: 0, man: 0, pb: false, ps: false, ms: false, nd: false }); })); break;
      case "wpcm":
        if (VARIANT === "m-inplace") outs.push(adv((n, q) => {
          let e = n.fs.find((x) => x.k === "g" && x.seq === 1);
          if (!e) { e = { k: "g", seq: 1, tg: q.sv.tag, pcm: 0, man: 0, pb: false, ps: true, ms: true, nd: true }; n.fs.push(e); }
          e.pcm = q.sv.tag; e.pb = false; }));
        else {
          outs.push(adv((n, q) => { tmpOf(n, q).pcm = q.sv.tag; }));
          outs.push(mod(s, (n, q) => { note(n, i); delTmp(n, tmpOf(n, q)); q.perf[q.sv.k].ph = "done"; q.sv = null; })); // write fails: tmp removed, error logged
        }
        break;
      case "wman": outs.push(adv((n, q) => { const e = VARIANT === "m-inplace" ? n.fs.find((x) => x.k === "g" && x.seq === 1) : tmpOf(n, q); e.man = q.sv.tag; })); break;
      case "fsyncf": outs.push(adv((n, q) => { const e = tmpOf(n, q) ?? n.fs.find((x) => x.k === "g" && x.tg === q.sv.tag); e.ps = true; e.ms = true; })); break;
      case "rename": outs.push(adv((n, q) => { const e = tmpOf(n, q); e.k = "g"; e.nd = false; })); break;
      case "fsyncd": outs.push(adv((n, q) => { for (const e of n.fs) e.nd = true; n.gh = []; })); break;
      case "del": {
        const older = gens(s).find((g) => g.seq < p.sv.seq);
        if (older) outs.push(mod(s, (n, q) => { note(n, i); del(n, older); }));
        else outs.push(adv(() => {}));
        break;
      }
      case "done": outs.push(mod(s, (n, q) => { note(n, i); n.committed = Math.max(n.committed, q.sv.tag); q.perf[q.sv.k].ph = "done"; q.sv = null; })); break;
    }
    return outs;
  };
  actions[`${P} exits after a shutdown`] = (s) => {
    const p = s.pr[i];
    return p.pc === "run" && p.perf.some((x) => x.ph === "done") ? mod(s, (n, q) => { n.pr[i] = { ...proc0 }; if (n.holder === i) n.holder = null; }) : false;
  };
  actions[`${P} is killed (kill -9 or crash)`] = (s) => s.pr[i].pc !== "off"
    ? mod(s, (n) => { n.pr[i] = { ...proc0 }; if (n.holder === i) n.holder = null; }) : false;
}

// Power loss or kernel panic: every process dies; unsynced items follow the chosen outcome.
for (const nameMode of ["persist", "revert"]) for (const dataMode of ["persist", "lose", "garbage"]) {
  actions[`power loss (names ${nameMode}, unsynced data ${dataMode})`] = (s) => {
    if (s.powers >= 1 || (s.pr[0].pc === "off" && s.pr[1].pc === "off" && s.launches === 0)) return false;
    const n = clone(s);
    n.powers++;
    n.fs = n.fs.map((e) => {
      const r = { ...e };
      if (!e.ps) { if (dataMode === "lose") r.pcm = 0; else if (dataMode === "garbage" && r.pcm > 0) r.pb = true; }
      if (!e.ms) { if (dataMode === "lose") r.man = 0; }
      if (e.k === "g" && !e.nd && nameMode === "revert") r.k = "t";
      r.ps = true; r.ms = true; r.nd = true;
      return r;
    });
    if (nameMode === "revert") n.fs.push(...n.gh);
    n.gh = [];
    n.pr = [{ ...proc0 }, { ...proc0 }]; n.holder = null;
    return canonFs(n);
  };
}

// Outside damage to the newest... any generation (bit rot, truncation by another tool): its manifest becomes unreadable.
actions["a generation on disk is damaged (manifest unreadable)"] = (s) => {
  const g = gens(s)[0];
  if (s.damaged >= 1 || !g || s.pr.some((p) => ["pick", "cleanfirst", "pickafter"].includes(p.pc))) return false;
  const n = clone(s); n.damaged = 1;
  n.fs.find((e) => JSON.stringify(e) === JSON.stringify(g)).man = 0;
  return canonFs(n);
};
export { actions };

export const rules = {
  OneSave: { says: "after any crash the next launch restores either nothing or a checkpoint whose PCM and manifest come from one save and whose bytes are intact; never a mismatched pair and never damaged audio",
    holds: (s) => !s.rx || s.rx.none || (s.rx.pt === s.rx.mt && !s.rx.pb) },
  Newest: { says: "the checkpoint a launch restores is the newest complete one on disk at that moment",
    holds: (s) => !s.rx || s.rx.exp === 0 || (!s.rx.none && s.rx.mt === s.rx.exp && s.rx.pt === s.rx.exp && !s.rx.pb) },
  NoRegress: { says: "a launch never restores older than the newest save that had fully finished (unless a stored generation was damaged by outside means)",
    holds: (s) => !s.rx || s.rx.dam || s.rx.mt >= s.rx.comm },
  Q4Keep: { says: "if the app was stopped or lost power after launch with no save started since the previous restore, the next launch restores the same checkpoint again",
    holds: (s) => !s.rx || s.rx.dam || !s.rx.same || s.rx.mt === s.rx.last },
  SecondInstance: { says: "a process that does not hold the instance lock never changes the state directory or the socket, and the running instance's socket stays in place",
    holds: (s) => !s.viol && [0, 1].every((i) => !(s.pr[i].pc === "run" && s.holder === i) || s.sock === i) },
};
export const canReach = {
  ShutdownSaves: { says: "a shutdown whose stop() hangs still reaches its save without any crash: no process stays stuck waiting for stop()",
    goal: (s) => s.pr.every((p) => !p.perf.some((x) => x.ph === "stop")),
    without: ["power loss (names persist, unsynced data persist)", "power loss (names persist, unsynced data lose)", "power loss (names persist, unsynced data garbage)",
              "power loss (names revert, unsynced data persist)", "power loss (names revert, unsynced data lose)", "power loss (names revert, unsynced data garbage)",
              "P0 is killed (kill -9 or crash)", "P1 is killed (kill -9 or crash)"] },
};
export const done = (s) => s.pr.every((p) => p.pc === "off");
export const label = (s) => `fs=${s.fs.map((e) => `${e.k}${e.seq}:${e.pcm}/${e.man}${e.pb ? "!" : ""}`).join(" ")} p=${s.pr.map((p) => p.pc + (p.perf.length ? "[" + p.perf.map((x) => x.ph + (x.hang ? "H" : "")).join(",") + "]" : "")).join("|")}`;
