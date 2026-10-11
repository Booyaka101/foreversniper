#!/usr/bin/env node
// ForeverDesktop - the outside-WoW half of the money machine (TSM AppHelper-style).
// Legal architecture: ONLY reads/writes the SavedVariables file on disk, ONLY
// while the game is closed. Never touches the game process, memory, or network
// game traffic. The file boundary is the same one TSM's desktop app uses.
//
// Usage: node forever-desktop.mjs [--sv <path>] [--force]
//   Reads ForeverSniperDB, computes the overnight briefing (realized sales,
//   market movers, volatility leaders, anomalies), writes it back as
//   ForeverSniperBriefing for the addon to print at next login.

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const DEFAULT_SV = 'D:/WoW/World of Warcraft/_classic_beta_/WTF/Account/301703346#1/SavedVariables/ForeverSniper.lua';
const args = process.argv.slice(2);
const force = args.includes('--force');
const svIdx = args.indexOf('--sv');
const svPath = svIdx >= 0 ? args[svIdx + 1] : DEFAULT_SV;
const statePath = path.join(import.meta.dirname, '.desktop-state.json');

// ---- tiny Lua-value parser (enough for SavedVariables shape) ----------------
function parseLua(src) {
  let i = 0;
  function skipWs() { while (i < src.length && /\s/.test(src[i])) i++; }
  function parseValue() {
    skipWs();
    const c = src[i];
    if (c === '{') return parseTable();
    if (c === '"') return parseString();
    const numMatch = /^-?[\d.eE+]+/.exec(src.slice(i));
    if (numMatch) { i += numMatch[0].length; return Number(numMatch[0]); }
    if (src.startsWith('true', i)) { i += 4; return true; }
    if (src.startsWith('false', i)) { i += 5; return false; }
    if (src.startsWith('nil', i)) { i += 3; return null; }
    throw new Error(`parse error at ${i}: ${src.slice(i, i + 30)}`);
  }
  function parseString() {
    i++; // opening quote
    let out = '';
    while (i < src.length && src[i] !== '"') {
      if (src[i] === '\\') { out += src[i + 1]; i += 2; }
      else out += src[i++];
    }
    i++; // closing
    return out;
  }
  function parseTable() {
    i++; // {
    const t = {};
    skipWs();
    while (i < src.length && src[i] !== '}') {
      skipWs();
      if (src[i] === '[') {
        i++;
        skipWs();
        let key;
        if (src[i] === '"') key = parseString();
        else {
          const m = /^-?\d+/.exec(src.slice(i));
          key = Number(m[0]); i += m[0].length;
        }
        skipWs(); i++; // ]
        skipWs(); i++; // =
        t[String(key)] = parseValue();
      } else if (src[i] === '{') {
        // array-part entry (no key): {\n{...},\n{...}\n}
        t[nextIdx(t)] = parseValue();
      } else {
        // bare-key form: name = value
        const m = /^[A-Za-z_]\w*/.exec(src.slice(i));
        if (!m) throw new Error(`bad key at ${i}`);
        const key = m[0]; i += key.length;
        skipWs(); i++; // =
        t[key] = parseValue();
      }
      skipWs();
      if (src[i] === ',') i++;
      skipWs();
    }
    i++; // }
    return t;
  }
  function nextIdx(t) {
    let n = 1;
    while (t[n] !== undefined) n++;
    return n;
  }
  const v = parseValue();
  return v;
}

// ---- money formatting --------------------------------------------------------
function money(c) {
  c = Math.floor(c || 0);
  const g = Math.floor(c / 10000), s = Math.floor((c % 10000) / 100), cc = c % 100;
  if (g > 0) return `${g}g${s}s${cc}c`;
  if (s > 0) return `${s}s${cc}c`;
  return `${cc}c`;
}

