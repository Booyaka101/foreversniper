import test from 'node:test';
import { section, run } from './lua.mjs';

const setup = `
local now, ready, nativeSell, browseVisible = 100, true, false, false
local cfg = {enabled=true,sweep=2,maxStock=0,undercut=false}
local db = {stockLimits={},watch={},blacklist={},book={}}
local S = {ahOpen=true,commoditySnapshots={},deals={},seen={},autoChecked={}}
local queries, timers, handlers = {}, {}, {}
local focus, auto, watch, synchronous = nil, {id=123,line=10,market=100}, nil, nil
local canQuery, lastQueryAt
local undercutTicker
local watchByID = {}
local processed = {}
local function num(value) return tonumber(value) end
local function freshMedian(samples) return samples and samples[1] end
function S.marketReference(id) return freshMedian(db.book[id] and db.book[id].s) end
function S.salesPolicy() end
local function processBrowseRows(rows) processed[#processed+1]=rows end
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
local function requestItemLoad() end
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
local on = onOptional
`;

const production = section('local SCAN_CATEGORIES =', '\nif db.boughtAt == nil')
  + section('local throttleReady, pagePending', '\nS.autoChecked =')
  + section('local function queryPacing()', '\nlocal function requestItemSearch')
  + section('canQuery = function(paging)', '\nlocal function discoveryScope')
  + section('do\n    -- Seed only,', '\ndo\n    function S.failBatch')
  + section('do\n    function S.failBatch', '\nlocal function sweepQuery()')
  + section('local function sweepQuery()', '\n-- DEEP')
  + section('-- DEEP SCAN (/fsn deepscan', '\nfunction S.wakeSweep()')
  + section('function S.wakeSweep()', '\n\n-- BATCH RELIST:')
  + section('stopRelisting = function()', '\nlocal function startRelisting')
  + section('do\nlocal function readDeepBrowse', '\n-- Event-driven throttle')
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

test('liquidity adds a bounded priority boost without starving older candidates', () => check(`
  function S.salesPolicy(id) if id==1 then return {rate=1,daily=100000} end end
  assert(S.candidatePriority({id=1,t=now})==2)
  assert(S.candidatePriority({id=2,t=now-8})>S.candidatePriority({id=1,t=now,profit=1000000000}))
`));

test('sales caps refresh owned stock with the manual cap off', () => check(`
  cfg.sales=true; local sent=0
  function S.requestSellingOwned() sent=sent+1; return true end
  sweepQuery(); assert(sent==1 and #queries==0)
`));

test('a focused validated offer gets one five-second ready window, then discovery resumes', () => check(`
  focus={id=123,line=10,market=100}; S.dealFocus={deal=focus}
  sweepQuery(); assert(#queries==0 and S.dealFocus.buyWindowUntil==105)
  now=104.9; sweepQuery(); assert(#queries==0)
  now=105; sweepQuery(); assert(#queries==1)
  complete(); now=106; sweepQuery(); assert(#queries==2)
  assert(S.dealFocus.buyWindowUntil==105)
`));

test('the focused click window begins at live readiness, not while the AH is busy', () => check(`
  focus={id=123,line=10,market=100}; S.dealFocus={deal=focus}
  ready=false; sweepQuery(); assert(not S.dealFocus.buyWindowUntil)
  now=110; ready=true; sweepQuery()
  assert(S.dealFocus.buyWindowUntil==115 and #queries==0)
`));

test('focused click windows never interrupt owned result pagination', () => check(`
  focus={id=123,line=10,market=100}; S.dealFocus={deal=focus}
  S.liveCandidate={id=456,t=now,needsPage=true}
  sweepQuery(); assert(count("page",456)==1)
  assert(not S.dealFocus.buyWindowUntil)
`));

test('ready events refresh purchase controls before scheduling another search', () => check(`
  local refreshed=0
  function S.refreshPurchasePresentation()
    refreshed=refreshed+1
    assert(not S.sweepWake)
  end
  S.sweepTicker={}
  handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  assert(refreshed==1 and S.sweepWake)
  S.sweepWake=nil
  handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED()
  assert(refreshed==2 and S.sweepWake)
`));

