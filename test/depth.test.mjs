import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import fengari from 'fengari';
import { source, section, run } from './lua.mjs';
import { fixture, provider, salesEnvironment, salesAPI } from './tsm-fixture.mjs';

const optimizer = fs.readFileSync(new URL('../DepthOptimizer.lua', import.meta.url), 'utf8');

const setup = `
local now, wallet, held, deposit = 100, 100000, 0, 2
local cfg = {enabled=true, keepGold=0, maxSpend=100000, maxStock=0, profit=1, cut=0.05,
    quality=1, overhang=0, vendorMin=1, freshMins=45}
local db = {stockLimits={}, stockPending={}, blacklist={}, book={}}
local S = {ahOpen=true, sellingOwnedUpdated=100, commoditySnapshots={}, boughtAt={},
    session={spent=0,buys=0}, deals={}}
local owned, rows, handlers = {}, {}, {}
local calls = {start=0, confirm=0}
local C_Item = {GetItemCount=function() return held end}
local C_AuctionHouse = {
    GetNumOwnedAuctions=function() return #owned end,
    GetOwnedAuctionInfo=function(i) return owned[i] end,
    HasFullCommoditySearchResults=function() return true end,
    GetNumCommoditySearchResults=function() return #rows end,
    GetCommoditySearchResultInfo=function(_,i) return rows[i] end,
    StartCommoditiesPurchase=function(...)
        calls.start=calls.start+1; calls.startArgs={...}
    end,
    ConfirmCommoditiesPurchase=function(...)
        calls.confirm=calls.confirm+1; calls.confirmArgs={...}
    end,
    SupportsCopperValues=function() return true end,
    CancelCommoditiesPurchase=function() end,
}
local C_Timer = {After=function() end}
local function GetMoney() return wallet end
local function GetTime() return now end
local function time() return now end
local function num(v)
    if type(v)=="number" and v==v and v>-math.huge and v<math.huge then return v end
end
local function infoOf() return {quality=1,stackable=true} end
local function commodityFor() return true end
local function requestItemLoad() end
local function offerKind(_,_,kind) return kind end
local function depositPerUnit() return deposit end
local function printf() end
local function err() end
local function fmtMoney(v) return tostring(v) end
local function push(list,cap,record) list[#list+1]=record end
local function freshMedian() return 100 end
local function dealLine() return 20 end
local function throttleGate() return true end
local function prepareCommodityDeal() end
local function purchaseAPIAvailable() return true end
local function markDealGone() end
local function recordGate() end
local diagnostics = {}
local function diagnostic(domain,message) diagnostics[#diagnostics+1]={domain=domain,message=message} end
local function printPending() end
local function renderPopup() end
local function checkWatchCommodity() end
local captured
local function fireAlert(kind,id,link,first,market,sweep)
    captured={kind=kind,id=id,market=market,sweep=sweep}
end
local buyFailUntil = {}
local quickBuy
function S.offerAvailable() return true end
function S.refreshPurchasePresentation() end
function S.wakeSweep() end
local function retirePurchase() S.snipePending=nil end
local function purchaseDetails(p) return p.deal.id,p.units,p.total end
local function on(event,fn) handlers[event]=fn end
local onOptional=on
local function snapshot(tiers)
    rows={}
    for _,tier in ipairs(tiers) do rows[#rows+1]={itemID=123,unitPrice=tier.price,quantity=tier.quantity,numOwnerItems=0} end
    S.commoditySnapshots[123]={tiers=tiers,t=now}
    return S.commoditySnapshots[123]
end
`;
const production = optimizer
  + section('function S.noteRevisit(', '\nS.autoChecked =')
  + section('local COMMODITY_SNAPSHOT_AGE', 'local function prepareCommodityDeal')
  + section('function S.purchaseBudget()', 'local function purchaseAPIAvailable()')
  + section('local function finishPurchase(p, source)', '\nmarkDealGone =')
  + section('quickBuy = function(r)', '\n-- KEY BINDINGS:')
  + section('local function onCommodityResults(itemID)', '\non("COMMODITY_PRICE_UPDATED"')
  + section('on("COMMODITY_PRICE_UPDATED", function', '\n-- merchant learner:');
const prepared = `
local function offer()
    snapshot({{price=10,quantity=10},{price=100,quantity=1}})
    quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind="market",t=100})
end
`;
function check(body) { run(setup + `cfg.sales=false; ForeverSniperTSM={sales=function() return {daily=100} end}\n` + production + prepared + body); }

function salesCheck(body) {
  run(setup + fixture.replace(/\bcalls\b/g, 'apiCalls') + salesEnvironment + provider
    + production + prepared + salesAPI.replace(/\bcalls\b/g, 'apiCalls') + body);
}

test('purchase start sends the native price argument for the observed Mageweave lot', () => check(`
  local saved=snapshot({{price=123,quantity=20},{price=413,quantity=103},{price=414,quantity=417}})
  S.commoditySnapshots[4338]=saved
  for _,row in ipairs(rows) do row.itemID=4338 end
  quickBuy({itemID=4338,line=123,units=20,cost=2460,market2=413,kind='market'})
  assert(calls.start==1 and #calls.startArgs==3)
  assert(calls.startArgs[1]==4338 and calls.startArgs[2]==20 and calls.startArgs[3]==123)
  assert(S.snipePending.tolTotal==2460 and S.snipePending.maxUnit==123)
  local message
  for _,entry in ipairs(diagnostics) do if entry.domain=='purchase request' then message=entry.message end end
  assert(message and message:find('item 4338 x20; request unit 123 copper; expected total 2460 copper',1,true))
  handlers.COMMODITY_PRICE_UPDATED(413,8260)
  assert(calls.confirm==0 and not S.snipePending)
`));

