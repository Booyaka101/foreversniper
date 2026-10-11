-- ForeverSniper.lua - auction deal sniper for the WoW: Forever beta.
--
-- How it works
--   * While the auction house window is open, the addon keeps requesting the
--     full-listing snapshot (C_AuctionHouse.ReplicateItems) on a cadence.
--   * Every completed scan does two jobs:
--       1. LEARN - per item, remember this scan's cheapest unit price. The
--          "market value" of an item is the median of the last 8 scan
--          minimums, so one mislisted 1c item cannot define a market.
--       2. SNIPE - diff the scan against the previous one. When a NEW listing
--          appears at or under threshold% of market, the whole DEPTH of that
--          item under the line is swept - every unit of every cheap listing,
--          totalled. A deal only fires if the estimated resale profit of the
--          sweep (market after the AH cut, minus cost) clears the profit
--          floor and the item clears the quality floor. Stackables report as
--          one lot ("240 units under market, 58g total"), not one listing at
--          a time. Watchlist rules (any [item] under [price]) sweep the same
--          way against the rule's own price ceiling.
--
-- Buying: every purchase this addon makes happens strictly inside a click you
-- made on a Buy button. Blizzard gates the purchase calls behind hardware
-- events on purpose - that gate is the whole security model, and it is
-- honored here: no timers, no event-driven purchases, no automation of any
-- kind. Each click is bounded by a spend cap, and prices are re-checked fresh
-- at click time, so a stale alert can never buy. Commodities open the filled
-- purchase for your final press; item listings buy out directly on your
-- click, cheapest first, and say exactly what they spent.
--
-- The beta moves week to week, so every C_AuctionHouse call is pcall-wrapped
-- and a failure is recorded in db.errors (the gap is data, ForeverBeacon
-- style). If an API changes shape, the addon goes quiet - mid-AH errors are
-- worse than silence.

local ADDON = ...

-- Database --------------------------------------------------------------------

local DEFAULTS = {
    enabled   = true,    -- master switch
    threshold = 0.50,    -- deal if unit price <= 50% of learned market
    every     = 45,      -- seconds between full scans while the AH is open
    sweep     = 2,       -- seconds between live browse sweeps (the sniper feed)
    freshMins = 45,      -- market age: older price samples do not arm alerts
    overhang  = 500,     -- max competing units above the deal; more = slow flip (0 = off)
    armAfter  = 2,       -- learned samples required before market alerts fire
    minUnit   = 100,     -- ignore deals under 1s per unit (classic economy floor)
    quality   = 1,       -- market alerts need this quality or better (0 = any)
    cut       = 0.05,    -- AH cut assumed when estimating resale profit
    profit    = 1000,    -- deals must clear 10s estimated profit (classic scale)
    maxSpend  = 1000000, -- spend cap per Buy click (100g default)
    sound     = true,
    popup     = true,
    flash     = true,    -- tier-colored screen flash on deals
    toast     = true,    -- slide-in toast notification on deals
    quiet     = false,   -- suppress per-scan summaries
    scanPage  = true,    -- auto-show the scanner monitor when the AH opens
    avoidBrowse = true, -- auto-switch the AH off the Browse tab so sweeps run
    undercut  = true,    -- guard your listings: alert when the market undercuts you
}

ForeverSniperDB = ForeverSniperDB or {}

local db = ForeverSniperDB
db.config    = db.config    or {}
db.book      = db.book      or {}   -- itemID -> { lastSeen, s = {t1,min1,t2,min2,...} }
db.watch     = db.watch     or {}   -- ["123"] by id, ["n:name"] by lowercase name
db.blacklist = db.blacklist or {}
db.errors    = db.errors    or {}
db.alerts    = db.alerts    or {}
db.stats     = db.stats     or {}
db.shape     = db.shape     or nil  -- first replicate return ever seen, as types

for k, v in pairs(DEFAULTS) do
    if db.config[k] == nil then db.config[k] = v end
end
-- one-time retune: installs from the retail-scale era keep their old gates
-- (10s unit floor, 1g profit) which silence a classic economy entirely
if not db.tunedClassic then
    db.tunedClassic = true
    db.config.minUnit = 100      -- 1s: the 12-20s tier markets qualify
    db.config.profit = 0         -- off: prove the pipeline, tighten later
    db.config.threshold = 0.50
    print("|cffff7d0aForever Sniper|r: retuned for the classic economy - 1s unit floor, profit gate off. /fsn profit 10s to raise it once deals flow.")
end
local cfg = db.config

local CAPS = { errors = 200, alerts = 60, samples = 30, book = 12000 }

-- Small helpers ---------------------------------------------------------------

local function push(list, cap, rec)
    list[#list + 1] = rec
    while #list > cap do table.remove(list, 1) end
end

local function err(domain, e)
    push(db.errors, CAPS.errors, { t = time(), domain = tostring(domain), err = tostring(e) })
end

local function printf(fmt, ...)
    print("|cffff7d0aForever Sniper|r: " .. string.format(fmt, ...))
end

-- temporary: trace the replicate pipeline in chat
local DEBUG = false
local function dbg(msg) if DEBUG then print("|cff888888[FSN-D]|r " .. msg) end end


-- Numbers that may be secret on this client never enter the book or the math.
local function num(v)
    if type(v) ~= "number" then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function fmtMoney(c)
    c = math.floor(num(c) or 0)
    if c <= 0 then return "0c" end
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local cc = c % 100
    local out = ""
    if g > 0 then out = string.format("|cffffd100%dg|r ", g) end
    if g > 0 or s > 0 then out = out .. string.format("|cffb8b8b8%ds|r ", s) end
    if cc > 0 or out == "" then out = out .. string.format("|cff9d6c3c%dc|r", cc) end
    return (out:gsub("%s+$", ""))
end

-- "50g", "3g50s", "12s", "500c", plain "50" (= gold), "2g 30s 50c"
local function parseMoney(text)
    text = tostring(text or ""):lower():gsub("%s", "")
    if text == "" or text:match("^%d*$") == "" and not text:match("%d") then return nil end
    local total, any = 0, false
    for amount, suffix in text:gmatch("(%d+)([gsc]?)") do
        amount = tonumber(amount)
        if amount then
            any = true
            if suffix == "g" or suffix == "" then total = total + amount * 10000
            elseif suffix == "s" then total = total + amount * 100
            elseif suffix == "c" then total = total + amount end
        end
    end
    if not any or total <= 0 then return nil end
    return total
end

-- Timers: C_Timer when present, an OnUpdate queue as the fallback.
local fallbackTimers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function(_, elapsed)
    local now = GetTime()
    for i = #fallbackTimers, 1, -1 do
        if now >= fallbackTimers[i].due then
            local fn = fallbackTimers[i].fn
            table.remove(fallbackTimers, i)
            local ok, e = pcall(fn)
            if not ok then err("timer", e) end
        end
    end
    if #fallbackTimers == 0 then timerFrame:Hide() end
end)

