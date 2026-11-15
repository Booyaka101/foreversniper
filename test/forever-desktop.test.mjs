import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { assertGameClosed, buildBriefing, resolveSavedVariables, updateBriefing } from '../tools/forever-desktop.mjs';
import { luaSequence, parseSavedVariables, toLua } from '../tools/savedvariables.mjs';

const closed = () => '"System","4","Services","0","120 K"\r\n';
const fixture = `ForeverSniperDB = {
  ["stats"] = { ["sales"] = 2, ["realized"] = 10000, },
  ["book"] = {
    [123] = {
      ["s"] = { 1700000000, 10000, 1700000060, 20000, },
      ["v"] = { 20, 40, },
    },
  },
}\n`;

function sandbox(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'foreversniper-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const sv = path.join(root, 'ForeverSniper.lua');
  fs.writeFileSync(sv, fixture);
  return { root, sv };
}

test('parses WoW scalar arrays, indexed tables, comments and escaped strings', () => {
  const parsed = parseSavedVariables(`-- header\nDB = { samples = { 1, 2, -3.5e2, }, [0] = true, text = "a\\n\\t\\034b", } -- end`);
  const db = parsed.get('DB').value;
  assert.deepEqual(luaSequence(db.samples), [1, 2, -350]);
  assert.equal(db[0], true);
  assert.equal(db.text, 'a\n\t"b');
  assert.deepEqual(luaSequence(parseSavedVariables('DB = {[1] = 8, [2] = 9}').get('DB').value), [8, 9]);
});

test('serializer round-trips control characters, quotes and hostile object keys', () => {
  const object = JSON.parse('{"__proto__":{"safe":true},"quote\\\"key":"value"}');
  object.text = 'x\r\n\t\x001"\\';
  const result = parseSavedVariables('DB = ' + toLua(object)).get('DB').value;
  assert.equal(result.text, object.text);
  assert.equal(result['quote"key'], 'value');
  assert.equal(result.__proto__.safe, true);
  assert.equal(Object.getPrototypeOf(result), null);
  assert.throws(() => toLua(Infinity), /non-finite/);
});

test('rejects truncated, malformed or executable input instead of repairing it', () => {
  for (const input of ['DB = {', 'DB = "unterminated', 'DB = {[1 = 3}', 'DB = {a 3}', 'DB = {1 2}', 'DB = 1e999', 'DB = os.execute("bad")', 'DB = {}\nDB = {}', 'DB = {x="\\999"}']) {
    assert.throws(() => parseSavedVariables(input), undefined, input);
  }
});

test('detects live, beta and Classic clients case-insensitively', () => {
  assert.doesNotThrow(() => assertGameClosed(closed));
  for (const exe of ['Wow.exe', 'WowB.exe', 'WoWClassic.exe', 'WowClassicB.exe', 'WowClassicT.exe', 'WowT.exe']) {
    assert.throws(() => assertGameClosed(() => closed() + `"${exe}","123","Console","1","100 K"`), /WoW is running/);
  }
});

test('process detection fails closed, and force is not a supported override', () => {
  assert.throws(() => assertGameClosed(() => { throw new Error('tasklist failed'); }), /Cannot verify/);
  for (const output of ['', 'ERROR: access denied', 'not a process list']) {
    assert.throws(() => assertGameClosed(() => output), /Unrecognized/);
  }
  for (const args of [['--force'], ['--sv'], ['--sv', '--force'], ['--unknown', 'x']]) {
    assert.throws(() => resolveSavedVariables(args), /Usage:/);
  }
});

test('discovers live Forever accounts and refuses ambiguous selection', t => {
  const { root, sv } = sandbox(t);
  const accountPath = account => path.join(root, '_forever_', 'WTF', 'Account', account, 'SavedVariables', 'ForeverSniper.lua');
  const first = accountPath('first');
  fs.mkdirSync(path.dirname(first), { recursive: true });
  fs.writeFileSync(first, fixture);
  assert.equal(resolveSavedVariables(['--wow-root', root]), first);
  const second = accountPath('second');
  fs.mkdirSync(path.dirname(second), { recursive: true });
  fs.writeFileSync(second, fixture);
  assert.throws(() => resolveSavedVariables(['--wow-root', root]), /select an account/);
  assert.equal(resolveSavedVariables(['--sv', sv]), sv);
});