test('mixed-tier start uses the rounded-up average rather than the line or highest tier', () => check(`
  snapshot({{price=10,quantity=2},{price=12,quantity=1},{price=100,quantity=1}})
  quickBuy({itemID=123,line=15,units=3,cost=32,market2=100,kind='market'})
  assert(calls.start==1 and calls.startArgs[3]==11)
  assert(S.snipePending.tolTotal==32 and S.snipePending.maxUnit==15)
  handlers.COMMODITY_PRICE_UPDATED(11,33)
  assert(calls.confirm==0 and not S.snipePending, 'rounding must not increase the approved total')
`));

test('native price rounding respects clients without copper prices', () => check(`
  C_AuctionHouse.SupportsCopperValues=function() return false end
  snapshot({{price=100,quantity=2},{price=200,quantity=1},{price=1000,quantity=1}})
  quickBuy({itemID=123,line=200,units=3,cost=400,market2=1000,kind='market'})
  assert(calls.start==1 and calls.startArgs[3]==200)
  assert(S.snipePending.tolTotal==400)
`));

test('purchase price uses click-time tiers when the displayed lot shrinks', () => check(`
  snapshot({{price=10,quantity=2},{price=100,quantity=1}})
  quickBuy({itemID=123,line=15,units=3,cost=32,market2=100,kind='market'})
  assert(calls.start==1 and calls.startArgs[2]==2 and calls.startArgs[3]==10)
  assert(S.snipePending.tolTotal==20)
`));

const remainderTrial = `
  S.sweepStats={}
  snapshot({{price=600,quantity=4},{price=1099,quantity=7},{price=1100,quantity=6}})
  local original={itemID=123,line=600,units=4,cost=2400,market2=1098,kind='market'}
  quickBuy(original)
  handlers.COMMODITY_PRICE_UPDATED(974,3897)
  assert(calls.start==1 and calls.confirm==0 and not S.snipePending)
  local retry=S.remainderRetry
  assert(retry and retry.failedUnits==4 and retry.line==600 and retry.cost==2400)
  local function completeRemainder(quantity)
    rows[1].quantity=quantity
    S.liveCandidate=S.liveCandidates[123]; S.liveCandidates[123]=nil
    assert(S.liveCandidate.remainder==S.remainderRetry and S.liveCandidate.forceSearch)
    onCommodityResults(123)
  end
  local function buyRemainder()
    assert(captured and captured.sweep)
    quickBuy({itemID=123,line=captured.sweep.line,units=captured.sweep.units,
      cost=captured.sweep.cost,market2=captured.market,kind=captured.kind})
  end
`;

test('the observed 4-at-600 failure recovers one reported remaining unit on the next hardware press', () => check(remainderTrial + `
  completeRemainder(1)
  assert(captured.sweep.units==1 and captured.sweep.cost==600 and captured.sweep.line==600)
  assert(calls.start==1 and calls.confirm==0, 'search completion must not start a buy')
  buyRemainder()
  assert(calls.start==2 and calls.startArgs[2]==1 and calls.startArgs[3]==600)
  handlers.COMMODITY_PRICE_UPDATED(600,600)
  assert(calls.confirm==1 and calls.confirmArgs[2]==1 and db.unsettledPurchase)
  assert(S.session.buys==0)
  handlers.COMMODITY_PURCHASE_SUCCEEDED()
  assert(S.session.buys==1 and S.session.spent==600 and db.stockPending['123']==1)
  assert(not S.remainderRetry)
`));

test('unchanged cached quantity is halved on separate presses down to one without relaxing price caps', () => check(remainderTrial + `
  completeRemainder(4)
  assert(captured.sweep.units==2 and captured.sweep.cost==1200)
  buyRemainder(); assert(calls.startArgs[2]==2)
  handlers.COMMODITY_PRICE_UPDATED(849,1699)
  assert(calls.confirm==0 and S.remainderRetry.failedUnits==2)
  assert(S.remainderRetry.expires==retry.expires)
  completeRemainder(4)
  assert(captured.sweep.units==1 and captured.sweep.cost==600)
  buyRemainder(); assert(calls.startArgs[2]==1)
  handlers.COMMODITY_PRICE_UPDATED(1099,1099)
  assert(calls.confirm==0 and not S.remainderRetry and calls.start==3)
`));

test('a fresh smaller remainder is taken whole rather than needlessly halved', () => check(remainderTrial + `
  completeRemainder(3)
  assert(captured.sweep.units==3 and captured.sweep.cost==1800)
  buyRemainder(); handlers.COMMODITY_PRICE_UPDATED(600,1800)
  assert(calls.startArgs[2]==3 and calls.confirmArgs[2]==3)
`));

test('recovery waits for its owned complete search and does not consume an unowned or partial event', () => check(remainderTrial + `
  onCommodityResults(123)
  assert(S.liveCandidates[123] and not captured and calls.start==1)
  local terms,reason=commodityOfferTerms(123,600,4,2400,1098,'market')
  assert(not terms and reason=='loading')
  S.liveCandidate=S.liveCandidates[123]; S.liveCandidates[123]=nil
  C_AuctionHouse.HasFullCommoditySearchResults=function() return false end
  onCommodityResults(123)
  assert(S.liveCandidate and not captured and calls.start==1)
  C_AuctionHouse.HasFullCommoditySearchResults=function() return true end
  rows[1].quantity=1; onCommodityResults(123)
  assert(captured.sweep.units==1 and calls.start==1)
`));

test('recovery caps survive another complete result and late responses cannot revive expired recovery', () => check(remainderTrial + `
  completeRemainder(4)
  S.deals={{id=123,line=600,market=1098,kind='market',units=2,cost=1200}}
  onCommodityResults(123)
  assert(captured.sweep.units==2 and S.commoditySnapshots[123].remainder==retry)
  now=retry.expires
  buyRemainder(); assert(calls.start==1)
  captured=nil; onCommodityResults(123)
  assert(not captured)
`));

test('smaller recovery still enforces profit, budget, exposure and complete-data guards', () => {
  for (const change of ['cfg.profit=10000', 'cfg.maxSpend=600', 'cfg.maxStock=1; held=1',
    'cfg.overhang=1', 'rows[1].itemID=456', 'rows[2].quantity=0/0']) check(remainderTrial + `
    ${change}
    completeRemainder(1)
    assert(not captured and calls.start==1 and calls.confirm==0)
  `);
});