const batchSetup = `
  cfg.batch=true; cfg.minUnit=1; cfg.freshMins=45; cfg.armAfter=2
  local resultRows, full, submit = {}, true, nil
  C_AuctionHouse.MakeItemKey=function(id) return {itemID=id} end
  C_AuctionHouse.SearchForItemKeys=function(keys)
    record("batch",#keys)
    if submit then submit(keys) end
  end
  C_AuctionHouse.GetBrowseResults=function() return resultRows end
  C_AuctionHouse.HasFullBrowseResults=function() return full end
  for id=1,205 do db.book[id]={s={100}} end
`;
function batchCheck(code) { check(batchSetup + code); }

const targetedSetup = `
  cfg.targeted=true
  ForeverSniperTSM={marketIdentity=function() return "normal-horde","forever-eu" end}
  function S.marketReference() return 10000 end
  auto=nil
`;
function targetedCheck(code) { batchCheck(targetedSetup + code); }

test('targeted seed contains 101 materials and bootstraps without changing the book', () => targetedCheck(`
  db.book={}
  local n=0; for id in pairs(S.targetedPool()) do assert(id>0 and id%1==0); n=n+1 end
  assert(n==101 and S.targetedItems[2592] and S.targetedItems[12360])
  assert(S.startBatch() and S.batchSearch.count==100)
  assert(next(db.book)==nil)
`));

test('targeted batches cover all 101 keys without the broad cooldown or discovery slots', () => targetedCheck(`
  local seen={}
  submit=function(keys)
    assert(#keys<=100)
    for _,key in ipairs(keys) do assert(S.targetedItems[key.itemID]); seen[key.itemID]=true end
    S.readBatch()
  end
  slots(2)
  local n=0; for _ in pairs(seen) do n=n+1 end
  assert(n==101 and count("batch")==2 and count("browse")==0)
  slots(6)
  assert(count("batch")==8 and count("browse")==0 and count("target")==0)
  assert(S.targetedStatus():find("101 distinct batch checks",1,true))
`));

test('real individual selector honours the target pool, budget and zero revisit cooldown', () => targetedCheck(`
  function S.purchaseBudget() return 10000 end
  local function dealLine(market) return market*.7 end
  local function infoOf() return {quality=2,stackable=true} end
  local function absorbVelocity() end
  local function movementScore() return 0 end
  ${section('local function nextAutoTarget(', '\n-- one watched item')}
  local pool={[2592]=true,[2775]=true}
  db.book={}; S.autoChecked[2592]=now; db.blacklist[2775]=true
  local target=nextAutoTarget(pool,0)
  assert(target and target.id==2592 and target.line==7000)
  assert(nextAutoTarget(pool,10)==nil)
  function S.purchaseBudget() return 6999 end
  assert(nextAutoTarget(pool,0)==nil)
  function S.purchaseBudget() return 10000 end
  commodityFor=function() return false end
  assert(nextAutoTarget(pool,0)==nil)
`));

test('targeted mode checks market identity and never falls through to broad searches', () => {
  for (const identity of [
    'return "normal-alliance","forever-eu"', 'return "hardcore-horde","forever-hc-eu"',
    'return "normal-horde","forever-us"', 'return nil,nil',
  ]) targetedCheck(`
    ForeverSniperTSM.marketIdentity=function() ${identity} end
    slots(8); assert(#queries==0 and not S.targetedPool())
  `);
  targetedCheck('ForeverSniperTSM=nil; slots(4); assert(#queries==0)');
});

test('targeted eligibility retains live commodity, blacklist, watch and reference checks', () => targetedCheck(`
  S.targetedItems={[1]=true,[2]=true,[3]=true,[4]=true,[5]=true,[6]=true}
  watchByID[1]={}; db.blacklist[2]=true
  local warmed=0
  requestItemLoad=function(id) assert(id==4); warmed=warmed+1 end
  commodityFor=function(id) if id==4 then return nil end return id~=3 end
  function S.marketReference(id) if id==5 then return 0 end return 10000 end
  submit=function(keys) assert(#keys==1 and keys[1].itemID==6) end
  assert(S.startBatch() and warmed==1)
`));

test('targeted candidates get detail checks before another summary, without discovery debt', () => targetedCheck(`
  local id=2592
  S.discoveryDue=true
  S.liveCandidates={[id]={id=id,t=now,line=10,market=10000},[999]={id=999,t=now}}
  slots(1)
  assert(count("target",id)==1 and count("batch")==0 and not S.discoveryDue)
  assert(not S.liveCandidates[999])
`));