// ---- the briefing ------------------------------------------------------------
function buildBriefing(db, prev) {
  const lines = [];
  const st = db.stats || {};
  lines.push(`overnight report: ${(st.deals || 0)} deals flagged lifetime, ${(st.sales || 0)} sales, ${money(st.realized || 0)} realized.`);
  if ((st.vendorDeals || 0) > 0) lines.push(`vendor flips: ${st.vendorDeals} worth ${money(st.vendorProfit || 0)}. undercuts answered: ${st.undercuts || 0}, cancels fired: ${st.cancels || 0}.`);

  const book = db.book || {};
  const ids = Object.keys(book);
  lines.push(`book: ${ids.length} items learned.`);

  // market movers vs the last desktop run
  if (prev && prev.book) {
    const movers = [];
    for (const id of ids) {
      const b = book[id];
      if (!b || !b.s || b.s.length < 4) continue;
      const now = b.s[b.s.length - 1];
      const was = prev.book[id] && prev.book[id].s && prev.book[id].s.length >= 2
        ? prev.book[id].s[prev.book[id].s.length - 1] : null;
      if (!was || was <= 0) continue;
      const change = (now - was) / was;
      if (Math.abs(change) >= 0.25) movers.push({ id, change, now });
    }
    movers.sort((a, b2) => Math.abs(b2.change) - Math.abs(a.change));
    for (const m of movers.slice(0, 5)) {
      const dir = m.change > 0 ? 'RISING' : 'FALLING';
      lines.push(`${dir} ${m.change > 0 ? '+' : ''}${Math.round(m.change * 100)}% -> ${money(m.now)} (item ${m.id})`);
    }
  }

  // volatility leaders (flippability board)
  const vols = [];
  for (const id of ids) {
    const b = book[id];
    if (!b || !b.v || b.v.length === 0) continue;
    const avg = b.v.reduce((x, y) => x + y, 0) / b.v.length;
    vols.push({ id, avg });
  }
  vols.sort((a, b2) => a.avg - b2.avg);
  if (vols.length > 0) {
    const hot = vols.slice(0, 3).map(v => `item ${v.id} (${Math.round(v.avg)}s)`).join(', ');
    lines.push(`fastest absorbers: ${hot} - buy every dip on these.`);
  }

  // hour anomaly scan: current server-hour buckets vs other hours
  const nowHour = new Date().getHours();
  for (const id of ids.slice(0, 500)) {
    const b = book[id];
    if (!b || !b.h || !b.h[nowHour]) continue;
    const cur = b.h[nowHour];
    if ((cur.n || 0) < 5) continue;
    let otherSum = 0, otherN = 0;
    for (const [h, bucket] of Object.entries(b.h)) {
      if (Number(h) === nowHour || !bucket || !bucket.n) continue;
      otherSum += bucket.sum; otherN += bucket.n;
    }
    if (otherN < 10) continue;
    const curAvg = cur.sum / cur.n, otherAvg = otherSum / otherN;
    if (otherAvg > 0 && curAvg < otherAvg * 0.5) {
      lines.push(`hour anomaly: item ${id} trades ${Math.round((1 - curAvg / otherAvg) * 100)}% under its usual - time to buy.`);
      break; // one is enough for a briefing
    }
  }
  return lines;
}

// ---- lua serializer for the briefing ----------------------------------------
function toLua(v) {
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'boolean') return String(v);
  if (typeof v === 'number') return String(v);
  if (typeof v === 'string') return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
  if (Array.isArray(v)) return '{\n' + v.map(x => toLua(x)).join(',\n') + ',\n}';
  const parts = Object.entries(v).map(([k, val]) => `["${k}"] = ${toLua(val)}`);
  return '{\n' + parts.join(',\n') + ',\n}';
}

// ---- main --------------------------------------------------------------------
let wowRunning = false;
try {
  const out = execSync('tasklist /FI "IMAGENAME eq WowB.exe" 2>nul', { encoding: 'utf8', shell: 'cmd.exe' });
  wowRunning = /WowB\.exe/i.test(out);
} catch { /* tasklist may fail; assume not running */ }

if (wowRunning && !force) {
  console.log('WoW is RUNNING - the file would be clobbered on logout. Close the game first (or --force).');
  process.exit(1);
}

if (!fs.existsSync(svPath)) {
  console.log('SavedVariables not found:', svPath);
  process.exit(1);
}

const raw = fs.readFileSync(svPath, 'utf8');
const m = raw.match(/^ForeverSniperDB\s*=\s*/m);
if (!m) { console.log('No ForeverSniperDB in file.'); process.exit(1); }
const db = parseLua(raw.slice(m.index + m[0].length));

let prev = null;
if (fs.existsSync(statePath)) {
  try { prev = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { /* fresh */ }
}

const lines = buildBriefing(db, prev);
console.log('--- briefing ---');
lines.forEach(l => console.log(' ' + l));

// backup, then write the briefing into the SV file
fs.copyFileSync(svPath, svPath + '.desktop-bak');
const briefingBlock = `ForeverSniperBriefing = ${toLua({ lines, built: Date.now() })}\n\n`;
let out;
const bm = raw.match(/^ForeverSniperBriefing\s*=\s*\{[\s\S]*?\n\}\n/m);
if (bm) out = raw.replace(bm[0], briefingBlock);
else out = briefingBlock + raw;
fs.writeFileSync(svPath, out, 'utf8');

// persist state for next run's movers (item -> last seen price)
const state = { book: {} };
for (const [id, b] of Object.entries(db.book || {})) {
  if (b && b.s && b.s.length >= 2) state.book[id] = { s: [b.s[b.s.length - 2], b.s[b.s.length - 1]] };
}
fs.writeFileSync(statePath, JSON.stringify(state));
console.log(`briefing written (${lines.length} lines), state saved, backup at ${svPath}.desktop-bak`);