local function after(sec, fn)
    if C_Timer and C_Timer.After then
        local ok = pcall(C_Timer.After, sec, fn)
        if ok then return end
    end
    fallbackTimers[#fallbackTimers + 1] = { due = GetTime() + sec, fn = fn }
    timerFrame:Show()
end

-- Book -------------------------------------------------------------------------

local function medianOfSamples(s)
    local vals, n = {}, 0
    for i = 2, #s, 2 do
        n = n + 1
        vals[n] = s[i]
    end
    if n == 0 then return nil end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return math.floor((vals[n / 2] + vals[n / 2 + 1]) / 2)
end

local function sampleCount(s) return math.floor(#s / 2) end

-- Median over FRESH samples only: a price seen an hour ago is not a market you
-- can list into today. Returns nil when fewer than `need` fresh samples exist.
local function freshMedian(s, now, maxAge, need)
    local vals, n = {}, 0
    for i = 1, #s - 1, 2 do
        if now - s[i] <= maxAge then
            n = n + 1
            vals[n] = s[i + 1]
        end
    end
    if n < need then return nil end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return (vals[n / 2] + vals[n / 2 + 1]) / 2
end

-- Item info cache: ONE GetItemInfo per item for name, icon, quality and
-- vendor price. Toast, feed and alerts all read from here - no per-frame
-- item info probing (the old code could pcall GetItemInfo 30+ times a
-- refresh; now it is once per item per session).
local itemInfoCache = {}
local function infoOf(itemID)
    local c = itemInfoCache[itemID]
    if c ~= nil then return c end
    -- direct by-ID queries first: no item link needed, and they answer when
    -- full GetItemInfo is not cached yet (GetItemMaxStackSizeByID is the
    -- stackable oracle on this client)
    local dName, dQuality, dIcon, dMaxStack
    if C_Item then
        if C_Item.GetItemNameByID then
            local okN, n = pcall(C_Item.GetItemNameByID, itemID)
            if okN and type(n) == "string" then dName = n end
        end
        if C_Item.GetItemQualityByID then
            local okQ, q2 = pcall(C_Item.GetItemQualityByID, itemID)
            if okQ and type(q2) == "number" then dQuality = q2 end
        end
        if C_Item.GetItemIconByID then
            local okI, ic = pcall(C_Item.GetItemIconByID, itemID)
            if okI and type(ic) == "string" then dIcon = ic end
        end
        if C_Item.GetItemMaxStackSizeByID then
            local okS, ms = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
            if okS and type(ms) == "number" then dMaxStack = ms end
        end
    end
    local ok, name, _, q, _, _, _, _, gStack, _, icon, sell = pcall(GetItemInfo, itemID)
    if dName == nil and (not ok or name == nil) then
        -- uncached item: never cache the unknown state - the client fills
        -- item info in asynchronously and the next call must see it
        return { name = nil, icon = nil, quality = -1, vendor = 0, maxStack = nil, stackable = nil }
    end
    c = {
        name = dName or ((ok and type(name) == "string") and name or nil),
        icon = dIcon or ((ok and type(icon) == "string") and icon or nil),
        quality = dQuality or ((ok and type(q) == "number") and q or -1),
        vendor = (ok and type(sell) == "number") and sell or 0,
        maxStack = dMaxStack or ((ok and type(gStack) == "number") and gStack or nil),
    }
    if c.maxStack ~= nil then
        c.stackable = (c.maxStack > 1) and true or false
    else
        c.stackable = nil -- unknown until the client caches the item
    end
    if not c.stackable and C_AuctionHouse and C_AuctionHouse.GetItemCommodityStatus then
        local okC, st = pcall(C_AuctionHouse.GetItemCommodityStatus, itemID)
        if okC and st == true then c.stackable = true end
    end
    itemInfoCache[itemID] = c
    return c
end
-- Listability: an item we cannot verify as sellable (quality unknown or below
-- the bar) never alerts; quality and vendor price come from the shared cache.
local function qualityOf(itemID)
    return infoOf(itemID).quality
end

-- Vendor sell price. A listing priced under this is FREE MONEY: buy it,
-- vendor it, instant guaranteed profit, no market risk, no relist wait.
local function vendorOf(itemID)
    return infoOf(itemID).vendor
end


-- ABSORPTION VELOCITY (secret sauce #1): track when each item first goes
-- below its deal line, and when the cheap stock is gone. The gap is how fast
-- this realm's buyers absorb deals - a per-item liquidity signal measured
-- live, not imported from region data nobody here has.
local absorbMarks = {}
local function absorbTrack(itemID, belowLine, now)
    local a = absorbMarks[itemID]
    if belowLine then
        if not a then absorbMarks[itemID] = { t = now, price = 0 } end
    elseif a then
        local dt = now - a.t
        local b = db.book[itemID]
        if b then
            b.v = b.v or {}
            local v = b.v
            v[#v + 1] = dt
            while #v > 4 do table.remove(v, 1) end
        end
            absorbMarks[itemID] = nil
        end
    end

-- MOMENTUM + VOLATILITY (strategy sauce): the book's recent samples tell
-- whether a market is climbing (hold/raise your price) or sinking (front the
-- queue now), and how much it swings (flippability).
local function bookTrend(itemID)
    local b = db.book[itemID]
    if not b or not b.s or #b.s < 8 then return 0 end
    local n = #b.s / 2
    local recent, prior = {}, {}
    for i = 1, n do
        local p = b.s[i * 2]
        if i > n - 3 then recent[#recent + 1] = p else prior[#prior + 1] = p end
    end
    local function avg(tbl) local s2 = 0 for _, v in ipairs(tbl) do s2 = s2 + v end return s2 / #tbl end
    local a, c = avg(recent), avg(prior)
    if c <= 0 then return 0 end
    return (a - c) / c
end

local function bookVolatility(itemID)
    local b = db.book[itemID]
    if not b or not b.s or #b.s < 8 then return nil end
    local vals = {}
    for i = 2, #b.s, 2 do vals[#vals + 1] = b.s[i] end
    local n = #vals
    local mean = 0
    for _, v in ipairs(vals) do mean = mean + v end
    mean = mean / n
    local var = 0
    for _, v in ipairs(vals) do var = var + (v - mean) * (v - mean) end
    if mean <= 0 then return nil end
    return math.sqrt(var / n) / mean
end

-- smart relist price: rising market -> ask above median; sinking -> undercut.
-- THE 1-COPPER FRONT (commodities): buyers purchase the cheapest listing
-- first, so listing 1c under the CURRENT cheapest (not the median) buys the
-- front of the queue for one copper - the oldest legal edge on any AH.
-- Items use charm pricing: 3g becomes 2g99s99c (price anchoring).
local function charmPrice(p)
    local g = math.floor(p / 10000)
    if g < 1 then return p end
    local rem = p - g * 10000
    if rem > 9900 then return p end -- already charm-y
    local charmed = (g - 1) * 10000 + 9999
    if charmed < 10000 then return p end
    return charmed
end

local function smartPrice(itemID, med, isCommodity)
    local tr = bookTrend(itemID)
    if isCommodity then
        local live = lastMinOf(itemID)
        if live and live > 100 and live <= med * 1.2 then
            return math.max(1, math.floor(live) - 1), tr, "fronting the queue at 1c under the cheapest"
        end
        if tr < -0.05 then return math.max(1, math.floor(med * 0.92)), tr end
        return math.floor(med), tr
    end
    if tr > 0.05 then return charmPrice(math.floor(med * 1.10)), tr end
    if tr < -0.05 then return charmPrice(math.floor(med * 0.92)), tr end
    return charmPrice(math.floor(med)), tr
end

-- TSM-STYLE TIERED THRESHOLD (their default sniper formula, classic-scaled):
-- expensive items only need a small discount, cheap ones need a huge one.
--   market > 250g -> 20% off | >100g -> 30% | >50g -> 40% | >25g -> 50%
--   >10g -> 60% | >5g -> 70% | >2g -> 80% | >1g -> 90% | else 95%
-- The deal line also never falls below the vendor sell price (max(vendorsell, tier*market)).
local function dealLine(med, itemID)
    local mult
    if med > 25000000 then mult = 0.8
    elseif med > 10000000 then mult = 0.7
    elseif med > 5000000 then mult = 0.6
    elseif med > 2500000 then mult = 0.5
    elseif med > 1000000 then mult = 0.4
    elseif med > 500000 then mult = 0.3
    elseif med > 200000 then mult = 0.2
    elseif med > 100000 then mult = 0.1
    else mult = 0.05 end
    local line = mult * med
    local vs = vendorOf(itemID)
    if vs > line then line = vs end
    return line, mult
end

local function absorbVelocity(itemID)
    local b = db.book[itemID]
    if not b or not b.v or #b.v == 0 then return nil end
    local s = 0
    for _, dt in ipairs(b.v) do s = s + dt end
    return s / #b.v
end


local function mergeIntoBook(curMins, t)
    local bookN = countKeys(db.book)
    for key, unit in pairs(curMins) do
        local eb = db.book[key]
        if eb and eb.ownUntil and t < eb.ownUntil then
            -- our own relist is showing: do not learn from it
        else
        local b = db.book[key]
        if not b then
            b = { lastSeen = t, s = {} }
            db.book[key] = b
            bookN = bookN + 1
        end
        b.lastSeen = t
        local hr = serverHour()
        b.h = b.h or {}
        local bucket = b.h[hr]
        if not bucket then bucket = { sum = 0, n = 0 } b.h[hr] = bucket end
        bucket.sum = bucket.sum + unit
        bucket.n = bucket.n + 1
        if bucket.n > 40 then -- rolling: decay old weight
            bucket.sum = bucket.sum * 0.75
            bucket.n = 30
        end
        local s = b.s
        s[#s + 1] = t
        s[#s + 1] = unit
        while sampleCount(s) > CAPS.samples do
            table.remove(s, 1)
            table.remove(s, 1)
        end
        end
    end
    -- Evict stalest items if the book outgrew its cap.
    if bookN > CAPS.book then
        local keys = {}
        for key in pairs(db.book) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b2)
            return (db.book[a].lastSeen or 0) < (db.book[b2].lastSeen or 0)
        end)
        for i = 1, bookN - CAPS.book do db.book[keys[i]] = nil end
    end
end

-- Scan state --------------------------------------------------------------------

local S = {
    ahOpen     = false,
    scanning   = false,
    prevList   = nil,   -- multiset: "id/count/buyout" -> occurrences
    scansDone  = 0,
    lastAlert  = db.lastAlert or {}, -- itemID -> { t, price } (persistent)
    pending    = nil,   -- { itemID, link, t } awaiting search results to print
    buying     = nil,   -- { itemID, link, line, market, commodity, t } active Buy click
    quote      = nil,   -- { itemID, units, total } live commodity quote
    boughtAt   = db.boughtAt or {}, -- itemID -> { t, price } purchase cooldown (persistent)
    session    = { started = time(), spent = 0, buys = 0, best = nil, realized = 0 }, -- money printer P&L
}

-- LOOPHOLE LAYER (TOS-legal edges): queue-fronting by 1 copper, deposit
-- math, hour-of-day arbitrage, and stack-size premium. All use data we
-- already sweep; none break any rule - they are just math most players
-- cannot be bothered to do.

local function lastMinOf(itemID)
    S.lastMin = S.lastMin or {}
    return S.lastMin[itemID]
end
local function noteStack(itemID, qty)
    S.stackSeen = S.stackSeen or {}
    local ss = S.stackSeen[itemID] or {}
    ss[qty] = (ss[qty] or 0) + 1
    S.stackSeen[itemID] = ss
end

serverHour = function()
    if GameTime_GetGameTime then
        local okH, h = pcall(GameTime_GetGameTime)
        if okH and type(h) == "number" then return h end
    end
    return date("*t").hour
end

-- hour-of-day memory: markets cycle (raid nights spike consumables, weekends
-- flood mats). An item 30% under ITS OWN hourly average is time-arbitrage.
hourAverage = function(itemID, hour)
    local b = db.book[itemID]
    if not b or not b.h then return nil end
    local bucket = b.h[hour]
    if not bucket or (bucket.n or 0) < 3 then return nil end
    return bucket.sum / bucket.n
end

-- Watchlist: split into fast lookups, rebuilt before each scan uses them.
local watchByID, watchByName = {}, {}
local function rebuildWatch()
    watchByID, watchByName = {}, {}
    for key, w in pairs(db.watch) do
        if key:sub(1, 2) ~= "n:" then
            watchByID[tonumber(key)] = w
        else
            watchByName[key:sub(3)] = w
        end
    end
end

local nameByKey = {}

local function nameOf(itemID, link)
    if nameByKey[itemID] then return nameByKey[itemID] end
    if link then
        local ok, name = pcall(GetItemInfo, link)
        if ok and type(name) == "string" then
            nameByKey[itemID] = strlower(name)
            return nameByKey[itemID]
        end
    end
    return nil
end

-- Alert UI ----------------------------------------------------------------------

local function playAlertSound()
    if not cfg.sound then return end
    pcall(PlaySound, "igQuestInviteAccepted")
end

-- Popup rows are rendered from this list, newest first, capped.
local popupRows = {}
local popup

local function renderPopup()
    if not popup then return end
    for i = 1, #popupRows do
        local row = popup.rows[i]
        local data = popupRows[i]
        row.icon:SetTexture(data.icon or "")
        if data.icon then row.icon:Show() else row.icon:Hide() end
        local price
        if data.units and data.units > 1 then
            price = string.format("x%d = %s", data.units, fmtMoney(data.cost or 0))
        else
            price = fmtMoney(data.unit)
        end
        local tag
        if data.market then
            tag = string.format(" |cff7cff4f-%d%%|r", math.floor((1 - data.unit / data.market) * 100 + 0.5))
        else
            tag = " |cff9d9d9dwatch|r"
        end
        row.text:SetText(string.format("%s  %s%s", data.link or data.label, price, tag))
        row.itemID = data.itemID
        row.link = data.link
        row.units = data.units
        row.line = data.line
        row.market = data.market
        row:Show()
    end
    for i = #popupRows + 1, #popup.rows do popup.rows[i]:Hide() end
    if cfg.popup then popup:Show() end
end

local function searchListing(itemID, link, units)
    if C_AuctionHouse == nil then
        printf("C_AuctionHouse is gone on this client - cannot search.")
        return
    end
    if not S.ahOpen then
        printf("open the auction house window first.")
        return
    end
    local key
    if C_AuctionHouse.MakeItemKey then
        local ok, k = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if ok then key = k end
    end
    key = key or { itemID = itemID }
    local sorts
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        -- this client validates the field by name: reverseSort, not reverse
        -- (live error: "Current Field: [reverseSort]"); Auctionator's shape
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    local ok, e = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not ok then
        err("SendSearchQuery", e)
        printf("search failed: %s", tostring(e):sub(1, 200))
        return
    end
    S.pending = { itemID = itemID, link = link, t = GetTime(), units = units }
    if units and units > 1 then
        printf("searching %s - buy the whole sweep: |cffffd100%d units|r is every one under your line.",
            link or ("item " .. tostring(itemID)), units)
    else
        printf("searching %s - cheapest listings print below; the buy is yours to click.",
            link or ("item " .. tostring(itemID)))
    end
end

-- Buy path -------------------------------------------------------------------
--
-- Architecture note: the purchase calls are hardware-event gated, and search
-- results arrive asynchronously AFTER the click. So the flow is two-stage:
--
--   1. Buy button press  -> live search (synchronous, inside the click)
--   2. results event     -> gather what is under the price line right now,
--                           cap it, and show the filled purchase dialog
--   3. Purchase press    -> every purchase call executes synchronously inside
--                           this hardware event. Nothing buys anywhere else.
--
-- Alert-time data is never trusted for a purchase; the dialog shows what the
-- server returned seconds ago, and misses (already-sold listings) are caught
-- and reported, never guessed around.

local confirmFrame

local function buildConfirm()
    if confirmFrame then return confirmFrame end
    local f = CreateFrame("Frame", "ForeverSniperConfirm", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(360, 150)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.TitleText:SetText("Forever Sniper - purchase")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOP", 0, -36)
    f.body:SetWidth(330)
    f.buy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.buy:SetSize(130, 22)
    f.buy:SetPoint("BOTTOM", -80, 14)
    f.buy:SetText("Purchase")
    f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancel:SetSize(90, 22)
    f.cancel:SetPoint("BOTTOM", 80, 14)
    f.cancel:SetText("Cancel")
    f.cancel:SetScript("OnClick", function(self)
        local q = self:GetParent().q
        if q and q.commodity and q.quoting then
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
        end
        self:GetParent().q = nil
        self:GetParent():Hide()
    end)
    confirmFrame = f
    return f
end

local function showConfirm(q)
    local f = buildConfirm()
    f.q = q
    f.buy:SetScript("OnClick", function(self)
        local q2 = self:GetParent().q
        if not q2 then self:GetParent():Hide() return end

        if q2.commodity then
            -- Commodities: start the quote now; the dialog flips to Confirm
            -- when the server answers with the exact total, and that press
            -- finalizes. Two presses, same as Blizzard's own flow.
            if q2.quoting then
                local ok, e = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, q2.itemID, q2.units)
                if ok then
                    printf("purchased |cffffd100%d units|r of %s.", q2.units, q2.link or ("item " .. q2.itemID))
                    S.boughtAt[q2.itemID] = { t = time(), price = q2.unit or 0 }
                    S.session.spent = S.session.spent + (q2.total or (q2.units or 0) * (q2.unit or 0))
                    S.session.buys = S.session.buys + 1
                    for _, d in ipairs(S.deals) do
                        if d.id == q2.itemID then d.bought = true end
                    end
                    refreshFeed()
                    self:GetParent().q = nil
                    self:GetParent():Hide()
                else
                    err("ConfirmCommoditiesPurchase", e)
                    printf("purchase failed: %s", tostring(e):sub(1, 200))
                end
            else
                local ok, e = pcall(C_AuctionHouse.StartCommoditiesPurchase, q2.itemID, q2.units)
                if ok then
                    q2.quoting = true
                    self:SetText("Confirm")
                    self:GetParent().body:SetText(string.format(
                        "%d x %s - fetching the exact total ...\n(press Confirm when it appears)",
                        q2.units, q2.link or ("item " .. q2.itemID)))
                    S.quote = q2
                else
                    err("StartCommoditiesPurchase", e)
                    printf("could not start the purchase: %s", tostring(e):sub(1, 200))
                end
            end
            return
        end

        -- Item listings: buy out every captured listing now, cheapest first,
        -- all inside this press, bounded by the spend cap.
        local spent, bought, misses = 0, 0, 0
        for _, L in ipairs(q2.list or {}) do
            if spent + L.buyout > cfg.maxSpend then
                printf("spend cap %s reached - skipped the rest. /fsn max to raise it.", fmtMoney(cfg.maxSpend))
                break
            end
            local okP, eP = pcall(C_AuctionHouse.PlaceBid, L.auctionID, L.buyout)
            if okP then
                spent = spent + L.buyout
                bought = bought + L.qty
            else
                misses = misses + 1
                err("PlaceBid", eP)
            end
        end
        if bought > 0 then
            printf("bought |cffffd100%d units|r of %s for |cffffd100%s|r.",
                bought, q2.link or ("item " .. q2.itemID), fmtMoney(spent))
            S.boughtAt[q2.itemID] = { t = time(), price = q2.line }
            S.session.spent = S.session.spent + spent
            S.session.buys = S.session.buys + 1
            for _, d in ipairs(S.deals) do
                if d.id == q2.itemID then d.bought = true end
            end
            refreshFeed()
        end
        if misses > 0 then
            printf("%d listing%s already gone - the re-scan will catch anything left.",
                misses, misses == 1 and "" or "s")
        end
        if bought == 0 and misses == 0 then
            printf("nothing was under the line anymore - someone beat you to it.")
        end
        self:GetParent().q = nil
        self:GetParent():Hide()
    end)
    f.body:SetText(q.body or "")
    f.buy:SetText("Purchase")
    f:Show()
end

local function buyFromResults(kind)
    local b = S.buying
    if not b or GetTime() - b.t > 15 then S.buying = nil return end
    S.buying = nil
    if not S.ahOpen then printf("the AH window closed - buy aborted.") return end

    -- this client's result readers are keyed: GetNumItemSearchResults(itemKey),
    -- GetItemSearchResultInfo(itemKey, index), GetCommoditySearchResultInfo(itemID, index)
    local key = { itemID = b.itemID }
    if C_AuctionHouse.MakeItemKey then
        local okK, k = pcall(C_AuctionHouse.MakeItemKey, b.itemID)
        if okK and type(k) == "table" then key = k end
    end

    if kind == "commodity" then
        -- Commodity results: price points, cheapest first. Take every unit
        -- under the line, cheapest first, stopping at the spend cap.
        local units, cost = 0, 0
        local i = 1
        while true do
            local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, b.itemID, i)
            if not ok or type(info) ~= "table" then break end
            local price = num(info.unitPrice or info.buyoutAmount)
            local avail = num(info.quantity) or 0
            if not price or price <= 0 or avail <= 0 then break end
            if price > b.line then break end -- sorted ascending; done under the line
            local take = avail
            if cost + take * price > cfg.maxSpend then
                take = math.floor((cfg.maxSpend - cost) / price)
            end
            if take > 0 then
                units = units + take
                cost = cost + take * price
            end
            if cost >= cfg.maxSpend or take < avail then break end
            i = i + 1
        end
        if units <= 0 then
            printf("nothing under %s anymore - someone beat you to it.", fmtMoney(b.line))
            return
        end
        showConfirm({
            commodity = true, itemID = b.itemID, link = b.link,
            units = units, unit = math.floor(cost / units),
            body = string.format("%d x %s - every unit under %s\nestimated total |cffffd100%s|r (cap %s)",
                units, b.link or ("item " .. b.itemID), fmtMoney(b.line), fmtMoney(cost), fmtMoney(cfg.maxSpend)),
        })
        return
    end

    -- Item listings: capture every listing under the line, cheapest first,
    -- capped. The Purchase press buys them; nothing executes here.
    local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults, key)
    n = okN and math.floor(num(n) or 0) or 0
    local list, units, cost = {}, 0, 0
    for i = 1, n do
        local ok, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, i)
        if ok and type(info) == "table" and info.auctionID then
            local buyout = num(info.buyoutAmount)
            local qty = num(info.quantity) or 1
            if buyout and buyout > 0 and qty > 0 and math.floor(buyout / qty) <= b.line then
                if cost + buyout > cfg.maxSpend then
                    list.capped = true
                    break
                end
                list[#list + 1] = { auctionID = info.auctionID, buyout = buyout, qty = qty }
                units = units + qty
                cost = cost + buyout
            end
        end
    end
    if units <= 0 then
        printf("nothing under %s anymore - someone beat you to it.", fmtMoney(b.line))
        return
    end
    showConfirm({
        commodity = false, itemID = b.itemID, link = b.link, line = b.line,
        units = units, list = list,
        body = string.format("%d units of %s - %d listing%s under %s\ntotal |cffffd100%s|r%s",
            units, b.link or ("item " .. b.itemID), #list, #list == 1 and "" or "s",
            fmtMoney(b.line), fmtMoney(cost),
            list.capped and string.format("  (cap %s hit)", fmtMoney(cfg.maxSpend)) or ""),
    })
end

local function buySweep(itemID, link, line, market)
    if C_AuctionHouse == nil then
        printf("C_AuctionHouse is gone on this client - cannot buy.")
        return
    end
    if not S.ahOpen then
        printf("open the auction house window first.")
        return
    end
    if not line or line <= 0 then
        printf("no price line recorded for this alert - re-scan and try again.")
        return
    end
    local commodity = false
    if C_AuctionHouse.GetItemCommodityStatus then
        local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, itemID)
        if ok and status ~= nil then
            commodity = (status == true)
            if type(status) == "number" then
                commodity = status == (Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 1)
            end
        end
    end
    local key
    if C_AuctionHouse.MakeItemKey then
        local ok, k = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if ok then key = k end
    end
    key = key or { itemID = itemID }
    local sorts
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    local ok, e = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not ok then
        err("SendSearchQuery", e)
        printf("could not search for a live price: %s", tostring(e):sub(1, 200))
        return
    end
    -- Results events route to the buy path while this is set.
    S.pending = nil
    S.buying = { itemID = itemID, link = link, line = line, market = market,
                 commodity = commodity, t = GetTime() }
    printf("checking live listings under %s ...", fmtMoney(line))
end

local function buildPopup()
    popup = CreateFrame("Frame", "ForeverSniperPopup", UIParent, "BasicFrameTemplateWithInset")
    popup:SetSize(380, 246)
    popup:SetPoint("RIGHT", UIParent, "RIGHT", -16, 0)
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, rel, relPoint, x, y = self:GetPoint()
        cfg.popPoint = {
            point = point, relName = rel and rel.GetName and rel:GetName() or nil,
            relPoint = relPoint, x = x, y = y,
        }
    end)
    popup.TitleText:SetText("Forever Sniper")
    popup.rows = {}

    for i = 1, 10 do
        local row = CreateFrame("Button", nil, popup)
        row:SetSize(350, 19)
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -34 - (i - 1) * 20)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT")
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetJustifyH("LEFT")
        text:SetWidth(240)
        text:SetWordWrap(false)
        row.icon, row.text = icon, text
        local buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        buyBtn:SetSize(52, 18)
        buyBtn:SetPoint("RIGHT")
        buyBtn:SetText("Buy")
        buyBtn:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if r.itemID and r.line then buySweep(r.itemID, r.link, r.line, r.market) end
        end)
        row:SetScript("OnClick", function(self)
            if self.itemID then searchListing(self.itemID, self.link, self.units) end
        end)
        row:Hide()
        popup.rows[i] = row
    end
    popup:Hide()

    if cfg.popPoint then
        local p = cfg.popPoint
        local rel = p.relName and _G[p.relName] or UIParent
        popup:ClearAllPoints()
        popup:SetPoint(p.point or "RIGHT", rel, p.relPoint or "RIGHT", p.x or -16, p.y or 0)
    end