test('a recovery quote rechecks changed wallet and never confirms a different quantity', () => {
  for (const change of ['cfg.maxSpend=599', 'rows[1].quantity=0', 'cfg.profit=10000']) check(remainderTrial + `
    completeRemainder(1); buyRemainder()
    ${change}
    handlers.COMMODITY_PRICE_UPDATED(600,600)
    assert(calls.confirm==0 and not db.unsettledPurchase)
  `);
});

test('recovery never expands the original ceiling, total or resale reference', () => check(remainderTrial + `
  completeRemainder(4)
  quickBuy({itemID=123,line=1099,units=20,cost=20000,market2=5000,kind='market'})
  assert(calls.startArgs[2]==2 and calls.startArgs[3]==600)
  assert(S.snipePending.maxUnit==600 and S.snipePending.expected==1200)
  handlers.COMMODITY_PRICE_UPDATED(601,1202)
  assert(calls.confirm==0)
  completeRemainder(4)
  local terms=S.remainderTerms(123,1099,20,20000,5000,'market',S.commoditySnapshots[123])
  assert(terms.line==600 and terms.units==1 and terms.resale<=1098)
`));

test('skip and clear revoke recovery even if a delayed owned result arrives', () => {
  for (const action of ['S.dismissDeal(123)', 'S.clearFeedDeals()']) check(remainderTrial + `
    local function refreshDealPresentation() end
    ${section('function S.dismissDeal(', '\nlocal function finishPurchase(')}
    local old=S.liveCandidates[123]
    ${action}
    assert(not S.remainderRetry and not (S.liveCandidates and S.liveCandidates[123]))
    S.liveCandidate=old; rows[1].quantity=1
    onCommodityResults(123)
    assert(not captured and calls.start==1 and calls.confirm==0)
  `);
});

test('Buy best stays on the recovery item instead of buying a different higher-profit offer', () => check(`
  local order={{id=456},{id=123}}
  local function collectDealGroups() local terms={}; for _,d in ipairs(order) do terms[d]=d end; return order,terms end
  local function commodityOfferReady() return true end
  local bought
  quickBuy=function(row) bought=row.itemID end
  ${section('local function feedBestBuy()', '\nlocal function feedBestSkip()')}
  S.remainderRetry={id=123,expires=110}
  feedBestBuy(); assert(bought==123)
  bought=nil; order={{id=456}}; feedBestBuy(); assert(not bought)
  now=110; feedBestBuy(); assert(bought==456)
`));

test('synchronous start quote sees its owner and confirmation retains the native two arguments', () => check(`
  C_AuctionHouse.StartCommoditiesPurchase=function(...)
    calls.start=calls.start+1; calls.startArgs={...}
    assert(S.snipePending and S.snipePending.requestUnitPrice==10)
    handlers.COMMODITY_PRICE_UPDATED(10,100)
  end
  offer()
  assert(calls.start==1 and calls.startArgs[3]==10 and calls.confirm==1)
  assert(#calls.confirmArgs==2 and calls.confirmArgs[1]==123 and calls.confirmArgs[2]==10)
  assert(db.unsettledPurchase and db.unsettledPurchase==S.snipePending)
`));

test('an unsolicited full or empty result cannot consume a queued fresh validation', () => check(`
  local candidate={id=123,line=10,market=100,kind='market',forceSearch=true,t=now,detectedAt=now}
  S.liveCandidates={[123]=candidate}
  local original=snapshot({{price=10,quantity=2},{price=100,quantity=5}})
  onCommodityResults(123)
  assert(S.liveCandidates[123]==candidate and S.commoditySnapshots[123]==original and not captured)
  local live=rows; rows={}; onCommodityResults(123); rows=live
  assert(S.liveCandidates[123]==candidate and S.commoditySnapshots[123]==original)
  S.liveCandidates[123]=nil; S.liveCandidate=candidate; S.sweepStats={}
  onCommodityResults(123)
  assert(captured.sweep.units==2 and calls.start==0)
`));

test('Buy best uses affordable reduced live terms and rechecks on the actual press', () => check(`
  snapshot({{price=10,quantity=2},{price=100,quantity=4}})
  cfg.maxSpend=30
  S.deals={{id=123,t=now,line=10,unit=10,units=10,cost=100,profit=500,market=100,kind='market'}}
  ${section('local function collectDealGroups(', '\nlocal function feedBestSkip()')}
  feedBestBuy()
  assert(calls.start==1 and calls.startArgs[2]==2 and S.snipePending.expected==20)
  cfg.maxSpend=19; handlers.COMMODITY_PRICE_UPDATED(10,20)
  assert(calls.confirm==0)
`));

test('synchronous overpriced start quote is still rejected', () => check(`
  C_AuctionHouse.StartCommoditiesPurchase=function(...)
    calls.start=calls.start+1; calls.startArgs={...}
    handlers.COMMODITY_PRICE_UPDATED(11,110)
  end
  offer()
  assert(calls.start==1 and calls.startArgs[3]==10 and calls.confirm==0)
  assert(not S.snipePending and not db.unsettledPurchase)
`));

test('unowned complete events do not inherit a previous request timestamp', () => check(`
  local saved=snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  saved.timing={searchAt=95,method='new item search'}
  now=101; onCommodityResults(123)
  assert(S.commoditySnapshots[123]~=saved and not S.commoditySnapshots[123].timing)
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market'})
  assert(S.snipePending and not S.snipePending.timing.searchAt)
`));

