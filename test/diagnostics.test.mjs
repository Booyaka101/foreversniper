import test from 'node:test';
import { section, run } from './lua.mjs';

test('diagnostic chat preserves timing tails while retaining the last-ten-record limit', () => run(`
  local db={errors={},diagnostics={}}
  local lines={}
  local function date() return '11-17 20:54' end
  local function printf(fmt,...) lines[#lines+1]=string.format(fmt,...) end
  ${section('local function printRecordedLog(', '\n-- temporary: trace')}
  for i=1,11 do db.diagnostics[i]={t=i,domain='attempt '..i,err='short'} end
  db.diagnostics[11].err=string.rep('x',180)..'click-to-quote 0.26s; detect-to-quote unknown'
  printRecordedLog(true)
  assert(#lines==11)
  assert(lines[1]:find('attempt 2 --',1,true))
  assert(lines[11]:find('attempt 11 (continued)',1,true))
  assert(lines[11]:find('click-to-quote 0.26s; detect-to-quote unknown',1,true))
`));
