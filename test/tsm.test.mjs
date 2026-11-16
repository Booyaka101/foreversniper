import test from 'node:test';
import { run } from './lua.mjs';
import { fixture, provider, helpers } from './tsm-fixture.mjs';

function check(body) { run('local now=1000000\n' + fixture + provider + helpers + body); }

test('public price API alone never establishes data freshness', () => check(`
  assert(ForeverSniperTSM.reference(123,now)==nil and calls==0)
  assert(ForeverSniperTSM.status(now):find('missing'))
`));

test('fresh realm market and recent feeds bootstrap with the lower price and historical cap', () => check(`
  market(); recent(); historical(); values.dbhistorical=9000
  local price,source=ForeverSniperTSM.reference(123,now)
  assert(price==9000 and source=='TSM dbhistorical' and calls==3)
  assert(ForeverSniperTSM.status(now):find('verified'))
`));

test('recent feed works without DBMarket coverage; historical-only and region-only cannot bootstrap', () => {
  check(`recent(); values.dbrecent=8000; assert(ForeverSniperTSM.reference(123,now)==8000)`);
  check(`market(); recent(); values.dbmarket=nil; assert(ForeverSniperTSM.reference(123,now)==11000)`);
  check(`historical(); assert(ForeverSniperTSM.reference(123,now)==nil)`);
  check(`feed('AUCTIONDB_REGION_STAT','regionMarketValue',now,'Forever-EU')
    assert(ForeverSniperTSM.reference(123,now)==nil)`);
});

test('wrong faction and realm data never qualify the current character', () => check(`
  market(now,'Normal-Horde'); recent(now,'Other-Alliance')
  assert(ForeverSniperTSM.reference(123,now)==nil and calls==0)
  faction='Horde'; assert(ForeverSniperTSM.reference(123,now)==10000)
  faction='Alliance'; assert(ForeverSniperTSM.reference(123,now)==nil)
`));

test('stale, future and unknown metadata fail closed without evaluating a payload', () => {
  for (const action of [
    'market(now-43201)', 'market(now+1)',
    `observed('AUCTIONDB_NON_COMMODITY_SCAN_STAT','Normal-Alliance','error("do not execute")')`,
    `feed('AUCTIONDB_NON_COMMODITY_SCAN_STAT','unknownField',now)`,
  ]) check(`${action}; assert(ForeverSniperTSM.reference(123,now)==nil and calls==0)`);
});

test('historical cap has an independent 48-hour expiry', () => check(`
  market(); historical(now-172801); values.dbhistorical=100
  assert(ForeverSniperTSM.reference(123,now)==10000 and calls==1)
`));

test('invalid or throwing public prices fall back safely rather than inventing a value', () => {
  for (const value of ['nil','0','-1','0/0','math.huge','"10000"','1.5']) {
    check(`market(); values.dbmarket=${value}; assert(ForeverSniperTSM.reference(123,now)==nil)`);
  }
  check(`market(); TSM_API.GetCustomPriceValue=function() error('not ready') end
    assert(ForeverSniperTSM.reference(123,now)==nil)`);
  check(`market(); TSM_API=nil; assert(ForeverSniperTSM.reference(123,now)==nil)`);
});

test('caching is bounded in time and cannot extend source freshness', () => check(`
  market(now-43199)
  assert(ForeverSniperTSM.reference(123,now)==10000 and calls==1)
  assert(ForeverSniperTSM.reference(123,now)==10000 and calls==1)
  now=now+2; assert(ForeverSniperTSM.reference(123,now)==nil and calls==1)
`));

test('initially missing item prices recover and duplicate feeds cannot renew their timestamp', () => check(`
  market(); values.dbmarket=nil
  assert(ForeverSniperTSM.reference(123,now)==nil)
  values.dbmarket=10000; now=now+5
  assert(ForeverSniperTSM.reference(123,now)==10000)
  now=now+43200; market()
  assert(ForeverSniperTSM.reference(123,now)==nil)
`));

test('missing observer support leaves the provider optional and unavailable', () => run(`
  TSM_API={GetCustomPriceValue=function() return 10000 end}
  ${provider}
  assert(ForeverSniperTSM.reference(123,1000000)==nil)
  assert(ForeverSniperTSM.status(1000000):find('observer unavailable'))
`));

const forever = `
WOW_PROJECT_ID=99; WOW_PROJECT_CAMELOT=99
Enum={GameRule={HardcoreRuleset=1,RPRuleset=2,PvPRuleset=3}}
local activeRules={false,false,false}
C_GameRules={IsGameRuleActive=function(rule) return activeRules[rule] end}
realm='A physical Forever realm'
`;

test('Forever resolves physical realms to the same ruleset markets as TSM', () => {
  for (const [hardcore, rp, pvp, market] of [
    [false,false,false,'Normal'], [false,false,true,'PvP'],
    [false,true,false,'Roleplay'], [false,true,true,'Roleplay PvP'],
    [true,false,false,'Hardcore'], [true,true,true,'Hardcore'],
  ]) check(`${forever}
    activeRules={${hardcore},${rp},${pvp}}
    market(now,'${market}-Alliance')
    assert(ForeverSniperTSM.reference(123,now)==10000)
    assert(ForeverSniperTSM.status(now):find('${market.toLowerCase()}-alliance',1,true))
    faction='Horde'; assert(ForeverSniperTSM.reference(123,now)==nil)
  `);
});

test('Forever never guesses Normal from missing, throwing or unreadable rules', () => {
  for (const failure of [
    'C_GameRules=nil', 'Enum=nil', 'Enum.GameRule.PvPRuleset=nil',
    'C_GameRules.IsGameRuleActive=function() error("not ready") end',
    'C_GameRules.IsGameRuleActive=function() return 0 end',
  ]) check(`${forever} market(); ${failure}
    assert(ForeverSniperTSM.reference(123,now)==nil and calls==0)
    assert(ForeverSniperTSM.status(now):find('identity unavailable'))
  `);
});

test('ruleset changes invalidate scope-specific cached prices and cannot borrow Normal data', () => check(`
  ${forever} market(); assert(ForeverSniperTSM.reference(123,now)==10000)
  activeRules[3]=true
  assert(ForeverSniperTSM.reference(123,now)==nil)
  assert(ForeverSniperTSM.status(now):find('missing for pvp-alliance',1,true))
`));

test('non-Forever clients retain physical realm matching even if ruleset APIs exist', () => check(`
  ${forever} WOW_PROJECT_ID=1
  market(); assert(ForeverSniperTSM.reference(123,now)==nil)
  market(now,realm..'-Alliance'); assert(ForeverSniperTSM.reference(123,now)==10000)
`));

test('status distinguishes stale, future, mismatched and unobserved data', () => {
  check(`market(now-43201); assert(ForeverSniperTSM.status(now):find('stale for normal-alliance',1,true))`);
  check(`market(now+1); assert(ForeverSniperTSM.status(now):find('future-dated',1,true))`);
  check(`market(now,'Other-Horde'); local status=ForeverSniperTSM.status(now)
    assert(status:find('missing for normal-alliance',1,true) and status:find('observed other-horde',1,true))`);
  check(`assert(ForeverSniperTSM.status(now):find('AppHelper may have loaded before observer',1,true))`);
});