test('purchase timing separates validation age from the fast quote response', () => check(`
  local saved=snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  saved.t=97.11
  saved.timing={detectedAt=90,searchAt=94,validatedAt=97.11,feedRenderedAt=98.11,method='refresh commodity'}
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market'})
  assert(calls.start==1 and S.snipePending.timing.completedAt==97.11)
  now=100.32
  handlers.COMMODITY_PRICE_UPDATED(11,110)
  local message
  for _,entry in ipairs(diagnostics) do if entry.domain=='purchase timing' then message=entry.message end end
  assert(message and message:find('attempt 1; item 123',1,true))
  assert(message:find('detect-to-search 4.00s',1,true))
  assert(message:find('search-to-complete 3.11s',1,true))
  assert(message:find('validate-to-click 2.89s',1,true))
  assert(message:find('validate-to-feed 1.00s',1,true))
  assert(message:find('feed-to-click 1.89s',1,true))
  assert(message:find('click-to-quote 0.32s',1,true))
  assert(message:find('detect-to-quote 10.32s',1,true))
  assert(message:find('refresh commodity',1,true) and calls.confirm==0)
`));

test('missing timing stays unknown and fallback reads do not reset completion age', () => check(`
  local saved=snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  saved.t=97
  C_AuctionHouse.HasFullCommoditySearchResults=function() return false end
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market'})
  now=100.3; handlers.COMMODITY_PRICE_UPDATED(11,110)
  local message
  for _,entry in ipairs(diagnostics) do if entry.domain=='purchase timing' then message=entry.message end end
  assert(message:find('detect-to-search unknown',1,true))
  assert(message:find('search-to-complete unknown',1,true))
  assert(message:find('validate-to-feed unknown',1,true))
  assert(message:find('feed-to-click unknown',1,true))
  assert(message:find('completed-age-at-click 3.00s',1,true))
  assert(message:find('completed fallback',1,true) and calls.confirm==0)
`));

const prebuyTrial = `
  cfg.prebuy=true
  local row={itemID=123,line=10,units=10,cost=100,market2=100,kind='market'}
  snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  quickBuy(row)
  assert(calls.start==0 and S.prebuyCheck and S.liveCandidates[123].prebuy==S.prebuyCheck)
  local check=S.prebuyCheck
  quickBuy(row); assert(S.prebuyCheck==check and calls.start==0)
  S.liveCandidate=S.liveCandidates[123]; S.liveCandidates[123]=nil
  S.liveCandidate.searchStartedAt=100.5
  S.searchMethods={[123]='new item search'}
  now=100.8
`;

test('prebuy requires a second hardware call after a new complete search', () => check(prebuyTrial + `
  onCommodityResults(123)
  assert(calls.start==0 and S.prebuyReady(123,10))
  assert(S.commoditySnapshots[123].timing.method=='new item search')
  now=101
  quickBuy(row)
  assert(calls.start==1 and S.snipePending.timing.prebuy)
  now=101.25; handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==1)
`));

test('prebuy records cheap tiers disappearing on the new search without buying', () => check(prebuyTrial + `
  rows={{itemID=123,unitPrice=28,quantity=100,numOwnerItems=0}}
  onCommodityResults(123)
  assert(calls.start==0 and captured==nil)
  local message
  for _,entry in ipairs(diagnostics) do if entry.domain=='prebuy result' then message=entry.message end end
  assert(message and message:find('before x10/100, after x0/0',1,true))
  quickBuy(row); assert(calls.start==0 and calls.confirm==0)
`));

test('prebuy still refuses contradictory quotes after a new search', () => check(prebuyTrial + `
  onCommodityResults(123); quickBuy(row)
  assert(calls.start==1)
  now=101; handlers.COMMODITY_PRICE_UPDATED(28,280)
  assert(calls.confirm==0 and not S.snipePending)
  local message
  for _,entry in ipairs(diagnostics) do if entry.domain=='purchase timing' then message=entry.message end end
  assert(message:find('mode new-search test; query new item search',1,true))
`));

test('prebuy cannot authorize incomplete, foreign or expired search results', () => {
  for (const change of [
    'C_AuctionHouse.HasFullCommoditySearchResults=function() return false end',
    'rows[1].itemID=999',
  ]) check(prebuyTrial + `
    ${change}; onCommodityResults(123)
    assert(not S.prebuyReady(123,10) and calls.start==0)
  `);
  check(prebuyTrial + `
    onCommodityResults(999)
    assert(not S.prebuyReady(123,10) and calls.start==0)
  `);
  check(prebuyTrial + `
    onCommodityResults(123)
    now=103; assert(not S.prebuyReady(123,10))
    quickBuy(row); assert(calls.start==0 and S.prebuyCheck~=check)
  `);
});

test('prebuy authorization is bound to item, ceiling and the completed snapshot', () => check(prebuyTrial + `
  onCommodityResults(123)
  assert(not S.prebuyReady(999,10) and not S.prebuyReady(123,11))
  local saved=S.commoditySnapshots[123]
  S.commoditySnapshots[123]={t=now,tiers=saved.tiers}
  assert(not S.prebuyReady(123,10))
  S.commoditySnapshots[123]=saved
  C_AuctionHouse.HasFullCommoditySearchResults=function() return false end
  quickBuy(row)
  assert(calls.start==0 and S.prebuyCheck~=check)
`));

test('prebuy retains purchase locks, budgets and eligibility checks on the second press', () => {
  for (const change of [
    'db.unsettledPurchase={}', 'cfg.enabled=false', 'S.ahOpen=false',
    'db.blacklist[123]=true', 'wallet=100', 'S.batchSearch={}',
  ]) check(prebuyTrial + `
    onCommodityResults(123); ${change}; quickBuy(row)
    assert(calls.start==0 and calls.confirm==0)
  `);
});

test('unowned result events cannot consume a queued prebuy request', () => check(`
  cfg.prebuy=true
  snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market'})
  local queued=S.liveCandidates[123]
  onCommodityResults(123)
  assert(S.liveCandidates[123]==queued and not S.prebuyReady(123,10))
  assert(calls.start==0)
`));

