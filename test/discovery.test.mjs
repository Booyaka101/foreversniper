import test from 'node:test';
import fs from 'node:fs';
import { section, run } from './lua.mjs';

const history = section('local HISTORY_SPACING =', '\n-- Item info cache:');
const merge = section('local function mergeIntoBook(', '\n-- FORWARD DECLARATIONS:');
const setup = `
local now=3600
local cfg={enabled=true,threshold=0.7,armAfter=2,minUnit=100,freshMins=45,profit=1000,
  maxSpend=100000,keepGold=0,maxStock=0,quality=1,overhang=500,cut=0.05}
local db={book={},stats={},alerts={},blacklist={},stockLimits={},stockPending={}}
local S={ahOpen=true,commoditySnapshots={},lastAlert={},seen={},sweepStats={},boughtAt={},
  session={spent=0,buys=0},deals={}}
local rows,handlers,admitted={},{},{}
local watchByID={}
local CAPS={samples=30,book=12000,alerts=60}
local function num(v) if type(v)=='number' and v==v and v>-math.huge and v<math.huge then return v end end
local function GetTime() return now end
local function time() return now end
local function GetMoney() return 1000000 end
local function countKeys(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local function sampleCount(s) return math.floor(#s/2) end
local function serverHour() return 12 end
local function vendorOf() return 0 end
local function rebuildWatch() end
local function noteStack() end
local function trackSold() end
local function absorbTrack() end
local function infoOf() return {quality=1,stackable=true} end
local function qualityOf() return 1 end
local function requestItemLoad() end
local function offerKind(_,_,kind) return kind end
local function depositPerUnit() return 2 end
local function printf() end
local function fmtMoney(v) return tostring(v) end
local function isNewListing() return true end
local function push(list,cap,v) list[#list+1]=v end
local function updateExistingDeal() return false end
local function refreshFeed() end
local function renderPopup() end
local function playAlertSound() end
local function tierOf() return 'TEST' end
local function alertDeal(tier,id,link,unit,market,sweep) admitted[#admitted+1]={id=id,sweep=sweep} end
local popupRows={}
local function printPending() end
local function markDealGone() end
local function checkWatchCommodity() end
local function on(event,fn) handlers[event]=fn end
local onOptional=on
function S.wakeSweep() end
local C_AuctionHouse={
  HasFullCommoditySearchResults=function() return true end,
  GetNumCommoditySearchResults=function() return #rows end,
  GetCommoditySearchResultInfo=function(_,i) return rows[i] end,
}
`;
const production = history + merge
  + section('local function dealLine(', '\n-- TOOLTIP INTELLIGENCE:')
  + fs.readFileSync(new URL('../DepthOptimizer.lua', import.meta.url), 'utf8')
  + section('local COMMODITY_SNAPSHOT_AGE', 'local function prepareCommodityDeal')
  + section('function S.purchaseBudget()', 'local function purchaseAPIAvailable()')
  + section('local function recordGate(', '\n-- The scan ')
  + section('local function processBrowseRows(', '\ndo\n    function S.failBatch')
  + section('local function onCommodityResults(', '\non("COMMODITY_PRICE_UPDATED"');
const helpers = `
local function seed()
  db.book[123]={s={1800,10000,1890,10000,1980,10000,2070,10000},lastSeen=2070}
end
local function observe(price,qty)
  processBrowseRows({{itemKey={itemID=123},minPrice=price,totalQuantity=qty}},false,'batch')
end
local function complete(low,qty,high,competition)
  rows={{unitPrice=low,quantity=qty,numOwnerItems=0}}
  if high then rows[#rows+1]={unitPrice=high,quantity=competition,numOwnerItems=0} end
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
end
`;
function check(body) { run(setup + production + helpers + body); }

test('moderate discount flows from summary through real live-depth validation to admission', () => check(`
  seed(); observe(6500,20)
  assert(S.liveCandidates[123] and #admitted==0)
  complete(6500,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified)
  assert(admitted[1].sweep.units==10 and admitted[1].sweep.cost==65000)
  assert(admitted[1].sweep.profit==29970)
`));

test('restored strict threshold still rejects the same moderate discount', () => check(`
  seed(); cfg.threshold=0.5; observe(6500,20)
  assert(not S.liveCandidates and #admitted==0)
  assert(S.gateLog.counts['not cheap enough']==1)
`));

test('broader discovery cannot bypass full results, net profit, budget, stock or overhang', () => {
  for (const change of [
    'C_AuctionHouse.HasFullCommoditySearchResults=function() return false end',
    'cfg.profit=30000', 'cfg.maxSpend=65000',
    'cfg.maxStock=9', 'cfg.overhang=9',
  ]) check(`seed(); observe(6500,20); assert(S.liveCandidates[123])
    ${change}; complete(6500,10,10000,10); assert(#admitted==0)`);
});

test('next live tier caps estimated resale instead of assuming the historical exit', () => check(`
  seed(); cfg.threshold=0.65; observe(6500,20); complete(6500,10,6600,10)
  assert(#admitted==0)
  assert(S.gateSummary.counts['validation: net after competition and deposit below floor']==1)
`));