end

-- relist assistant: find bought flips in the bags and post them at the
-- learned market - one SELL click, no sell-tab fiddling ---------------------
-- Post mechanics live-proven by Auctionator on this client:
--   C_AuctionHouse.PostItem(itemLocation, duration, quantity, buyout)
--   C_AuctionHouse.PostCommodity(itemLocation, duration, quantity, unitPrice)

local function findInBags(itemID)
    if C_Container == nil or C_Container.GetContainerNumSlots == nil then return nil end
    for bag = 0, 11 do
        local n = C_Container.GetContainerNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                local id = C_Container.GetContainerItemID(bag, slot)
                if id == itemID then
                    local qty = 1
                    if C_Container.GetContainerItemInfo then
                        local info = C_Container.GetContainerItemInfo(bag, slot)
                        if type(info) == "table" and info.stackCount then
                            qty = info.stackCount
                        elseif type(info) == "number" then
                            qty = info -- some builds return count directly
                        end
                    end
                    return bag, slot, qty
                end
            end
        end
    end
    return nil
end

-- post one listing of every unit we hold of itemID at unitPrice; returns ok
local function sellAt(itemID, unitPrice)
    if not S.ahOpen then
        printf("open the Auction House first - selling needs the window up.")
        return false
    end
    if C_AuctionHouse == nil or C_AuctionHouse.PostItem == nil then return false end
    unitPrice = math.floor(num(unitPrice) or 0)
    if unitPrice <= 0 then return false end
    local bag, slot, qty = findInBags(itemID)
    if bag == nil then
        local info = infoOf(itemID)
        printf("%s is not in your bags - nothing to list.", info.name or ("item " .. itemID))
        return false
    end
    local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot(bag, slot)
    if loc == nil then return false end
    if C_AuctionHouse.IsSellItemValid then
        local okV, valid = pcall(C_AuctionHouse.IsSellItemValid, loc)
        if okV and valid == false then
            printf("%s cannot be sold on the AH (soulbound?). Vendor it.",
                infoOf(itemID).name or ("item " .. itemID))
            return false
        end
    end
    local isCommodity = false
    if C_AuctionHouse.GetItemCommodityStatus then
        local okC, st = pcall(C_AuctionHouse.GetItemCommodityStatus, itemID)
        if okC then isCommodity = (st == true) end
    end
    -- duration pick: fast absorbers sell inside 12h, so pay the smaller
    -- deposit; slow movers need the long window. Velocity decides.
    local vel = absorbVelocity(itemID)
    local duration = (vel and vel < 120) and 1 or 3
    local depositTxt = ""
    if isCommodity and C_AuctionHouse.CalculateCommodityDeposit then
        local okD, dep = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, qty)
        if okD and type(dep) == "number" and dep > 0 then
            depositTxt = " (deposit " .. fmtMoney(dep) .. ")"
        end
    end
    local ok, e
    if isCommodity and C_AuctionHouse.PostCommodity then
        ok, e = pcall(C_AuctionHouse.PostCommodity, loc, duration, qty, unitPrice)
    else
        ok, e = pcall(C_AuctionHouse.PostItem, loc, duration, qty, unitPrice * qty)
    end
    if ok then
        local _, tr = smartPrice(itemID, unitPrice)
        -- stack-split premium: buyers pay more per unit for small stacks; the
        -- modal size seen in sweeps is what this market actually buys
        local modal, bestN = nil, 0
        if S.stackSeen and S.stackSeen[itemID] then
            for q, c in pairs(S.stackSeen[itemID]) do
                if c > bestN then bestN = c modal = q end
            end
        end
        if modal and qty > modal * 2 then
            printf("|cff888888(tip: %d units splits into %d stacks of %d - small stacks sell at a premium)|r",
                qty, math.floor(qty / modal), modal)
        end
        local trendTxt = ""
        if tr > 0.05 then trendTxt = " (market climbing - hold for more)"
        elseif tr < -0.05 then trendTxt = " (market sinking - priced to front the queue)" end
        printf("listed |cffffd100%d x %s|r at |cffffd100%s each|r (%s total) - 48h%s.",
            qty, infoOf(itemID).name or ("item " .. itemID),
            fmtMoney(unitPrice), fmtMoney(unitPrice * qty), trendTxt)
        S.session.listed = (S.session.listed or 0) + 1
        local b = db.book[itemID]
        if b then b.ownUntil = time() + 300 end -- our price is not the market
        return true
    end
    err(isCommodity and "PostCommodity" or "PostItem", e)
    printf("could not list: %s", tostring(e):sub(1, 160))
    return false
end


-- WoWSniper-parity alerts: tiers, sound, flash, toast, and a deal feed -----
-- Deal depth tiers (WoWSniper's model): SNIPE = forgot a zero, GREAT = heavy
-- underprice, GOOD = solid. Sound, screen flash and toast fire per tier, and
-- every deal lands in a profit-sorted feed window (/fsn feed) with BUY buttons.

local TIERS = {
    DUMP  = { mult = 1.0, sound = 8959, r = 0.75, g = 0.30, b = 1.00 },
    SNIPE = { mult = 5.0, sound = 8959, r = 1.00, g = 0.35, b = 0.15 },
    GREAT = { mult = 3.0, sound = 888,  r = 0.35, g = 0.80, b = 1.00 },
    GOOD  = { mult = 2.0, sound = 3081, r = 0.30, g = 1.00, b = 0.45 },
    VENDOR = { mult = 1.0, sound = 8959, r = 1.00, g = 0.85, b = 0.20 },
}
local function tierOf(market, price)
    if not market or market <= 0 or not price or price <= 0 then return nil end
    local m = market / price
    if m >= TIERS.SNIPE.mult then return "SNIPE" end
    if m >= TIERS.GREAT.mult then return "GREAT" end
    if m >= TIERS.GOOD.mult then return "GOOD" end
    return nil
end

local function playTierSound(tier)
    if not cfg.sound then return end
    local t = tier and TIERS[tier]
    PlaySound(t and t.sound or 3081, "Master")
end

-- screen flash ---------------------------------------------------------------------
local flashFrame
local function flashScreen(tier)
    if not cfg.flash then return end
    if flashFrame then
        local t = tier and TIERS[tier]
        flashFrame.tex:SetColorTexture(t and t.r or 1, t and t.g or 0.85, t and t.b or 0, 0.2)
        flashFrame:Show()
        if flashFrame.anim then flashFrame.anim:Stop() flashFrame.anim:Play() end
        return
    end
    flashFrame = CreateFrame("Frame", nil, UIParent)
    flashFrame:SetAllPoints()
    flashFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    flashFrame:SetFrameLevel(100)
    flashFrame:Hide()
    flashFrame.tex = flashFrame:CreateTexture(nil, "BACKGROUND")
    flashFrame.tex:SetAllPoints()
    flashFrame.tex:SetColorTexture(1, 0.85, 0, 0.15)
    flashFrame.anim = flashFrame:CreateAnimationGroup()
    local fadeIn = flashFrame.anim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0) fadeIn:SetToAlpha(1) fadeIn:SetDuration(0.1) fadeIn:SetOrder(1)
    local fadeOut = flashFrame.anim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1) fadeOut:SetToAlpha(0) fadeOut:SetDuration(0.4) fadeOut:SetOrder(2)
    flashFrame.anim:SetScript("OnFinished", function() flashFrame:Hide() end)
    flashScreen(tier)
end

-- toast ----------------------------------------------------------------------------
local toastFrame
local function showToast(tier, itemID, price, market, profit)
    if not cfg.toast then return end
    if not toastFrame then
        toastFrame = CreateFrame("Frame", nil, UIParent)
        toastFrame:SetSize(280, 50)
        toastFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -120)
        toastFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        toastFrame:Hide()
        local bg = toastFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints() bg:SetColorTexture(0.08, 0.08, 0.12, 0.95)
        toastFrame.icon = toastFrame:CreateTexture(nil, "ARTWORK")
        toastFrame.icon:SetSize(36, 36) toastFrame.icon:SetPoint("LEFT", 6, 0)
        toastFrame.title = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        toastFrame.title:SetPoint("TOPLEFT", toastFrame.icon, "TOPRIGHT", 6, -2)
        toastFrame.title:SetPoint("RIGHT", -6, 0)
        toastFrame.title:SetJustifyH("LEFT")
        toastFrame.detail = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        toastFrame.detail:SetPoint("BOTTOMLEFT", toastFrame.icon, "BOTTOMRIGHT", 6, 2)
        toastFrame.detail:SetPoint("RIGHT", -6, 0)
        toastFrame.detail:SetJustifyH("LEFT")
    end
    local t = tier and TIERS[tier]
    local info = infoOf(itemID)
    local name = info.name or ("item " .. tostring(itemID))
    if info.icon then toastFrame.icon:SetTexture(info.icon) end
    local c = t and string.format("|cff%02x%02x%02x",
        math.floor((t.r * 255) + 0.5), math.floor((t.g * 255) + 0.5), math.floor((t.b * 255) + 0.5)) or "|cffffd100"
    toastFrame.title:SetText(c .. (tier or "DEAL") .. "|r " .. name)
    local actionText = "relist on the AH"
    if tier == "VENDOR" then actionText = "VENDOR it - instant"
    elseif market and market > 0 then actionText = "AH at " .. fmtMoney(math.floor(market)) end
    toastFrame.detail:SetText(fmtMoney(price) .. "  market " .. fmtMoney(market or 0)
        .. "  |cff44cc44+" .. fmtMoney(profit or 0) .. "|r\n|cffffd100> " .. actionText .. "|r")
    toastFrame:Show()
    if toastFrame.hideTimer then toastFrame.hideTimer:Cancel() end
    toastFrame.hideTimer = C_Timer.NewTimer(5, function() toastFrame:Hide() end)
end

-- deal feed ------------------------------------------------------------------------
-- deals, seen-listings and alert guards are db-backed: they survive /reload
-- and relogs, so a restart never re-alerts listings you already dismissed
S.deals = db.deals or {}
db.deals = S.deals
local MAX_FEED = 200
local feedFrame, feedRows, feedStatus
local FEED_ROWS, FEED_ROW_H, FEED_W = 14, 26, 560
local feedDirty, feedLastRefresh = false, 0