test('briefing uses actual Lua price and velocity samples', () => {
  const db = parseSavedVariables(fixture).get('ForeverSniperDB').value;
  const lines = buildBriefing(db, { book: { 123: { s: [1700000000, 10000] } } });
  assert.ok(lines.some(line => line.includes('RISING +100% -> 2g0s0c')));
  assert.ok(lines.some(line => line.includes('item 123 (30s)')));
  assert.ok(lines.some(line => line.includes('not confirmed sales')));
});

test('updates only briefing, preserves database bytes, backs up and saves per-account history', t => {
  const { sv, root } = sandbox(t);
  const lines = updateBriefing(sv, { listProcesses: closed, log() {} });
  const output = fs.readFileSync(sv, 'utf8');
  assert.ok(output.endsWith(fixture));
  assert.equal(fs.readFileSync(sv + '.desktop-bak', 'utf8'), fixture);
  const briefing = parseSavedVariables(output).get('ForeverSniperBriefing').value;
  assert.deepEqual(luaSequence(briefing.lines), lines);
  assert.ok(briefing.built < 1e11, 'timestamps use seconds, not milliseconds');
  assert.deepEqual(JSON.parse(fs.readFileSync(sv + '.desktop-state.json', 'utf8')).book['123'].s, [1700000060, 20000]);
  assert.ok(!fs.readdirSync(root).some(file => /desktop-(tmp|lock)$/.test(file)));
});

test('replaces compact or CRLF briefings without accumulating duplicate globals', t => {
  const { sv } = sandbox(t);
  fs.writeFileSync(sv, 'ForeverSniperBriefing = { lines = {"old"}, built = 1 }\r\n' + fixture);
  for (let i = 0; i < 2; i++) updateBriefing(sv, { listProcesses: closed, log() {} });
  const output = fs.readFileSync(sv, 'utf8');
  assert.equal((output.match(/ForeverSniperBriefing =/g) || []).length, 1);
  assert.ok(output.endsWith(fixture));
  assert.equal(parseSavedVariables(output).size, 2);
});

test('malformed input and a running game leave SavedVariables untouched', t => {
  const { sv, root } = sandbox(t);
  for (const raw of ['ForeverSniperDB = {', fixture]) {
    fs.writeFileSync(sv, raw);
    const listProcesses = raw === fixture ? () => '"Wow.exe","12","Console","1","100 K"' : closed;
    assert.throws(() => updateBriefing(sv, { listProcesses, log() {} }));
    assert.equal(fs.readFileSync(sv, 'utf8'), raw);
    assert.deepEqual(fs.readdirSync(root), ['ForeverSniper.lua']);
  }
});

test('aborts if WoW starts or the source changes during briefing generation', t => {
  const { sv, root } = sandbox(t);
  for (const change of ['start', 'edit']) {
    fs.writeFileSync(sv, fixture);
    let calls = 0;
    const listProcesses = () => {
      if (++calls === 2) {
        if (change === 'start') return '"Wow.exe","12","Console","1","100 K"';
        fs.writeFileSync(sv, fixture + '-- external change\n');
      }
      return closed();
    };
    assert.throws(() => updateBriefing(sv, { listProcesses, log() {} }), change === 'start' ? /WoW is running/ : /changed during analysis/);
    assert.equal(fs.readFileSync(sv, 'utf8'), fixture + (change === 'edit' ? '-- external change\n' : ''));
    assert.deepEqual(fs.readdirSync(root), ['ForeverSniper.lua']);
  }
});

test('an existing helper lock prevents concurrent writers without removing their lock', t => {
  const { sv } = sandbox(t);
  fs.writeFileSync(sv + '.desktop.lock', 'owned by another helper');
  assert.throws(() => updateBriefing(sv, { listProcesses: closed, log() {} }), /EEXIST/);
  assert.equal(fs.readFileSync(sv, 'utf8'), fixture);
  assert.equal(fs.readFileSync(sv + '.desktop.lock', 'utf8'), 'owned by another helper');
});

test('the addon declares the briefing global as SavedVariables', () => {
  const toc = fs.readFileSync(new URL('../ForeverSniper.toc', import.meta.url), 'utf8');
  assert.match(toc, /^## SavedVariables:.*\bForeverSniperBriefing\b/m);
});