test('partial prebuy replies retain ownership until complete and a quote consumes the check', () => check(prebuyTrial + `
  C_AuctionHouse.HasFullCommoditySearchResults=function() return false end
  C_AuctionHouse.RequestMoreCommoditySearchResults=function() end
  onCommodityResults(123)
  assert(S.liveCandidate and S.liveCandidate.needsPage and not check.finished)
  assert(not S.prebuyReady(123,10) and calls.start==0)
  C_AuctionHouse.HasFullCommoditySearchResults=function() return true end
  now=101; onCommodityResults(123)
  assert(S.prebuyReady(123,10) and calls.start==0)
  quickBuy(row)
  assert(calls.start==1 and not S.prebuyCheck)
`));

test('fresh sale averages cap resale profit without raising lower live exits', () => {
  salesCheck(`salesFeed(); values.dbregionsaleavg=50
    local terms=S.optimizedCommodityTerms(123,10,100,'market',snapshot({{price=10,quantity=10},{price=100,quantity=1}}))
    assert(terms and terms.resale==50 and terms.profit==355)`);
  salesCheck(`salesFeed(); values.dbregionsaleavg=1000
    local terms=S.optimizedCommodityTerms(123,10,100,'market',snapshot({{price=10,quantity=10},{price=80,quantity=1}}))
    assert(terms and terms.resale==79)`);
});

test('known low sale rate or daily volume rejects market and dump positions', () => {
  for (const kind of ['market', 'dump']) for (const change of [
    'values.dbregionsalerate=0.01', 'values.dbregionsalerate=0',
    'values.dbregionsoldperday=0', 'values.dbregionsoldperday=9.999',
  ]) salesCheck(`salesFeed(); ${change}
    local terms,reason=S.optimizedCommodityTerms(123,10,100,'${kind}',snapshot({{price=10,quantity=1}}))
    assert(not terms and reason==(${change.includes('soldperday=0') ? "'salesvolume'" : "'liquidity'"}))`);
});

test('daily volume bounds inventory, owned auctions and pending exposure', () => salesCheck(`
  salesFeed(); values.dbregionsoldperday=100
  held=4; owned={{itemKey={itemID=123},quantity=2}}; db.stockPending['123']=1
  local terms=S.optimizedCommodityTerms(123,10,100,'market',snapshot({{price=10,quantity=3}}))
  assert(terms and terms.units==3)
  held=5
  local rejected,reason=S.optimizedCommodityTerms(123,10,100,'market',snapshot({{price=10,quantity=3}}))
  assert(not rejected and reason=='stocklimit')
`));

test('sales caps select complete prefixes and cannot loosen manual stock caps', () => salesCheck(`
  salesFeed(); values.dbregionsoldperday=50
  local wall=snapshot({{price=10,quantity=4},{price=20,quantity=4},{price=100,quantity=1}})
  local terms=S.optimizedCommodityTerms(123,20,100,'market',wall)
  assert(terms and terms.units==4 and terms.line==10)
  db.stockLimits['123']=3
  local rejected,reason=S.optimizedCommodityTerms(123,20,100,'market',wall)
  assert(not rejected and reason=='stocklimit')
`));

test('volume caps require fresh readable stock with the manual cap off', () => {
  for (const action of ['held=nil', 'S.sellingOwnedUpdated=nil', 'now=now+21']) salesCheck(`
    salesFeed(); ${action}
    local terms,reason=S.optimizedCommodityTerms(123,10,100,'market',snapshot({{price=10,quantity=1}}))
    assert(not terms and reason=='stockinfo')
  `);
});

test('missing, stale, zero or unavailable volume blocks every exit regardless of optional checks', () => {
  for (const action of ['', 'salesFeed(now-172801)', 'salesFeed(); values.dbregionsoldperday=nil',
    'cfg.sales=false; salesFeed(); values.dbregionsoldperday=0', 'cfg.tsm=false; salesFeed()']) {
    salesCheck(`${action}
      for _,kind in ipairs({'vendor','watch','market','dump'}) do
        local terms,reason=S.optimizedCommodityTerms(123,10,100,kind,snapshot({{price=10,quantity=10}}))
        assert(not terms and reason=='salesvolume')
      end`);
  }
});

test('vendor and watch deals with positive sales still work', () => salesCheck(`
  salesFeed()
  local wall=snapshot({{price=10,quantity=10}})
  assert(S.optimizedCommodityTerms(123,10,100,'vendor',wall))
  assert(S.optimizedCommodityTerms(123,10,nil,'watch',wall))
`));

test('old vendor rows are hidden even without loaded tiers and cannot start a purchase', () => salesCheck(`
  salesFeed(); values.dbregionsoldperday=nil
  S.deals={{id=123,t=now,line=10,unit=10,units=10,cost=100,profit=500,market=100,kind='vendor'}}
  ${section('local function collectDealGroups(', '\nlocal function feedBestSkip()')}
  assert(#collectDealGroups()==0)
  snapshot({{price=10,quantity=10}})
  feedBestBuy()
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='vendor'})
  assert(calls.start==0)
`));

test('a vendor quote cannot confirm after the regional feed becomes unavailable', () => salesCheck(`
  salesFeed(); snapshot({{price=10,quantity=10}})
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='vendor'})
  assert(calls.start==1); TSM_API=nil
  handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==0 and not db.unsettledPurchase)
`));

test('guarded Buy rechecks liquidity instead of trusting displayed offers', () => salesCheck(`
  salesFeed(); values.dbregionsalerate=0
  offer(); assert(calls.start==0 and not S.snipePending)
`));

test('guarded Buy rechecks sale-average profit and total exposure', () => {
  for (const change of ['values.dbregionsaleavg=5', 'values.dbregionsoldperday=50']) {
    salesCheck(`salesFeed(); ${change}
      offer(); assert(calls.start==0 and not S.snipePending)`);
  }
});

test('quote confirmation rechecks sales settings and newly held stock', () => {
  for (const change of ['cfg.saleRate=0.30', 'cfg.saleShare=0.005', 'held=95']) {
    salesCheck(`salesFeed(); offer(); assert(calls.start==1)
      ${change}; handlers.COMMODITY_PRICE_UPDATED(10,100)
      assert(calls.confirm==0 and not S.snipePending)`);
  }
});