local function refreshFeed()
    if not feedFrame or not feedFrame:IsShown() then feedDirty = true return end
    -- throttled: a burst of deals refreshes once per quarter second, not per alert
    local now = GetTime()
    if now - feedLastRefresh < 0.25 then feedDirty = true return end
    feedLastRefresh = now
    feedDirty = false
    for i = 1, FEED_ROWS do
        local row = feedRows[i]
        local d = S.deals[i]
        if d then
            local info = infoOf(d.id)
            row.name:SetText(info.name or ("item " .. tostring(d.id)))
            if info.icon then row.icon:SetTexture(info.icon) end
            row.price:SetText(fmtMoney(d.unit))
            row.market:SetText(fmtMoney(d.market or 0))
            row.pct:SetText(d.market and ("-"
                .. math.floor((1 - d.unit / d.market) * 100 + 0.5) .. "%") or "watch")
            row.tier:SetText(d.tier or "")
            local t = d.tier and TIERS[d.tier]
            if t then
                row.tier:SetTextColor(t.r, t.g, t.b)
                row.profit:SetTextColor(0.3, 1, 0.45)
                row.profit:SetText(d.profit and ("+" .. fmtMoney(d.profit)) or "")
            else
                row.tier:SetTextColor(0.6, 0.6, 0.6)
                row.profit:SetText("")
            end
            row.newBadge:SetShown(d.isNew == true)
            row.itemID, row.link, row.line, row.market2 = d.id, d.link, d.line, d.market
            -- the action label: what to DO with this deal
            if d.tier == "VENDOR" then
                row.action:SetText("|cffffd100VENDOR|r")
            elseif d.market and d.market > 0 then
                row.action:SetText("|cff7cff4fAH " .. fmtMoney(math.floor(d.market)) .. "|r")
            else
                row.action:SetText("|cff9d9d9dwatch|r")
            end
            row.buyBtn:SetShown(not d.bought)
            if d.bought then row.name:SetTextColor(0.5, 0.5, 0.5) else row.name:SetTextColor(1, 1, 1) end
            row:Show()
        else
            row:Hide()
        end
    end
    if feedStatus then
        local mins = math.floor((time() - (S.session.started or time())) / 60 + 0.5)
        feedStatus:SetText(string.format(
            "|cff888888%d deal(s) this session - %d buy(s), %s committed in %d min - book %d items|r",
            #S.deals, S.session.buys or 0, fmtMoney(S.session.spent or 0), mins,
            countKeys(db.book)))
    end
end

-- called from the OnUpdate ticker: applies a deferred refresh when one was
-- requested during the throttle window
local function feedTick()
    if feedDirty then refreshFeed() end
end

local function addDeal(tier, itemID, link, unit, market, sweep, isNew)
    for _, d in ipairs(S.deals) do
        if d.id == itemID and d.unit == unit and not d.bought then return end
    end
    local deal = {
        id = itemID, link = link, unit = unit, market = market, tier = tier,
        profit = sweep and sweep.profit, units = sweep and sweep.units,
        line = sweep and sweep.line, isNew = isNew, t = time(), bought = false,
    }
    local inserted = false
    for i, d in ipairs(S.deals) do
        if (deal.profit or 0) > (d.profit or 0) then
            table.insert(S.deals, i, deal)
            inserted = true
            break
        end
    end
    if not inserted then S.deals[#S.deals + 1] = deal end
    while #S.deals > MAX_FEED do table.remove(S.deals) end
    refreshFeed()
end

local function buildFeed()
    if feedFrame then return end
    feedFrame = CreateFrame("Frame", "ForeverSniperFeed", UIParent)
    feedFrame:SetSize(FEED_W, 58 + FEED_ROWS * FEED_ROW_H + 26)
    feedFrame:SetPoint("LEFT", UIParent, "LEFT", 16, 0)
    feedFrame:SetMovable(true)
    feedFrame:EnableMouse(true)
    feedFrame:RegisterForDrag("LeftButton")
    feedFrame:SetScript("OnDragStart", feedFrame.StartMoving)
    feedFrame:SetScript("OnDragStop", feedFrame.StopMovingOrSizing)
    local bg = feedFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints() bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)
    local title = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cffff7d0aForever Sniper|r - deals (profit first)")
    local clearBtn = CreateFrame("Button", nil, feedFrame)
    clearBtn:SetSize(52, 18) clearBtn:SetPoint("TOPRIGHT", -62, -6)
    local cbg = clearBtn:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints() cbg:SetColorTexture(0.35, 0.2, 0.1, 0.9)
    clearBtn.fs = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clearBtn.fs:SetAllPoints() clearBtn.fs:SetText("Clear")
    clearBtn.fs:SetTextColor(1, 0.8, 0.6)
    clearBtn:SetScript("OnClick", function()
        for i = #S.deals, 1, -1 do
            if S.deals[i].bought then table.remove(S.deals, i) end
        end
        refreshFeed()
    end)
    local closeBtn = CreateFrame("Button", nil, feedFrame)
    closeBtn:SetSize(52, 18) closeBtn:SetPoint("TOPRIGHT", -6, -6)
    local xbg = closeBtn:CreateTexture(nil, "BACKGROUND")
    xbg:SetAllPoints() xbg:SetColorTexture(0.2, 0.2, 0.25, 0.95)
    closeBtn.fs = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    closeBtn.fs:SetAllPoints() closeBtn.fs:SetText("Close")
    closeBtn.fs:SetTextColor(0.9, 0.9, 0.9)
    closeBtn:SetScript("OnClick", function() feedFrame:Hide() end)

    local function col(x, w, label, right)
        local h = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        h:SetPoint("LEFT", x, 0) h:SetWidth(w or 60)
        h:SetJustifyH(right and "RIGHT" or "LEFT")
        h:SetTextColor(0.55, 0.55, 0.6)
        h:SetText(label)
    end
    col(60, 200, "item")
    col(265, 65, "price", true)
    col(333, 65, "market", true)
    col(402, 38, "off", true)
    col(443, 36, "tier")
    col(481, 58, "profit", true)
    col(541, 60, "action", true)

    feedRows = {}
    for i = 1, FEED_ROWS do
        local row = CreateFrame("Button", nil, feedFrame)
        row:SetSize(FEED_W - 16, FEED_ROW_H)
        row:SetPoint("TOPLEFT", feedFrame, "TOPLEFT", 8, -30 - (i - 1) * FEED_ROW_H)
        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints()
        rbg:SetColorTexture(0.07, 0.07, 0.10, i % 2 == 0 and 0.6 or 0.35)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20) row.icon:SetPoint("LEFT", 2, 0)
        row.newBadge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.newBadge:SetPoint("LEFT", 26, 0) row.newBadge:SetText("|cffff4444NEW|r")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", 60, 0) row.name:SetWidth(200)
        row.name:SetJustifyH("LEFT") row.name:SetWordWrap(false)
        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("LEFT", 265, 0) row.price:SetWidth(65) row.price:SetJustifyH("RIGHT")
        row.market = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.market:SetPoint("LEFT", 333, 0) row.market:SetWidth(65) row.market:SetJustifyH("RIGHT")
        row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.pct:SetPoint("LEFT", 402, 0) row.pct:SetWidth(38) row.pct:SetJustifyH("CENTER")
        row.tier = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.tier:SetPoint("LEFT", 443, 0) row.tier:SetWidth(36)
        row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.profit:SetPoint("LEFT", 481, 0) row.profit:SetWidth(58) row.profit:SetJustifyH("RIGHT")
        row.action = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.action:SetPoint("RIGHT", -104, 0) row.action:SetWidth(86) row.action:SetJustifyH("RIGHT")
        row.sellBtn = CreateFrame("Button", nil, row)
        row.sellBtn:SetSize(40, 18) row.sellBtn:SetPoint("RIGHT", -50, 0)
        local sbg = row.sellBtn:CreateTexture(nil, "BACKGROUND")
        sbg:SetAllPoints() sbg:SetColorTexture(0.15, 0.25, 0.45, 0.9)
        row.sellBtn.fs = row.sellBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.sellBtn.fs:SetAllPoints() row.sellBtn.fs:SetText("SELL")
        row.sellBtn.fs:SetTextColor(0.55, 0.75, 1)
        row.sellBtn:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if r.itemID and r.market2 then
                local isComm = false
                if C_AuctionHouse and C_AuctionHouse.GetItemCommodityStatus then
                    local okC, st = pcall(C_AuctionHouse.GetItemCommodityStatus, r.itemID)
                    if okC then isComm = (st == true) end
                end
                local sp, tr, why = smartPrice(r.itemID, r.market2, isComm)
                if why then printf("|cff888888%s.|r", why) end
                sellAt(r.itemID, sp)
            end
        end)
        row.buyBtn = CreateFrame("Button", nil, row)
        row.buyBtn:SetSize(40, 18) row.buyBtn:SetPoint("RIGHT", -6, 0)
        local bbg = row.buyBtn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints() bbg:SetColorTexture(0.15, 0.4, 0.15, 0.9)
        row.buyBtn.fs = row.buyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.buyBtn.fs:SetAllPoints() row.buyBtn.fs:SetText("BUY")
        row.buyBtn.fs:SetTextColor(0.3, 1, 0.3)
        row.buyBtn:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if r.itemID and r.line then buySweep(r.itemID, r.link, r.line, r.market2) end
        end)
        row:SetScript("OnClick", function(self)
            if self.itemID then searchListing(self.itemID, self.link, nil) end
        end)
        row:Hide()
        feedRows[i] = row
    end

    feedStatus = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    feedStatus:SetPoint("BOTTOMLEFT", 10, 6)
    feedStatus:SetWidth(FEED_W - 20)
    feedStatus:SetJustifyH("LEFT")
    feedStatus:SetTextColor(0.55, 0.55, 0.6)
    feedStatus:SetText("|cff888888waiting for the first sweep...|r")
end
local function alertDeal(tier, itemID, link, unit, market, sweep, isNew)
    playTierSound(tier)
    flashScreen(tier)
    showToast(tier, itemID, unit, market, sweep and sweep.profit)
    addDeal(tier, itemID, link, unit, market, sweep, isNew)
end

local function fireAlert(kind, itemID, link, unit, market, sweep, isNew)
    local now = time()
    local key = tostring(itemID)
    local last = S.lastAlert[key]
    -- Spam guard: one alert per item per minute unless it got cheaper again.
    if last and now - last.t < 60 and unit >= (last.price or 0) * 0.9 then return end
    -- Purchase cooldown: just-bought items stay quiet for 5 minutes unless a
    -- NEW listing undercuts what was paid, which is genuinely a new deal.
    local bought = S.boughtAt[key]
    if bought and now - bought.t < 300 and unit >= (bought.price or 0) then return end
    S.lastAlert[key] = { t = now, price = unit }

    sweep = sweep or { units = 1, cost = unit }
    db.stats.deals = (db.stats.deals or 0) + 1
    if kind == "vendor" then
        db.stats.vendorDeals = (db.stats.vendorDeals or 0) + 1
        db.stats.vendorProfit = (db.stats.vendorProfit or 0) + (sweep.profit or 0)
    end
    local profit = sweep.profit or 0
    if profit > 0 and (not S.session.best or profit > (S.session.best.profit or 0)) then
        S.session.best = { id = itemID, profit = profit }
    end
    push(db.alerts, CAPS.alerts, {
        t = now, kind = kind, id = itemID, unit = unit, market = market,
        units = sweep.units, cost = sweep.cost, profit = sweep.profit,
    })

    local label = link or (infoOf(itemID).name) or ("item " .. tostring(itemID))
    -- the action label: every deal says what to DO with it
    local action
    if kind == "dump" then
        action = "|cffb44cffBUY THE FLOOR|r - a reset: absorb it, relist in stages"
    elseif kind == "vendor" then
        action = "|cffffd100VENDOR it|r - instant, no relist"
    elseif market and market > 0 then
        action = "|cffffd100relist on the AH at " .. fmtMoney(math.floor(market)) .. "|r"
    else
        action = "|cff9d9d9dyour watch rule|r"
    end
    if market and market > 0 then
        if sweep.units > 1 then
            printf("|cffff4d00DEAL|r %s - |cffffd100%d units|r under %s: |cffffd100%s total|r (avg %s, market %s) |cff7cff4f+%s profit|r",
                label, sweep.units, fmtMoney(math.floor(sweep.cost / sweep.units + 0.5)),
                fmtMoney(sweep.cost), fmtMoney(math.floor(sweep.cost / sweep.units + 0.5)),
                fmtMoney(market), fmtMoney(sweep.profit or 0), action)
        else
            printf("|cffff4d00DEAL|r %s - %s  (market %s, |cff7cff4f-%d%%|r, |cff7cff4f+%s|r)",
                label, fmtMoney(unit), fmtMoney(market),
                math.floor((1 - unit / market) * 100 + 0.5),
                fmtMoney(math.floor(market * (1 - cfg.cut) - unit)), action)
        end
    else
        if sweep.units > 1 then
            printf("|cffff4d00DEAL|r %s - |cffffd100%d units|r at or under %s: |cffffd100%s total|r (|cff9d9d9dwatch rule|r)",
                label, sweep.units, fmtMoney(unit), fmtMoney(sweep.cost))
        else
            printf("|cffff4d00DEAL|r %s - %s  (|cff9d9d9dwatch rule|r)", label, fmtMoney(unit))
        end
    end
    playAlertSound()

    -- WoWSniper-parity: tiered sound/flash/toast + the deal feed
    local tier = (kind == "vendor") and "VENDOR" or (kind == "dump") and "DUMP" or tierOf(market, unit)
    alertDeal(tier, itemID, link, unit, market, sweep, isNew)

    if cfg.popup then
        local icon
        local ok, iid, _, _, _, iconFile = pcall(GetItemInfoInstant, link or itemID)
        if ok and iconFile then icon = iconFile end
        table.insert(popupRows, 1, {
            itemID = itemID, link = link, label = label, unit = unit,
            market = market, icon = icon,
            units = sweep.units, cost = sweep.cost, profit = sweep.profit,
            line = sweep.line or unit,
        })
        while #popupRows > 10 do table.remove(popupRows) end
        renderPopup()
    end
end

-- The scan ------------------------------------------------------------------------

