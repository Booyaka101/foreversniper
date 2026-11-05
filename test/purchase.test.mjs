import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import fengari from 'fengari';

const source = fs.readFileSync(new URL('../ForeverSniper.lua', import.meta.url), 'utf8');
function section(start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  assert.ok(first >= 0 && last > first, `Missing Lua test boundary: ${start}`);
  return source.slice(first, last);
}

// Execute the production purchase functions and event handlers, not a JS port.
const purchase = section('local confirmFrame', '\n-- Buy path')
  + section('local function clearPurchase()', '\n-- ');
const results = section('local function printPending(kind)', '\n-- options panel:');
const query = section('local function canQuery()', '\nlocal function processBrowseRows');
const close = section('on("AUCTION_HOUSE_CLOSED", function()', '\n    stopSweeping()') + '\nend)';
const preamble = `
local now = 100
local cfg = { maxSpend = 1000, enabled = true }
local S = { ahOpen = true, boughtAt = {}, session = { spent = 0, buys = 0 }, deals = {} }
local calls = { start = 0, confirm = 0, cancel = 0, bid = 0, search = 0 }
local handlers = {}
local function on(event, fn) handlers[event] = fn end
local onOptional = on
local function num(v) return tonumber(v) end
local function printf(...) end
local function err(...) end
local function fmtMoney(v) return tostring(v) end
local function refreshFeed() end
local function infoOf() return { stackable = true } end
local function fireAlert() end
local function GetTime() return now end
local function time() return now end
local UIParent = {}
local commodityRows = { { unitPrice = 100, quantity = 2 } }
local itemRows = { { auctionID = 10, buyoutAmount = 200, quantity = 2 } }
local C_AuctionHouse = {
  StartCommoditiesPurchase = function() calls.start = calls.start + 1 end,
  ConfirmCommoditiesPurchase = function() calls.confirm = calls.confirm + 1 end,
  CancelCommoditiesPurchase = function() calls.cancel = calls.cancel + 1 end,
  PlaceBid = function() calls.bid = calls.bid + 1 end,
  SendSearchQuery = function() calls.search = calls.search + 1 end,
  GetItemCommodityStatus = function() return true end,
  GetCommoditySearchResultInfo = function(_, i) return commodityRows[i] end,
  GetNumItemSearchResults = function() return #itemRows end,
  GetItemSearchResultInfo = function(_, i) return itemRows[i] end,
}
local function CreateFrame(_, _, parent)
  local f = { parent = parent, scripts = {}, shown = false }
  function f:SetScript(name, fn) self.scripts[name] = fn end
  function f:GetParent() return self.parent end
  function f:SetText(text) self.text = text end
  function f:Enable() self.enabled = true end
  function f:Disable() self.enabled = false end
  function f:Show() self.shown = true end
  function f:IsShown() return self.shown end
  function f:Hide()
    local shown = self.shown
    self.shown = false
    if shown and self.scripts.OnHide then self.scripts.OnHide(self) end
  end
  local function noop() end
  for _, name in ipairs({"SetSize", "SetPoint", "SetMovable", "EnableMouse", "RegisterForDrag", "SetWidth"}) do
    f[name] = noop
  end
  f.TitleText = { SetText = noop }
  function f:CreateFontString() return CreateFrame() end
  return f
end
local throttleReady, pagePending, lastQueryAt = true, false, 0
`;
const helpers = `
local function search(commodity)
  C_AuctionHouse.GetItemCommodityStatus = function() return commodity end
  buySweep(123, "test item", 100, 200)
end
local function results(commodity, id)
  if commodity then handlers.COMMODITY_SEARCH_RESULTS_UPDATED(id or 123)
  else handlers.ITEM_SEARCH_RESULTS_UPDATED({ itemID = id or 123 }) end
end
local function click() confirmFrame.buy.scripts.OnClick(confirmFrame.buy) end
local function quote(unit, total) handlers.COMMODITY_PRICE_UPDATED(unit, total) end
local function ready() search(true) results(true) click() quote(100, 200) end
`;

function run(body) {
  const L = fengari.lauxlib.luaL_newstate();
  fengari.lualib.luaL_openlibs(L);
  try {
    const status = fengari.lauxlib.luaL_dostring(L, fengari.to_luastring(
      preamble + purchase + query + results + close + helpers + body));
    const error = status === fengari.lua.LUA_OK ? '' : fengari.to_jsstring(fengari.lua.lua_tostring(L, -1));
    assert.equal(status, fengari.lua.LUA_OK, error);
  } finally {
    fengari.lua.lua_close(L);
  }
}