test('the exact sale-rate floor and sales exposure limit permit guarded confirmation', () => salesCheck(`
  salesFeed(); values.dbregionsalerate=0.05; values.dbregionsoldperday=100
  offer(); assert(calls.start==1)
  handlers.COMMODITY_PRICE_UPDATED(10,100); assert(calls.confirm==1)
`));

test('an in-flight batch summary blocks buying even with a valid complete snapshot', () => check(`
  S.batchSearch={t=now}
  offer()
  assert(calls.start==0 and S.snipePending==nil)
  S.batchSearch=nil
  offer()
  assert(calls.start==1)
`));

test('a contradicted cheap offer cannot be retried from cached tiers before a fresh result', () => check(`
  local function refreshDealPresentation() end
  ${section('markDealGone = function(', '\nquickBuy = function')}
  ${section('function S.offerAvailable(', '\nfunction S.dismissDeal(')}
  ${section('local function prepareCommodityDeal(', '\nlocal function offerKind(')
    .replace('local function prepareCommodityDeal(', 'prepareCommodityDeal = function(')}
  local deal={id=123,line=25,units=13,cost=325,market=300,kind='market'}
  S.deals={deal}
  snapshot({{price=25,quantity=13},{price=300,quantity=1}})
  local row={itemID=123,line=25,units=13,cost=325,market2=300,kind='market',offer=deal,t=100}
  quickBuy(row); assert(calls.start==1)
  handlers.COMMODITY_PRICE_UPDATED(159,2070)
  assert(calls.confirm==0 and deal.gone and not S.commoditySnapshots[123])
  assert(S.liveCandidates[123] and S.liveCandidates[123].line==25)
  quickBuy(row); assert(calls.start==1)
  local terms,reason=commodityOfferTerms(123,25,13,325,300,'market')
  assert(not terms and reason=='loading','API cache alone must not restore Buy readiness')
  S.liveCandidate=S.liveCandidates[123]; S.liveCandidates[123]=nil
  rows={{unitPrice=155,quantity=100,numOwnerItems=0}}
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
  assert(S.commoditySnapshots[123] and deal.gone and not captured)
`));

test('commodity tier prices preserve the observed Forever item identity and copper units', () => check(`
  WOW_PROJECT_ID=99; WOW_PROJECT_CAMELOT=99
  rows={{itemID=2772,unitPrice=296,quantity=173,numOwnerItems=0}}
  local result=readCommodityTiers(2772)
  assert(result and result.tiers[1].price==296 and result.tiers[1].quantity==173)
`));

test('Buy diagnostics capture raw live tiers and distinguish completed age from quote age', () => check(`
  snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  rows[1].auctionID=123030736
  now=110
  quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market',t=100})
  assert(calls.start==1 and S.snipePending.t==110)
  local entry=diagnostics[1]
  assert(entry.domain=='purchase tiers')
  assert(entry.message:find('live API; completed age 10.00s; read age 0.00s',1,true))
  assert(entry.message:find('123:10:10:0:123030736',1,true))
  assert(entry.message:find('approved x10/100 copper',1,true))
`));

test('Buy diagnostics identify empty and loading fallback without changing approval', () => {
  for (const reason of ['empty', 'loading']) check(`
    snapshot({{price=10,quantity=10},{price=100,quantity=1}})
    S.commoditySnapshots[123]=readCommodityTiers(123)
    now=105; rows={}
    ${reason === 'loading' ? 'C_AuctionHouse.HasFullCommoditySearchResults=function() return false end' : ''}
    quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market',t=100})
    assert(calls.start==1 and S.snipePending.expected==100 and S.snipePending.maxUnit==10)
    assert(diagnostics[1].message:find('completed fallback: ${reason}; completed age 5.00s; read age 5.00s',1,true))
    assert(diagnostics[1].message:find('123:10:10:0:unknown',1,true))
  `);
});

test('raw tier evidence is bounded and copies values instead of retaining API row tables', () => check(`
  snapshot({{price=10,quantity=10},{price=20,quantity=1},{price=30,quantity=1},{price=40,quantity=1}})
  local saved=readCommodityTiers(123)
  assert(#saved.tiers==4 and saved.evidence=='123:10:10:0:unknown,123:20:1:0:unknown,123:30:1:0:unknown')
  rows[1].unitPrice=999
  assert(saved.tiers[1].price==10 and saved.evidence:find('123:10:10:0:unknown',1,true))
`));

test('mismatched or missing Forever tier identity cannot authorize Buy or fall back to cached tiers', () => {
  for (const id of ['456', '123.5', '"123"', 'nil']) check(`
    WOW_PROJECT_ID=99; WOW_PROJECT_CAMELOT=99
    snapshot({{price=10,quantity=10}}); rows[1].itemID=${id}
    local result,reason,identity=readCommodityTiers(123)
    assert(not result and reason=='unreadable' and identity:find('requested item 123',1,true))
    result,reason=commodityTiersForBuy(123)
    assert(not result and reason=='unreadable','wrong-item results must not reuse the old snapshot')
    quickBuy({itemID=123,line=10,units=10,cost=100,market2=100,kind='market',t=100})
    assert(calls.start==0 and not S.snipePending)
    handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
    assert(not S.commoditySnapshots[123])
  `);
});

test('one wrong-item tier discards the whole wall instead of selecting a cheap partial prefix', () => check(`
  snapshot({{price=2,quantity=21},{price=274,quantity=100}})
  rows[2].itemID=456
  local result,reason=readCommodityTiers(123)
  assert(not result and reason=='unreadable')
`));

const commands = section('    elseif cmd == "keep" then', '\n    elseif cmd == "thresh" then')
  .replace('elseif cmd', 'if cmd');
function commandCheck(body) {
  run(setup + section('local function parseMoney(text)', '\n-- Timers:') + `
    local function refreshDealPresentation() end
    function S.requestSellingOwned() end
    local function command(cmd,rest)
    ${commands}
    end
    end
    ${body}
  `);
}

