import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import test from 'node:test';
import { run, section } from './lua.mjs';

test('trace resolves the restored global, bounds history and retains same-second ordering', () => run(`
  local db={diagnostics={}}
  local function time() return 100 end
  ${section('local function push(', '\nlocal function printf(')}
  ForeverSniperTrace={seq=95,records={}}
  for i=1,300 do diagnostic("purchase result","failure "..i) end
  assert(#db.diagnostics==50 and #ForeverSniperTrace.records==250)
  assert(ForeverSniperTrace.records[1].seq==146 and ForeverSniperTrace.records[250].seq==395)
`));

test('reader exports only relevant saved records without modifying the source', t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'forever-trace-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const sv=path.join(dir,'ForeverSniper.lua');
  const data='ForeverSniperDB={book={private="not exported"}}\nForeverSniperTrace={seq=1,records={{seq=1,t=100,domain="purchase result",err="server reported purchase failed"}}}';
  fs.writeFileSync(sv,data);
  const result=spawnSync(process.execPath,['tools/purchase-trace.mjs','--sv',sv],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  const report=JSON.parse(result.stdout);
  assert.equal(report.source,'trace'); assert.equal(report.entries[0].seq,1);
  assert.ok(!result.stdout.includes('not exported')); assert.equal(fs.readFileSync(sv,'utf8'),data);
});

for (const flag of ['--wait-save','--wait-shot']) test(`one-shot watcher ${flag} detects the next file`, {timeout:8000}, async t=>{
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'forever-watch-'));
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
  const dir=path.join(root,'WTF','Account','test','SavedVariables');
  fs.mkdirSync(dir,{recursive:true}); fs.mkdirSync(path.join(root,'Screenshots'));
  const sv=path.join(dir,'ForeverSniper.lua');
  fs.writeFileSync(sv,'ForeverSniperDB={}');
  const child=spawn(process.execPath,['tools/purchase-trace.mjs',flag,'--sv',sv],{stdio:['ignore','pipe','pipe']});
  t.after(()=>child.kill());
  let out='';
  child.stdout.on('data',chunk=>out+=chunk);
  const closed=once(child,'close');
  await once(child.stderr,'data');
  if (flag==='--wait-shot') fs.writeFileSync(path.join(root,'Screenshots','sample.jpg'),'fixture');
  else {
    fs.writeFileSync(sv+'.tmp','ForeverSniperDB={diagnostics={{t=10,domain="purchase request",err="new save"}}}');
    fs.renameSync(sv+'.tmp',sv);
  }
  const [code]=await closed;
  assert.equal(code,0); assert.match(out,flag==='--wait-shot'?/sample\.jpg/:/new save/);
});
