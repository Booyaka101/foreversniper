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
