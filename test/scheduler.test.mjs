import test from 'node:test';
import { section, run } from './lua.mjs';

const setup = `
local now, ready, nativeSell, browseVisible = 100, true, false, false
local cfg = {enabled=true,sweep=2,maxStock=0,undercut=false}
local db = {stockLimits={},watch={},blacklist={}}
local S = {ahOpen=true,commoditySnapshots={},deals={},seen={},autoChecked={}}
local queries, timers, handlers = {}, {}, {}
local focus, auto, watch, synchronous = nil, {id=123,line=10,market=100}, nil, nil
local canQuery, lastQueryAt
local undercutTicker
local function GetTime() return now end
local function time() return now end
local function record(kind,id) queries[#queries+1]={kind=kind,id=id,t=now} end
local function after(delay,fn) timers[#timers+1]={at=now+delay,fn=fn} end
local C_Timer = {NewTicker=function(period,fn)
    return {period=period,fn=fn,Cancel=function(self) self.cancelled=true end}
end}
local function advance(target)
    local steps=0
    while true do
        local index
        for i,timer in ipairs(timers) do
            if timer.at<=target and (not index or timer.at<timers[index].at) then index=i end
        end
        if not index then break end
        local timer=table.remove(timers,index)
        now=timer.at; timer.fn(); steps=steps+1
        assert(steps<200,"recursive wake loop")
    end
    now=target
end
local function push(list,cap,value) list[#list+1]=value end
local function throttleGate() return ready end
local function commodityFor() return true end
local function requestItemSearch(id)
    record("target",id)
    if synchronous then synchronous(id) end
end
local function recordGate() end
local function err() end
local function printf() end
local function dbg() end
local function focusedDeal() return focus end
local function rebuildWatch() end
local function nextWatchKey()
    if watch then return {itemID=watch},watch,{maxPrice=10} end
end
local function nextAutoTarget() return auto end
local function blizzardBrowseActive() return browseVisible end
local function discoveryScope(cat) return {classID=cat.classID},cat.name,false end
local function updateScanPage() end
local function refreshFeed() end
local function feedTick() end
local function checkUndercuts() end
local function onOwnedAuctionsUpdated() end
function S.nativeSellActive() return nativeSell end
local C_AuctionHouse = {
    SendSearchQuery=function() end,
    SendBrowseQuery=function(query) record("browse",query.itemClassFilters[1].classID) end,
    RequestMoreCommoditySearchResults=function(id) record("page",id) end,
    HasFullBrowseResults=function() return false end,
    RequestMoreBrowseResults=function() record("deep page") end,
}
local function onOptional(event,fn) handlers[event]=fn end
`;

const production = section('local SCAN_CATEGORIES =', '\nif db.boughtAt == nil')
  + section('local throttleReady, pagePending', '\nS.autoChecked =')
  + section('local function queryPacing()', '\nlocal function requestItemSearch')
  + section('canQuery = function(paging)', '\nlocal function discoveryScope')
  + section('local function sweepQuery()', '\n-- DEEP')
  + section('-- DEEP SCAN (/fsn deepscan', '\nfunction S.wakeSweep()')
  + section('function S.wakeSweep()', '\n\n-- BATCH RELIST:')
  + section('stopRelisting = function()', '\nlocal function startRelisting')
  + section('onOptional("OWNED_AUCTIONS_UPDATED"', '\nlocal function onReplicateUpdated()');
const helpers = `
local function complete()
    S.autoSearch,S.watchSearch,S.liveCandidate=nil,nil,nil
    pagePending,S.sweeping,throttleReady=false,false,true
end
local function count(kind,id)
    local total=0
    for _,query in ipairs(queries) do
        if query.kind==kind and (not id or query.id==id) then total=total+1 end
    end
    return total
end
local function slots(n)
    for i=1,n do complete(); now=now+1; sweepQuery() end
end
`;
function check(code) { run(setup + production + helpers + code); }

test('weighted category rotation spreads classes without changing their shares', () => check(`
  local counts,previous={},nil
  for i=1,20 do
    local cat=nextCategory()
    assert(cat.classID~=previous,"adjacent duplicate category")
    counts[cat.classID]=(counts[cat.classID] or 0)+1
    previous=cat.classID
  end
  assert(counts[7]==6 and counts[0]==6 and counts[3]==4 and counts[8]==4)
`));

test('discovery receives every second slot with automatic targets available', () => check(`
  slots(16)
  assert(count("browse")==8 and count("target",123)==8)
`));

test('a displayed deal cannot stop discovery and only takes bounded refresh slots', () => check(`
  focus={id=999,line=10,market=100,kind="market"}
  S.dealFocus={deal=focus}
  slots(40)
  assert(count("browse")==20)
  assert(count("target",999)>0 and count("target",999)<=3)
  assert(count("target",123)>=17)
`));

test('manual watches retain their slot while discovery and automatic checks continue', () => check(`
  watch=456
  slots(16)
  assert(count("target",456)==4 and count("target",123)==4 and count("browse")==8)
`));

