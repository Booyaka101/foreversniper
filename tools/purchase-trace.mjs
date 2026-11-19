// Read WoW's last completed save. Never load it as executable code.
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { resolveSavedVariables } from './forever-desktop.mjs';
import { luaSequence, parseSavedVariables } from './savedvariables.mjs';

const { values } = parseArgs({options:{
  sv:{type:'string'}, 'wow-root':{type:'string'}, 'wait-save':{type:'boolean'}, 'wait-shot':{type:'boolean'},
}});
const file = resolveSavedVariables(Object.entries(values).filter(([k]) => !k.startsWith('wait-'))
  .flatMap(([k,v]) => [`--${k}`,v]));
function report() {
  const globals = parseSavedVariables(fs.readFileSync(file,'utf8'));
  const db = globals.get('ForeverSniperDB')?.value;
  if (!db) throw new Error('No completed ForeverSniperDB save found.');
  const trace = globals.get('ForeverSniperTrace')?.value;
  const entries = luaSequence(trace?.records ?? db.diagnostics).filter(r => /^(boot|purchase|remainder|prebuy|commodity result)/.test(r.domain));
  console.log(JSON.stringify({savedAt:fs.statSync(file).mtime.toISOString(),source:trace?'trace':'legacy', entries,
    recentPurchases:luaSequence(db.purchases).slice(-10).map(({t,id,units,total,source})=>({t,id,units,total,source})),
    unsettled:db.unsettledPurchase ? {id:db.unsettledPurchase.deal?.id,units:db.unsettledPurchase.units,
      attempt:db.unsettledPurchase.attempt,reason:db.unsettledPurchase.reason} : null},null,2));
}
if (values['wait-shot']) {
  if (values['wait-save']) throw new Error('Choose one wait mode.');
  const dir = path.resolve(path.dirname(file),'../../../..','Screenshots');
  const existing = new Set(fs.readdirSync(dir));
  let settle;
  const watcher = fs.watch(dir,()=>{
    clearTimeout(settle);
    settle = setTimeout(()=>{
      const candidates = fs.readdirSync(dir).filter(name => !existing.has(name) && /\.(jpg|jpeg|png|tga)$/i.test(name));
      if (!candidates.length) return;
      clearTimeout(timer); watcher.close();
      // WoW names all screenshots alike; inspect the overlay before attribution.
      for (const name of candidates) console.log('New game screenshot (verify failure overlay):',path.join(dir,name));
    },500);
  });
  const timer = setTimeout(()=>{clearTimeout(settle);watcher.close(); console.error('No new screenshot within 10 minutes.');process.exitCode=1;},600000);
  console.error('Watching for the next local game screenshot.');
} else if (!values['wait-save']) report();
else {
  // watchFile survives WoW replacing the file. Retry incomplete saves on the
  // next change, and always release the watcher after one report or ten minutes.
  const timer = setTimeout(()=>{fs.unwatchFile(file); console.error('No readable new save within 10 minutes.'); process.exitCode=1;},600000);
  fs.watchFile(file,{interval:500},(curr,prev)=>{
    if (!curr.size || curr.mtimeMs===prev.mtimeMs && curr.size===prev.size) return;
    try { report(); } catch { return; }
    clearTimeout(timer); fs.unwatchFile(file);
  });
  console.error('Watching for the next readable SavedVariables save.');
}