test('reserve command supports setting, disabling, and rejecting invalid input', () => commandCheck(`
  command("keep","10g"); assert(cfg.keepGold==100000)
  command("keep","0"); assert(cfg.keepGold==0)
  command("keep","3g50s"); assert(cfg.keepGold==35000)
  command("keep","-10g"); assert(cfg.keepGold==35000)
  command("keep","invalid"); assert(cfg.keepGold==35000)
  command("keep","0g"); assert(cfg.keepGold==0)
`));

test('stock commands manage defaults, overrides, and guarded receipt acknowledgements', () => commandCheck(`
  command("stock","200"); assert(cfg.maxStock==200)
  command("stock","123 100"); assert(db.stockLimits["123"]==100)
  command("stock","123 0"); assert(db.stockLimits["123"]==0)
  command("stock","123 inherit"); assert(db.stockLimits["123"]==nil)
  command("stock","-1"); assert(cfg.maxStock==200)
  command("stock","123 1.5"); assert(db.stockLimits["123"]==nil)
  db.stockPending["123"]=10
  S.snipePending={}; command("received","123"); assert(db.stockPending["123"]==10)
  S.snipePending=nil; db.unsettledPurchase={}
  command("received","123"); assert(db.stockPending["123"]==10)
  db.unsettledPurchase=nil
  command("received","123"); assert(db.stockPending["123"]==nil)
`));

test('all production Lua chunks compile', () => {
  for (const code of [optimizer, source, fs.readFileSync(new URL('../TSMReference.lua', import.meta.url), 'utf8')]) {
    const L = fengari.lauxlib.luaL_newstate();
    try {
      const status = fengari.lauxlib.luaL_loadstring(L, fengari.to_luastring(code));
      assert.equal(status, fengari.lua.LUA_OK,
        status === fengari.lua.LUA_OK ? '' : fengari.to_jsstring(fengari.lua.lua_tostring(L, -1)));
    } finally { fengari.lua.lua_close(L); }
  }
});

test('optimiser compares all eligible complete prefixes, not the first qualifying one', () => check(`
  local wall=snapshot({{price=10,quantity=10},{price=20,quantity=10},{price=100,quantity=1}})
  local best=S.optimizedCommodityTerms(123,20,100,"market",wall)
  assert(best and best.units==20 and best.cost==300 and best.line==20)
  assert(best.profit==1541)
`));

test('a smaller complete position can beat the larger wall', () => check(`
  local wall=snapshot({{price=10,quantity=10},{price=50,quantity=1000},{price=60,quantity=100}})
  local best=S.optimizedCommodityTerms(123,50,52,"market",wall)
  assert(best and best.units==10 and best.line==10 and best.resale==49)
`));

test('equal-price rows stay together, inputs stay unchanged, ties use less capital', () => run(optimizer + `
  local tiers={{price=20,quantity=2},{price=10,quantity=3},{price=10,quantity=4}}
  local best=ForeverSniperDepthOptimizer.choose(tiers,20,function(line,lot)
    if line==10 then assert(lot.units==7 and lot.cost==70 and lot.competing==20) end
    return {profit=5,cost=lot.cost,units=lot.units}
  end)
  assert(best.units==7 and best.line==10 and tiers[1].price==20)
`));

test('no ceiling expansion, fractional tiers, invented demand, or partial-tier clipping', () => check(`
  local wall=snapshot({{price=10,quantity=10},{price=20,quantity=100}})
  cfg.maxSpend=99
  assert(not S.optimizedCommodityTerms(123,20,100,"market",wall))
  cfg.maxSpend=100000
  assert(not S.optimizedCommodityTerms(123,9,100,"market",wall))
  assert(not S.optimizedCommodityTerms(123,20,nil,"market",wall))
  assert(not S.optimizedCommodityTerms(123,20,100,"market",{tiers={{price=10,quantity=1.5}}}))
`));

test('missing higher listings use the supplied market, never a made-up minimum gap', () => check(`
  local best=S.optimizedCommodityTerms(123,10,8,"market",snapshot({{price=10,quantity=10}}))
  assert(not best)
  local valid=S.optimizedCommodityTerms(123,10,15,"market",snapshot({{price=10,quantity=10}}))
  assert(valid and valid.resale==15)
`));

test('gold reserve adds to, rather than replaces, the existing wallet and spend guards', () => check(`
  wallet=1000; cfg.maxSpend=2000
  assert(S.purchaseBudget()==950)
  cfg.keepGold=900; assert(S.purchaseBudget()==100)
  cfg.maxSpend=50; assert(S.purchaseBudget()==50)
  cfg.keepGold=1001; assert(S.purchaseBudget()==0)
  cfg.keepGold=0/0; assert(S.purchaseBudget()==0)
`));

test('gold reserve includes relist deposits and rejects a whole tier instead of clipping it', () => check(`
  wallet=1000; cfg.keepGold=890
  local wall=snapshot({{price=10,quantity=10},{price=100,quantity=1}})
  assert(not S.optimizedCommodityTerms(123,10,100,"market",wall))
  cfg.keepGold=880
  assert(S.optimizedCommodityTerms(123,10,100,"market",wall).units==10)
`));

test('stock limits include client-known holdings, owned auctions, and persistent reservations', () => check(`
  cfg.maxStock=100; held=20
  owned={{itemKey={itemID=123},quantity=30},{itemKey={itemID=456},quantity=500}}
  db.stockPending["123"]=10
  assert(S.stockAllowance(123)==40)
  db.stockLimits["123"]=70; assert(S.stockAllowance(123)==10)
  db.stockLimits["123"]=0; assert(S.stockAllowance(123)==math.huge)
  db.stockLimits["123"]=nil; assert(S.stockAllowance(123)==40)
`));

