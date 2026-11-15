#!/usr/bin/env node
// ForeverDesktop - the outside-WoW half of the money machine (TSM AppHelper-style).
// Legal architecture: ONLY reads/writes the SavedVariables file on disk, ONLY
// while the game is closed. Never touches the game process, memory, or network
// game traffic. The file boundary is the same one TSM's desktop app uses.
//
// Usage: node forever-desktop.mjs [--sv <path>] [--wow-root <path>]
//   Reads ForeverSniperDB, computes the overnight briefing (realized sales,
//   market movers, volatility leaders, anomalies), writes it back as
//   ForeverSniperBriefing for the addon to print at next login.

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { luaSequence, parseSavedVariables, toLua } from './savedvariables.mjs';

const DEFAULT_WOW_ROOT = 'D:/WoW/World of Warcraft';

// ---- money formatting --------------------------------------------------------
function money(c) {
  c = Math.floor(c || 0);
  const g = Math.floor(c / 10000), s = Math.floor((c % 10000) / 100), cc = c % 100;
  if (g > 0) return `${g}g${s}s${cc}c`;
  if (s > 0) return `${s}s${cc}c`;
  return `${cc}c`;
}

// ---- the briefing ------------------------------------------------------------
export function buildBriefing(db, prev) {
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
      const samples = luaSequence(b?.s);
      if (samples.length < 4) continue;
      const now = samples[samples.length - 1];
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
    const velocities = luaSequence(b?.v);
    if (velocities.length === 0) continue;
    const avg = velocities.reduce((x, y) => x + y, 0) / velocities.length;
    vols.push({ id, avg });
  }
  vols.sort((a, b2) => a.avg - b2.avg);
  if (vols.length > 0) {
    const hot = vols.slice(0, 3).map(v => `item ${v.id} (${Math.round(v.avg)}s)`).join(', ');
    lines.push(`fastest observed listing disappearances: ${hot}. Disappearances are not confirmed sales.`);
  }

  // The addon records date("*t").hour, so use the same local-clock hour.
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
      lines.push(`hour anomaly: item ${id} was listed ${Math.round((1 - curAvg / otherAvg) * 100)}% under its usual. Recheck live prices before buying.`);
      break; // one is enough for a briefing
    }
  }
  return lines;
}

export function assertGameClosed(listProcesses = () => {
  if (process.platform !== 'win32') throw new Error('Process detection requires Windows');
  return execFileSync('tasklist.exe', ['/FO', 'CSV', '/NH'], { encoding: 'utf8', timeout: 10000 });
}) {
  let output;
  try { output = listProcesses(); }
  catch { throw new Error('Cannot verify WoW is closed. No files were written.'); }
  if (!/^"[^"\r\n]+","\d+",/m.test(output)) {
    throw new Error('Unrecognized process list. No files were written.');
  }
  if (/^"Wow(?:B|T|Classic(?:B|T)?)?\.exe",/im.test(output)) {
    throw new Error('WoW is running. Close all WoW clients before updating SavedVariables.');
  }
}

export function resolveSavedVariables(args) {
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i];
    if (!['--sv', '--wow-root'].includes(key) || !args[i + 1] || args[i + 1].startsWith('--') || options[key]) {
      throw new Error('Usage: node tools/forever-desktop.mjs [--sv <path>] [--wow-root <path>]. No force override is supported.');
    }
    options[key] = args[i + 1];
  }
  if (options['--sv']) return path.resolve(options['--sv']);
  const accounts = path.join(options['--wow-root'] || DEFAULT_WOW_ROOT, '_forever_', 'WTF', 'Account');
  const candidates = fs.readdirSync(accounts, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(accounts, entry.name, 'SavedVariables', 'ForeverSniper.lua'))
    .filter(file => fs.existsSync(file));
  if (candidates.length !== 1) throw new Error('Expected one ForeverSniper SavedVariables file. Run the addon and log out first, or select an account with --sv <path>.');
  return candidates[0];
}

export function updateBriefing(svPath, { listProcesses, log = console.log } = {}) {
  assertGameClosed(listProcesses);
  const lockPath = svPath + '.desktop.lock';
  const lock = fs.openSync(lockPath, 'wx');
  const tempPath = svPath + '.desktop-tmp';
  const statePath = svPath + '.desktop-state.json';
  let tempCreated = false;
  try {
    const raw = fs.readFileSync(svPath, 'utf8');
    const assignments = parseSavedVariables(raw);
    const db = assignments.get('ForeverSniperDB')?.value;
    if (!db || typeof db !== 'object') throw new Error('No valid ForeverSniperDB table in file.');
    let prev = null;
    if (fs.existsSync(statePath)) {
      try { prev = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { /* start with fresh history */ }
    }
    const lines = buildBriefing(db, prev);
    const block = `ForeverSniperBriefing = ${toLua({ lines, built: Math.floor(Date.now() / 1000) })}`;
    const old = assignments.get('ForeverSniperBriefing');
    const out = old ? raw.slice(0, old.start) + block + raw.slice(old.end) : block + '\n\n' + raw;
    fs.writeFileSync(tempPath, out, { encoding: 'utf8', flag: 'wx' });
    tempCreated = true;
    // A helper lock cannot stop WoW starting. Recheck immediately before commit.
    assertGameClosed(listProcesses);
    if (fs.readFileSync(svPath, 'utf8') !== raw) throw new Error('SavedVariables changed during analysis. Retry with WoW closed.');
    fs.writeFileSync(svPath + '.desktop-bak', raw, 'utf8');
    fs.renameSync(tempPath, svPath);
    tempCreated = false;
    const state = { book: Object.create(null) };
    for (const [id, b] of Object.entries(db.book || {})) {
      const samples = luaSequence(b?.s);
      if (samples.length >= 2) state.book[id] = { s: samples.slice(-2) };
    }
    fs.writeFileSync(statePath, JSON.stringify(state));
    lines.forEach(line => log(line));
    log(`Briefing written (${lines.length} lines). Backup: ${svPath}.desktop-bak`);
    return lines;
  } finally {
    if (tempCreated) fs.unlinkSync(tempPath);
    fs.closeSync(lock);
    fs.unlinkSync(lockPath);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try { updateBriefing(resolveSavedVariables(process.argv.slice(2))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