test('targeted batch failure and missing APIs restrict individual fallback to the seed pool', () => {
  for (const change of ['S.batchDisabled="failed"', 'cfg.batch=false', 'C_AuctionHouse.SearchForItemKeys=nil']) targetedCheck(`
    ${change}
    nextAutoTarget=function(pool,cooldown)
      assert(pool==S.targetedItems and cooldown==0)
      return {id=2592,line=10,market=10000}
    end
    slots(8)
    assert(count("target",2592)==8 and count("browse")==0 and count("batch")==0)
  `);
});

test('targeted mode with no eligible keys idles instead of running a broad query', () => targetedCheck(`
  function S.marketReference() end
  slots(8); assert(#queries==0)
`));

test('targeted summaries retain candidate-only processing and buy locks', () => {
  targetedCheck(`
    submit=function(keys)
      resultRows={{itemKey=keys[1],minPrice=10,totalQuantity=50}}
      S.readBatch()
    end
    slots(1)
    assert(#processed==1 and next(S.commoditySnapshots)==nil and #S.deals==0)
  `);
  for (const change of ['db.unsettledPurchase={}', 'S.quote={}', 'S.batchBuy={pending=true}', 'ready=false', 'nativeSell=true']) {
    targetedCheck(`${change}; slots(4); assert(#queries==0)`);
  }
});

test('targeted batches retain shared one-second and rolling-minute pacing', () => targetedCheck(`
  submit=function() S.readBatch() end
  for i=0,700 do now=100+i/10; sweepQuery() end
  for i,query in ipairs(queries) do
    if i>1 then assert(query.t-queries[i-1].t>=1) end
    local n=0
    for j=i,1,-1 do if query.t-queries[j].t>=60 then break end n=n+1 end
    assert(n<=60)
  end
  assert(count("batch")>=60 and count("browse")==0)
`));

test('targeted command preserves saved watches and in-flight ownership', () => {
  const command = section('    elseif cmd == "targeted" then', '\n    elseif cmd == "sweep" then')
    .replace('elseif cmd', 'if cmd');
  targetedCheck(`
    local function command(rest)
      local cmd="targeted"
      ${command}
      end
    end
    db.watch[2592]={maxPrice=100}; local watches=db.watch
    assert(S.startBatch()); local owner=S.batchSearch
    command("off"); assert(not cfg.targeted and S.batchSearch==owner)
    S.discoveryDue=true; command("on")
    assert(cfg.targeted and not S.discoveryDue and db.watch==watches)
    command("invalid"); assert(cfg.targeted and S.batchSearch==owner)
    S.readBatch(); assert(S.targetedSeen and not S.batchSearch)
  `);
});

test('batch targets can use a trusted reference before local history has warmed up', () => batchCheck(`
  db.book={[123]={s={}}}
  function S.marketReference(id) assert(id==123); return 10000 end
  assert(S.startBatch() and S.batchSearch.ids[123])
`));

test('owner-approved default enables batching without overriding explicit saved choices', () => {
  const init = section('local DEFAULTS =', '\n-- one-time retune:');
  for (const setting of ['nil', 'false', 'true']) run(`
    ForeverSniperDB={config={batch=${setting}}}
    ${init}
    assert(db.config.batch==${setting === 'nil' ? 'true' : setting})
  `);
});

test('targeted mode is opt-in and preserves explicit saved choices', () => {
  const init = section('local DEFAULTS =', '\n-- one-time retune:');
  for (const setting of ['nil', 'false', 'true']) run(`
    ForeverSniperDB={config={targeted=${setting}}}
    ${init}
    assert(db.config.targeted==${setting === 'nil' ? 'false' : setting})
  `);
});

test('prebuy test is opt-in and preserves explicit saved choices', () => {
  const init = section('local DEFAULTS =', '\n-- one-time retune:');
  for (const setting of ['nil', 'false', 'true']) run(`
    ForeverSniperDB={config={prebuy=${setting}}}
    ${init}
    assert(db.config.prebuy==${setting === 'nil' ? 'false' : setting})
  `);
});