test('queued candidates cannot consume reserved discovery slots', () => check(`
  S.liveCandidates={}
  for id=1,20 do S.liveCandidates[id]={id=id,t=now,line=10,market=100} end
  slots(8)
  assert(count("browse")==4 and count("target")==4)
`));

test('an unrelated in-flight search can finish paging while a deal is displayed', () => check(`
  focus={id=999}; S.dealFocus={deal=focus}
  S.autoSearch={id=123,t=now,needsPage=true}
  sweepQuery()
  assert(count("page",123)==1 and count("target")==0 and count("browse")==0)
  now=now+1; sweepQuery()
  assert(#queries==1,"must wait for the in-flight page")
`));

test('ready events dispatch at minimum spacing rather than waiting for the watchdog', () => check(`
  startSweeping(); advance(100.01)
  assert(#queries==1)
  complete(); now=100.2
  handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  advance(101)
  assert(#queries==1)
  advance(101.02)
  assert(#queries==2 and queries[2].t<102)
  assert(queries[2].t-queries[1].t>=1)
`));

test('bursts of ready events coalesce without duplicate requests', () => check(`
  S.sweepTicker={}; lastQueryAt=now
  for i=1,20 do
    handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED()
  end
  assert(#timers==1)
  advance(101)
  assert(#queries==1)
`));

test('server readiness is checked again when a scheduled wake fires', () => check(`
  S.sweepTicker={}; lastQueryAt=now
  handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  ready=false
  advance(101)
  assert(#queries==0 and #timers==0)
`));

test('all purchase, disabled, closed, ownership, and native-form gates survive event wakes', () => {
  for (const change of [
    'S.snipePending={}', 'db.unsettledPurchase={}', 'S.quote={}',
    'S.batchBuy={pending=true}', 'cfg.enabled=false', 'S.ahOpen=false',
    'nativeSell=true', 'S.scanning=true', 'S.harvestOwner={}',
    'S.pending={}', 'S.buying=true', 'S.autoSearch={id=123,t=now}',
  ]) check(`
    S.sweepTicker={}; lastQueryAt=now; S.wakeSweep()
    ${change}
    advance(101)
    assert(#queries==0)
  `);
});

test('stopping or restarting invalidates old scheduled wakes', () => check(`
  startSweeping(); local old=S.sweepTicker
  stopSweeping(); advance(101)
  assert(#queries==0 and old.cancelled)
  startSweeping(); stopSweeping(); startSweeping()
  advance(101.1)
  assert(#queries==1)
`));

test('the fallback ticker still progresses when ready events are absent', () => check(`
  startSweeping(); advance(100.01); complete()
  now=102; S.sweepTicker.fn()
  assert(#queries==2)
`));

test('a watchdog request cannot be followed too closely by an already queued wake', () => check(`
  startSweeping(); advance(100.01); complete()
  S.wakeSweep()
  now=101.01; S.sweepTicker.fn()
  complete(); advance(101.02)
  assert(#queries==2)
  assert(queries[2].t-queries[1].t>=1)
`));

test('synchronous cached replies schedule the next request without recursive dispatch', () => check(`
  synchronous=function()
    complete()
    S.wakeSweep()
    S.wakeSweep()
  end
  startSweeping(); advance(100.01)
  assert(#queries==1 and #timers==1)
  advance(101.02)
  assert(#queries==2 and queries[2].t-queries[1].t>=1)
`));

test('deep discovery continues past a displayed deal without replacing live target ownership', () => check(`
  focus={id=999}; S.dealFocus={deal=focus}
  startDeepScan(true)
  assert(count("browse")==1)
  local scan=S.deepScan
  scan.wantsPage=true; now=101
  S.autoSearch={id=123,t=now}
  scan.ticker.fn(); assert(count("deep page")==0)
  S.autoSearch=nil
  scan.ticker.fn(); assert(count("deep page")==1)
`));

test('deep discovery still pauses for pending and unresolved purchases', () => {
  for (const change of ['S.snipePending={}', 'db.unsettledPurchase={}']) check(`
    focus={id=999}; S.dealFocus={deal=focus}
    startDeepScan(true)
    local scan=S.deepScan
    scan.wantsPage=true; now=101
    ${change}
    scan.ticker.fn()
    assert(count("browse")==1 and count("deep page")==0)
    assert(S.deepScan==scan)
  `);
});

test('failed search submissions consume spacing rather than triggering a retry burst', () => check(`
  requestItemSearch=function() record("failed target"); error("unavailable") end
  startSweeping(); advance(100.01)
  assert(count("failed target")==1 and S.autoSearch==nil)
  for i=1,10 do handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY() end
  advance(100.9); assert(#queries==1)
  advance(101.02); assert(#queries==2 and queries[2].kind=="browse")
`));

test('dropped requests wake a paced recovery rather than bypassing spacing', () => check(`
  S.sweepTicker={}; lastQueryAt=now; pagePending=true; throttleReady=false
  handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
  advance(100.9); assert(#queries==0)
  advance(101); assert(#queries==1)
`));
