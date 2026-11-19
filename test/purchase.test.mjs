import test from 'node:test';
import { section, run } from './lua.mjs';

// The old dialog tests now exercise the current owned quote lifecycle.
// Complete-tier selection and server-only accounting are covered by depth.test.
const setup = `
local now = 100
local cfg = {enabled=true}
local db = {blacklist={}}
local S = {ahOpen=true,commoditySnapshots={}}
local handlers, buyFailUntil = {}, {}
local calls = {cancel=0,confirm=0}
local diagnostics={}
local function GetTime() return now end
local function num(v) if type(v)=="number" and v==v then return v end end
local function printf() end
local function err() end
local function recordGate() end
local function diagnostic(domain,message) diagnostics[#diagnostics+1]={domain=domain,message=message} end
local function markDealGone(id,price) calls.gone={id=id,price=price} end
local function prepareCommodityDeal(id,link,line,market,kind) calls.refresh={id=id,line=line,market=market,kind=kind} end
function S.wakeSweep() calls.wake=(calls.wake or 0)+1 end
local function finishPurchase() end
local function on(event,fn) handlers[event]=fn end
function S.purchaseBudget() return 1000 end
function S.offerAvailable() return true end
function S.refreshPurchasePresentation() end
local function commodityOfferTerms() return {units=10} end
local C_AuctionHouse = {
  CancelCommoditiesPurchase=function()
    calls.cancel=calls.cancel+1
    assert(S.snipePending==nil, "retire ownership before cancelling")
  end,
  ConfirmCommoditiesPurchase=function() calls.confirm=calls.confirm+1 end,
}
`;
const production = section('local function retirePurchase(reason)', '\nlocal function purchaseDetails')
  + section('on("COMMODITY_PRICE_UPDATED", function', '\n-- merchant learner:');
function check(body) {
  run(setup + production + `
    local function offer()
      S.snipePending={deal={id=123},units=10,t=100,maxUnit=10,tolTotal=100}
    end
  ` + body);
}

test('cancelling an unconfirmed quote retires ownership before the API call', () => check(`
  offer(); retirePurchase("cancelled")
  assert(calls.cancel==1 and not S.snipePending and not db.unsettledPurchase)
  retirePurchase("duplicate"); assert(calls.cancel==1)
`));

test('retiring a submitted purchase preserves an unknown-outcome lock', () => check(`
  offer(); local p=S.snipePending; p.confirmed=true
  retirePurchase("auction house closed")
  assert(not S.snipePending and calls.cancel==0)
  assert(db.unsettledPurchase==p and S.outcomeOwner==p)
  assert(p.reason=="auction house closed")
`));

test('quotes without an owned request cannot confirm', () => check(`
  handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==0)
`));

test('unit and total quote ceilings are exact and independently enforced', () => {
  for (const quote of ['11,100', '10,101', '10.1,100', '10,100.1', 'nil,100', '10,nil', '0,100']) {
    check(`offer(); handlers.COMMODITY_PRICE_UPDATED(${quote})
      assert(calls.confirm==0 and calls.cancel==1 and not S.snipePending)`);
  }
});

test('expired quotes and revoked permissions cannot confirm', () => {
  for (const change of ['now=103', 'cfg.enabled=false', 'S.ahOpen=false',
    'db.blacklist[123]=true', 'function S.offerAvailable() return false end',
    'function S.purchaseBudget() return 99 end']) {
    check(`offer(); ${change}; handlers.COMMODITY_PRICE_UPDATED(10,100)
      assert(calls.confirm==0 and not S.snipePending)`);
  }
});

test('quote refusals identify the exact unchanged guard and retain numeric evidence', () => {
  for (const [change, quote, reason] of [
    ['', '11,100', 'unit price above approved ceiling'],
    ['', '10,101', 'total above approved purchase cost'],
    ['', 'nil,100', 'unreadable unit price'],
    ['', '10,nil', 'unreadable total price'],
    ['now=103', '10,100', 'quote older than 2 seconds'],
    ['cfg.enabled=false', '10,100', 'scanner disabled'],
    ['S.ahOpen=false', '10,100', 'auction house closed'],
    ['db.blacklist[123]=true', '10,100', 'item blacklisted'],
    ['function S.offerAvailable() return false end', '10,100', 'displayed offer retired'],
    ['function S.purchaseBudget() return 99 end', '10,100', 'total above current budget'],
  ]) check(`offer(); ${change}; handlers.COMMODITY_PRICE_UPDATED(${quote})
    assert(calls.confirm==0 and calls.cancel==1 and not S.snipePending)
    assert(#diagnostics==1 and diagnostics[1].domain=='purchase quote')
    local message=diagnostics[1].message
    assert(message:find('${reason}',1,true) and message:find('item 123 x10',1,true)
      and message:find('quote unit/total',1,true) and message:find('age ',1,true))`);
});

test('a changed complete position prevents quote confirmation', () => check(`
  offer(); commodityOfferTerms=function() return {units=11} end
  handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==0 and not S.snipePending)
`));

test('overpriced quotes discard only contradicted tiers and queue revalidation at the original caps', () => {
  for (const quote of ['11,100', '10,101']) check(`
    local other={t=now}; S.commoditySnapshots[456]=other
    S.commoditySnapshots[123]={t=now}; offer()
    S.snipePending.market=50; S.snipePending.kind='market'
    handlers.COMMODITY_PRICE_UPDATED(${quote})
    assert(calls.confirm==0 and calls.cancel==1 and not db.unsettledPurchase)
    assert(S.commoditySnapshots[123]==nil and S.commoditySnapshots[456]==other)
    assert(calls.gone.id==123 and calls.gone.price==math.huge)
    assert(calls.refresh.id==123 and calls.refresh.line==10 and calls.refresh.market==50
      and calls.refresh.kind=='market' and calls.wake==1)
    handlers.COMMODITY_PRICE_UPDATED(10,100); assert(calls.confirm==0)
  `);
});

test('non-price quote refusals do not discard unrelated valid market data', () => {
  for (const change of ['now=103', 'cfg.enabled=false', 'function S.purchaseBudget() return 99 end']) check(`
    offer(); local saved={t=now}; S.commoditySnapshots[123]=saved
    ${change}; handlers.COMMODITY_PRICE_UPDATED(10,100)
    assert(calls.confirm==0 and S.commoditySnapshots[123]==saved and not calls.refresh and not calls.gone)
  `);
});

test('duplicate valid quotes submit once and keep ownership for the server outcome', () => check(`
  offer(); local p=S.snipePending
  handlers.COMMODITY_PRICE_UPDATED(10,100)
  handlers.COMMODITY_PRICE_UPDATED(10,100)
  assert(calls.confirm==1 and p.confirmed and p.total==100)
  assert(db.unsettledPurchase==p and S.outcomeOwner==p)
`));

test('unavailable quotes and AH errors cancel unsubmitted purchases', () => {
  for (const event of ['COMMODITY_PRICE_UNAVAILABLE', 'AUCTION_HOUSE_SHOW_ERROR']) {
    check(`offer(); handlers.${event}("unavailable")
      assert(calls.cancel==1 and not S.snipePending and not db.unsettledPurchase)`);
  }
});

test('unavailable quotes after submission retain the reconciliation lock', () => check(`
  offer(); handlers.COMMODITY_PRICE_UPDATED(10,100)
  local p=S.snipePending
  handlers.COMMODITY_PRICE_UNAVAILABLE()
  assert(not S.snipePending and db.unsettledPurchase==p and calls.cancel==0)
`));
