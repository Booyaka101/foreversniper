import test from 'node:test';
import { section, run } from './lua.mjs';

const setup = `
local now, visible, renders = 100, true, 0
local timers, order = {}, {}
local S = {commoditySnapshots={}}
local feedDirty, feedLastRefresh, feedRefreshWake = false, 0, nil
local feedFrame = {IsShown=function() return visible end}
local FEED_ROWS, TIERS = 1, {}
local function widget()
  return {SetText=function() end,SetTexture=function() end,SetTextColor=function() end,
    SetShown=function() end,SetEnabled=function() end}
end
local row = {Show=function() end,Hide=function() end}
for _,key in ipairs({'name','icon','price','market','pct','tier','profit','newBadge','action','buyBtn','sellBtn'}) do
  row[key]=widget()
end
row.buyBtn.fs=widget()
local feedRows={row}
local function GetTime() return now end
local function time() return now end
local function after(delay,fn) timers[#timers+1]={at=now+delay,fn=fn} end
local function advance(target)
  local steps=0
  while timers[1] and timers[1].at<=target do
    local timer=table.remove(timers,1)
    now=timer.at; timer.fn(); steps=steps+1
    assert(steps<10,'unbounded redraw timers')
  end
  now=target
end
local function collectDealGroups() renders=renders+1; return order end
local function infoOf() return {name='Material'} end
local function fmtMoney(value) return tostring(value) end
local function strupper(value) return string.upper(value) end
local function commodityActionState() return 'Buy',true,'' end
local function feedOverview() return '','' end
`;
const production = section('local function refreshFeed()', '\n-- Deferred redraws own their deadline');
function check(body) { run(setup + production + body); }

test('a throttled deal renders at the quarter-second deadline without another scanner event', () => check(`
  refreshFeed(); assert(renders==1)
  now=100.1
  order={{id=123,units=10,cost=100,line=10}}
  refreshFeed(); assert(row.itemID==nil and renders==1)
  advance(100.25)
  assert(row.itemID==123 and renders==2, 'validated deal must not wait for the two-second scan tick')
`));

test('redraw bursts coalesce without moving the original deadline', () => check(`
  refreshFeed()
  for i=1,20 do now=100+i/100; refreshFeed() end
  assert(#timers==1)
  advance(100.25)
  assert(renders==2 and #timers==0 and not feedDirty)
`));

test('a hidden feed stays dirty without redrawing or scheduling a timer loop', () => check(`
  refreshFeed(); now=100.1; refreshFeed()
  visible=false
  advance(100.25)
  assert(renders==1 and feedDirty and #timers==0)
  visible=true; refreshFeed()
  assert(renders==2 and not feedDirty)
`));

test('an intervening redraw makes its old deferred callback harmless', () => check(`
  refreshFeed(); now=100.1; refreshFeed()
  local old=table.remove(timers,1)
  now=100.3; refreshFeed()
  now=100.35; refreshFeed()
  old.fn()
  assert(renders==2 and #timers==1)
  advance(100.55)
  assert(renders==3 and #timers==0)
`));

test('feed timing records the first eligible row submission without resetting validation', () => check(`
  local timing={validatedAt=99.5}
  S.commoditySnapshots[123]={timing=timing}
  order={{id=123,units=10,cost=100,line=10}}
  refreshFeed()
  assert(timing.feedRenderedAt==100 and timing.validatedAt==99.5)
  now=101; refreshFeed(); assert(timing.feedRenderedAt==100)
`));

test('hidden, unready and retired rows do not claim an eligible feed-render time', () => {
  for (const change of [
    'visible=false', 'commodityActionState=function() return "Load",false,"" end',
    'order[1].gone=true', 'order[1].bought=true', 'order={}',
  ]) check(`
    local timing={validatedAt=99.5}
    S.commoditySnapshots[123]={timing=timing}
    order={{id=123,units=10,cost=100,line=10}}
    ${change}; refreshFeed(); assert(not timing.feedRenderedAt)
  `);
});