test('prebuy holds a bounded second-press window without starting a purchase', () => check(`
  cfg.prebuy=true; S.prebuyCheck={completedAt=100}
  now=101; sweepQuery(); assert(#queries==0)
  now=102; sweepQuery(); assert(#queries==0)
  now=102.1; sweepQuery(); assert(count("target")==1)
`));

test('forced prebuy dispatch bypasses cached-result refresh and owns synchronous replies', () => check(`
  ${section('local function requestItemSearch(', '\nlocal function searchListing').replace('local function requestItemSearch(', 'requestItemSearch = function(')}
  local refreshed,sent=0,0
  C_AuctionHouse.MakeItemKey=function(id) return {itemID=id} end
  C_AuctionHouse.HasSearchResults=function() return true end
  C_AuctionHouse.RefreshCommoditySearchResults=function() refreshed=refreshed+1 end
  C_AuctionHouse.SendSearchQuery=function(key)
    assert(S.liveCandidate and S.liveCandidate.id==key.itemID and S.liveCandidate.prebuy)
    assert(S.searchMethods[key.itemID]=='new item search')
    sent=sent+1
  end
  sendTargetSearch('autoSearch',{id=123})
  assert(refreshed==1 and sent==0 and S.searchMethods[123]=='refresh commodity')
  complete(); now=101
  sendTargetSearch('liveCandidate',{id=123,prebuy={}})
  assert(refreshed==1 and sent==1 and S.liveCandidate.searchStartedAt==101)
`));

test('batch command toggles future requests without abandoning an in-flight owner', () => {
  const command = section('    elseif cmd == "batch" then', '\n    elseif cmd == "prebuy" then')
    .replace('elseif cmd', 'if cmd');
  batchCheck(`
    local function command(rest)
      local cmd="batch"
      ${command}
      end
    end
    S.batchDisabled="failed"
    command("invalid"); assert(S.batchDisabled=="failed")
    command("on"); assert(cfg.batch and not S.batchDisabled)
    assert(S.startBatch()); local owner=S.batchSearch
    command("off"); assert(not cfg.batch and S.batchSearch==owner)
    S.readBatch(); assert(not S.batchSearch)
  `);
});

test('batch requests are bounded, deterministic and rotate across known keys', () => batchCheck(`
  local batches={}
  submit=function(keys) batches[#batches+1]=keys end
  slots(5)
  -- Complete each summary before allowing the next target opportunity.
  assert(count("batch")==1 and #batches[1]==100)
  assert(batches[1][1].itemID==1 and batches[1][100].itemID==100)
  S.readBatch(); now=now+1; assert(S.startBatch())
  assert(#batches[2]==100 and batches[2][1].itemID==101)
  S.readBatch(); now=now+1; assert(S.startBatch())
  assert(#batches[3]==5 and batches[3][1].itemID==201)
  S.readBatch(); assert(not S.startBatch())
  assert(S.sweepStats.batchKeys==205)
`));

test('batch mode preserves broad discovery opportunities', () => batchCheck(`
  submit=function() S.readBatch() end
  slots(8)
  assert(count("batch")==3 and count("browse")==2 and count("target")==3)
`));

test('batch replies use the shared candidate pipeline, never a tier snapshot', () => batchCheck(`
  submit=function(keys)
    assert(S.batchSearch and S.batchSearch.ids[keys[1].itemID])
    resultRows={{itemKey=keys[1], minPrice=10,totalQuantity=50}}
    handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
  end
  slots(1)
  assert(S.batchSearch==nil and #processed==1)
  assert(processed[1][1].minPrice==10)
  assert(next(S.commoditySnapshots)==nil and #S.deals==0)
  assert(S.sweepStats.batchCompleted==1 and S.sweepStats.batchRows==1)
`));

test('missing or disabled batch API preserves individual checks', () => {
  for (const change of [
    'cfg.batch=false', 'C_AuctionHouse.SearchForItemKeys=nil',
    'C_AuctionHouse.MakeItemKey=nil', 'C_AuctionHouse.HasFullBrowseResults=nil',
  ]) batchCheck(`${change}; slots(1); assert(count("target")==1 and count("batch")==0)`);
});

