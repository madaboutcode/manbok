#!/usr/bin/env node
// check.mjs: explores every reachable state of an event-order model, reports which rules hold, and
// detects drift between a model (or inputs check) and the code it covers. Node built-ins only, one thread.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const USAGE = `check.mjs: check the order of events in a model, and detect drift from the code it covers.
usage:
  node check.mjs <model.mjs> [--json] [-q] [--all-paths] [--chart FILE] [--max-states N] [--max-mb N]
  node check.mjs --sync <check-file...>      record hashes of covered code (after confirming the model matches it)
  node check.mjs drift <dir|check-file...>   list covered code that changed since the last sync
examples:
  node check.mjs verify/mentions.model.mjs --all-paths --chart verify/mentions.chart.mmd
  node check.mjs drift verify/
exit: 0 every rule holds · 1 a rule breaks · 2 model or usage error · 3 stopped at a cap (not checked) · 130 Ctrl-C`;

class Fail extends Error {}
const fmt = (n) => n.toLocaleString('en-US');
const plural = (n, w) => `${fmt(n)} ${w}${n === 1 ? '' : 's'}`;
const short = (s, n = 100) => (s.length > n ? s.slice(0, n - 1) + '…' : s);

function write(fd, s) {
  const b = Buffer.from(s + '\n');
  for (let o = 0; o < b.length; ) {
    try { o += fs.writeSync(fd, b, o); } catch (e) {
      if (e.code === 'EPIPE') process.exit(0);
      if (e.code !== 'EAGAIN') throw e;
    }
  }
}
const out = (s) => write(1, s);
const err = (s) => write(2, s);

// ---------- hashing covered code ----------
// Returns the index after a string, template literal or comment that starts at i, or -1 if none does.
function skip(s, i) {
  const c = s[i], d = s[i + 1];
  if (c === '/' && d === '/') { const j = s.indexOf('\n', i); return j < 0 ? s.length : j; }
  if (c === '/' && d === '*') {
    const j = s.indexOf('*/', i + 2);
    if (j < 0) throw new Fail('unterminated comment');
    return j + 2;
  }
  if (c === "'" || c === '"') {
    for (i++; i < s.length && s[i] !== c && s[i] !== '\n'; i++) if (s[i] === '\\') i++;
    return i + 1;
  }
  if (c === '`') {
    for (i++; i < s.length && s[i] !== '`'; ) {
      if (s[i] === '\\') i += 2;
      else if (s[i] === '$' && s[i + 1] === '{') i = matchBrace(s, i + 1) + 1;
      else i++;
    }
    return i + 1;
  }
  return -1;
}
function matchBrace(s, i) {
  let depth = 0;
  while (i < s.length) {
    const j = skip(s, i);
    if (j >= 0) { i = j; continue; }
    if (s[i] === '{') depth++;
    else if (s[i] === '}' && --depth === 0) return i;
    i++;
  }
  throw new Fail('braces do not balance');
}
// Source text of function `fn` in JavaScript: from its declaring line to the matching closing brace.
// `fn` may be "Class.method": the method is then searched only inside that class's braces.
export function jsSpan(src, fn) {
  const dot = fn.indexOf('.');
  if (dot > 0) {
    const [cls, method] = [fn.slice(0, dot), fn.slice(dot + 1)];
    const m = new RegExp(`^\\s*(?:export\\s+)?(?:default\\s+)?(?:abstract\\s+)?class\\s+${cls.replace(/[$]/g, '\\$&')}(?![\\w$])`, 'm').exec(src);
    if (!m) throw new Fail(`class \`${cls}\` not found in the file`);
    const open = src.indexOf('{', m.index);
    if (open < 0) throw new Fail(`class \`${cls}\` has no body`);
    let body;
    try { body = src.slice(m.index, matchBrace(src, open) + 1); } catch (e) {
      if (e instanceof Fail) throw new Fail(`braces of class \`${cls}\` do not balance`);
      throw e;
    }
    try { return jsSpan(body.slice(body.indexOf('{') + 1), method); } catch (e) {
      if (e instanceof Fail && /not found in the file$/.test(e.message)) throw new Fail(`method \`${method}\` not found in class \`${cls}\``);
      throw e;
    }
  }
  const n = fn.replace(/[$]/g, '\\$&');
  const decl = [
    `^\\s*(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\s*\\*?\\s*${n}\\s*\\(`,
    `^\\s*(?:(?:static|async|get|set)\\s+|\\*\\s*)*${n}\\s*\\(`,
    `^\\s*(?:export\\s+)?(?:(?:const|let|var)\\s+|this\\.)?${n}\\s*=\\s*(?:async\\s*)?(?:function\\b|\\(|[\\w$]+\\s*=>)`,
  ].map((p) => new RegExp(p));
  let offset = 0;
  for (const line of src.split('\n')) {
    const start = offset;
    offset += line.length + 1;
    if (!decl.some((r) => r.test(line))) continue;
    let i = start, parens = 0;
    while (i < src.length) {
      const j = skip(src, i);
      if (j >= 0) { i = j; continue; }
      const c = src[i];
      if (c === '(' || c === '[') parens++;
      else if (c === ')' || c === ']') parens--;
      else if (c === ';' && parens === 0) break; // a call or a bodyless line, not a declaration
      else if (c === '=' && src[i + 1] === '>' && parens === 0 && !/^\s*\{/.test(src.slice(i + 2, i + 40)))
        throw new Fail(`\`${fn}\` is an arrow function without braces. Add braces, or list the whole file in meta.covers`);
      else if (c === '{' && parens === 0) {
        try { return src.slice(start, matchBrace(src, i) + 1); } catch (e) {
          if (e instanceof Fail) throw new Fail(`braces of \`${fn}\` do not balance. If it contains a regex literal with braces, list the whole file in meta.covers instead`);
          throw e;
        }
      }
      i++;
    }
  }
  throw new Fail(`function \`${fn}\` not found in the file`);
}
// Source text of Python `def fn`: from the def line to the next line indented at or below it.
// `fn` may be "Class.method": the def is then searched only inside that class's indented block.
export function pySpan(src, fn) {
  const dot = fn.indexOf('.');
  if (dot > 0) {
    const [cls, method] = [fn.slice(0, dot), fn.slice(dot + 1)];
    const all = src.split('\n');
    const re = new RegExp(`^(\\s*)class\\s+${cls}\\b`);
    const a = all.findIndex((l) => re.test(l));
    if (a < 0) throw new Fail(`class \`${cls}\` not found (looked for "class ${cls}")`);
    const ind = re.exec(all[a])[1].length;
    let b = a + 1;
    while (b < all.length && (all[b].trim() === '' || all[b].match(/^\s*/)[0].length > ind)) b++;
    try { return pySpan(all.slice(a + 1, b).join('\n'), method); } catch (e) {
      if (e instanceof Fail && /not found/.test(e.message)) throw new Fail(`method \`${method}\` not found in class \`${cls}\` (looked for "def ${method}(")`);
      throw e;
    }
  }
  const lines = src.split('\n');
  const re = new RegExp(`^(\\s*)(?:async\\s+)?def\\s+${fn}\\s*\\(`);
  for (let a = 0; a < lines.length; a++) {
    const m = re.exec(lines[a]);
    if (!m) continue;
    let b = a + 1;
    while (b < lines.length && (lines[b].trim() === '' || lines[b].match(/^\s*/)[0].length > m[1].length)) b++;
    while (lines[b - 1].trim() === '') b--;
    return lines.slice(a, b).join('\n');
  }
  throw new Fail(`function \`${fn}\` not found (looked for "def ${fn}(")`);
}
const hashOf = (text) => crypto.createHash('sha1').update(text.replace(/\r\n/g, '\n')).digest('hex').slice(0, 8);

function findCovered(checkFile, rel) {
  for (let d = path.dirname(path.resolve(checkFile)); ; d = path.dirname(d)) {
    const p = path.join(d, rel);
    if (fs.existsSync(p)) return p;
    if (path.dirname(d) === d) throw new Fail(`covered file "${rel}" not found in or above ${path.dirname(checkFile)}. Fix \`meta.covers\`.`);
  }
}
// { "file#fn" or "file": hash } for every covered item
function coverHashes(checkFile, covers) {
  const h = {};
  for (const c of covers) {
    const p = findCovered(checkFile, c.file);
    const src = fs.readFileSync(p, 'utf8');
    let text = src;
    try {
      if (c.fn && /\.(m?js|cjs|jsx|tsx?|mts)$/.test(p)) text = jsSpan(src, c.fn);
      else if (c.fn && /\.py$/.test(p)) text = pySpan(src, c.fn);
    } catch (e) { if (e instanceof Fail) throw new Fail(`${c.file}: ${e.message}`); throw e; }
    h[c.fn ? `${c.file}#${c.fn}` : c.file] = hashOf(text);
  }
  return h;
}

// ---------- check files, sync records, drift ----------
const isModel = (f) => /\.model\.mjs$/.test(f);
const syncPath = (f) => path.join(path.dirname(f), path.basename(f).replace(/\.(model\.mjs|inputs\.\w+)$/, '').replace(/\.\w+$/, '') + '.sync.json');
const normCovers = (m) => (m.covers || []).map((c) => ({ file: c.file, fn: c.fn, mirrored: !!c.mirrored }));

function headerMeta(file) {
  const text = fs.readFileSync(file, 'utf8').split('\n').slice(0, 80)
    .map((l) => l.replace(/^\s*(?:#+|\/\/+|\/?\*+|"""|''')\s?/, '').replace(/(?:\*\/|"""|''')\s*$/, '')).join('\n');
  const at = text.search(/\bmeta\b[^{\n]*\{/);
  const example = '# meta: {"title": "...", "covers": [{"file": "src/x.py", "fn": "f", "mirrored": false}], "notModeled": [], "assumptions": []}';
  if (at < 0) throw new Fail(`${file} has no \`meta\` in its header comment. Add one line like: ${example}`);
  try { return JSON.parse(text.slice(text.indexOf('{', at), matchBrace(text, text.indexOf('{', at)) + 1)); } catch {
    throw new Fail(`the \`meta\` in the header of ${file} is not valid JSON. Example: ${example}`);
  }
}
async function loadModule(file) {
  if (!fs.existsSync(file)) throw new Fail(`model file not found: ${file}`);
  try { return await import(pathToFileURL(path.resolve(file)).href); } catch (e) {
    throw new Fail(`model file ${file} failed to load: ${e.message}`);
  }
}
// meta, plus rule text hashes for models. Models are imported; other files are only read.
async function loadCheck(file) {
  if (!isModel(file)) return { meta: headerMeta(file), rules: null, mod: null };
  const mod = await loadModule(file);
  const rules = {};
  for (const [k, v] of Object.entries(mod.rules || {})) rules[k] = hashOf(String(v && v.says));
  return { meta: mod.meta || {}, rules, mod };
}
function gitCommit(dir) {
  try { return execFileSync('git', ['-C', dir, 'rev-parse', '--short', 'HEAD'], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); } catch { return null; }
}
function drift(file, covers, rules) {
  const sp = syncPath(file);
  const now = coverHashes(file, covers);
  if (!fs.existsSync(sp)) return { synced: false, commit: null, changed: [], rulesChanged: [], items: Object.keys(now) };
  const rec = JSON.parse(fs.readFileSync(sp, 'utf8'));
  const changed = Object.entries(now).filter(([k, h]) => (rec.covers || {})[k] !== h)
    .map(([k, h]) => ({ item: k, from: (rec.covers || {})[k] || null, to: h }));
  const rulesChanged = rules ? Object.keys({ ...rec.rules, ...rules }).filter((k) => (rec.rules || {})[k] !== rules[k]) : [];
  return { synced: true, commit: rec.commit, syncedAt: rec.syncedAt, changed, rulesChanged, items: Object.keys(now) };
}
const itemName = (k) => (k.includes('#') ? `${k.split('#')[1]}()` : k);
const driftLine = (d) => {
  if (!d.synced) return 'drift   no sync record yet (run --sync once the model matches the code)';
  const ch = d.changed.map((c) => `${itemName(c.item)} changed since sync (hash ${c.from ? c.from.slice(0, 4) : 'new'} → ${c.to.slice(0, 4)})`);
  const rules = d.rulesChanged.length ? `rule text changed: ${d.rulesChanged.join(', ')}` : 'rules unchanged';
  return `drift   ${ch.length ? ch.join('; ') : 'none since sync' + (d.commit ? ` (${d.commit})` : '')}   ${rules}`;
};

async function doSync(files) {
  if (!files.length) throw new Fail('--sync needs one or more check files. Example: node check.mjs --sync verify/mentions.model.mjs');
  for (const f of files) {
    const { meta, rules } = await loadCheck(f);
    const covers = coverHashes(f, normCovers(meta));
    const sp = syncPath(f);
    const rec = fs.existsSync(sp) ? JSON.parse(fs.readFileSync(sp, 'utf8')) : {};
    const next = {
      commit: gitCommit(path.dirname(path.resolve(f))), syncedAt: new Date().toISOString(),
      covers: { ...rec.covers, ...covers }, rules: rules || rec.rules || {},
    };
    fs.writeFileSync(sp, JSON.stringify(next, null, 2) + '\n');
    out(`synced ${f}: ${plural(Object.keys(covers).length, 'covered item')}${rules ? `, ${plural(Object.keys(rules).length, 'rule')}` : ''} → ${sp}`);
  }
  return 0;
}
// A directory yields, recursively and sorted, every *.model.mjs and every source file with a `meta:` header line.
// node_modules and dot-directories are skipped. Other files (a vendored check.mjs, replay scripts) are ignored.
const META_LINE = /^\s*(?:#+|\/\/+|\/?\*+)\s*meta:\s*\{/;
const SOURCE = /\.(?:[cm]?[jt]s|py|sh)$/;
function hasMetaLine(f) {
  try { return fs.readFileSync(f, 'utf8').split('\n', 80).some((l) => META_LINE.test(l)); } catch { return false; }
}
function findChecks(dir) {
  const found = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'node_modules' && !e.name.startsWith('.')) found.push(...findChecks(p)); }
    else if (e.isFile() && (isModel(e.name) || (SOURCE.test(e.name) && hasMetaLine(p)))) found.push(p);
  }
  return found;
}
async function doDrift(args, json) {
  const files = args.flatMap((a) => (fs.existsSync(a) && fs.statSync(a).isDirectory() ? findChecks(a) : [a]));
  if (!files.length) throw new Fail('no check files found. Example: node check.mjs drift verify/');
  const results = [];
  for (const f of files) {
    const { meta, rules } = await loadCheck(f);
    results.push({ file: f, ...drift(f, normCovers(meta), rules) });
  }
  if (json) out(JSON.stringify(results, null, 2));
  else for (const r of results) out(`${r.file}  ${driftLine(r).replace(/^drift\s+/, '')}`);
  return 0;
}

// ---------- the model ----------
function validate(mod, file) {
  const need = (cond, msg) => { if (!cond) throw new Fail(msg); };
  need(mod.rules && typeof mod.rules === 'object', 'model has no `rules` export. Add `export const rules = { Name: { says, holds } }`.');
  need(mod.init !== undefined, 'model has no `init` export. Add `export const init = { ... }` (one state, or an array of states).');
  need(mod.actions && typeof mod.actions === 'object' && Object.keys(mod.actions).length, 'model has no `actions` export. Add `export const actions = { "step in plain words": (state) => nextState | false }`.');
  for (const [k, f] of Object.entries(mod.actions)) need(typeof f === 'function', `action "${k}" is not a function. Write it as (state) => nextState | false.`);
  need(Object.keys(mod.rules).length, 'model `rules` is empty. Add at least one rule.');
  for (const [k, r] of Object.entries(mod.rules)) need(r && typeof r.says === 'string' && typeof r.holds === 'function', `rule "${k}" must be { says: "plain sentence", holds: (state) => bool }.`);
  for (const [k, r] of Object.entries(mod.canReach || {})) {
    need(r && typeof r.says === 'string' && typeof r.goal === 'function', `canReach "${k}" must be { says, goal: (state) => bool, without?: [step labels] }.`);
    for (const w of r.without || []) need(w in mod.actions, `canReach "${k}" lists "${w}" in \`without\`, but no action has that label.`);
  }
  for (const k of ['done', 'label']) need(mod[k] === undefined || typeof mod[k] === 'function', `\`${k}\` must be a function (state) => ${k === 'done' ? 'bool' : 'string'}.`);
  const m = mod.meta || {};
  return { title: m.title || path.basename(file), covers: normCovers(m), notModeled: m.notModeled || [], assumptions: m.assumptions || [], bounds: mod.bounds };
}
// Canonical JSON: sorted keys, so equal states get equal keys.
function canon(v) {
  if (v === null || typeof v === 'string' || typeof v === 'boolean') return JSON.stringify(v);
  if (typeof v === 'number') { if (!Number.isFinite(v)) throw new Fail('state contains NaN or Infinity'); return String(v); }
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  if (typeof v === 'object' && [Object.prototype, null].includes(Object.getPrototypeOf(v)))
    return '{' + Object.keys(v).sort().filter((k) => v[k] !== undefined).map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
  throw new Fail(`state contains a ${typeof v === 'object' ? v.constructor.name : typeof v}; states must be plain JSON values`);
}

// Breadth-first search over the whole reachable space (or until a cap / Ctrl-C).
async function explore(mod, opt, ctl) {
  const labels = Object.keys(mod.actions), fns = labels.map((l) => mod.actions[l]);
  const ruleNames = Object.keys(mod.rules), rules = ruleNames.map((n) => mod.rules[n]);
  const keys = [], index = new Map(), parent = [], pedge = [], depth = [];
  const eFrom = [], eTo = [], eAct = [];
  const broken = ruleNames.map(() => []), deadlocks = [];
  const KEEP = 50; // violating states kept per rule, nearest first (enough for --all-paths)
  const r = { keys, labels, ruleNames, broken, deadlocks, eFrom, eTo, eAct, depth, parent, pedge, complete: false, stop: null };
  const call = (what, ctx, f, ...a) => {
    try { return f(...a); } catch (e) { throw new Fail(`${what} threw ${ctx}: ${e.message}`); }
  };
  const add = (state, from, act) => {
    const ctx = act < 0 ? 'an initial state' : `action "${labels[act]}" on ${short(keys[from])}`;
    let key;
    try { key = canon(state); } catch (e) { if (e instanceof Fail) throw new Fail(`${ctx} returned a bad state: ${e.message}`); throw e; }
    let i = index.get(key);
    if (i === undefined) {
      if (keys.length >= opt.maxStates) { r.stop = 'states'; return -1; }
      i = keys.length;
      index.set(key, i); keys.push(key); parent.push(from < 0 ? -1 : from); pedge.push(eFrom.length); depth.push(from < 0 ? 0 : depth[from] + 1);
      rules.forEach((rule, k) => {
        const ok = call(`rule "${ruleNames[k]}"`, `on state ${short(key)}`, rule.holds, state);
        if (typeof ok !== 'boolean') throw new Fail(`rule "${ruleNames[k]}" returned ${typeof ok} on state ${short(key)}. \`holds\` must return true or false.`);
        if (!ok && broken[k].length < KEEP) broken[k].push(i);
      });
    }
    if (from >= 0) { eFrom.push(from); eTo.push(i); eAct.push(act); }
    return i;
  };
  const inits = Array.isArray(mod.init) ? mod.init : [mod.init];
  inits.forEach((s) => add(s, -1, -1));
  r.initCount = keys.length;
  let q = 0;
  for (; q < keys.length && !r.stop; q++) {
    if (q % 1000 === 999) {
      await new Promise((res) => setImmediate(res));
      if (ctl.interrupted) { r.stop = 'interrupt'; break; }
      if (process.memoryUsage().heapUsed > opt.maxMb * 1048576) { r.stop = 'memory'; break; }
      ctl.progress?.(keys.length, depth[q]);
    }
    let enabled = 0;
    for (let a = 0; a < fns.length && !r.stop; a++) {
      const res = call(`action "${labels[a]}"`, `on state ${short(keys[q])}`, fns[a], JSON.parse(keys[q]));
      if (res === undefined) throw new Fail(`action "${labels[a]}" returned undefined on state ${short(keys[q])}. Return the next state, or false when the step cannot happen.`);
      if (res === false) continue;
      for (const s of Array.isArray(res) ? res : [res]) { enabled++; add(s, q, a); }
    }
    if (!r.stop && !enabled && !(mod.done && call('`done`', `on state ${short(keys[q])}`, mod.done, JSON.parse(keys[q])))) {
      if (deadlocks.length < KEEP) deadlocks.push(q);
    }
  }
  r.complete = !r.stop && q >= keys.length;
  r.depthMax = depth.reduce((m, d) => Math.max(m, d), 0);
  return r;
}

// Reverse adjacency in compact arrays: for state s, the edge ids whose target is s.
function reverseEdges(r, skipActs = new Set()) {
  const n = r.keys.length, start = new Int32Array(n + 1);
  const use = [];
  r.eTo.forEach((t, e) => { if (!skipActs.has(r.eAct[e])) { use.push(e); start[t + 1]++; } });
  for (let i = 0; i < n; i++) start[i + 1] += start[i];
  const fill = start.slice(0, n), list = new Int32Array(use.length);
  for (const e of use) list[fill[r.eTo[e]]++] = e;
  return { start, list };
}
// Paths from an initial state to `target`: [{states:[idx...], steps:[label...]}], shortest first.
function pathsTo(r, rev, target, limit) {
  const found = [], seen = new Set();
  let visits = 0;
  const walk = (s, states, steps) => {
    if (found.length >= limit || visits++ > 200000) return;
    if (r.depth[s] === 0) {
      const st = [s, ...states], sp = [...steps];
      const id = st[0] + '|' + sp.join('|');
      if (!seen.has(id)) { seen.add(id); found.push({ states: st, steps: sp }); }
      return;
    }
    for (let k = rev.start[s]; k < rev.start[s + 1]; k++) {
      const e = rev.list[k];
      if (r.depth[r.eFrom[e]] === r.depth[s] - 1) walk(r.eFrom[e], [s, ...states], [r.labels[r.eAct[e]], ...steps]);
    }
  };
  walk(target, [], []);
  return found;
}
function firstPath(r, target) {
  const states = [], steps = [];
  for (let s = target; s >= 0; s = r.parent[s]) {
    states.unshift(s);
    if (r.parent[s] >= 0) {
      steps.unshift(r.labels[r.eAct[r.pedge[s]]]);
    }
  }
  return { states, steps };
}

function evaluate(mod, r, opt) {
  const rev = opt.allPaths ? reverseEdges(r) : null;
  const pathsFor = (targets) => {
    if (!opt.allPaths) return [firstPath(r, targets[0])];
    const all = [];
    for (const t of targets) { all.push(...pathsTo(r, rev, t, 5 - all.length)); if (all.length >= 5) break; }
    return all;
  };
  const verdict = (name, says, bad, builtin) => {
    if (bad.length) return { name, says, status: 'breaks', paths: pathsFor(bad), builtin };
    return { name, says, status: r.complete ? 'holds' : 'not checked', paths: [], builtin };
  };
  const rules = r.ruleNames.map((n, k) => verdict(n, mod.rules[n].says, r.broken[k]));
  rules.push(verdict('NoDeadlock', 'the system never gets stuck with nothing left to do', r.deadlocks, true));
  const canReach = Object.entries(mod.canReach || {}).map(([name, c]) => {
    if (!r.complete) return { name, says: c.says, status: 'not checked', paths: [] };
    const rv = reverseEdges(r, new Set((c.without || []).map((w) => r.labels.indexOf(w))));
    const ok = new Uint8Array(r.keys.length), queue = [];
    r.keys.forEach((k, i) => { if (c.goal(JSON.parse(k))) { ok[i] = 1; queue.push(i); } });
    for (let h = 0; h < queue.length; h++) {
      for (let k = rv.start[queue[h]]; k < rv.start[queue[h] + 1]; k++) {
        const f = r.eFrom[rv.list[k]];
        if (!ok[f]) { ok[f] = 1; queue.push(f); }
      }
    }
    const bad = [];
    for (let i = 0; i < ok.length && bad.length < 50; i++) if (!ok[i]) bad.push(i);
    return verdict(name, c.says, bad);
  });
  return { rules, canReach };
}

// ---------- chart ----------
function mermaid(mod, r, results, file) {
  const desc = (i) => (mod.label ? String(mod.label(JSON.parse(r.keys[i]))) : `S${i}`).replace(/["\n;]/g, (c) => (c === '"' ? "'" : c === ';' ? ',' : ' '));
  const ids = new Map(), id = (i) => { const d = desc(i); if (!ids.has(d)) ids.set(d, 'n' + ids.size); return ids.get(d); };
  const arrows = new Set();
  for (let i = 0; i < r.initCount; i++) arrows.add(`[*] --> ${id(i)}`);
  r.eFrom.forEach((f, e) => arrows.add(`${id(f)} --> ${id(r.eTo[e])}: ${r.labels[r.eAct[e]].replace(/[\n;]/g, ' ')}`));
  const hot = new Set();
  for (const x of [...results.rules, ...results.canReach]) if (x.status === 'breaks') for (const s of x.paths[0].states) hot.add(id(s));
  const lines = ['stateDiagram-v2', ...[...ids].map(([d, n]) => `    state "${d}" as ${n}`), ...[...arrows].map((a) => '    ' + a)];
  if (hot.size) lines.push('    classDef breaks fill:#fdd,stroke:#c00,color:#600', `    class ${[...hot].join(',')} breaks`);
  fs.writeFileSync(file, lines.join('\n') + '\n');
  return { states: ids.size, arrows: arrows.size - r.initCount };
}

// ---------- report ----------
const STOP = {
  states: (o) => `search stopped at the cap of ${fmt(o.maxStates)} states. Lower the model's bounds, or raise --max-states`,
  memory: (o) => `search stopped at the memory cap of ${o.maxMb} MB. Lower the model's bounds, or raise --max-mb`,
  interrupt: () => 'search stopped by Ctrl-C',
};
function render(mod, info, r, results, opt, secs, chart, fancy) {
  const all = [...results.rules, ...results.canReach];
  const nBroken = all.filter((x) => x.status === 'breaks').length;
  const c = (code, s) => (fancy ? `\x1b[${code}m${s}\x1b[0m` : s);
  const mark = { breaks: fancy ? c(31, '✗') : 'breaks ', holds: fancy ? c(32, '✓') : 'holds  ', 'not checked': fancy ? c(33, '?') : 'not checked' };
  const desc = (i) => {
    const s = JSON.parse(r.keys[i]);
    return short(mod.label ? String(mod.label(s)) : JSON.stringify(s));
  };
  const L = [];
  for (const x of all) {
    if (opt.quiet && x.status !== 'breaks') continue;
    L.push(`${mark[x.status]} ${x.name}  ${x.says}`);
    x.paths.forEach((p, k) => {
      if (x.paths.length > 1) L.push(`    path ${k + 1} of ${x.paths.length}`);
      if (r.initCount > 1) L.push(`    start: ${desc(p.states[0])}`);
      if (!p.steps.length) L.push('    already true at the start');
      p.steps.forEach((s, n) => L.push(`    ${n + 1}. ${s}`));
      L.push(`    ends in: ${desc(p.states[p.states.length - 1])}`);
    });
  }
  if (r.stop) L.push(`${c(33, 'not checked')}  ${STOP[r.stop](opt)}`);
  if (!opt.quiet) {
    if (mod.bounds) L.push(`bounds  ${Object.entries(mod.bounds).map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ')}`);
    if (info.assumptions.length) L.push(`assumes  ${info.assumptions.join(' · ')}`);
    L.push(`not modeled  ${info.notModeled.length ? info.notModeled.join(' · ') : '(nothing listed)'}`);
    if (chart) L.push(`chart  ${opt.chart} (${plural(chart.states, 'state')}, ${plural(chart.arrows, 'arrow')})${chart.arrows > 20 ? ' · dense: use coarser label() names for a readable picture' : ''}`);
    const stats = `${fmt(r.keys.length)} states · depth ${r.depthMax} · ${secs.toFixed(1)} s`;
    const head = nBroken ? `${nBroken} of ${all.length} rules break${r.stop ? ', the rest not checked' : ''}`
      : r.stop ? 'not checked' : `${all.length} rules hold`;
    L.push(`${head} · ${stats}`);
  }
  return L;
}
function exitCode(results, r, interrupted) {
  if (interrupted) return 130;
  if ([...results.rules, ...results.canReach].some((x) => x.status === 'breaks')) return 1;
  return r.stop ? 3 : 0;
}

async function doCheck(file, opt) {
  const mod = await loadModule(file);
  const info = validate(mod, file);
  const dr = drift(file, info.covers, Object.fromEntries(Object.entries(mod.rules).map(([k, v]) => [k, hashOf(v.says)])));
  const fancy = process.stdout.isTTY && !process.env.NO_COLOR;
  if (!opt.json) {
    out(info.title);
    const mirrored = info.covers.filter((x) => x.mirrored).map((x) => (x.fn ? `${x.fn}()` : x.file));
    const byFile = new Map();
    for (const x of info.covers) byFile.set(x.file, [...(byFile.get(x.file) || []), x.fn ? `${x.fn}()` : '']);
    if (!opt.quiet) out(`covers  ${[...byFile].map(([f, fns]) => [f, ...fns].filter(Boolean).join(' ')).join(' · ') || '(none)'}${mirrored.length ? `   hand-mirrored: ${mirrored.join(', ')}` : ''}`);
    out(driftLine(dr));
  }
  const ctl = { interrupted: false };
  process.once('SIGINT', () => { ctl.interrupted = true; });
  let last = Date.now();
  ctl.progress = (n, d) => { if (Date.now() - last > 2000) { last = Date.now(); err(`exploring: ${fmt(n)} states so far, depth ${d}`); } };
  const t0 = Date.now();
  const r = await explore(mod, opt, ctl);
  const results = evaluate(mod, r, opt);
  const secs = (Date.now() - t0) / 1000;
  const chart = opt.chart ? mermaid(mod, r, results, opt.chart) : null;
  const code = exitCode(results, r, ctl.interrupted);
  if (opt.json) {
    const pick = (x) => ({ name: x.name, says: x.says, status: x.status, path: x.paths[0]?.steps || [], ...(x.paths.length > 1 ? { paths: x.paths.map((p) => p.steps) } : {}) });
    out(JSON.stringify({
      title: info.title, states: r.keys.length, depth: r.depthMax, bounds: mod.bounds || {}, exit: code, stopped: r.stop,
      seconds: secs, drift: dr, rules: results.rules.map(pick), canReach: results.canReach.map(pick),
      notModeled: info.notModeled, assumptions: info.assumptions, chart: chart ? { file: opt.chart, ...chart } : null,
    }, null, 2));
  } else {
    render(mod, info, r, results, opt, secs, chart, fancy).forEach(out);
    if (!opt.quiet) out(`exit ${code}`);
  }
  return code;
}

function parseArgs(argv) {
  const o = { maxStates: 200000, maxMb: 256, rest: [] };
  const num = (flag, v) => {
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0) throw new Fail(`${flag} needs a positive number, for example ${flag} 1000`);
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    let a = argv[i], v;
    if (a.startsWith('--') && a.includes('=')) [a, v] = [a.slice(0, a.indexOf('=')), a.slice(a.indexOf('=') + 1)];
    const val = () => { if (v !== undefined) return v; if (i + 1 >= argv.length) throw new Fail(`${a} needs a value`); return argv[++i]; };
    if (a === '--json') o.json = true;
    else if (a === '-q' || a === '--quiet') o.quiet = true;
    else if (a === '--all-paths') o.allPaths = true;
    else if (a === '--sync') o.sync = true;
    else if (a === '-h' || a === '--help') o.help = true;
    else if (a === '--chart') o.chart = val();
    else if (a === '--max-states') o.maxStates = num(a, val());
    else if (a === '--max-mb') o.maxMb = num(a, val());
    else if (a.startsWith('-') && a !== '-') throw new Fail(`unknown option ${a}. Run with no arguments for usage.`);
    else o.rest.push(a);
  }
  return o;
}

async function main(argv) {
  try { os.setPriority(19); } catch { /* not allowed here; run at normal priority */ }
  if (!argv.length) { err(USAGE); return 2; }
  const o = parseArgs(argv);
  if (o.help) { out(USAGE); return 0; }
  if (o.sync) return doSync(o.rest);
  if (o.rest[0] === 'drift') return doDrift(o.rest.slice(1), o.json);
  if (o.rest.length !== 1) throw new Fail('give exactly one model file. Example: node check.mjs verify/area.model.mjs');
  return doCheck(o.rest[0], o);
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
    if (e instanceof Fail) err(`error: ${e.message}`);
    else err(`${e.stack}\nthis is a check.mjs bug`);
    process.exit(2);
  });
}