test('commodity confirmation waits for the two-field server quote and uses its total', () => run(`
  search(true) results(true) click()
  assert(calls.start == 1 and not confirmFrame.buy.enabled)
  click()
  assert(calls.confirm == 0)
  quote(90, 180)
  assert(confirmFrame.buy.enabled and confirmFrame.buy.text == "Confirm")
  assert(S.session.spent == 0)
  click()
  assert(calls.confirm == 1 and S.session.spent == 180)
  assert(S.quote == nil and confirmFrame.q == nil and calls.cancel == 0)
`));

test('over-cap, over-line, missing and invalid quote prices abort without buying', () => {
  for (const quote of ['100, 1001', '101, 200', '90, 201', '100, nil', '0, 200', '100, -1']) {
    run(`search(true) results(true) click() quote(${quote})
      assert(calls.confirm == 0 and calls.cancel == 1)
      assert(S.quote == nil and confirmFrame.q == nil)`);
  }
});

test('quote expiry, dialog expiry and a reduced cap are checked again on click', () => {
  for (const change of [
    'now = now + 11', 'cfg.maxSpend = 199', 'S.ahOpen = false',
    'C_AuctionHouse.GetQuoteDurationRemaining = function() return 0 end',
    'C_AuctionHouse.GetQuoteDurationRemaining = function() error("unavailable") end',
  ]) {
    run(`ready() ${change} click()
      assert(calls.confirm == 0 and S.quote == nil and confirmFrame.q == nil)`);
  }
  run(`search(true) results(true) now = now + 16 click() assert(calls.start == 0)`);
  run(`search(true) results(true) click() now = now + 16 quote(100, 200)
    assert(S.quote == nil and calls.confirm == 0)`);
});

test('cancel, window close, unavailable quote and AH close clear purchase state', () => {
  for (const action of [
    'confirmFrame.cancel.scripts.OnClick()',
    'confirmFrame:Hide()',
    'handlers.COMMODITY_PRICE_UNAVAILABLE()',
    'handlers.AUCTION_HOUSE_CLOSED()',
  ]) run(`ready() ${action} quote(90, 180)
    assert(S.quote == nil and confirmFrame.q == nil and calls.confirm == 0)
    assert(calls.cancel == 1)`);
});

test('result events must match both item ID and purchase kind', () => run(`
  search(true)
  results(true, 456) results(false)
  assert(S.buying and not confirmFrame)
  results(true)
  assert(not S.buying and confirmFrame.q.commodity)
`));

test('purchase searches own their results and pause background sweeps', () => run(`
  S.watchSearch = { id = 123, maxPrice = 100, t = now }
  search(false)
  assert(not S.watchSearch and not canQuery())
  search(false) assert(calls.search == 1)
  results(false)
  assert(confirmFrame.q and not canQuery())
  searchListing(456, "other item", 1)
  assert(calls.search == 1)
  now = now + 16
  assert(canQuery() and not confirmFrame.q)
`));

test('stale results and failed searches never produce a purchase dialog', () => run(`
  search(true) now = now + 16 results(true)
  assert(not S.buying and not confirmFrame)
  C_AuctionHouse.SendSearchQuery = function() error("failed") end
  search(true) assert(not S.buying)
`));

test('quote API errors clear state without recording a purchase', () => {
  run(`search(true) results(true)
    C_AuctionHouse.StartCommoditiesPurchase = function() error("failed") end
    click() assert(not S.quote and not confirmFrame.q and S.session.spent == 0)`);
  run(`ready()
    C_AuctionHouse.ConfirmCommoditiesPurchase = function() error("failed") end
    click() assert(not S.quote and not confirmFrame.q and S.session.spent == 0)`);
});

test('item purchases enforce exact unit ceiling, cap and dialog freshness', () => {
  run(`itemRows[1].buyoutAmount = 201 search(false) results(false)
    assert(not confirmFrame and calls.bid == 0)`);
  run(`search(false) results(false) now = now + 16 click() assert(calls.bid == 0)`);
  run(`search(false) results(false) cfg.maxSpend = 199 click() assert(calls.bid == 0)`);
  run(`search(false) results(false) click() assert(calls.bid == 1 and S.session.spent == 200)`);
});

test('state is registered before synchronous search and quote callbacks', () => run(`
  C_AuctionHouse.SendSearchQuery = function() results(true) end
  search(true)
  assert(confirmFrame.q)
  C_AuctionHouse.StartCommoditiesPurchase = function() quote(90, 180) end
  click()
  assert(confirmFrame.buy.enabled and confirmFrame.buy.text == "Confirm")
  click() assert(calls.confirm == 1)
`));