test('batch eligibility excludes watches, blacklist, stale history and noncommodities', () => batchCheck(`
  db.book={ [1]={s={100}},[2]={s={100}},[3]={s={100}},[4]={s={}},[5]={s={100}} }
  watchByID[1]={}; db.blacklist[2]=true
  commodityFor=function(id) return id~=3 end
  submit=function(keys) assert(#keys==1 and keys[1].itemID==5) end
  assert(S.startBatch())
`));

test('uncached or invalid item keys cannot starve later valid batch keys', () => batchCheck(`
  C_AuctionHouse.MakeItemKey=function(id)
    if id<=100 then error("uncached") end
    return {itemID=id}
  end
  submit=function(keys)
    assert(#keys==100 and keys[1].itemID==101 and keys[100].itemID==200)
  end
  assert(S.startBatch())
`));

test('batch ownership blocks new searches, inspection gates and deep requests', () => batchCheck(`
  slots(1)
  assert(S.batchSearch and not canQuery() and not canQuery(true))
  now=now+1; sweepQuery(); assert(#queries==1)
  startDeepScan(true); now=now+1; S.deepScan.ticker.fn()
  assert(#queries==1)
`));

test('batch mode still honours all purchase, readiness and native-form gates', () => {
  for (const change of [
    'S.snipePending={}', 'db.unsettledPurchase={}', 'S.quote={}',
    'S.batchBuy={pending=true}', 'nativeSell=true', 'ready=false',
    'S.pending={}', 'S.buying=true', 'cfg.enabled=false', 'S.ahOpen=false',
  ]) batchCheck(`${change}; slots(1); assert(#queries==0)`);
});

test('manual watches and displayed deal refreshes keep priority over batches', () => batchCheck(`
  watch=456; slots(1)
  assert(count("target",456)==1 and count("batch")==0)
  focus={id=999,line=10,market=100}; S.dealFocus={deal=focus}
  complete(); now=now+1; sweepQuery()
  assert(count("target",999)==0 and S.dealFocus.buyWindowUntil==now+5)
  now=now+5
  slots(1); assert(count("batch")==1)
  S.readBatch(); slots(1)
  assert(count("target",999)==1 and count("batch")==1)
`));

test('bad, foreign, duplicate and incomplete summaries trigger fallback without processing', () => {
  for (const reply of [
    'full=false', 'resultRows=false', 'resultRows={false}',
    'resultRows={{itemKey={itemID=999},minPrice=1,totalQuantity=1}}',
    'resultRows={{itemKey={itemID=1},minPrice=-1,totalQuantity=1}}',
    'resultRows={{itemKey={itemID=1},minPrice=1,totalQuantity=0.5}}',
    'resultRows={{itemKey={itemID=1},minPrice=1,totalQuantity=1},{itemKey={itemID=1},minPrice=1,totalQuantity=1}}',
  ]) batchCheck(`
    slots(1); ${reply}
    handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    assert(S.batchDisabled and not S.batchSearch and #processed==0)
    assert(next(S.batchChecked)==nil)
    slots(2); assert(count("target")==2 and count("batch")==1)
  `);
});

test('batch submission errors, timeouts and dropped requests use paced individual fallback', () => {
  for (const failure of [
    'submit=function() error("unsupported") end; slots(1)',
    'slots(1); now=now+5; sweepQuery()',
    'slots(1); handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()',
    'slots(1); handlers.AUCTION_HOUSE_BROWSE_FAILURE()',
  ]) batchCheck(`
    ${failure}
    assert(S.batchDisabled and not S.batchSearch)
    local before=#queries; sweepQuery(); assert(#queries==before)
    slots(2); assert(count("batch")==1 and count("target")>=1)
    assert(S.sweepStats.batchFailures==1)
  `);
});

test('turning off batches or stopping does not leave a stale owner', () => batchCheck(`
  startSweeping(); advance(100.01); assert(S.batchSearch)
  cfg.batch=false
  assert(not canQuery())
  S.readBatch(); assert(not S.batchSearch)
  cfg.batch=true; now=now+1; assert(S.startBatch())
  stopSweeping(); assert(S.batchSearch) -- a timer restart must retain ownership
  S.ahOpen=false; stopSweeping(); assert(not S.batchSearch)
`));