test('prices above the configured ceiling never reach candidate validation', () => check(`
  seed(); observe(7100,20)
  assert(not S.liveCandidates and #admitted==0)
`));

test('repeat scan rate does not change the number or value of reference observations', () => check(`
  local function learn(step)
    db.book={}; now=1800
    for stamp=1800,3600,step do now=stamp; mergeIntoBook({[123]=10000},now) end
    return db.book[123].s
  end
  local fast,slow=learn(1),learn(10)
  assert(#fast==#slow and #fast==42)
  for i=1,#fast do assert(fast[i]==slow[i]) end
  assert(freshMedian(fast,now,2700,2)==10000)
`));

test('five minutes of repeated low sightings do not erase a time-spaced mature baseline', () => check(`
  now=1800
  for stamp=1800,3300,100 do now=stamp; mergeIntoBook({[123]=10000},now) end
  for stamp=3310,3600,10 do now=stamp; mergeIntoBook({[123]=4000},now) end
  assert(freshMedian(db.book[123].s,now,2700,2)==10000)
  assert(#db.book[123].s<=60)
`));

test('history still adapts to sustained declines and expires without fresh evidence', () => check(`
  seed()
  for stamp=2160,5760,90 do now=stamp; mergeIntoBook({[123]=4000},now) end
  assert(freshMedian(db.book[123].s,now,2700,2)==4000)
  assert(#db.book[123].s==60)
  assert(freshMedian(db.book[123].s,now+2701,2700,2)==nil)
`));

test('dense legacy samples cannot arm a market or outweigh time-spaced observations', () => check(`
  local dense={}
  for stamp=3500,3529 do dense[#dense+1]=stamp; dense[#dense+1]=4000 end
  local med,count=freshMedian(dense,now,2700,2)
  assert(med==nil and count==1)
  local mixed={1800,10000,1890,10000,1980,10000}
  for _,v in ipairs(dense) do mixed[#mixed+1]=v end
  assert(freshMedian(mixed,now,2700,2)==10000)
`));

test('within-interval updates only lower the reference and retain its original age', () => check(`
  now=3500; mergeIntoBook({[123]=10000},now)
  now=3510; mergeIntoBook({[123]=12000},now)
  assert(#db.book[123].s==2 and db.book[123].s[2]==10000)
  now=3520; mergeIntoBook({[123]=8000},now)
  assert(db.book[123].s[1]==3500 and db.book[123].s[2]==8000)
  assert(db.book[123].lastSeen==3520)
  mergeIntoBook({[123]=1000},3515)
  assert(db.book[123].s[2]==8000 and db.book[123].lastSeen==3520)
`));

test('future, expired and unreadable samples do not count as market evidence', () => check(`
  local med,count=freshMedian({1,10000,3601,10000,3500,0,3510,0/0},now,2700,2)
  assert(med==nil and count==0)
`));

test('selection migration retunes only the former default once and records its prior value', () => {
  const init = section('local DEFAULTS =', '\nlocal CAPS =');
  for (const value of [0.5, 0.6, 0.8]) run(`
    local function print() end
    ForeverSniperDB={config={threshold=${value}},tunedClassic=true}
    ${init}
    assert(cfg.threshold==${value === 0.5 ? 0.7 : value})
    assert(db.previousThreshold==${value === 0.5 ? '0.5' : 'nil'})
  `);
  run(`local function print() end
    ForeverSniperDB={config={threshold=0.5},tunedClassic=true,selectionRetuned=true}
    ${init}
    assert(cfg.threshold==0.5)
  `);
});

test('buy action labels distinguish readiness waits from quote and outcome ownership', () => check(`
  local commodityActionState
  local buyFailUntil={}
  local ready,readinessReason=true,nil
  local function commodityFor() return true end
  local function purchaseAPIAvailable() return true end
  local function throttleGate() return ready,readinessReason end
  local function commodityOfferReady() return true end
  ${section('commodityActionState = function(', '\n-- (quickBuy and markDealGone')}
  local function label() return commodityActionState(123,nil,6500,10,65000,10000,'market') end
  assert(label()=='Buy')
  ready=false; assert(label()=='Busy')
  readinessReason='unavailable'; assert(label()=='N/A')
  S.snipePending={}; assert(label()=='Quote')
  S.snipePending.confirmed=true; assert(label()=='Result')
  S.snipePending=nil; db.unsettledPurchase={}; assert(label()=='Lock')
`));

test('readiness updates enable the existing Buy row without waiting for a full feed rebuild', () => check(`
  local ready=false
  local function commodityActionState() return ready and 'Buy' or 'Busy',ready,'live hint' end
  local strupper=string.upper
  local button={fs={SetText=function(self,v) self.text=v end},SetEnabled=function(self,v) self.enabled=v end}
  local row={itemID=123,buyBtn=button,IsShown=function() return true end}
  local feedRows={row}
  ${section('function S.refreshBuyButtons()', '\nlocal function feedTick()')}
  S.refreshBuyButtons(); assert(button.enabled==false and button.fs.text=='BUSY')
  ready=true; S.refreshBuyButtons(); assert(button.enabled==true and button.fs.text=='BUY')
  row.gone=true; S.refreshBuyButtons(); assert(button.enabled==false)
`));