local function completeScan(reason)
    if not S.scanning then return end
    S.scanning = false
    S.lastScan = time()

    local n = 0
    do
        local ok, v = pcall(C_AuctionHouse.GetNumReplicateItems)
        if ok then n = math.floor(num(v) or 0) end
    end
    if n <= 0 then
        err("scan", "completed with 0 listings via " .. tostring(reason))
        if S.ahOpen then after(cfg.every, requestReplicate) end
        return
    end

    -- One-time record of the return shape, so a future beta change is visible.
    if not db.shape then
        local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 =
            pcall(C_AuctionHouse.GetReplicateItemInfo, 1)
        if ok then
            local shape = {}
            local vals = { a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 }
            for i = 1, 18 do
                local v = vals[i]
                local t = type(v)
                if t == "number" then
                    shape[i] = issecretvalue and issecretvalue(v) and "secret" or "number"
                elseif t == "string" then
                    shape[i] = "string:" .. #v
                else
                    shape[i] = t
                end
            end
            db.shape = shape
        end
    end

    local t = time()
    local firstScan = S.prevList == nil
    local curMins, curSeen = {}, {}
    local depth = {}     -- itemID -> { {unit=, count=}, ... } every priced listing
    local cands = {}     -- new listings this scan (details for the alert pass)

    -- Layout: the Forever client returns [3]=count, [10]=buyout, [17]=itemID,
    -- [18]=loaded-flag, link via GetReplicateItemLink (Auctionator's live-proven
    -- positions on this client); retail lineage is 1=itemID, 7=count, 8=link,
    -- 9=quality, 14=buyout. Detect once from row 1, parse accordingly.
    local foreverLayout = false
    do
        local okP, q1,q2,q3,q4,q5,q6,q7,q8,q9,q10,q11,q12,q13,q14,q15,q16,q17,q18 =
            pcall(C_AuctionHouse.GetReplicateItemInfo, 1)
        if okP and num(q17) and num(q17) > 0 then foreverLayout = true end
    end

    -- Auctionator's ProcessBatch shape: the analysis tail is finishScan, the
    -- rows are harvested 250 at a time so a 3k-listing server never freezes
    -- a frame, and finishScan runs when the last row lands
    local function finishScan()

    -- Market deals: a new listing under threshold% of a learned median. The
    -- whole depth under that line is swept (every unit of every cheap listing,
    -- so stackables come as one lot), and the deal only fires if the estimated
    -- resale profit - market after the AH cut, minus cost - clears the floor.
    local deals = 0
    if not firstScan then
        for _, c in ipairs(cands) do
            if not db.blacklist[c.id] and c.unit >= cfg.minUnit then
                local b = db.book[c.id]
                local med = b and freshMedian(b.s, t, (cfg.freshMins or 45) * 60, cfg.armAfter) or nil
                local lineR = med and dealLine(med, c.id) or nil
                if med and med >= cfg.minUnit and lineR and c.unit <= lineR then
                    local line = lineR
                    -- exact overhang: units listed ABOVE the deal line queue
                    -- ahead of the relist; too many means a slow flip
                    local overhangUnits = 0
                    for _, L in ipairs(depth[c.id] or {}) do
                        if L.unit > line then overhangUnits = overhangUnits + L.count end
                    end
                    local q = qualityOf(c.id)
                    local maxOver = cfg.overhang or 0
                    local stackableR = infoOf(c.id).stackable
                    if stackableR == false then
                        -- stackables-only mode
                    elseif stackableR == nil or q == -1 then
                        requestItemLoad(c.id) -- uncached: passes next scan
                    elseif q < (cfg.quality or 1) then
                        dbg("skip " .. c.id .. ": quality " .. q .. " below bar, not a clean relist")
                    elseif maxOver > 0 and overhangUnits > maxOver then
                        dbg("skip " .. c.id .. ": " .. overhangUnits .. " units sit above the line, relist would queue")
                    else
                        local units, cost = 0, 0
                        for _, L in ipairs(depth[c.id] or {}) do
                            if L.unit <= line then
                                units = units + L.count
                                cost = cost + L.count * L.unit
                            end
                        end
                        if units > 0 then
                            local profit = math.floor(units * med * (1 - cfg.cut) - cost)
                            if profit >= cfg.profit then
                                fireAlert("market", c.id, c.link, c.unit, med,
                                    { units = units, cost = cost, profit = profit, line = line }, true)
                                deals = deals + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Watch rules: absolute price, no history needed, fires even on scan one.
    -- Swept against the rule's own ceiling the same way, so a stack of cheap
    -- cloth reads as one lot, but no profit guess - the rule IS the decision.
    if next(db.watch) ~= nil then
        rebuildWatch()
        for _, c in ipairs(cands) do
            if not db.blacklist[c.id] then
                local w = watchByID[c.id]
                if not w and next(watchByName) then
                    local name = nameOf(c.id, c.link)
                    if name then
                        w = watchByName[name]
                        if w then
                            db.watch[tostring(c.id)] = { name = w.name, maxPrice = w.maxPrice }
                            db.watch["n:" .. name] = nil
                        end
                    end
                end
                if w and c.unit <= w.maxPrice then
                    local units, cost = 0, 0
                    for _, L in ipairs(depth[c.id] or {}) do
                        if L.unit <= w.maxPrice then
                            units = units + L.count
                            cost = cost + L.count * L.unit
                        end
                    end
                    if units == 0 then units, cost = c.count or 1, c.unit end
                    fireAlert("watch", c.id, c.link, c.unit, nil,
                        { units = units, cost = cost, line = w.maxPrice })
                    deals = deals + 1
                end
            end
        end
    end

    -- Learn last so this scan's own deals cannot drag the median toward themselves.
    mergeIntoBook(curMins, t)

    S.prevList = curSeen
    S.scansDone = S.scansDone + 1
    db.stats.scans = S.scansDone
    db.stats.lastScan = t
    db.stats.lastListings = n
    db.stats.book = countKeys(db.book)

    if not cfg.quiet and (firstScan or deals > 0) then
        if firstScan then
            printf("scan 1 done: %d listings, %d items learned. Alerts arm after %d scans; watch rules are live now.",
                n, db.stats.book, cfg.armAfter)
        else
            printf("scan %d: %d listings, %d new, %d deal%s.", S.scansDone, n, #cands, deals, deals == 1 and "" or "s")
        end
    end

    if S.ahOpen then after(cfg.every, requestReplicate) end
    end -- finishScan

    -- 250 rows per tick, Auctionator's ProcessBatch cadence
    local rowIndex = 0
    local function harvestBatch()
        local step = 0
        while rowIndex < n and step < 250 do
            rowIndex = rowIndex + 1
            local i = rowIndex
            local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 =
                pcall(C_AuctionHouse.GetReplicateItemInfo, i)
            if not ok then
                err("replicate:" .. i, a1)
            else
                local itemID, count, buyout, link, quality
                if foreverLayout then
                    itemID, count, buyout = num(a17), num(a3), num(a10)
                    if C_AuctionHouse.GetReplicateItemLink then
                        local okL, l = pcall(C_AuctionHouse.GetReplicateItemLink, i)
                        if okL and type(l) == "string" then link = l end
                    end
                    -- no quality field in this layout; the alert filter tolerates nil
                else
                    itemID, count, buyout, quality = num(a1), num(a7), num(a14), num(a9)
                    link = type(a8) == "string" and a8 or nil
                end
                if itemID and itemID > 0 and count and count >= 1 and buyout and buyout > 0 then
                    local unit = math.floor(buyout / count)
                    local mk = tostring(itemID) .. "/" .. count .. "/" .. buyout
                    curSeen[mk] = (curSeen[mk] or 0) + 1
                    if not curMins[itemID] or unit < curMins[itemID] then
                        curMins[itemID] = unit
                    end
                    local dl = depth[itemID]
                    if not dl then dl = {}; depth[itemID] = dl end
                    dl[#dl + 1] = { unit = unit, count = count }
                    local isNew = firstScan or curSeen[mk] > (S.prevList[mk] or 0)
                    if isNew then
                        cands[#cands + 1] = { id = itemID, link = link, unit = unit, q = quality }
                    end
                end
            end
            step = step + 1
        end
        return rowIndex >= n
    end
    if harvestBatch() then
        finishScan()
    else
        S.harvestTicker = C_Timer.NewTicker(0, function()
            if harvestBatch() then
                S.harvestTicker:Cancel()
                S.harvestTicker = nil
                finishScan()
            end
        end)
    end
end

-- Scan engine, mirroring Auctionator's server-proven shape:
--   * one request per 15 minutes of our own (CanInitiate cooldown)
--   * no throttle check, no watchdog: the event completes the scan,
--     AUCTION_HOUSE_CLOSED resets everything
--   * pre-check: harvest data another addon already delivered instead of
--     requesting over it (a fresh request clears the delivered rows and the
--     server grants one list per session - live-traced 2026-10-11)
--   * rows are harvested in 250-row batches (Auctionator's ProcessBatch)
local SCAN_COOLDOWN = 15 * 60

function requestReplicate()
    if not cfg.enabled or not S.ahOpen or S.scanning then return end
    if C_AuctionHouse == nil then return end
    if S.lastScan and time() - S.lastScan < math.min(cfg.every, 60) then return end
    local okN, n = pcall(C_AuctionHouse.GetNumReplicateItems)
    n = okN and math.floor(num(n) or 0) or 0
    if n > 0 then
        dbg("replicate data present: n=" .. n .. " - harvesting, no new request")
        S.scanning = true
        after(3, function()
            -- let an in-flight delivery settle; the event may beat the timer
            if S.scanning then completeScan("present") end
        end)
        return
    end
    if S.lastRequest and time() - S.lastRequest < SCAN_COOLDOWN then
        dbg("request cooldown: " .. (time() - S.lastRequest) .. "s since last, waiting for the event or other data")
        return
    end
    S.lastRequest = time()
    local ok, e = pcall(C_AuctionHouse.ReplicateItems)
    dbg("ReplicateItems: ok=" .. tostring(ok) .. " ret=" .. tostring(e))
    if not ok then
        err("ReplicateItems", e)
        S.lastRequest = nil
        return
    end
    S.scanning = true
    -- event-driven from here: REPLICATE_ITEM_LIST_UPDATE completes the scan
end


-- scanner monitor: the always-visible heartbeat page (WoWSniper's scan view) --
-- Auto-shows with the AH: what the sniper is doing RIGHT NOW - sweeping,
-- paused (and why), counters, and the last category hunted. If this window
-- is quiet, something is wrong; /fsn says the same in text.
local scanPage, scanPageLines

local function buildScanPage()
    if scanPage then return end
    scanPage = CreateFrame("Frame", "ForeverSniperScanPage", UIParent)
    scanPage:SetSize(320, 118)
    scanPage:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -16, -220)
    scanPage:SetMovable(true)
    scanPage:EnableMouse(true)
    scanPage:RegisterForDrag("LeftButton")
    scanPage:SetScript("OnDragStart", scanPage.StartMoving)
    scanPage:SetScript("OnDragStop", scanPage.StopMovingOrSizing)
    local bg = scanPage:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints() bg:SetColorTexture(0.05, 0.05, 0.07, 0.94)
    local title = scanPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cffff7d0aForever Sniper|r")
    local closeBtn = CreateFrame("Button", nil, scanPage)
    closeBtn:SetSize(40, 16) closeBtn:SetPoint("TOPRIGHT", -4, -4)
    local xbg = closeBtn:CreateTexture(nil, "BACKGROUND")
    xbg:SetAllPoints() xbg:SetColorTexture(0.35, 0.15, 0.15, 0.9)
    closeBtn.fs = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    closeBtn.fs:SetAllPoints() closeBtn.fs:SetText("X")
    closeBtn.fs:SetTextColor(1, 0.7, 0.7)
    closeBtn:SetScript("OnClick", function()
        scanPage:Hide()
        cfg.scanPage = false
    end)
    scanPageLines = {}
    for i = 1, 4 do
        local l = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", 12, -26 - (i - 1) * 20)
        l:SetWidth(296)
        l:SetJustifyH("LEFT")
        l:SetText("|cff888888...|r")
        scanPageLines[i] = l
    end
end

local function updateScanPage()
    if not scanPage or not scanPage:IsShown() then return end
    local ss = S.sweepStats or { sent = 0, rows = 0, yields = 0 }
    local statusText, r, g, b
    if not S.ahOpen then
        statusText = "IDLE - open the Auction House"
        r, g, b = 0.55, 0.55, 0.55
    elseif S.warnedBrowse then
        statusText = "PAUSED - the Browse tab is up. Switch tabs!"
        r, g, b = 1, 0.35, 0.3
    elseif S.sweepTicker then
        statusText = "SCANNING - " .. (S.sweepStats.lastCat or "market") .. " (" .. (S.sweepStats.lastSort or "?") .. ")"
        r, g, b = 0.35, 1, 0.45
    else
        statusText = "STOPPED - no sweep ticker (/fsn on)"
        r, g, b = 1, 0.5, 0.3
    end
    scanPageLines[1]:SetText(string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), statusText))
    scanPageLines[2]:SetText(string.format("|cff888888sweeps|r |cffffd100%d|r  |cff888888rows read|r |cffffd100%d|r  |cff888888yields|r |cffffd100%d|r",
        ss.sent, ss.rows, ss.yields))
    scanPageLines[3]:SetText(string.format("|cff888888book|r |cffffd100%d|r items  |cff888888deals|r |cffffd100%d|r  |cff888888buys|r |cffffd100%d|r",
        db.stats.book or 0, db.stats.deals or 0, S.session.buys or 0))
    scanPageLines[4]:SetText(string.format("|cff888888committed|r |cffff4d00%s|r  |cff888888listed|r |cffffd100%d|r  |cff888888watch rules|r |cffffd100%d|r",
        fmtMoney(S.session.spent or 0), S.session.listed or 0, countKeys(db.watch)))
end

-- UNDERCUT GUARD (sell-side sauce): a flip only prints if it SELLS, and it
-- sells fastest at the front of the queue. Poll our own auctions; when the
-- learned market drops under our listing price, someone is in front of us -
-- cancel and relist. The cancel-relist loop TSM charges a subscription for,
-- running on book data no other local addon has.
local undercutTicker
local function checkUndercuts()
    if not S.ahOpen or not cfg.undercut then return end
    if C_AuctionHouse == nil or C_AuctionHouse.QueryOwnedAuctions == nil then return end
    if GetTime() - (S.lastUndercutQuery or 0) < 1.0 then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady then
        local okT, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if okT and ready == false then return end
    end
    S.lastUndercutQuery = GetTime()
    local ok, e = pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    if not ok then err("QueryOwnedAuctions", e) end
end

-- Live sweep (the sniper feed) --------------------------------------------------------
-- WoWSniper's engine, ported: weighted category rotation (one class per query,
-- faster detection within the AH throttle), event-driven throttle tracking,
-- browse paging, a safety check against Blizzard's own browse tab (querying
-- under it can crash the client), and new-listing detection with expiry.
-- The book learns from every row; deals fire only on NEW cheap listings that
-- pass the listability gates.

