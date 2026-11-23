import test from 'node:test';
import fs from 'node:fs';
import { section, run } from './lua.mjs';
import { fixture, provider, helpers as tsmHelpers, salesEnvironment, salesAPI } from './tsm-fixture.mjs';

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
${section('local vendorOf\n', '\n-- DEPOSIT PER UNIT')}
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
local function diagnostic() end
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
  + section('function S.noteRevisit(', '\nS.autoChecked =')
  + section('function S.marketReference(', '\nlocal COMMODITY_SNAPSHOT_AGE')
  + section('local function dealLine(', '\n-- TOOLTIP INTELLIGENCE:')
  + fs.readFileSync(new URL('../DepthOptimizer.lua', import.meta.url), 'utf8')
  + section('local COMMODITY_SNAPSHOT_AGE', 'local function prepareCommodityDeal')
  + section('function S.purchaseBudget()', 'local function purchaseAPIAvailable()')
  + section('function S.chooseExit(', '\nlocal function finishPurchase(')
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
  rows={{itemID=123,unitPrice=low,quantity=qty,numOwnerItems=0}}
  if high then rows[#rows+1]={itemID=123,unitPrice=high,quantity=competition,numOwnerItems=0} end
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
end
`;
const covered = `cfg.sales=false; ForeverSniperTSM.sales=function() return {daily=100} end\n`;
function check(body) { run(setup + `ForeverSniperTSM={reference=function() end}\n` + covered + production + helpers + body); }

function tsmCheck(body) { run(setup + fixture + provider + covered + production + helpers + tsmHelpers + body); }

function salesCheck(body) { run(setup + fixture + salesEnvironment + provider + production + helpers + tsmHelpers + salesAPI + body); }

test('sale averages cap existing references but cannot bootstrap regional-only prices', () => {
  salesCheck(`salesFeed(); assert(S.marketReference(123)==nil)
    market(); assert(S.marketReference(123)==9000)
    values.dbregionsaleavg=50000; now=now+31
    assert(S.marketReference(123)==10000)`);
  salesCheck(`salesFeed(); seed(); assert(S.marketReference(123)==9000)`);
});

test('sales data reaches live-tier admission and conservative profit estimates', () => salesCheck(`
  salesFeed(); market(); cfg.sales=false
  observe(6000,10); assert(S.liveCandidates[123] and #admitted==0)
  complete(6000,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified and admitted[1].sweep.profit==25480)
`));

test('only the verified NPC exit can queue and alert without reported AH volume', () => salesCheck(`
  salesFeed(); market(); values.dbregionsoldperday=nil
  vendorOf=function() return 9000 end
  observe(100,10)
  assert(S.liveCandidates[123].kind=='vendor' and #admitted==0 and #db.alerts==0)
  complete(100,10,9000,20)
  assert(#admitted==1 and admitted[1].sweep.units==10 and admitted[1].sweep.profit==89000)
`));

test('a cold vendor table learns the unit payout during discovery and retains the vendor exit over an AH flip', () => salesCheck(`
  salesFeed(); market()
  Enum.TooltipDataLineType={SellPrice=11}
  C_TooltipInfo={GetItemByID=function(id)
    return {id=id,lines={{type=2,price=50000},{type=11,price=1000}}}
  end}
  observe(100,10)
  assert(db.vendorVerified['123']==1000 and S.liveCandidates[123].kind=='vendor')
  complete(100,10,1000,30)
  assert(#admitted==1 and admitted[1].sweep.kind=='vendor' and admitted[1].sweep.profit==9000)
  assert(admitted[1].sweep.kind=='vendor','same-priced competing stock cannot beat NPC after fees')
`));

test('overlap produces a single AH recommendation when a larger eligible lot beats the NPC position', () => salesCheck(`
  salesFeed(); market(); cfg.sales=false; db.vendorVerified={['123']=1000}
  observe(100,10)
  rows={{itemID=123,unitPrice=100,quantity=10},{itemID=123,unitPrice=1200,quantity=5},{itemID=123,unitPrice=8000,quantity=4}}
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
  local sweep=admitted[1].sweep
  assert(#admitted==1 and sweep.kind=='market' and sweep.line==1200 and sweep.units==15 and sweep.cost==7000)
  assert(sweep.exitComparison.npcUnits==10 and sweep.exitComparison.npc==9000 and sweep.exitComparison.net==sweep.profit)
`));

test('ambiguous, foreign, fractional and missing tooltip values do not qualify a vendor flip', () => check(`
  Enum={TooltipDataLineType={SellPrice=11}}
  for _,tip in ipairs({{id=456,lines={{type=11,price=1000}}},{lines={{type=3,price=1000}}},
    {lines={{type=11,price=10.5}}},{lines={{type=11}}}}) do
    now=now+61; C_TooltipInfo={GetItemByID=function() return tip end}
    observe(100,10); assert(not db.vendorVerified and not S.liveCandidates)
  end
`));

test('one copper total vendor profit is admitted despite legacy 50s and AH floors, break-even is not', () => check(`
  cfg.vendorMin=5000; cfg.profit=100000; cfg.tsm=false
  db.vendorVerified={['123']=101}
  observe(101,1); assert(not S.liveCandidates and #admitted==0)
  observe(100,1); complete(100,1,101,7)
  assert(#admitted==1 and admitted[1].sweep.kind=='vendor' and admitted[1].sweep.profit==1)
`));

test('merchant updates learn newly sold stack payouts per unit without waiting to reopen', () => check(`
  local callback
  C_Timer={After=function(_,fn) assert(not callback);callback=fn end}
  GetNumBuybackItems=function() return 0 end
  GetBuybackItemLink=function() return 'item:123' end
  GetBuybackItemInfo=function() return 'cloth',0,900,3 end
  ${section('-- merchant learner:', '\n-- options panel:')}
  function S.vendorVisit() end
  handlers.MERCHANT_SHOW(); callback(); callback=nil
  assert(vendorOf(123)==0)
  GetNumBuybackItems=function() return 1 end
  handlers.MERCHANT_UPDATE(); handlers.MERCHANT_UPDATE(); callback()
  assert(vendorOf(123)==300)
`));

test('wrong-item cheap API tiers cannot admit deals or teach automatic price history', () => salesCheck(`
  market(); S.autoSearch={id=123,t=now}
  S.liveCandidate={id=123,line=7000,market=10000,kind='market',t=now}
  rows={{itemID=456,unitPrice=2,quantity=21,numOwnerItems=0}}
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
  assert(#admitted==0 and not S.commoditySnapshots[123] and not db.book[123])
`));

test('sales commands inspect coverage and validate policy options', () => salesCheck(`
  local function command(rest)
    local cmd='sales'
    ${section('    elseif cmd == "sales" then', '\n    elseif cmd == "tsm" then').replace('elseif cmd', 'if cmd')}
    end
  end
  command('123'); command('rate 10'); command('share 5')
  assert(cfg.saleRate==0.10 and cfg.saleShare==0.05)
  command('share 0'); command('rate 101'); command('nonsense')
  assert(cfg.saleRate==0.10 and cfg.saleShare==0.05)
  command('off'); assert(cfg.sales==false)
  command('on'); assert(cfg.sales==true)
`));

test('TSM admits a first-sighting candidate with an empty book, but only live tiers admit a deal', () => tsmCheck(`
  market(); assert(next(db.book)==nil)
  observe(6500,20); assert(S.liveCandidates[123] and #admitted==0)
  complete(6500,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified and admitted[1].sweep.profit==29970)
`));

test('physical Forever realms find fresh Normal faction feeds on their first sighting', () => tsmCheck(`
  WOW_PROJECT_ID=99; WOW_PROJECT_CAMELOT=99; realm='A physical Forever realm'
  Enum={GameRule={HardcoreRuleset=1,RPRuleset=2,PvPRuleset=3}}
  C_GameRules={IsGameRuleActive=function() return false end}
  market(); observe(6500,20)
  assert(S.liveCandidates[123] and #admitted==0)
  complete(6500,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified)
`));

test('TSM bootstrap still enforces complete results, net profit, stock, budget and overhang', () => {
  for (const change of [
    'C_AuctionHouse.HasFullCommoditySearchResults=function() return false end',
    'cfg.profit=30000','cfg.maxSpend=65000','cfg.maxStock=9','cfg.overhang=9',
  ]) tsmCheck(`market(); observe(6500,20); assert(S.liveCandidates[123])
    ${change}; complete(6500,10,10000,10); assert(#admitted==0)`);
});

test('mature local history caps TSM while missing, stale or disabled TSM preserves local fallback', () => {
  tsmCheck(`market(); seed(); values.dbmarket=20000
    local price,source=S.marketReference(123); assert(price==10000 and source:find('caps TSM'))
    observe(7500,20); assert(not S.liveCandidates)`);
  for (const action of ['TSM_API=nil','market(now-43201)','cfg.tsm=false; market()']) {
    tsmCheck(`seed(); ${action}; assert(S.marketReference(123)==10000)
      observe(6500,20); assert(${action.includes('cfg.tsm=false') ? 'not S.liveCandidates' : 'S.liveCandidates[123]'})`);
  }
});

test('without verified TSM and mature local history the first sighting still only learns', () => {
  for (const action of ['', 'market(now-43201)', 'cfg.tsm=false; market()', 'historical()']) {
    tsmCheck(`${action}; observe(6500,20); assert(not S.liveCandidates and #admitted==0)
      assert(S.gateLog.counts['no fresh market reference']==1 and #db.book[123].s==2)`);
  }
});

test('the first full snapshot also queues TSM candidates before learning its own floor', () => tsmCheck(`
  market(); cfg.quiet=true; db.watch={}; S.scansDone=0; S.scanning=true
  local function err(_,message) error(message) end
  local function after() end
  local function dbg() end
  function S.resumeDeferredDeepScan() end
  C_AuctionHouse.GetNumReplicateItems=function() return 2 end
  C_AuctionHouse.GetReplicateItemInfo=function(i)
    return nil,nil,10,nil,nil,nil,nil,nil,nil,i==1 and 65000 or 100000,
      nil,nil,nil,nil,nil,nil,123,true
  end
  ${section('local function completeScan(', '\n-- Scan engine,')}
  completeScan('test')
  assert(S.scansDone==1 and S.liveCandidates[123] and #admitted==0)
  assert(db.book[123].s[2]==6500)
  complete(6500,10,10000,10); assert(#admitted==1 and admitted[1].sweep.verified)
`));

test('TSM commands inspect a reference and preserve an explicit local-only choice', () => tsmCheck(`
  market()
  local function command(rest)
    local cmd='tsm'
    ${section('    elseif cmd == "tsm" then', '\n    elseif cmd == "batch" then').replace('elseif cmd', 'if cmd')}
    end
  end
  command('123'); assert(S.marketReference(123)==10000)
  command('off'); assert(cfg.tsm==false and S.marketReference(123)==nil)
  command('bad'); assert(cfg.tsm==false)
  command('on'); assert(S.marketReference(123)==10000)
`));

test('every deep-scan page evaluates new rows before learning and still needs live tiers', () => tsmCheck(`
  market(); S.deepScan={rows=0}; local pages=0
  local function deepMore() pages=pages+1 end
  ${section('local function readDeepBrowse(', '\non("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"')}
  rows={{itemKey={itemID=123},minPrice=6500,totalQuantity=20}}
  C_AuctionHouse.GetBrowseResults=function() return rows end
  readDeepBrowse(false)
  assert(S.deepScan.received and S.deepScan.rows==1 and pages==1)
  assert(S.liveCandidates[123] and #admitted==0)
  assert(db.book[123].s[2]==6500)
  readDeepBrowse(true); assert(S.deepScan.rows==1 and S.browseRecorded==1)
  now=now+2; complete(6500,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified)
  assert(S.sweepStats.validationLast==2 and S.sweepStats.validationMax==2)
`));

test('moderate discount flows from summary through real live-depth validation to admission', () => check(`
  seed(); observe(6500,20)
  assert(S.liveCandidates[123] and #admitted==0)
  complete(6500,10,10000,10)
  assert(#admitted==1 and admitted[1].sweep.verified)
  assert(admitted[1].sweep.units==10 and admitted[1].sweep.cost==65000)
  assert(admitted[1].sweep.profit==29970)
`));

test('validation timing separates submitted search response from earlier queue wait', () => check(`
  seed(); observe(6500,20)
  local candidate=S.liveCandidates[123]
  candidate.detectedAt=now-3; candidate.searchStartedAt=now-1
  complete(6500,10,10000,10)
  assert(#admitted==1 and S.sweepStats.validationLast==3)
  assert(S.sweepStats.responseLast==1 and S.sweepStats.responseMax==1)
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