test('unchanged summaries remain eligible on the next revisit, including quantity changes below 1%', () => batchCheck(`
  db.book={[1]={s={100}}}
  resultRows={{itemKey={itemID=1},minPrice=10,totalQuantity=1000}}
  assert(S.startBatch()); S.readBatch()
  now=now+10
  assert(S.startBatch()); S.readBatch()
  now=now+10; resultRows[1].totalQuantity=1001
  assert(S.startBatch()); S.readBatch()
  assert(#processed==3)
`));

test('candidate value boost is bounded so aging prevents starvation', () => check(`
  S.liveCandidates={
    [1]={id=1,t=now,line=10,profit=1000000},
    [2]={id=2,t=now,line=10,profit=1},
  }
  slots(1); assert(count("target",1)==1)
  S.liveCandidates[1]={id=1,t=now+10,line=10,profit=100000000}
  complete(); now=now+11; sweepQuery(); complete(); now=now+1; sweepQuery()
  assert(count("target",2)==1)
`));

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

test('discovery receives every fourth slot with automatic targets available', () => check(`
  slots(16)
  assert(count("browse")==4 and count("target",123)==12)
`));

test('a displayed deal cannot stop discovery and only takes bounded refresh slots', () => check(`
  focus={id=999,line=10,market=100,kind="market"}
  S.dealFocus={deal=focus}
  sweepQuery(); assert(#queries==0 and S.dealFocus.buyWindowUntil==105)
  now=105
  slots(40)
  assert(count("browse")==10)
  assert(count("target",999)>0 and count("target",999)<=3)
  assert(count("target",123)>=27)
`));

test('manual watches retain their slot while discovery and automatic checks continue', () => check(`
  watch=456
  slots(16)
  assert(count("target",456)==4 and count("target",123)==8 and count("browse")==4)
`));

test('continuous candidates can defer discovery by only one slot', () => check(`
  S.liveCandidates={}
  for id=1,20 do S.liveCandidates[id]={id=id,t=now,line=10,market=100} end
  slots(9)
  assert(count("browse")==2 and count("target")==7)
  assert(queries[4].kind=="target" and queries[5].kind=="browse")
  assert(queries[8].kind=="target" and queries[9].kind=="browse")
`));

test('a fresh bargain borrows discovery then repays before another candidate', () => check(`
  slots(3)
  S.liveCandidates={[789]={id=789,t=now,detectedAt=now,line=10,market=100}}
  slots(1)
  assert(count("target",789)==1 and count("browse")==0 and S.discoveryDue)
  assert(S.sweepStats.queueLast==1 and S.sweepStats.queueMax==1)
  S.liveCandidates[790]={id=790,t=now,line=10,market=100}
  slots(1)
  assert(count("browse")==1 and count("target",790)==0 and not S.discoveryDue)
  slots(1); assert(count("target",790)==1)
`));

test('queued bargains precede background refresh after the existing click window', () => check(`
  slots(2)
  focus={id=999,line=10,market=100}; S.dealFocus={deal=focus,buyWindowUntil=now}
  S.liveCandidates={[789]={id=789,t=now,line=10,market=100}}
  slots(1); assert(count("target",789)==1 and count("target",999)==0)
`));

test('borrowing never bypasses throttle or an owned search', () => check(`
  slots(3)
  S.liveCandidates={[789]={id=789,t=now,line=10,market=100}}
  complete(); ready=false; now=now+1; sweepQuery()
  assert(#queries==3 and not S.discoveryDue)
  ready=true; S.autoSearch={id=123,t=now}; sweepQuery()
  assert(#queries==3 and not S.discoveryDue)
  complete(); sweepQuery(); assert(count("target",789)==1 and S.discoveryDue)
`));

test('failed borrowed validation still reserves the next discovery slot', () => check(`
  slots(3)
  S.liveCandidates={[789]={id=789,t=now,line=10,market=100}}
  requestItemSearch=function() error("submission failed") end
  slots(1); assert(S.discoveryDue and not S.liveCandidate)
  S.liveCandidates[790]={id=790,t=now,line=10,market=100}
  slots(1); assert(count("browse")==1 and not S.discoveryDue)
`));

test('discovery borrowing is disabled while deep or native browse owns the channel', () => {
  for (const owner of ['S.deepScan={}', 'browseVisible=true']) check(`
    slots(3)
    S.liveCandidates={[789]={id=789,t=now,line=10,market=100}}
    ${owner}
    slots(1)
    assert(not S.discoveryDue and count("target",789)==0 and S.liveCandidates[789])
    slots(1); assert(count("target",789)==1)
  `);
});

