import test from 'node:test';
import { run } from './lua.mjs';
import { fixture, provider, salesEnvironment, salesAPI } from './tsm-fixture.mjs';

function check(body) { run('local now=1000000\n' + fixture + salesEnvironment + provider + salesAPI + body); }

test('sales use only verified Forever regional sale feeds and preserve decimal API values', () => check(`
  salesFeed(); values.dbregionsoldperday=123.456
  local data=ForeverSniperTSM.sales(123,now)
  assert(data.average==9000 and data.rate==0.25 and math.abs(data.daily-123.456)<0.0001)
  assert(data.region=='forever-eu' and data.stamp==now and calls==3)
`));

test('known zero liquidity is preserved instead of becoming missing data', () => check(`
  salesFeed(); values.dbregionsalerate=0; values.dbregionsoldperday=0
  local data=ForeverSniperTSM.sales(123,now)
  assert(data.rate==0 and data.daily==0)
`));

test('unknown fields never become zero liquidity or invented average prices', () => check(`
  salesFeed(); values.dbregionsaleavg=nil; values.dbregionsalerate=nil
  local data=ForeverSniperTSM.sales(123,now)
  assert(data.average==nil and data.rate==nil and data.daily==1000)
`));

test('missing, stale and future sales metadata never enables public API queries', () => {
  for (const action of ['', 'salesFeed(now-172801)', 'salesFeed(now+1)',
    `salesFeed(now,'Other-EU')`, `salesFeed(now,'Forever-US')`,
    `observed('AUCTIONDB_REGION_SALE','Forever-EU','return {downloadTime='..now..',fields={"regionSale"},data={}}')`,
  ]) check(`${action}; assert(ForeverSniperTSM.sales(123,now)==nil and calls==0)`);
});

test('hardcore and regional scope cannot borrow a normal region cached result', () => check(`
  salesFeed(); assert(ForeverSniperTSM.sales(123,now))
  hardcore=true; assert(ForeverSniperTSM.sales(123,now)==nil)
  salesFeed(now,'Forever-HC-EU'); assert(ForeverSniperTSM.sales(123,now).region=='forever-hc-eu')
  portal='US'; assert(ForeverSniperTSM.sales(123,now)==nil)
`));

test('unknown region and non-Forever clients cannot infer sale-feed identity', () => {
  for (const action of [`portal='public-test'`, 'WOW_PROJECT_ID=1', 'C_GameRules=nil']) {
    check(`salesFeed(); ${action}; assert(ForeverSniperTSM.sales(123,now)==nil and calls==0)`);
  }
});

test('invalid values and API failures remain unknown', () => {
  for (const invalid of ['0','-1','0/0','math.huge','"1000"','1.5']) check(`
    salesFeed(); TSM_API.GetCustomPriceValue=function() return ${invalid} end
    assert(ForeverSniperTSM.sales(123,now)==nil)
  `);
  check(`salesFeed(); TSM_API.GetCustomPriceValue=function() error('not ready') end
    assert(ForeverSniperTSM.sales(123,now)==nil)`);
  check(`salesFeed(); values.dbregionsalerate=1.1
    assert(ForeverSniperTSM.sales(123,now).rate==nil)`);
});

test('sales cache cannot outlive source freshness and missing coverage recovers', () => {
  check(`salesFeed(now-172799); assert(ForeverSniperTSM.sales(123,now))
    assert(ForeverSniperTSM.sales(123,now) and calls==3)
    now=now+2; assert(ForeverSniperTSM.sales(123,now)==nil and calls==3)`);
  check(`salesFeed(); values={}; assert(ForeverSniperTSM.sales(123,now)==nil)
    values.dbregionsaleavg=9000; now=now+5
    assert(ForeverSniperTSM.sales(123,now).average==9000)`);
});
