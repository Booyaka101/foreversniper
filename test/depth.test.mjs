import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import fengari from 'fengari';
import { source, section, run } from './lua.mjs';

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
    StartCommoditiesPurchase=function() calls.start=calls.start+1 end,
    ConfirmCommoditiesPurchase=function() calls.confirm=calls.confirm+1 end,
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
    for _,tier in ipairs(tiers) do rows[#rows+1]={unitPrice=tier.price,quantity=tier.quantity,numOwnerItems=0} end
    S.commoditySnapshots[123]={tiers=tiers,t=now}
    return S.commoditySnapshots[123]
end
`;
const production = optimizer
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
function check(body) { run(setup + production + prepared + body); }

test('an in-flight batch summary blocks buying even with a valid complete snapshot', () => check(`
  S.batchSearch={t=now}
  offer()
  assert(calls.start==0 and S.snipePending==nil)
  S.batchSearch=nil
  offer()
  assert(calls.start==1)
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

test('both production Lua chunks compile', () => {
  for (const code of [optimizer, source]) {
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