-- STACKABLE ONLY: mats, consumables, gems, enhancements. Non-stackables
-- (gear, mounts, pets, recipes) are out of scope by design - the rotation
-- hunts commodity classes, and every alert path re-checks stackability.
local SCAN_CATEGORIES = {
    { name = "Trade Goods",  classID = 7, priority = 3 },
    { name = "Consumables",  classID = 0, priority = 3 },
    { name = "Gems",         classID = 3, priority = 2 },
    { name = "Enhancements", classID = 8, priority = 2 },
}
local rotationList, rotationIndex = {}, 0
for _, cat in ipairs(SCAN_CATEGORIES) do
    for p = 1, cat.priority do rotationList[#rotationList + 1] = cat end
end
local function nextCategory()
    rotationIndex = rotationIndex + 1
    if rotationIndex > #rotationList then
        rotationIndex = 1
        -- rotate the seen-cache at the top of each full pass
        local cutoff = time() - 300
        for k, t in pairs(S.seen or {}) do
            if t < cutoff then S.seen[k] = nil end
        end
    end
    return rotationList[rotationIndex]
end

S.seen = db.seen or {}
db.seen = S.seen
-- prune stale entries at load: seen data older than an hour is meaningless
do
    local cutoff = time() - 3600
    for k, t in pairs(S.seen) do
        if t < cutoff then S.seen[k] = nil end
    end
    for k, a in pairs(S.lastAlert) do
        if (a.t or 0) < cutoff then S.lastAlert[k] = nil end
    end
end
local function isNewListing(itemID, price, peekOnly)
    local k = tostring(itemID) .. ":" .. tostring(price)
    if S.seen[k] then return false end
    if not peekOnly then S.seen[k] = time() end
    return true
end

-- request the client to cache an item's info; quality checks pass next sweep
local function requestItemLoad(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local throttleReady, pagePending, lastQueryAt = true, false, 0
local sweepCount, watchCursor, sortFlip = 0, 0, 0
S.sweepStats = { sent = 0, rows = 0, yields = 0, lastRows = 0 }

-- one watched item as a search key, or nil when nothing is watched
local function nextWatchKey()
    if not next(db.watch) then return nil end
    rebuildWatch()
    local ids = {}
    for id, w in pairs(watchByID) do ids[#ids + 1] = tonumber(id) or id end
    if #ids == 0 then return nil end
    watchCursor = (watchCursor % #ids) + 1
    local id = ids[watchCursor]
    local w = watchByID[id]
    local key = { itemID = id }
    if C_AuctionHouse and C_AuctionHouse.MakeItemKey then
        local okK, k = pcall(C_AuctionHouse.MakeItemKey, id)
        if okK and type(k) == "table" then key = k end
    end
    return key, id, w
end

-- Querying while Blizzard's own browse tab is up can crash its ScrollBox
local function blizzardBrowseActive()
    if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown()
        and AuctionHouseFrame.BrowseResultsFrame
        and AuctionHouseFrame.BrowseResultsFrame.IsShown
        and AuctionHouseFrame.BrowseResultsFrame:IsShown() then
        return true
    end
    return false
end

-- the AH opens on the Browse tab by default, and sweeping under it risks the
-- client's ScrollBox crash - so land somewhere else instead of yielding.
-- Tab 1 is Browse on this client family (Auctionator's LibAHTab relies on the
-- same AuctionHouseFrame.Tabs layout); clicking any other tab clears it.
local function avoidBrowseTab()
    if not cfg.avoidBrowse or not S.ahOpen then return end
    local ahf = AuctionHouseFrame
    if not (ahf and ahf.Tabs) then return end
    if not blizzardBrowseActive() then return end -- already on another page
    for i = 2, #ahf.Tabs do
        local tab = ahf.Tabs[i]
        if tab then
            local ok = pcall(function() tab:Click() end)
            if ok then
                printf("switched the AH off the Browse tab - the live sweep needs a clear page.")
                updateScanPage()
                return
            end
        end
    end
end

local function canQuery()
    if not cfg.enabled or not S.ahOpen then return false end
    if pagePending or not throttleReady then return false end
    if GetTime() - lastQueryAt < 1.0 then return false end
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
        local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if ok and ready == false then return false end
    end
    return true
end

local function processBrowseRows(rows)
    S.gateLog = { at = time(), counts = {}, examples = {} }
    local function why(reason, itemID, extra)
        S.gateLog.counts[reason] = (S.gateLog.counts[reason] or 0) + 1
        if #S.gateLog.examples < 6 and itemID then
            S.gateLog.examples[#S.gateLog.examples + 1] =
                (infoOf(itemID).name or ("item " .. itemID)) .. ": " .. reason .. (extra or "")
        end
    end
    local mins, t = {}, time()
    for _, r in ipairs(rows) do
        local key = num(r.itemKey and r.itemKey.itemID)
        local price = num(r.minPrice)
        local qty = num(r.totalQuantity) or 0
        if key and price and price > 0 then
            mins[key] = price
            if qty and qty > 0 then noteStack(key, qty) end
            -- VENDOR FLIP: priced under the vendor sell price = guaranteed
            -- instant profit. No market gates apply - the vendor always buys.
            local sell = vendorOf(key)
            -- vendor flips ignore the stackable filter: guaranteed profit is
            -- guaranteed, and gear vendored is gear sold
            if false then
                if (S.gateLog.counts["not stackable (skipped)"] or 0) < 6 then
                    why("not stackable (skipped)", key, " (stack=" .. tostring(infoOf(key).maxStack) .. ")")
                else
                    S.gateLog.counts["not stackable (skipped)"] = (S.gateLog.counts["not stackable (skipped)"] or 0) + 1
                end
            end
            if sell > 0 and price < sell then
                if not isNewListing(key, price, true) then
                    why("already seen (vendor flip)", key)
                end
            end
            if sell > 0 and price < sell and isNewListing(key, price) then
                local est = (sell - price) * qty
                fireAlert("vendor", key, nil, price, sell,
                    { units = qty, cost = price * qty, profit = est, line = sell })
            end
            local b = db.book[key]
            if b then
                local med = freshMedian(b.s, t, (cfg.freshMins or 45) * 60, cfg.armAfter)
                local dealLinePx = nil
                if not med then
                    if (S.gateLog.counts["no fresh median"] or 0) < 3 then
                        why("no fresh median yet", key)
                    end
                elseif med < cfg.minUnit then
                    why("market under floor", key)
                else
                    dealLinePx = dealLine(med, key)
                    if price > dealLinePx then
                        if (S.gateLog.counts["not cheap enough"] or 0) < 3 then
                            local _, mult = dealLine(med, key)
                            why("not cheap enough", key, " (" .. fmtMoney(price) .. " vs line " .. fmtMoney(math.floor(dealLinePx)) .. " @" .. math.floor((1 - mult) * 100 + 0.5) .. "% off)")
                        end
                    end
                end
                if key == 4338 then
                end
                absorbTrack(key, med ~= nil and dealLinePx ~= nil and price <= dealLinePx, t)
                if med and med >= cfg.minUnit and dealLinePx and price <= dealLinePx then
                    -- listability gates: verifiable quality (uncached items get a
                    -- load request and pass on the NEXT sweep - the client caches
                    -- item info asynchronously), a market not buried under
                    -- competing stock, and a NEW listing
                    local q = qualityOf(key)
                    local overhang = cfg.overhang or 0
                    local crowded = overhang > 0 and qty > overhang
                    local stackable = infoOf(key).stackable
                    if stackable == false then
                        -- stackables-only mode: non-stackables never alert
                    elseif stackable == nil or q == -1 then
                        -- unknown (stackable or quality): load and pass next sweep
                        requestItemLoad(key)
                        -- unknown: never a hard block, just not this sweep
                        requestItemLoad(key)
                    elseif q < (cfg.quality or 1) then
                        -- quality below bar: not a clean relist
                    elseif crowded and qty >= 100 and price <= 0.4 * med then
                        -- DUMP DETECTOR: a huge wall at a deep discount is a reset
                        -- (someone quitting, or crashing a market). Goblins buy the
                        -- floor and relist in stages as the queue clears.
                        if isNewListing(key, price) then
                            local cost = qty * price
                            local est = math.floor(qty * med * (1 - cfg.cut) - cost)
                            fireAlert("dump", key, nil, price, med,
                                { units = qty, cost = cost, profit = est, line = price }, true)
                        end
                    elseif crowded then
                        dbg("skip " .. key .. ": " .. qty .. " units listed, relist would queue behind them")
                    elseif not isNewListing(key, price) then
                        -- already seen at this price: not a new deal
                    else
                        local line = dealLine(med, key)
                        local cost = qty * price
                        local est = math.floor(qty * med * (1 - cfg.cut) - cost)
                        local hr = serverHour()
                        local hAvg = hourAverage(key, hr)
                        if hAvg and med < hAvg * 0.7 then
                            printf("|cff4fc0ff(time arbitrage: %d%% below this hour's usual %s)|r",
                                math.floor((1 - med / hAvg) * 100 + 0.5), fmtMoney(math.floor(hAvg)))
                        end
                        local vol = bookVolatility(key)
                        if vol and vol > 0.25 then
                            printf("|cff888888(swings +%d%% - prime flip territory)|r", math.floor(vol * 100 + 0.5))
                        end
                        local vel = absorbVelocity(key)
                        if vel and vel < 60 then
                            printf("|cff888888(absorbed in %ds last time - HOT)|r", math.floor(vel + 0.5))
                        elseif vel and vel > 600 then
                            printf("|cff888888(slow absorber - %dm to sell last time)|r", math.floor(vel / 60 + 0.5))
                        end
                        fireAlert("market", key, nil, price, med,
                            { units = qty, cost = cost, profit = est, line = line }, true)
                    end
                end
            end
        end
    end
    if next(mins) then mergeIntoBook(mins, t) end
end

local function sweepQuery()
    if not canQuery() then return end
    if C_AuctionHouse == nil then return end
    if blizzardBrowseActive() then
        -- querying under Blizzard's own browse results can crash its ScrollBox;
        -- hunt a watched item instead (searches never touch that frame), and
        -- tell the user ONCE why the full sweep is paused
        S.sweepStats = S.sweepStats or { sent = 0, rows = 0, yields = 0 }
        S.sweepStats.yields = S.sweepStats.yields + 1
        if not S.warnedBrowse then
            S.warnedBrowse = true
            printf("the AH's own |cffffd100Browse tab is showing|r - the live sweep pauses under it (client crash risk). Switch to any other tab and the sniper resumes.")
        end
        return
    end
    sweepCount = sweepCount + 1
    -- every 5th query hunts a watched item directly: deep listings the browse
    -- first page never shows, at the speed of an explicit search
    if sweepCount % 5 == 0 and C_AuctionHouse.SendSearchQuery then
        local key, id, w = nextWatchKey()
        if key and w then
            local sorts = {}
            if Enum and Enum.AuctionHouseSortOrder then
                local so = Enum.AuctionHouseSortOrder.Price or Enum.AuctionHouseSortOrder.Buyout
                if so then sorts = { { sortOrder = so, reverseSort = false } } end
            end
            local ok, e = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
            if ok then
                lastQueryAt = GetTime()
                S.watchSearch = { id = id, maxPrice = w.maxPrice, t = GetTime() }
                return
            end
            err("SendSearchQuery(watch)", e)
        end
    end
    if C_AuctionHouse.SendBrowseQuery == nil then return end
    local cat = nextCategory()
    sortFlip = sortFlip + 1
    local newest = (sortFlip % 2 == 0)
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        local so = Enum.AuctionHouseSortOrder.Price or Enum.AuctionHouseSortOrder.Buyout
        if newest and Enum.AuctionHouseSortOrder.TimeLeft then
            -- freshest listings first: the sniper's true feed (a price-sorted
            -- first page is dominated by vendor-junk tier; a 50g item posted
            -- at 10g never reaches it)
            so = Enum.AuctionHouseSortOrder.TimeLeft
        end
        if so then sorts = { { sortOrder = so, reverseSort = newest } } end
    end
    local query = {
        searchString = "",
        sorts = sorts,
        filters = {},
        itemClassFilters = { { classID = cat.classID } },
    }
    S.sweepStats.lastSort = newest and "newest" or "cheapest"
    local ok, e = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then
        err("SendBrowseQuery", e)
        return
    end
    lastQueryAt = GetTime()
    pagePending = true -- cleared when results land (or paging completes)
    S.sweeping = true
    S.sweepStats.sent = S.sweepStats.sent + 1
    S.sweepStats.lastCat = cat.name
    updateScanPage()
    dbg("sweep sent: " .. cat.name)
end

local function maybeMorePages()
    if not S.ahOpen or C_AuctionHouse.HasFullBrowseResults == nil then pagePending = false return end
    local ok, full = pcall(C_AuctionHouse.HasFullBrowseResults)
    if ok and not full and canQuery() then
        local ok2 = pcall(C_AuctionHouse.RequestMoreBrowseResults)
        if ok2 then lastQueryAt = GetTime() return end
    end
    pagePending = false
end

local function startSweeping()
    if S.sweepTicker or not cfg.enabled then return end
    if cfg.undercut and not undercutTicker and C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
        undercutTicker = C_Timer.NewTicker(30, checkUndercuts)
    end
    local period = math.max(tonumber(cfg.sweep) or 3, 2)
    S.sweepTicker = C_Timer.NewTicker(period, function()
        sweepQuery()
        feedTick() -- apply deferred feed refreshes
        updateScanPage()
    end)
    after(1, sweepQuery)
    dbg("live sweep armed: category rotation every " .. period .. "s")
end

local function stopSweeping()
    if S.sweepTicker then
        S.sweepTicker:Cancel()
        S.sweepTicker = nil
    end
    if undercutTicker then
        undercutTicker:Cancel()
        undercutTicker = nil
    end
    S.sweeping = false
    pagePending = false
end


local function onOwnedAuctionsUpdated()
    if C_AuctionHouse.GetNumOwnedAuctions == nil then return end
    local okN, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
    n = okN and math.floor(num(n) or 0) or 0
    if n == 0 then return end
    local t = time()
    for i = 1, n do
        local okI, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
        if okI and type(info) == "table" then
            local itemID = info.itemKey and info.itemKey.itemID
            local buyout = num(info.buyoutAmount)
            local qty = num(info.quantity) or 1
            if itemID and buyout and buyout > 0 then
                local unit = math.floor(buyout / qty)
                local b = db.book[itemID]
                local med = b and freshMedian(b.s, t, (cfg.freshMins or 45) * 60, cfg.armAfter) or nil
                if med and med > 0 and unit > med * 1.05 then
                    if not (b.ownUntil and t < b.ownUntil) then
                        local key = tostring(itemID)
                        S.lastUndercut = S.lastUndercut or {}
                        local last = S.lastUndercut[key]
                        if not (last and t - last < 300) then
                            S.lastUndercut[key] = t
                            db.stats.undercuts = (db.stats.undercuts or 0) + 1
                            printf("|cffff8800UNDERCUT|r %s - you list at %s, market now %s. |cffffd100Cancel + relist.|r",
                                info.itemLink or (infoOf(itemID).name or ("item " .. itemID)),
                                fmtMoney(unit), fmtMoney(math.floor(med)))
                            playTierSound("SNIPE")
                        end
                    end
                end
            end
        end
    end
end

-- MAILBOX MINT (dark sauce): sold-auction mail carries the invoice - exact
-- deposit paid, AH cut taken, real sale price. Crossed with what we PAID
-- (boughtAt), this closes the P&L loop with realized profit, the number
-- every other sniper guesses at.
local function scanMailbox()
    if GetInboxNumItems == nil then return end
    local okN, n = pcall(GetInboxNumItems)
    n = okN and math.floor(num(n) or 0) or 0
    if n == 0 then return end
    local t = time()
    for i = 1, n do
        -- invoice data only exists on auction-sold mail
        if GetInboxInvoiceInfo then
            local okI, invoiceType, itemName, quantity, invoiceAmount, deposit, consignment =
                pcall(GetInboxInvoiceInfo, i)
            if okI and invoiceType == "seller" and invoiceAmount then
                local key = S.mailSeen and S.mailSeen[i] -- dedupe by slot+amount
                local totalReceived = invoiceAmount + (deposit or 0) - (consignment or 0)
                local sig = tostring(i) .. ":" .. tostring(totalReceived)
                S.mailSeen = S.mailSeen or {}
                if S.mailSeen[sig] ~= true then
                    S.mailSeen[sig] = true
                    db.stats.sales = (db.stats.sales or 0) + 1
                    db.stats.realized = (db.stats.realized or 0) + totalReceived
                    S.session.realized = (S.session.realized or 0) + totalReceived
                    printf("|cff7cff4fSOLD|r %s x%s - |cffffd100%s|r received (deposit %s, AH cut %s)",
                        itemName or "item", quantity or 1,
                        fmtMoney(totalReceived), fmtMoney(deposit or 0), fmtMoney(consignment or 0))
                end
            end
        end
    end
end

-- Events ---------------------------------------------------------------------------

local f = CreateFrame("Frame")
local handlers = {}
local unknownEvents = {}

-- Register a handler; altEvent is a fallback name for clients that spell the
-- event differently (the Forever client fires REPLICATE_ITEM_LIST_UPDATE,
-- retail fires REPLICATE_ITEM_LIST_UPDATED - one letter cost the whole scan loop)
local function on(event, fn, altEvent)
    handlers[event] = fn
    if pcall(f.RegisterEvent, f, event) then return end
    if altEvent and pcall(f.RegisterEvent, f, altEvent) then
        handlers[altEvent] = fn
        return
    end
    unknownEvents[#unknownEvents + 1] = event
end

-- Optional handler: register if this client has the event, stay silent if not
local function onOptional(event, fn)
    handlers[event] = fn
    pcall(f.RegisterEvent, f, event)
end

f:SetScript("OnEvent", function(_, event, ...)
    local fn = handlers[event]
    if not fn then return end
    local ok, e = pcall(fn, ...)
    if not ok then err(event, e) end
end)

onOptional("MAIL_SHOW", function() scanMailbox() end)

on("PLAYER_LOGIN", function()
    buildPopup()
    after(8, scanMailbox) -- sales that landed while offline
    if C_AuctionHouse == nil then
        printf("C_AuctionHouse is not on this client; going dormant.")
        return
    end
    if #unknownEvents > 0 then
        err("events", "unknown: " .. table.concat(unknownEvents, ", "))
    end
    if not db.welcomed then
        db.welcomed = true
        printf("|cffff7d0aWelcome to Forever Sniper|r - the AH money printer.")
        printf("1. open the Auction House - it learns prices and hunts deals automatically")
        printf("2. type |cffffd100/fsn feed|r for the live deal window (click a row to check prices, BUY to buy)")
        printf("3. under-vendor listings alert as |cffffd100VENDOR|r flips: buy, vendor, instant profit")
        printf("everything else: |cffffd100/fsn help|r")
    else
        printf("armed. /fsn help - visits to the AH build the price book (alert %d%% of market).",
            math.floor(cfg.threshold * 100 + 0.5))
    end
end)

on("AUCTION_HOUSE_SHOW", function()
    S.ahOpen = true
    S.warnedBrowse = nil -- the yield hint fires once per AH session
    if cfg.scanPage then buildScanPage() scanPage:Show() updateScanPage() end
    after(0.5, avoidBrowseTab) -- let the frame settle on Browse, then move off it
    if cfg.enabled and C_AuctionHouse then
        startSweeping()
        after(2, requestReplicate) -- replicate is the book bootstrap, not the feed
    end
end)

on("AUCTION_HOUSE_CLOSED", function()
    S.ahOpen = false
    S.scanning = false
    stopSweeping()
    if scanPage then updateScanPage() end
    if S.harvestTicker then
        S.harvestTicker:Cancel()
        S.harvestTicker = nil
    end
    scanMailbox() -- sales land while trading
    -- compact session summary: what the printer did while you were in there
    local best = S.session.best
    if best and best.profit and best.profit > 0 then
        printf("session: |cffffd100%d buy(s)|r for |cffff4d00%s|r |cff7cff4f|%d sold for %s|r (realized) - best find %s |cff7cff4f+%s|r.",
            S.session.buys or 0, fmtMoney(S.session.spent or 0),
            db.stats.sales or 0, fmtMoney(S.session.realized or 0),
            infoOf(best.id).name or ("item " .. best.id), fmtMoney(best.profit))
    end
end)

on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    -- a fresh result set answers our sweep (or any manual search); read it
    if S.sweeping and C_AuctionHouse.GetBrowseResults then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            dbg("browse results: " .. #rows .. " row(s)")
            S.sweepStats.rows = S.sweepStats.rows + #rows
            S.sweepStats.lastRows = #rows
            processBrowseRows(rows)
            maybeMorePages()
        elseif not ok then
            S.sweeping = false
            pagePending = false
            err("GetBrowseResults", rows)
        end
    end
end)

on("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function()
    -- the next page landed: process it, keep paging until full
    if S.sweeping and C_AuctionHouse.GetBrowseResults then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            processBrowseRows(rows)
        end
        maybeMorePages()
    end
end)

-- Event-driven throttle (WoWSniper's approach: never guess, listen)
onOptional("OWNED_AUCTIONS_UPDATED", function() onOwnedAuctionsUpdated() end)
onOptional("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() throttleReady = true end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", function() throttleReady = true end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function() throttleReady = false end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", function() throttleReady = false end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    throttleReady = true
    pagePending = false -- retry on the next tick
end)

on("REPLICATE_ITEM_LIST_UPDATE", function()
    dbg("REPLICATE_ITEM_LIST_UPDATE fired")
    completeScan("event")
end, "REPLICATE_ITEM_LIST_UPDATED") -- Forever spells it UPDATE, retail UPDATED

-- Print the cheapest live listings for the last row clicked.
local function printPending(kind)
    local p = S.pending
    if not p or GetTime() - p.t > 10 then return end
    S.pending = nil
    local shown = 0
    local key = { itemID = p.itemID }
    if C_AuctionHouse.MakeItemKey then
        local okK, k = pcall(C_AuctionHouse.MakeItemKey, p.itemID)
        if okK and type(k) == "table" then key = k end
    end
    if kind == "commodity" and C_AuctionHouse.GetCommoditySearchResultInfo then
        local i = 1
        while shown < 3 do
            local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, p.itemID, i)
            if not ok or type(info) ~= "table" then break end
            printf("  %d x %s each", info.quantity or 1, fmtMoney(info.unitPrice or info.buyoutAmount))
            shown = shown + 1
            i = i + 1
        end
    elseif C_AuctionHouse.GetItemSearchResultInfo then
        local ok, n = pcall(C_AuctionHouse.GetNumItemSearchResults, key)
        n = ok and math.floor(num(n) or 0) or 0
        for i = 1, math.min(n, 3) do
            local ok2, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, i)
            if ok2 and type(info) == "table" then
                printf("  x%d - %s  (buy in the AH window)", info.quantity or 1,
                    fmtMoney(info.buyoutAmount or info.unitPrice))
                shown = shown + 1
            end
        end
    end
    if p.units and p.units > 1 then
        printf("  |cffffd100buy %d units|r - that is every one under your line, one purchase.", p.units)
    end
    if shown == 0 then printf("  results are in - check the AH window; nothing printable.") end
end

on("ITEM_SEARCH_RESULTS_UPDATED", function()
    -- watch-rule search results first: cheapest listing under the rule's
    -- ceiling fires a watch alert immediately
    local ws = S.watchSearch
    if ws and GetTime() - ws.t < 10 and C_AuctionHouse.GetItemSearchResultInfo then
        S.watchSearch = nil
        local key = { itemID = ws.id }
        if C_AuctionHouse.MakeItemKey then
            local okK, k = pcall(C_AuctionHouse.MakeItemKey, ws.id)
            if okK and type(k) == "table" then key = k end
        end
        local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults, key)
        n = okN and math.floor(num(n) or 0) or 0
        if n > 0 then
            local okI, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, 1)
            if okI and type(info) == "table" then
                local buyout = num(info.buyoutAmount)
                local qty = num(info.quantity) or 1
                if buyout and buyout > 0 then
                    local unit = math.floor(buyout / qty)
                    if infoOf(ws.id).stackable == true and unit <= ws.maxPrice then
                        fireAlert("watch", ws.id, info.itemLink,
                            unit, nil, { units = qty, cost = buyout, line = ws.maxPrice })
                    end
                end
            end
        end
        return
    end
    if S.buying then buyFromResults("item") else printPending("item") end
end)
on("COMMODITY_SEARCH_RESULTS_UPDATED", function()
    if S.buying then buyFromResults("commodity") else printPending("commodity") end
end)
on("COMMODITY_PRICE_UPDATED", function(total)
    -- The live quote for a pending commodity purchase: keep the confirm
    -- dialog honest with the server's own number.
    local q = S.quote
    local t = num(total)
    if q and t and t > 0 then
        q.total = t
        if confirmFrame and confirmFrame:IsShown() and confirmFrame.q == q then
            confirmFrame.body:SetText(string.format("%d x %s\n|cffffd100total %s|r",
                q.units, q.link or ("item " .. q.itemID), fmtMoney(t)))
        end
    end
end)

-- options panel: plain-frame toggles and steppers, no templates needed ------
local optionsFrame

local function buildOptions()
    if optionsFrame then return end
    optionsFrame = CreateFrame("Frame", "ForeverSniperOptions", UIParent)
    optionsFrame:SetSize(300, 240)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    local bg = optionsFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints() bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cffff7d0aForever Sniper|r - options")
    local closeBtn = CreateFrame("Button", nil, optionsFrame)
    closeBtn:SetSize(52, 18) closeBtn:SetPoint("TOPRIGHT", -6, -6)
    local xbg = closeBtn:CreateTexture(nil, "BACKGROUND")
    xbg:SetAllPoints() xbg:SetColorTexture(0.2, 0.2, 0.25, 0.95)
    closeBtn.fs = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    closeBtn.fs:SetAllPoints() closeBtn.fs:SetText("Close")
    closeBtn:SetScript("OnClick", function() optionsFrame:Hide() end)

    local function toggle(y, label, key, extra)
        local b = CreateFrame("Button", nil, optionsFrame)
        b:SetSize(120, 22) b:SetPoint("TOPLEFT", 12, -y)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.fs:SetPoint("LEFT", 6, 0)
        local function paint()
            if cfg[key] then
                b.bg:SetColorTexture(0.15, 0.4, 0.15, 0.9)
                b.fs:SetTextColor(0.4, 1, 0.5)
            else
                b.bg:SetColorTexture(0.35, 0.15, 0.15, 0.9)
                b.fs:SetTextColor(1, 0.5, 0.5)
            end
            b.fs:SetText(label .. ": " .. (cfg[key] and "on" or "off"))
        end
        b:SetScript("OnClick", function()
            cfg[key] = not cfg[key]
            paint()
            if extra then extra() end
        end)
        paint()
        return b
    end

    toggle(34, "sound", "sound")
    toggle(62, "screen flash", "flash")
    toggle(90, "toast", "toast")
    toggle(118, "alert popup", "popup")
    toggle(146, "quiet summaries", "quiet")

    local function stepper(y, label, get, set, fmt, step)
        local lab = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lab:SetPoint("TOPLEFT", 160, -y - 3)
        lab:SetText(label)
        local val = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("TOPLEFT", 160, -y - 22)
        local function paint() val:SetText(fmt(get())) end
        local function mk(text, dx, fn)
            local b = CreateFrame("Button", nil, optionsFrame)
            b:SetSize(24, 20) b:SetPoint("TOPLEFT", 160 + dx, -y - 20)
            local t = b:CreateTexture(nil, "BACKGROUND")
            t:SetAllPoints() t:SetColorTexture(0.2, 0.25, 0.35, 0.95)
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetAllPoints() fs:SetText(text)
            b:SetScript("OnClick", function() fn() paint() end)
        end
        mk("-", 100, function() set(get() - step) end)
        mk("+", 128, function() set(get() + step) end)
        paint()
    end

    stepper(34, "deal threshold", function() return cfg.threshold end,
        function(v) cfg.threshold = math.min(0.99, math.max(0.01, v)) end,
        function(v) return math.floor(v * 100 + 0.5) .. "% of market" end, 0.05)
    stepper(96, "sweep seconds", function() return cfg.sweep end,
        function(v)
            cfg.sweep = math.min(30, math.max(2, math.floor(v)))
            if S.sweepTicker then stopSweeping() startSweeping() end
        end,
        function(v) return tostring(v) .. "s between sweeps" end, 1)
    stepper(152, "spend cap (gold)", function() return cfg.maxSpend / 10000 end,
        function(v) cfg.maxSpend = math.max(1, math.floor(v)) * 10000 end,
        function(v) return math.floor(v + 0.5) .. "g per Buy" end, 25)
end
-- Slash commands ---------------------------------------------------------------------

local HELP = {
    "|cffff7d0aForever Sniper|r - it watches, you buy",
    "|cffffd100core|r",
    "/fsn                  status",
    "/fsn feed             deal window (click a row = live prices, BUY = buy)",
    "/fsn profit           money printer stats (session + lifetime)",
    "/fsn undercut         guard your listings (alert when undercut)",
    "/fsn options          settings panel",
    "/fsn page             scanner monitor window (toggle)",
    "/fsn on | off         enable / disable",
    "/fsn watch <link> 50s watchlist rule (a plain item name works too)",
    "/fsn unwatch <link>|all",
    "|cffffd100tuning|r",
    "/fsn thresh 50        alert at %% of learned market (1-99)",
    "/fsn sweep 3          seconds between live sweeps (2-30)",
    "/fsn max 250g         spend cap per Buy click",
    "/fsn min 10s          ignore deals under this per-unit price",
    "/fsn quality 2        minimum rarity for market alerts (0 = any)",
    "/fsn profit 1g        minimum estimated resale profit (0 = off)",
    "/fsn arm 2            scans of history before alerts fire",
    "/fsn fresh 45         minutes a price sample stays fresh (5-480)",
    "/fsn overhang 500     skip deals buried under more units (0 = off)",
    "/fsn every 45 / cut 5 full-scan cadence / assumed AH cut percent",
    "|cffffd100alerts|r - sound, flash, toast, pop, quiet",
    "|cffffd100data|r - alerts, watchlist, shape, errors, wipe book|all",
}

local function usageWatch(rest)
    -- "/fsn watch [Item Link] 3g50s" - the money words come off the end.
    local words = { strsplit(" ", (rest:gsub("%s+", " "):gsub("^%s", ""))) }
    local moneyWords = {}
    while #words > 0 and words[#words]:match("^%d+[gGsScC]?%d*[gGsScC]?$") and words[#words]:match("%d") do
        table.insert(moneyWords, 1, table.remove(words))
    end
    local price = parseMoney(table.concat(moneyWords, " "))
    local target = table.concat(words, " ")
    if not price or target == "" then
        printf("usage: /fsn watch <item link or name> <price>   e.g. /fsn watch [Linen Cloth] 50s")
        return
    end
    local itemID = tonumber(target:match("|Hitem:(%d+)"))
    if itemID then
        db.watch[tostring(itemID)] = { maxPrice = price }
        printf("watching %s at or under %s.", target:match("%[(.+)%]") or target, fmtMoney(price))
    else
        local ok, iid = pcall(GetItemInfoInstant, target)
        if ok and iid then
            db.watch[tostring(iid)] = { maxPrice = price }
            printf("watching %s (item %d) at or under %s.", target, iid, fmtMoney(price))
        else
            db.watch["n:" .. strlower(target)] = { name = target, maxPrice = price }
            printf("watching %q by name at or under %s (resolves to an ID on first sighting).", target, fmtMoney(price))
        end
    end
end

SLASH_FOREVERSNIPER1 = "/fsn"
SLASH_FOREVERSNIPER2 = "/foreversniper"
SlashCmdList.FOREVERSNIPER = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")

    if cmd == "help" or cmd == "?" then
        for _, line in ipairs(HELP) do print("  " .. line) end

    elseif cmd == "" or cmd == "status" then
        printf("%s | %d scans done | book %d items | %d alerts fired",
            cfg.enabled and "|cff7cff4fon|r" or "|cffff4d4doff|r",
            S.scansDone, db.stats.book or 0, db.stats.deals or 0)
        local ss = S.sweepStats or { sent = 0, rows = 0, yields = 0 }
        if S.sweepTicker then
            printf("live sweep: |cffffd100%d sent|r, %d rows read, %d yields (browse-tab pauses). AH open: %s.",
                ss.sent, ss.rows, ss.yields, S.ahOpen and "yes" or "no")
        elseif S.ahOpen then
            printf("|cffff4d4dlive sweep is NOT running|r - the AH is open but no ticker. /fsn on, then reopen the AH.")
        else
            printf("live sweep idle - it runs while the AH is open (%d sent last session).", ss.sent)
        end
        if S.warnedBrowse and S.ahOpen then
            printf("|cffffd100the Browse tab is blocking sweeps|r - switch to another AH tab.")
        end
        if db.stats.lastScan then
            printf("last scan %s: %d listings. threshold %d%% of market, every %ds, arm after %d, floor %s.",
                date("%m-%d %H:%M", db.stats.lastScan), db.stats.lastListings or 0,
                math.floor(cfg.threshold * 100 + 0.5), cfg.every, cfg.armAfter, fmtMoney(cfg.minUnit))
        else
            printf("no scans yet - open the auction house to start learning.")
        end
        printf("profit gate: quality %s, %d%% AH cut, minimum profit %s.",
            cfg.quality == 0 and "any" or (cfg.quality .. "+"),
            math.floor(cfg.cut * 100 + 0.5), cfg.profit > 0 and fmtMoney(cfg.profit) or "off")
        printf("spend cap per Buy click: |cffffd100%s|r. every purchase is your click - never automatic.",
            fmtMoney(cfg.maxSpend))
        printf("AH window %s. %d watch rules, %d blacklisted. /fsn help for everything.",
            S.ahOpen and "open" or "closed", countKeys(db.watch), countKeys(db.blacklist))

    elseif cmd == "on" then cfg.enabled = true; printf("enabled. open the AH to scan.")
    elseif cmd == "off" then cfg.enabled = false; printf("disabled.")

    elseif cmd == "thresh" then
        local v = tonumber(rest)
        if v and v >= 1 and v <= 99 then
            cfg.threshold = v / 100
            printf("threshold set to %d%% of market.", v)
        else printf("usage: /fsn thresh 50  (percent, 1-99)") end

    elseif cmd == "every" then
        local v = tonumber(rest)
        if v and v >= 15 and v <= 900 then
            cfg.every = math.floor(v)
            printf("scanning every %ds while the AH is open.", cfg.every)
        else printf("usage: /fsn every 45  (seconds, 15-900)") end

    elseif cmd == "sweep" then
        local v = tonumber(rest)
        if v and v >= 2 and v <= 30 then
            cfg.sweep = math.floor(v)
            if S.sweepTicker then stopSweeping(); startSweeping() end
            printf("live sweep every %ds while the AH is open.", cfg.sweep)
        else printf("usage: /fsn sweep 3  (seconds, 2-30)") end

    elseif cmd == "fresh" then
        local v = tonumber(rest)
        if v and v >= 5 and v <= 480 then
            cfg.freshMins = math.floor(v)
            printf("market samples older than %d min no longer arm alerts.", cfg.freshMins)
        else printf("usage: /fsn fresh 45  (minutes, 5-480)") end

    elseif cmd == "overhang" then
        local v = tonumber(rest)
        if v and v >= 0 and v <= 100000 then
            cfg.overhang = math.floor(v)
            if cfg.overhang == 0 then
                printf("overhang gate off: alerts fire regardless of competing stock.")
            else
                printf("alerts skip items with more than %d units listed above the deal.", cfg.overhang)
            end
        else printf("usage: /fsn overhang 500  (units, 0 = off)") end

    elseif cmd == "arm" then
        local v = tonumber(rest)
        if v and v >= 1 and v <= 10 then
            cfg.armAfter = math.floor(v)
            printf("market alerts arm after %d scans of history.", cfg.armAfter)
        else printf("usage: /fsn arm 2  (scans, 1-10)") end

    elseif cmd == "min" then
        local v = parseMoney(rest)
        if v then cfg.minUnit = v; printf("deal floor set to %s per unit.", fmtMoney(v))
        else printf("usage: /fsn min 10s  (money, bare numbers are gold)") end

    elseif cmd == "quality" then
        local v = tonumber(rest)
        local names = { [0] = "any quality", [1] = "common (white) or better",
                        [2] = "uncommon (green) or better", [3] = "rare (blue) or better",
                        [4] = "epic (purple) only" }
        if v and v >= 0 and v <= 4 then
            cfg.quality = math.floor(v)
            printf("market alerts require %s.", names[cfg.quality])
        else printf("usage: /fsn quality 2  (0 any, 1 white+, 2 green+, 3 blue+, 4 purple)") end

    elseif cmd == "cut" then
        local v = tonumber(rest)
        if v and v >= 0 and v <= 20 then
            cfg.cut = v / 100
            printf("assuming a %d%% AH cut when estimating profit.", v)
        else printf("usage: /fsn cut 5  (percent, 0-20)") end

    elseif cmd == "why" then
        local g = S.gateLog
        if not g or not g.at or time() - g.at > 300 then
            printf("no recent sweep data - open the AH and wait a few seconds.")
        else
            printf("last sweep %ds ago decided:", time() - g.at)
            for reason, n in pairs(g.counts) do
                printf("  |cffffd100%dx|r %s", n, reason)
            end
            for _, ex in ipairs(g.examples) do
                printf("  e.g. %s", ex)
            end
        end

    elseif cmd == "profit" then
        local v = parseMoney(rest)
        if v then
            cfg.profit = v
            printf("deals must clear %s estimated profit%s.", fmtMoney(v), v == 0 and " (floor off)" or "")
        else printf("usage: /fsn profit 1g  (money; 0 disables the floor)") end

    elseif cmd == "max" then
        local v = parseMoney(rest)
        if v then
            cfg.maxSpend = v
            printf("spend cap per Buy click: %s.", fmtMoney(v))
        else printf("usage: /fsn max 250g  (money; caps one click's total spend)") end

    elseif cmd == "watch" then usageWatch(rest)

    elseif cmd == "unwatch" then
        if strlower(rest) == "all" then
            db.watch = {}
            printf("watchlist cleared.")
        else
            local itemID = tonumber((rest:match("|Hitem:(%d+)")))
            if itemID and db.watch[tostring(itemID)] then
                db.watch[tostring(itemID)] = nil
                printf("no longer watching item %d.", itemID)
            else
                local k = "n:" .. strlower(strtrim(rest))
                if db.watch[k] then db.watch[k] = nil; printf("no longer watching %q.", strtrim(rest))
                else printf("not on the watchlist. /fsn watchlist") end
            end
        end

    elseif cmd == "watchlist" then
        local n = countKeys(db.watch)
        if n == 0 then printf("no watch rules. /fsn watch <link> 50g")
        else
            printf("%d watch rule%s:", n, n == 1 and "" or "s")
            for key, w in pairs(db.watch) do
                local ok, name = pcall(GetItemInfo, tonumber(key) or key)
                printf("  %s - at or under %s", (key:sub(1, 2) == "n:" and key:sub(3)) or name or ("item " .. key), fmtMoney(w.maxPrice))
            end
        end

    elseif cmd == "ignore" or cmd == "unignore" then
        if strlower(rest) == "all" then
            db.blacklist = {}
            printf("blacklist cleared.")
        else
            local itemID = tonumber((rest:match("|Hitem:(%d+)")))
            if not itemID then
                local ok, iid = pcall(GetItemInfoInstant, strtrim(rest))
                if ok then itemID = iid end
            end
            if itemID then
                if cmd == "ignore" then
                    db.blacklist[itemID] = true
                    printf("item %d blacklisted - no more alerts.", itemID)
                else
                    db.blacklist[itemID] = nil
                    printf("item %d un-blacklisted.", itemID)
                end
            else printf("usage: /fsn %s <item link>", cmd) end
        end

    elseif cmd == "scan" then
        if not S.ahOpen then printf("open the auction house window first.")
        else S.scanning = false; requestReplicate(); printf("scan requested.") end

    elseif cmd == "pop" then
        cfg.popup = not cfg.popup
        if popup then if cfg.popup then renderPopup() else popup:Hide() end end
        printf("popup %s.", cfg.popup and "on" or "off")

    elseif cmd == "quiet" then
        cfg.quiet = not cfg.quiet
        printf("scan summaries %s.", cfg.quiet and "hidden" or "shown")

    elseif cmd == "sound" then
        cfg.sound = not cfg.sound
        printf("alert sound %s.", cfg.sound and "on" or "off")

    elseif cmd == "undercut" then
        cfg.undercut = not cfg.undercut
        if cfg.undercut and S.ahOpen then startSweeping() end
        if not cfg.undercut and undercutTicker then undercutTicker:Cancel() undercutTicker = nil end
        printf("undercut guard %s.", cfg.undercut and "on - checks your listings every 30s" or "off")

    elseif cmd == "flash" then
        cfg.flash = not cfg.flash
        printf("screen flash %s.", cfg.flash and "on" or "off")

    elseif cmd == "toast" then
        cfg.toast = not cfg.toast
        printf("toast notifications %s.", cfg.toast and "on" or "off")

    elseif cmd == "feed" then
        buildFeed()
        if feedFrame:IsShown() then
            feedFrame:Hide()
            printf("deal feed hidden.")
        else
            feedFrame:Show()
            refreshFeed()
            printf("deal feed showing - best profit on top. BUY re-checks live prices.")
        end

    elseif cmd == "page" then
        cfg.scanPage = not cfg.scanPage
        if cfg.scanPage then
            buildScanPage()
            scanPage:Show()
            updateScanPage()
            printf("scanner monitor on - it shows with the AH.")
        else
            if scanPage then scanPage:Hide() end
            printf("scanner monitor off.")
        end

    elseif cmd == "options" then
        buildOptions()
        if optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            optionsFrame:Show()
        end

    elseif cmd == "profit" then
        local st = db.stats or {}
        local mins = math.floor((time() - (S.session.started or time())) / 60 + 0.5)
        printf("|cffffd100money printer|r - session: %d buy(s), |cffff4d00%s committed|r in %d min.",
            S.session.buys or 0, fmtMoney(S.session.spent or 0), mins)
        printf("lifetime: %d deal(s) flagged, %d vendor flip(s) worth |cffffd100%s|r, |cff7cff4f%d sold|%r |cff7cff4f%s realized|r.",
            st.deals or 0, st.vendorDeals or 0, fmtMoney(st.vendorProfit or 0),
            st.sales or 0, fmtMoney(st.realized or 0))
        printf("book: %d item(s) learned, %d scan(s) done. spend cap %s per Buy.",
            (st.book or 0), st.scans or 0, fmtMoney(cfg.maxSpend))

    elseif cmd == "alerts" then
        local shown = 0
        for i = #db.alerts, 1, -1 do
            local a = db.alerts[i]
            local suffix = a.market and (" (market " .. fmtMoney(a.market) .. ")") or " (watch)"
            if a.units and a.units > 1 then
                suffix = suffix .. string.format(", %d units for %s", a.units, fmtMoney(a.cost or 0))
            end
            if a.profit and a.profit > 0 then
                suffix = suffix .. string.format(", |cff7cff4f+%s profit|r", fmtMoney(a.profit))
            end
            printf("  [%s] %s - %s%s", date("%m-%d %H:%M", a.t), a.link or ("item " .. tostring(a.id)),
                fmtMoney(a.unit), suffix)
            shown = shown + 1
            if shown >= 8 then break end
        end
        if shown == 0 then printf("no alerts yet.") end

    elseif cmd == "shape" then
        if db.shape then
            printf("first replicate listing returned %d values: %s", #db.shape, table.concat(db.shape, ", "))
        else printf("no scan recorded yet.") end

    elseif cmd == "errors" then
        if #db.errors == 0 then printf("no recorded API failures.") end
        for i = math.max(1, #db.errors - 10), #db.errors do
            local e = db.errors[i]
            printf("  [%s] %s -- %s", date("%m-%d %H:%M", e.t), e.domain, tostring(e.err):sub(1, 180))
        end

    elseif cmd == "wipe" then
        if rest == "book" then
            db.book = {}
            db.stats.book = 0
            printf("price book cleared.")
        elseif rest == "all" then
            -- Rebuild the SavedVariables global from scratch so the logout
            -- write starts clean instead of holding the orphaned old table.
            ForeverSniperDB = {}
            db = ForeverSniperDB
            db.config = {}
            for k, v in pairs(DEFAULTS) do db.config[k] = v end
            cfg = db.config
            db.book, db.watch, db.blacklist, db.errors, db.alerts, db.stats, db.shape = {}, {}, {}, {}, {}, {}, nil
            S.prevList, S.scansDone = nil, 0
            printf("everything cleared. /reload for a clean slate.")
        else printf("usage: /fsn wipe book|all") end

    else
        printf("unknown command %q. /fsn help", cmd)
    end
end