test('queued bargains use the next monitoring slot ahead of watches and speculative searches', () => check(`
  watch=456
  slots(1); assert(count("target",456)==1)
  S.liveCandidates={[789]={id=789,t=now,line=10,market=100,detectedAt=now}}
  slots(1); assert(count("target",789)==1 and count("browse")==0)
  assert(S.liveCandidate.detectedAt==101)
`));

test('batch hot-item boost is bounded so older coverage still wins', () => batchCheck(`
  db.book={[1]={s={now,80}},[2]={s={now,100}}}
  function S.marketReference() return 100 end
  S.batchChecked={[1]=now-10,[2]=now-12}
  submit=function(keys) assert(keys[1].itemID==1) end
  assert(S.startBatch()); S.readBatch()
  now=now+10; S.batchChecked[2]=now-16
  submit=function(keys) assert(keys[1].itemID==2) end
  assert(S.startBatch())
`));

test('completed checks record actual revisit intervals, not submission counts', () => check(`
  S.noteRevisit(123); assert(not S.sweepStats.revisitCount)
  now=now+7; S.noteRevisit(123)
  now=now+11; S.noteRevisit(123)
  assert(S.revisitByID[123]==11 and S.checkedAt[123]==now)
  assert(S.sweepStats.revisitCount==2 and S.sweepStats.revisitTotal==18)
  assert(S.sweepStats.revisitMax==11)
`));

test('deep pages yield to fresh candidates and have bounded background spacing', () => check(`
  startDeepScan(true); local scan=S.deepScan; scan.wantsPage=true
  now=103; scan.ticker.fn(); assert(count("deep page")==0)
  now=104; S.liveCandidates={[789]={id=789,t=now}}
  scan.ticker.fn(); assert(count("deep page")==0)
  S.liveCandidates=nil; scan.ticker.fn(); assert(count("deep page")==1)
  scan.wantsPage=true; now=107; scan.ticker.fn(); assert(count("deep page")==1)
  now=108; scan.ticker.fn(); assert(count("deep page")==2)
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

test('a stale sent-event flag cannot veto live readiness after minimum spacing', () => check(`
  S.sweepTicker={}; lastQueryAt=now
  handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_SENT()
  now=100.9; sweepQuery(); assert(#queries==0)
  now=101; sweepQuery(); assert(#queries==1)
`));

test('out-of-order queued events cannot add a five-second wait after a ready wake', () => check(`
  S.sweepTicker={}; lastQueryAt=now
  handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED()
  advance(101)
  assert(#queries==1)
`));

test('live busy readiness still blocks queries regardless of cached readiness', () => check(`
  S.sweepTicker={}; lastQueryAt=now
  handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  ready=false
  advance(101); assert(#queries==0)
  now=106; sweepQuery(); assert(#queries==0)
`));

test('feed distinguishes owned batch and browse replies from idle throttle waits', () => {
  check(`
    local function countKeys(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
    local function recentGateReasons() return nil,{} end
    local function fmtMoney(v) return tostring(v) end
    local function historyReadiness() return {ready=0,warming=0,stale=0} end
    S.session={}; cfg.armAfter=2
    ${section('local function feedOverview(visibleCount)', '\nlocal function refreshFeed()')}
    ready=false
    S.batchSearch={t=now}
    assert(feedOverview(0):find("Waiting for batch summaries",1,true))
    S.batchSearch=nil; S.sweeping=true
    assert(feedOverview(0):find("Waiting for discovery results",1,true))
    S.sweeping=false
    assert(feedOverview(0):find("Waiting for AH throttle",1,true))
    S.batchSearch={t=now}; S.snipePending={}
    assert(feedOverview(0):find("Purchase pending",1,true))
  `);
});

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
  scan.ticker.fn(); assert(count("deep page")==0)
  now=106
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
  advance(101.02); assert(#queries==2 and queries[2].kind=="failed target")
`));

test('dropped requests wake a paced recovery rather than bypassing spacing', () => check(`
  S.sweepTicker={}; lastQueryAt=now; pagePending=true; throttleReady=false
  handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
  advance(100.9); assert(#queries==0)
  advance(101); assert(#queries==1)
`));