test('stock limits can select a smaller complete prefix, but never split a price tier', () => check(`
  cfg.maxStock=15
  local wall=snapshot({{price=10,quantity=10},{price=20,quantity=10},{price=100,quantity=1}})
  local best=S.optimizedCommodityTerms(123,20,100,"market",wall)
  assert(best and best.units==10 and best.line==10)
  cfg.maxStock=9
  assert(not S.optimizedCommodityTerms(123,20,100,"market",wall))
`));

test('enabled stock caps fail closed on stale, missing, or unreadable inventory data', () => {
  for (const change of [
    'S.sellingOwnedUpdated=nil', 'now=121', 'now=99',
    'C_Item.GetItemCount=nil', 'C_Item.GetItemCount=function() error("unavailable") end',
    'held=-1', 'held=0/0', 'owned={{itemKey={itemID=123},quantity=-1}}',
    'C_AuctionHouse.GetNumOwnedAuctions=function() return nil end',
    'C_AuctionHouse.GetOwnedAuctionInfo=function() error("unavailable") end; owned={true}',
    'db.stockPending["123"]="unknown"',
  ]) check(`cfg.maxStock=100; ${change}
    local allowance,reason=S.stockAllowance(123)
    assert(allowance==nil and reason=="stockinfo")`);
});

test('watch rules retain their exact ceiling and full-lot semantics', () => check(`
  local wall=snapshot({{price=10,quantity=10},{price=20,quantity=10}})
  local best=S.optimizedCommodityTerms(123,20,nil,"watch",wall)
  assert(best and best.units==20 and not best.line and not best.profit)
  cfg.maxStock=15
  local rejected,reason=S.optimizedCommodityTerms(123,20,nil,"watch",wall)
  assert(not rejected and reason=="stocklimit")
`));

test('existing quality, competition and profit gates still apply to every candidate', () => check(`
  local wall=snapshot({{price=10,quantity=10},{price=20,quantity=10},{price=100,quantity=100}})
  cfg.quality=2; assert(not S.optimizedCommodityTerms(123,20,100,"market",wall))
  cfg.quality=1; cfg.overhang=50
  assert(not S.optimizedCommodityTerms(123,20,100,"market",wall))
  cfg.overhang=0; cfg.profit=100000
  assert(not S.optimizedCommodityTerms(123,20,100,"market",wall))
`));

test('reserve and stock policies are enforced before starting any purchase', () => {
  for (const change of ['cfg.keepGold=99999', 'cfg.maxStock=9', 'cfg.maxStock=100; S.sellingOwnedUpdated=nil']) {
    check(`${change}; offer(); assert(calls.start==0 and calls.confirm==0)`);
  }
});

test('reserve, stock, and inventory changes during a quote prevent confirmation', () => {
  for (const change of [
    'cfg.keepGold=99999', 'cfg.maxStock=9',
    'cfg.maxStock=15; held=6', 'cfg.maxStock=15; db.stockPending["123"]=6',
    'cfg.maxStock=100; S.sellingOwnedUpdated=nil',
  ]) check(`offer(); assert(calls.start==1); ${change}
    handlers.COMMODITY_PRICE_UPDATED(10,100)
    assert(calls.confirm==0 and not S.snipePending)`);
});

test('only the server outcome records exposure, and duplicate outcomes cannot double-count', () => check(`
  offer(); handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==1 and not db.stockPending["123"] and S.session.buys==0)
  handlers.COMMODITY_PURCHASE_SUCCEEDED()
  assert(db.stockPending["123"]==10 and S.session.buys==1 and S.session.spent==100)
  handlers.COMMODITY_PURCHASE_SUCCEEDED()
  assert(db.stockPending["123"]==10 and S.session.buys==1)
  S.sellingOwnedUpdated=100; cfg.maxStock=15
  assert(S.stockAllowance(123)==5)
`));

test('overpriced, stale, and failed quotes cannot reserve stock or record a buy', () => {
  for (const action of [
    'handlers.COMMODITY_PRICE_UPDATED(11,110)',
    'now=103; handlers.COMMODITY_PRICE_UPDATED(10,100)',
    'handlers.COMMODITY_PURCHASE_FAILED()',
  ]) check(`offer(); ${action}; assert(not db.stockPending["123"] and S.session.buys==0)`);
});

test('completed search events publish the optimised ceiling and reject partial results', () => check(`
  snapshot({{price=10,quantity=10},{price=50,quantity=1000},{price=60,quantity=100}})
  S.liveCandidate={id=123,line=50,market=52,kind="market",t=100}
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
  assert(captured and captured.sweep.line==10 and captured.sweep.units==10 and captured.market==49)
  captured=nil
  S.liveCandidate={id=123,line=50,market=52,kind="market",t=100}
  C_AuctionHouse.HasFullCommoditySearchResults=function() return false end
  handlers.COMMODITY_SEARCH_RESULTS_UPDATED(123)
  assert(not captured)
`));

test('optimisation matches exhaustive complete-prefix evaluation across bounded markets', () => check(`
  for case=1,100 do
    local tiers={}
    for i=1,6 do tiers[i]={price=5+i*3,quantity=1+(case*i)%9} end
    local wall=snapshot(tiers)
    cfg.maxSpend=100+case*5
    cfg.maxStock=case%3==0 and 15 or 0
    local best=S.optimizedCommodityTerms(123,20,25+case%7,"market",wall)
    local expected
    for _,tier in ipairs(tiers) do
      if tier.price<=20 then
        local terms=commodityOfferTerms(123,tier.price,nil,nil,25+case%7,"market")
        if terms and (not expected or terms.profit>expected.profit
          or (terms.profit==expected.profit and terms.cost<expected.cost)) then expected=terms end
      end
    end
    assert((not best and not expected) or (best and expected and best.cost==expected.cost and best.profit==expected.profit))
  end
`));

test('stock is read once per optimisation, not once per price tier', () => check(`
  cfg.maxStock=1000
  local reads=0
  C_Item.GetItemCount=function() reads=reads+1; return 0 end
  S.optimizedCommodityTerms(123,20,100,"market",snapshot({{price=10,quantity=10},{price=20,quantity=10},{price=100,quantity=1}}))
  assert(reads==1)
`));
