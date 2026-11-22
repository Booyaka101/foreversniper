-- ForeverSniper.lua - auction deal sniper for the WoW: Forever beta.
--
-- Discovery rotates broad/subcategory pages alongside automatic item checks.
-- Replicate/deep scans also build local history; overlapping snapshots are
-- observations, never additive inventory. Market references use fresh samples.
-- Offers require complete live commodity tiers, affordability and exit gates.
-- A hardware BUY starts one position; an acceptable quote auto-confirms under
-- the current client contract. Only outcome events settle normal purchases.
-- Unknown confirmed outcomes persist and lock further buying. Individual
-- listing purchases remain disabled. Real-client protected execution still
-- requires validation; the local simulator cannot establish it.

local ADDON = ...

-- WoW restores this addon's SavedVariables after executing its Lua files.
-- Build the runtime only once the restored tables are available, so closures,
-- frame handlers and stock/purchase locks all share the same database.
local function initialize()
-- Database --------------------------------------------------------------------

local DEFAULTS = {
    enabled   = true,    -- master switch
    threshold = 0.70,    -- discovery ceiling; live depth and net-profit gates still apply
    every     = 45,      -- seconds between full scans while the AH is open
    sweep     = 2,       -- fallback scheduler tick; ready events also wake paced searches
    batch     = true,    -- owner-approved rollout; failures retain individual fallback
    targeted  = false,   -- opt-in Normal Horde material list; no routine broad discovery
    prebuy    = false,   -- diagnostic two-press new-search comparison, not faster buying
    tsm       = true,    -- verified realm pricing bootstraps discovery; local history caps it
    sales     = true,    -- fresh TSM sales data only tightens market/dump estimates
    saleRate  = 0.05,    -- minimum regional posting success rate when known
    saleShare = 0.10,    -- known exposure limited to this share of regional daily AH volume
    freshMins = 45,      -- market age: older price samples do not arm alerts
    overhang  = 500,     -- max competing units above the deal; more = slow flip (0 = off)
    armAfter  = 2,       -- require two learned observations before market alerts
    minUnit   = 100,     -- ignore deals under 1s per unit (classic economy floor)
    quality   = 1,       -- market alerts need this quality or better (0 = any)
    cut       = 0.05,    -- AH cut assumed when estimating resale profit
    profit    = 1000,    -- deals must clear 10s estimated profit (classic scale)
    maxSpend  = 1000000, -- spend cap per Buy click (100g default)
    keepGold  = 0,       -- explicit reserve, in addition to the existing 5% wallet buffer
    maxStock  = 0,       -- per-item known exposure cap; 0 leaves existing behaviour unchanged
    sound     = true,
    popup     = true,
    flash     = true,    -- tier-colored screen flash on deals
    feedPage  = true,    -- auto-show the deal feed when the auction house opens
    toast     = true,    -- slide-in toast notification on deals
    quiet     = false,   -- suppress per-scan summaries
    scanPage  = true,    -- auto-show the scanner monitor when the AH opens
    avoidBrowse = true, -- auto-switch the AH off the Browse tab so sweeps run
    undercut  = true,    -- guard your listings: alert when the market undercuts you
    tolerance = 5,       -- snipe quote tolerance %: live total vs snapshot, abort past it
    vendorMin = 5000,    -- vendor flips need this much total estimated profit (50s)
}

ForeverSniperDB = ForeverSniperDB or {}

local db = ForeverSniperDB
db.config    = db.config    or {}
db.book      = db.book      or {}   -- itemID -> { lastSeen, s = {t1,min1,t2,min2,...} }
db.watch     = db.watch     or {}   -- ["123"] by id, ["n:name"] by lowercase name
db.blacklist = db.blacklist or {}
db.errors    = db.errors    or {}
db.diagnostics = db.diagnostics or {}
db.alerts    = db.alerts    or {}
db.stats     = db.stats     or {}
db.shape     = db.shape     or nil  -- first replicate return ever seen, as types

for k, v in pairs(DEFAULTS) do
    if db.config[k] == nil then db.config[k] = v end
end
-- one-time retune: installs from the retail-scale era keep their old gates
-- (10s unit floor, 1g profit) which silence a classic economy entirely.
-- Market-tuned for the Forever beta: 1s unit floor, 10s profit floor, 5%
-- snipe tolerance, 50s vendor-flip floor.
if not db.tunedClassic then
    db.tunedClassic = true
    db.config.minUnit = 100      -- 1s: the 12-20s tier markets qualify
    db.config.profit = 1000      -- 10s: real floor, not off - junk stays out
    db.config.threshold = 0.50
    db.config.tolerance = 5
    db.config.vendorMin = 5000
    print("|cffff7d0aForever Sniper|r: retuned for the classic economy - 1s unit floor, 10s profit floor, 5% snipe tolerance. /fsn options to adjust.")
end
local cfg = db.config

-- Retune only the old default once. Subsequent /fsn thresh choices survive reloads.
if not db.selectionRetuned then
    db.selectionRetuned = true
    if cfg.threshold == 0.50 then
        db.previousThreshold = cfg.threshold
        cfg.threshold = 0.70
        print("|cffff7d0aForever Sniper|r: discovery ceiling changed from 50% to 70% of reference; live risk checks unchanged. /fsn thresh 50 restores the old setting.")
    end
end

db.stockLimits = db.stockLimits or {}
db.stockPending = db.stockPending or {}

local CAPS = { errors = 200, alerts = 60, samples = 30, book = 12000 }

-- Small helpers ---------------------------------------------------------------

local function push(list, cap, rec)
    list[#list + 1] = rec
    while #list > cap do table.remove(list, 1) end
end

local function err(domain, e)
    push(db.errors, CAPS.errors, { t = time(), domain = tostring(domain), err = tostring(e) })
end

local function diagnostic(domain, message)
    -- Resolve at event time: don't pin the pre-load SavedVariables table.
    ForeverSniperTrace = ForeverSniperTrace or {seq=0, records={}}
    local trace = ForeverSniperTrace
    trace.seq = trace.seq + 1
    local record = {seq=trace.seq, t=time(), domain=domain, err=message}
    push(trace.records, 250, record)
    push(db.diagnostics, 50, record)
end

local function printf(fmt, ...)
    print("|cffff7d0aForever Sniper|r: " .. string.format(fmt, ...))
end

local function printRecordedLog(informational)
    local records = {}
    for _, record in ipairs(db.errors) do
        if (record.domain == "boot") == informational then records[#records + 1] = record end
    end
    if informational then
        for _, record in ipairs(ForeverSniperTrace and ForeverSniperTrace.records or db.diagnostics) do
            records[#records + 1] = record
        end
    end
    table.sort(records, function(a, b)
        if a.t == b.t then return (a.seq or 0) < (b.seq or 0) end
        return (a.t or 0) < (b.t or 0)
    end)
    if #records == 0 then
        printf(informational and "no recorded diagnostics." or "no recorded failures. Startup traces: /fsn diagnostics.")
    end
    for i = math.max(1, #records - 9), #records do
        local record = records[i]
        local message = tostring(record.err)
        local length = informational and #message or math.min(180, #message)
        for offset = 1, math.max(1, length), 180 do
            printf("  [%s] %s%s -- %s", date("%m-%d %H:%M", record.t), record.domain,
                offset > 1 and " (continued)" or "", message:sub(offset, offset + 179))
        end
    end
end

-- temporary: trace the replicate pipeline in chat
local DEBUG = false
local function dbg(msg) if DEBUG then print("|cff888888[FSN-D]|r " .. msg) end end


-- Numbers that may be secret on this client never enter the book or the math.
local function num(v)
    if type(v) ~= "number" then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    if v ~= v or v == math.huge or v == -math.huge then return nil end
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
    -- positional layout: the last 2 digits are always copper, the next 2
    -- silver, the rest gold - a price reads at a glance and the feed's
    -- columns line up. Zero groups only drop when the whole higher unit is
    -- zero (12g 05s 00c / 3s 40c / 75c).
    if g > 0 then
        return string.format("|cffffd100%dg|r |cffb8b8b8%02ds|r |cff9d6c3c%02dc|r", g, s, cc)
    elseif s > 0 then
        return string.format("|cffb8b8b8%ds|r |cff9d6c3c%02dc|r", s, cc)
    end
    return string.format("|cff9d6c3c%dc|r", cc)
end

local function fmtSignedMoney(c)
    c = math.floor(num(c) or 0)
    return (c < 0 and "-" or c > 0 and "+" or "") .. fmtMoney(math.abs(c))
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

local HISTORY_SPACING = 90 -- 30 observations cover roughly the 45-minute freshness window

local function freshPricePoints(s, now, maxAge)
    local raw, points = {}, {}
    for i = 1, #s - 1, 2 do
        local stamp, price = num(s[i]), num(s[i + 1])
        if stamp and price and price > 0 and stamp <= now and now - stamp <= maxAge then
            raw[#raw + 1] = {t=stamp, price=price}
        end
    end
    table.sort(raw, function(a, b) return a.t < b.t end)
    for _, point in ipairs(raw) do
        local last = points[#points]
        if last and point.t - last.t < HISTORY_SPACING then
            -- Conservative aggregation also de-clusters legacy dense samples.
            last.price = math.min(last.price, point.price)
        else
            points[#points + 1] = point
        end
    end
    return points
end

-- Median over FRESH samples only: a price seen an hour ago is not a market you
-- can list into today. Returns nil when fewer than `need` fresh samples exist.
local function freshMedian(s, now, maxAge, need)
    local vals, n = {}, 0
    for _, point in ipairs(freshPricePoints(s, now, maxAge)) do
        n = n + 1
        vals[n] = point.price
    end
    if n < need then return nil, n end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2], n end
    return (vals[n / 2] + vals[n / 2 + 1]) / 2, n
end

-- Item info cache: ONE GetItemInfo per item for name, icon, quality and
-- vendor price. Toast, feed and alerts all read from here - no per-frame
-- item info probing (the old code could pcall GetItemInfo 30+ times a
-- refresh; now it is once per item per session).
-- the item-info oracle: C_Item.GetItemInfo on this client (the global
-- GetItemInfo / GetItemInfoInstant do not exist here), global fallback for
-- future builds. Returns nothing when neither answers.
local function anyGetItemInfo(x)
    if C_Item and C_Item.GetItemInfo then
        local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11 = pcall(C_Item.GetItemInfo, x)
        if ok and a1 ~= nil then return a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11 end
    end
    local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11 = pcall(GetItemInfo, x)
    if ok then return a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11 end
end
local function anyGetItemInfoInstant(x)
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, a1,a2,a3,a4,a5,a6,a7 = pcall(C_Item.GetItemInfoInstant, x)
        if ok and a1 ~= nil then return a1,a2,a3,a4,a5,a6,a7 end
    end
    local ok, a1,a2,a3,a4,a5,a6,a7 = pcall(GetItemInfoInstant, x)
    if ok then return a1,a2,a3,a4,a5,a6,a7 end
end

-- ===== DE VALUE: the competition's best sniper mode, rebuilt on our book ===
-- A green/blue/purple disenchanted by Classic's odds (by item level band;
-- armour gives mostly dust, weapons mostly essence - the odds below are the
-- Enchantrix-validated Classic table with Forever's material IDs, the same
-- numbers the competition ships). Materials are priced from OUR book; a
-- material nobody has seen yet means NO value - a guess is no basis for
-- spending gold. Rolls: low = worst result (every buy pays off), avg =
-- expected, high = the lucky result.
local DE_DUST = { strange = 10940, soul = 11083, vision = 11137, dream = 11176, illusion = 16204 }
local DE_ESS = { lmagic = 10938, gmagic = 10939, lastral = 10998, gastral = 11082, lmystic = 11134,
    gmystic = 11135, lnether = 11174, gnether = 11175, leternal = 16202, geternal = 16203 }
local DE_SHARD = { sglim = 10978, lglim = 11084, sglow = 11138, lglow = 11139, srad = 11177, lrad = 11178,
    sbril = 14343, lbril = 14344, nexus = 20725 }
-- greens: upper item level; dust, essence, shard as { id, min, max }; then
-- the ARMOUR chances in % (dust, essence, shard) - weapons swap dust/essence
local DE_GREEN = {
    { 15,  { DE_DUST.strange, 1, 2 }, { DE_ESS.lmagic, 1, 2 }, nil, 80, 20, 0 },
    { 20,  { DE_DUST.strange, 2, 3 }, { DE_ESS.gmagic, 1, 2 }, { DE_SHARD.sglim, 1, 1 }, 75, 20, 5 },
    { 25,  { DE_DUST.strange, 4, 6 }, { DE_ESS.lastral, 1, 2 }, { DE_SHARD.sglim, 1, 1 }, 75, 15, 10 },
    { 30,  { DE_DUST.soul, 1, 2 }, { DE_ESS.gastral, 1, 2 }, { DE_SHARD.lglim, 1, 1 }, 75, 20, 5 },
    { 35,  { DE_DUST.soul, 2, 5 }, { DE_ESS.lmystic, 1, 2 }, { DE_SHARD.sglow, 1, 1 }, 75, 20, 5 },
    { 40,  { DE_DUST.vision, 1, 2 }, { DE_ESS.gmystic, 1, 2 }, { DE_SHARD.lglow, 1, 1 }, 75, 20, 5 },
    { 45,  { DE_DUST.vision, 2, 5 }, { DE_ESS.lnether, 1, 2 }, { DE_SHARD.srad, 1, 1 }, 75, 20, 5 },
    { 50,  { DE_DUST.dream, 1, 2 }, { DE_ESS.gnether, 1, 2 }, { DE_SHARD.lrad, 1, 1 }, 75, 20, 5 },
    { 55,  { DE_DUST.dream, 2, 5 }, { DE_ESS.leternal, 1, 2 }, { DE_SHARD.sbril, 1, 1 }, 75, 20, 5 },
    { 60,  { DE_DUST.illusion, 1, 2 }, { DE_ESS.geternal, 1, 2 }, { DE_SHARD.lbril, 1, 1 }, 75, 20, 5 },
    { 999, { DE_DUST.illusion, 2, 5 }, { DE_ESS.geternal, 2, 3 }, { DE_SHARD.lbril, 1, 1 }, 75, 20, 5 },
}
local DE_BLUE = { { 25, DE_SHARD.sglim }, { 30, DE_SHARD.lglim }, { 35, DE_SHARD.sglow }, { 40, DE_SHARD.lglow },
    { 45, DE_SHARD.srad }, { 50, DE_SHARD.lrad }, { 55, DE_SHARD.sbril }, { 999, DE_SHARD.lbril } }
local DE_PURPLE = { { 45, { DE_SHARD.srad, 2, 4 } }, { 50, { DE_SHARD.lrad, 2, 4 } },
    { 55, { DE_SHARD.sbril, 2, 4 } }, { 60, { DE_SHARD.nexus, 1, 1 } }, { 999, { DE_SHARD.nexus, 1, 2 } } }
-- lesser and greater essences convert both ways: neither sells above the
-- other form allows (a lesser is worth at most a third of a greater)
local DE_PAIR = {}
for _, p in ipairs({ { DE_ESS.lmagic, DE_ESS.gmagic }, { DE_ESS.lastral, DE_ESS.gastral },
    { DE_ESS.lmystic, DE_ESS.gmystic }, { DE_ESS.lnether, DE_ESS.gnether },
    { DE_ESS.leternal, DE_ESS.geternal } }) do
    DE_PAIR[p[1]] = { p[2], 1 / 3 }
    DE_PAIR[p[2]] = { p[1], 3 }
end

-- cheapest known price of a DE material (book samples any freshness, else a
-- learned vendor price); essence pairs cap each other
local function deMatPrice(matID)
    local b = db.book[matID]
    local low = nil
    if b and b.s and #b.s >= 2 then
        local lowest = math.huge
        for i = 2, #b.s, 2 do
            if b.s[i] > 0 and b.s[i] < lowest then lowest = b.s[i] end
        end
        if lowest < math.huge then low = math.floor(lowest) end
    end
    local pair = DE_PAIR[matID]
    if pair then
        local o = db.book[pair[1]]
        if o and o.s and #o.s >= 2 then
            local olow = math.huge
            for i = 2, #o.s, 2 do
                if o.s[i] > 0 and o.s[i] < olow then olow = o.s[i] end
            end
            local via = (olow < math.huge) and math.ceil(olow * pair[2]) or nil
            if via and (not low or via < low) then low = via end
        end
    end
    if low then return low end
    local v = db.vendorVerified and db.vendorVerified[tostring(matID)]
    if v and v > 0 then return math.floor(v) end
    return nil
end

--- what one of `itemID` disenchants into at `roll` ("low"/"avg"/"high"),
--- priced from our book; nil when it cannot be disenchanted or a material
--- price is unknown
local function deValueFor(itemID, roll)
    local _, _, quality, ilvl = anyGetItemInfo(itemID)
    local _, _, _, equipLoc, _, classID = anyGetItemInfoInstant(itemID)
    if (classID ~= 2 and classID ~= 4) or not equipLoc or equipLoc == "" then return nil end
    if not quality or not ilvl then return nil end
    local tbl = (quality == 2 and DE_GREEN) or (quality == 3 and DE_BLUE) or (quality == 4 and DE_PURPLE)
    if not tbl then return nil end
    local band
    for _, b in ipairs(tbl) do
        if ilvl <= b[1] then band = b break end
    end
    if not band then return nil end
    if quality >= 3 then
        -- blues and purples: shards only
        local sh = band[2]
        local ids = (type(sh) == "table") and sh[1] or sh
        local lo = (type(sh) == "table") and sh[2] or 1
        local hi = (type(sh) == "table") and sh[3] or 1
        local p = deMatPrice(ids)
        if not p then return nil end
        if roll == "low" then return math.floor(p * lo) end
        if roll == "high" then return math.floor(p * hi) end
        return math.floor(p * (lo + hi) / 2)
    end
    -- Class IDs do not depend on the client's localized item-type text.
    local isWeapon = classID == 2
    local chances = { band[5] / 100, band[6] / 100, band[7] / 100 }
    if isWeapon then chances[1], chances[2] = chances[2], chances[1] end
    local total, lowest, highest = 0, math.huge, 0
    for i = 2, 4 do
        local slot = band[i]
        if slot then
            local p = deMatPrice(slot[1])
            if not p then return nil end
            local ch = chances[i - 1] or 0
            local mid = (slot[2] + slot[3]) / 2
            local q = (roll == "low" and slot[2]) or (roll == "high" and slot[3]) or mid
            total = total + ch * q * p
            if ch > 0 then
                lowest = math.min(lowest, slot[2] * p)
                highest = math.max(highest, slot[3] * p)
            end
        end
    end
    if roll == "low" then return lowest < math.huge and math.floor(lowest) or nil end
    if roll == "high" then return highest > 0 and math.floor(highest) or nil end
    return total > 0 and math.floor(total) or nil
end

--- the most a watch target pays for one of this item: a fixed price, or for
--- value targets a copper under what it vendors for / disenchants into.
--- nil: nothing to gain, or the value is not known yet (never a guess)
local function watchMaxFor(itemID, w)
    if not w then return nil end
    if w.deRoll then
        local v = deValueFor(itemID, w.deRoll)
        return (v and v > 1) and (v - 1) or nil
    end
    if w.vendorMode then
        local v = db.vendorVerified and db.vendorVerified[tostring(itemID)]
        return (v and v > 1) and (v - 1) or nil
    end
    return w.maxPrice
end

local itemInfoCache = {}
local commodityFor
do
    local function keyInfo(ah, itemID)
        return ah.GetItemKeyInfo(ah.MakeItemKey(itemID))
    end
    commodityFor = function(itemID)
        local ah = C_AuctionHouse
        if not ah then return nil end
        -- Item keys work for auctions we do not own. The standard status API
        -- expects an ItemLocation. Retain the item-ID fallback for custom clients.
        if ah.MakeItemKey and ah.GetItemKeyInfo then
            local ok, info = pcall(keyInfo, ah, itemID)
            if ok and type(info) == "table" and type(info.isCommodity) == "boolean" then
                return info.isCommodity
            end
        end
        if ah.GetItemCommodityStatus then
            local ok, status = pcall(ah.GetItemCommodityStatus, itemID)
            if ok then
                if type(status) == "boolean" then return status end
                local values = Enum and Enum.ItemCommodityStatus
                if status == (values and values.Commodity or 2) then return true end
                if status == (values and values.Item or 1) then return false end
            end
        end
        return nil
    end
end

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
    -- C_Item.GetItemInfo gives name/link/quality/icon on this client, but
    -- its sell slot is GARBAGE (it claimed a 517g vendor price on a 4c item
    -- and flooded the feed with fake flips - proven live 2026-10-12). The
    -- global GetItemInfo does not exist here either. Vendor prices are
    -- LEARNED instead (merchant windows / tooltips - see vendorOf).
    local dLink
    if C_Item and C_Item.GetItemInfo then
        local okI, n, l, q2, _, _, _, _, gStack, ic = pcall(C_Item.GetItemInfo, itemID)
        if okI and type(n) == "string" then
            dName = dName or n
            dLink = (type(l) == "string") and l or nil
            dQuality = dQuality or (type(q2) == "number" and q2 or nil)
            dMaxStack = dMaxStack or (type(gStack) == "number" and gStack or nil)
            dIcon = dIcon or (type(ic) == "string" and ic or nil)
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
        link = dLink,
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
    -- A name may load before quality/stack metadata. Cache only a complete
    -- eligibility answer so partial responses cannot strand an item forever.
    if c.quality ~= -1 and c.stackable ~= nil then itemInfoCache[itemID] = c end
    return c
end
-- Listability: an item we cannot verify as sellable (quality unknown or below
-- the bar) never alerts; quality and vendor price come from the shared cache.
local function qualityOf(itemID)
    return infoOf(itemID).quality
end

-- Vendor sell price. A listing priced under this is FREE MONEY: buy it,
-- vendor it, instant guaranteed profit, no market risk, no relist wait.
-- THE CATCH: this client has no vendor-price API (C_Item.GetItemInfo's sell
-- slot lies), so prices are LEARNED - from merchant windows (what a vendor
-- really pays for items you sell it lands in the buyback list) and from
-- native "Sell Price" tooltips as you browse. Unlearned items read 0: no
-- flips, no floods.
local function vendorOf(itemID)
    local v = db.vendorVerified and db.vendorVerified[tostring(itemID)]
    if v and v > 0 then return v end
    return 0
end

-- DEPOSIT PER UNIT for relisting. A flip only profits if the wallet can pay
-- the buy AND the deposit, so every budget and every profit estimate needs
-- this number. Prefer the client's own calculators; fall back to the classic
-- rule of thumb (deposit scales with vendor value, ~15% per 12h); last
-- resort, 5% of value. Always an estimate until Blizzard's own call answers.
local function depositPerUnit(itemID, isComm)
    local units = 1
    -- Deposit calculators require an ItemLocation, not an itemID. Until
    -- the item is in our bags use the verified vendor-based estimate;
    -- guessing signatures previously produced wildly inflated reserves.
    local vs = vendorOf(itemID)
    if vs and vs > 0 then return math.floor(vs * 0.30) end -- ~24h of classic deposit
    return nil -- unknown: caller decides (assumed 5% of price as a floor)
end


-- ABSORPTION VELOCITY (secret sauce #1): track when each item first goes
-- below its deal line, and when the cheap stock is gone. The gap is how fast
-- this realm's buyers absorb deals - a per-item liquidity signal measured
-- live, not imported from region data nobody here has.
local absorbMarks = {}
-- Stock depletion includes cancellations and expirations. Repeated recent
-- observations guide search priority, never sales accounting or buy approval.
local soldPace = {} -- itemID -> { qty = lastQty, t = lastT, perDay = est }

local function trackSold(itemID, currentQty, now)
    local sp = soldPace[itemID]
    if not sp or now - sp.t > 1800 or now < sp.t then
        soldPace[itemID] = { qty = currentQty, t = now, drops = 0 }
        return nil
    end
    local dt = now - sp.t
    if dt < 30 then return sp.perDay end -- too soon since last check
    local dropped = sp.qty - currentQty
    local positive = math.max(0, dropped)
    local perDay = positive * 86400 / dt
    local turnover = math.min(24, positive / math.max(1, sp.qty) * 86400 / dt)
    sp.perDay = math.floor((sp.perDay or 0) * 0.5 + perDay * 0.5 + 0.5)
    sp.turnover = (sp.turnover or 0) * 0.5 + turnover * 0.5
    sp.drops = positive > 0 and math.min(3, (sp.drops or 0) + 1) or math.max(0, (sp.drops or 0) - 1)
    sp.qty = currentQty
    sp.t = now
    return sp.perDay
end

local function soldPaceOf(itemID)
    local sp = soldPace[itemID]
    return sp and time() >= sp.t and time() - sp.t <= 600 and sp.perDay or nil
end

local function movementScore(itemID, now)
    local sp = soldPace[itemID]
    if not sp or now < sp.t or now - sp.t > 600 or (sp.drops or 0) < 2 then return 0 end
    return math.min(4, math.log(1 + (sp.turnover or 0))) * sp.drops / 3
end

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
            b.velocityAt = now
            while #v > 4 do table.remove(v, 1) end
        end
            absorbMarks[itemID] = nil
        end
    end

local function freshBookPrices(itemID)
    local b = db.book[itemID]
    local now, maxAge = time(), (cfg.freshMins or 45) * 60
    local prices = {}
    for _, point in ipairs(freshPricePoints(b and b.s or {}, now, maxAge)) do
        prices[#prices + 1] = point.price
    end
    return prices
end

-- Price movement describes observed listings, not completed sales or profit.
local function bookTrend(itemID)
    local prices = freshBookPrices(itemID)
    local n = #prices
    if n < 4 then return 0 end
    local recent, prior = {}, {}
    for i = 1, n do
        local p = prices[i]
        if i > n - 3 then recent[#recent + 1] = p else prior[#prior + 1] = p end
    end
    local function avg(tbl) local s2 = 0 for _, v in ipairs(tbl) do s2 = s2 + v / #tbl end return s2 end
    local a, c = avg(recent), avg(prior)
    if c <= 0 then return 0 end
    return (a - c) / c
end

local function bookVolatility(itemID)
    local vals = freshBookPrices(itemID)
    local n = #vals
    if n < 4 then return nil end
    local mean = 0
    for _, v in ipairs(vals) do mean = mean + v / n end
    local var = 0
    for _, v in ipairs(vals) do var = var + (v / mean - 1) ^ 2 end
    if mean <= 0 then return nil end
    return math.sqrt(var / n)
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

local lastMinOf
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

-- TSM-STYLE TIERED THRESHOLD, now wired to /fsn thresh. TSM's defaults assume
-- a mature economy where sub-1g items are vendor trash; on a fresh classic
-- realm the WHOLE market is sub-1g, so a flat "95% off for cheap items" rule
-- meant the sniper could mathematically never fire - every sweep came back
-- "not cheap enough". The philosophy stands (expensive items need less
-- discount), but the tiers are FLOORS on top of cfg.threshold, so /fsn
-- thresh finally tunes the sweep (it silently did nothing before):
--   /fsn thresh 50 -> cheap items fire at 50% of market, >100g items at 20%
--   /fsn thresh 70 -> cheap items fire at 70% - easy mode, a lot more hits
-- The deal line still never falls below the vendor sell price.
local function dealLine(med, itemID)
    local base = num(cfg.threshold) or 0.7
    base = math.min(0.99, math.max(0.01, base))
    local mult
    if med > 10000000 then mult = math.max(base, 0.8)      -- >1000g: at least 20% off
    elseif med > 1000000 then mult = math.max(base, 0.75)  -- >100g: at least 25% off
    elseif med > 100000 then mult = math.max(base, 0.65)   -- >10g: at least 35% off
    else mult = base end                                   -- cheap: exactly /fsn thresh
    local line = mult * med
    local vs = vendorOf(itemID)
    if vs > line then line = vs end
    return line, mult
end

-- TOOLTIP INTELLIGENCE: hover any item anywhere and the book talks - market
-- price now, vendor floor, what you paid, and whether relisting it now nets
-- profit after the cut (ForeverForge's flagship, rebuilt on our book).
-- HOOK NOTE: this client has no OnTooltipSetItem script and no
-- TooltipDataProcessor - OnShow + GetItem is the portable hook, and the
-- whole thing is pcall'd so a refusal costs the feature, never the tooltip.
if GameTooltip and GameTooltip.HookScript then
    local function enrich(tt)
        if not tt.GetItem then return end
        local okG, _, link = pcall(tt.GetItem, tt)
        if not okG or not link then return end
        local itemID = tonumber(tostring(link):match("item:(%d+)"))
        if not itemID then return end
        -- VENDOR PRICE LEARNER: the native tooltip carries the TRUE sell
        -- price (C_Item.GetItemInfo's sell slot is garbage here). The amount
        -- sits in the tooltip's money frame; read it guarded - if the
        -- structure ever changes, learning goes quiet instead of lying.
        -- Learns BEFORE the display early-return: every hover teaches.
        db.vendor = db.vendor or {}
        if tt.NumLines and tt:NumLines() > 0 then
            for li = 1, tt:NumLines() do
                local lf = _G["GameTooltipTextLeft" .. li]
                local txt = lf and lf:GetText()
                if txt and txt:find("Sell Price") then
                    local mf = _G.GameTooltipMoneyFrame1
                    local amount = mf and (tonumber(mf.staticMoney) or (mf.info and tonumber(mf.info.amount)))
                    if type(amount) == "number" and amount > 0 then
                        db.vendor[tostring(itemID)] = amount
                    end
                    break
                end
            end
        end
        local b = db.book[itemID]
        local med = b and freshMedian(b.s, time(), (cfg.freshMins or 45) * 60, 1) or nil
        local paid = db.boughtAt and (db.boughtAt[tostring(itemID)] or db.boughtAt[itemID])
        local vend = vendorOf(itemID)
        if not med and not paid and not (vend and vend > 0) then return end
        tt:AddLine(" ")
        tt:AddLine("|cffff7d0aForever Sniper|r", 1, 0.5, 0.05)
        if med then
            tt:AddLine("recent price median: " .. fmtMoney(math.floor(med)), 1, 1, 1)
        end
        if vend and vend > 0 then
            tt:AddLine("vendor: " .. fmtMoney(vend), 0.8, 0.8, 0.85)
        end
        if paid then
            local ageM = math.floor((time() - (paid.t or time())) / 60 + 0.5)
            tt:AddLine(string.format("last paid reference: %s (%dm ago)", fmtMoney(paid.price or 0), ageM), 1, 1, 1)
            if med and (paid.price or 0) > 0 then
                local net = math.floor(med * (1 - (cfg.cut or 0.05)) - paid.price)
                tt:AddLine(string.format("estimated after-cut difference: %s (before deposits)", fmtSignedMoney(net)),
                    net > 0 and 0.3 or 1, net > 0 and 1 or 0.3, 0.45)
            end
        end
        tt:Show()
    end
    -- HOOK NOTE: on this client GameTooltip is a Tooltip-type object with no
    -- widget scripts (OnTooltipSetItem AND OnShow are both refused), and
    -- there is no TooltipDataProcessor. The portable hook is the template's
    -- own show function - GameTooltip_OnShow runs for every item tooltip.
    if hooksecurefunc and GameTooltip_OnShow then
        hooksecurefunc("GameTooltip_OnShow", function(tt)
            if tt and tt.GetItem then
                local ok, hookErr = pcall(enrich, tt)
                if not ok and hookErr then err("tooltip", hookErr) end
            end
        end)
    end
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
        local latest = eb and num(eb.lastSeen or (eb.s and eb.s[#eb.s - 1]))
        if not num(t) or t > time() or not num(unit) or unit <= 0 or (latest and t <= latest)
            or (eb and eb.ownUntil and t < eb.ownUntil) then
            -- Same-second replies are one observation, not extra evidence.
            -- Reject stale/out-of-order data and our recent relist as well.
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
        local stamp = num(s[#s - 1])
        if stamp and t - stamp < HISTORY_SPACING then
            s[#s] = math.min(s[#s], unit)
        else
            s[#s + 1] = t
            s[#s + 1] = unit
        end
        while math.floor(#s / 2) > CAPS.samples do
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
    -- every writer refreshes the gauge: the sweep path never updated this, so
    -- /fsn status showed "book 0 items" while the real book was full
    db.stats.book = math.min(bookN, CAPS.book)
    -- persisted merge counter: proves (or disproves) the sweep ever writes
    db.stats.merges = (db.stats.merges or 0) + 1
end

-- FORWARD DECLARATIONS: these functions are defined further down but called
-- from code that appears earlier (the popup panel, the feed, etc.). Declaring
-- them here means every closure captures the same local variable -- no nil
-- calls, no "attempt to call a nil value".
local quickBuy      -- the one-press purchase engine
local markDealGone  -- the sweep's reaper (marks dead deals)
local requestItemLoad

-- Scan state --------------------------------------------------------------------

local S = {
    -- session stats: referenced from the buy paths, the feed footer and the
    -- summaries. The initializer was lost in a merge - every S.session access
    -- was a crash waiting for the first Purchase click (seen live: the nil
    -- value error at the S.session.spent line right after a purchase).
    session    = { started = time(), buys = 0, spent = 0, listed = 0, realized = 0, best = nil },
    ahOpen     = false,
    scanning   = false,
    prevList   = nil,   -- multiset: "id/count/buyout" -> occurrences
    scansDone  = 0,
    lastAlert  = db.lastAlert or {}, -- itemID -> { t, price } (persistent)
    pending    = nil,   -- { itemID, link, t } awaiting search results to print
    buying     = nil,   -- { itemID, link, line, market, commodity, t } active Buy click
    quote      = nil,   -- { itemID, units, total } live commodity quote
    boughtAt   = db.boughtAt or {}, -- itemID -> { t, price } purchase cooldown (persistent)
}
db.lastAlert = S.lastAlert

function S.marketReference(itemID, now)
    now = now or time()
    local b = db.book[itemID]
    local median = b and freshMedian(b.s or {}, now, (cfg.freshMins or 45) * 60, cfg.armAfter)
    local price, source
    if cfg.tsm ~= false and ForeverSniperTSM then price, source = ForeverSniperTSM.reference(itemID, now) end
    if median and (not price or median < price) then
        source = price and "local history (caps TSM)" or "local history"
        price = median
    end
    local sales = S.salesPolicy(itemID, now)
    if price and sales and sales.average and sales.average < price then price, source = sales.average, "TSM regional sale average (caps reference)" end
    return price, source
end

local COMMODITY_SNAPSHOT_AGE = 20
S.commoditySnapshots = {}

local readCommodityTiers
do
    -- Protect the complete read once, not every row. Any getter failure still
    -- discards the whole wall; this helper is allocated only at addon load.
    local function readCompletedTiers(ah, itemID)
        local count = num(ah.GetNumCommoditySearchResults(itemID))
        if not count or count < 0 or count % 1 ~= 0 then return nil, "unreadable" end
        if count == 0 then return nil, "empty" end
        local tiers, evidence = {}, {}
        for i = 1, count do
            local row = ah.GetCommoditySearchResultInfo(itemID, i)
            if type(row) ~= "table" then return nil, "unreadable" end
            -- Forever returns an item ID on every tier. Never attribute a
            -- shared/stale API result to the item requested by this search.
            local returnedID = num(row.itemID)
            local forever = WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT
            if (forever or row.itemID ~= nil) and returnedID ~= itemID then
                return nil, "unreadable", string.format("requested item %d; tier %d returned item %s",
                    itemID, i, tostring(returnedID))
            end
            local price, quantity = num(row.unitPrice), num(row.quantity)
            local owned = row.numOwnerItems == nil and 0 or num(row.numOwnerItems)
            if not price or price <= 0 or price % 1 ~= 0 or not quantity or quantity < 0 or quantity % 1 ~= 0
                or not owned or owned < 0 or owned % 1 ~= 0 or owned > quantity then
                return nil, "unreadable"
            end
            tiers[#tiers + 1] = { price = price, quantity = math.max(0, quantity - owned) }
            if i <= 3 then
                evidence[#evidence + 1] = string.format("%s:%d:%d:%d:%s", tostring(returnedID),
                    price, quantity, owned, tostring(num(row.auctionID) or "unknown"))
            end
        end
        return { tiers = tiers, t = GetTime(), readAt = GetTime(), evidence = table.concat(evidence, ",") }
    end

    readCommodityTiers = function(itemID)
        local ah = C_AuctionHouse
        if not (ah and ah.HasFullCommoditySearchResults and ah.GetNumCommoditySearchResults) then return nil, "loading" end
        local okFull, full = pcall(ah.HasFullCommoditySearchResults, itemID)
        if not okFull or full ~= true then return nil, "loading" end
        local ok, snapshot, reason, identity = pcall(readCompletedTiers, ah, itemID)
        if not ok then return nil, "unreadable" end
        return snapshot, reason, identity
    end
end

local function commodityTiersForBuy(itemID)
    local saved = S.commoditySnapshots[itemID]
    if not saved or GetTime() < saved.t or GetTime() - saved.t > COMMODITY_SNAPSHOT_AGE then return nil, "loading" end
    local snapshot, reason = readCommodityTiers(itemID)
    if snapshot then
        snapshot.t, snapshot.timing, snapshot.remainder = saved.t, saved.timing, saved.remainder
        return snapshot, nil, "live API"
    end
    -- A refresh may clear the API's result table. Keep the completed search
    -- that produced the offer, not a partial refresh or persisted deal row.
    if reason == "loading" or reason == "empty" then return saved, nil, "completed fallback: " .. reason end
    return nil, reason
end

local function commodityLot(snapshot, line)
    local units, cost, first, competing, competingUnits = 0, 0, nil, nil, 0
    for _, tier in ipairs(snapshot.tiers) do
        if tier.quantity > 0 then
            if tier.price <= line then
                units, cost = units + tier.quantity, cost + tier.price * tier.quantity
                first = math.min(first or tier.price, tier.price)
            else
                competing = math.min(competing or tier.price, tier.price)
                competingUnits = competingUnits + tier.quantity
            end
        end
    end
    return units, cost, first, competing, competingUnits
end

do
    -- Session-only monotonic timestamps. Missing stages stay unknown, never 0s.
    function S.purchaseTiming(snapshot, source)
        local timing = snapshot and snapshot.timing or {}
        return {detectedAt=timing.detectedAt, searchAt=timing.searchAt,
            completedAt=snapshot and snapshot.t, validatedAt=timing.validatedAt,
            feedRenderedAt=timing.feedRenderedAt,
            method=timing.method, source=source, clickAt=GetTime(), prebuy=cfg.prebuy == true}
    end

    function S.purchaseResult(p, outcome)
        if not p then return end
        local text = string.format("attempt %s; item %s x%s; expected %sc; %s",
            tostring(p.attempt or "?"), tostring(p.deal and p.deal.id or "?"), tostring(p.units or "?"),
            tostring(p.expected or "?"), outcome)
        diagnostic("purchase result", text)
        if S.captureFailure and (outcome:find("failed",1,true) or outcome:find("rejected",1,true)
            or outcome:find("refused",1,true) or outcome:find("timed out",1,true)
            or outcome:find("unavailable",1,true) or outcome:find("error",1,true)) then
            S.captureFailure = nil
            C_Timer.After(0, function()
                local panel = CreateFrame("Frame", nil, UIParent)
                panel:SetFrameStrata("TOOLTIP")
                panel:SetSize(600, 186)
                panel:SetPoint("CENTER")
                local bg = panel:CreateTexture(nil,"BACKGROUND")
                bg:SetAllPoints(); bg:SetColorTexture(0,0,0,0.95)
                local label = panel:CreateFontString(nil,"OVERLAY","GameFontNormal")
                label:SetPoint("TOPLEFT",12,-12); label:SetWidth(576); label:SetJustifyH("LEFT")
                local lines = {"Forever Sniper failure capture", text}
                for i=#db.diagnostics,1,-1 do
                    local r = db.diagnostics[i]
                    if r.domain == "purchase request" then break end
                    if r.domain == "purchase quote" or r.domain == "purchase timing" then
                        lines[#lines+1] = r.err
                    end
                end
                label:SetText(table.concat(lines,"\n"))
                C_Timer.After(0.3, Screenshot)
                C_Timer.After(2,function() panel:Hide() end)
            end)
        end
    end

    function S.logPurchaseTiming(p, outcome)
        if not p.timing then return end
        local timing = p.timing
        local function elapsed(start, finish)
            if not start or not finish or finish < start then return "unknown" end
            return string.format("%.2fs", finish - start)
        end
        diagnostic("purchase timing", string.format("attempt %d; item %d; %s; mode %s; query %s; detect-to-search %s; search-to-complete %s; validate-to-click %s; validate-to-feed %s; feed-to-click %s; click-to-quote %s; detect-to-quote %s; completed-age-at-click %s; %s (not server snapshot age)",
            p.attempt, p.deal.id, outcome, timing.prebuy and "new-search test" or "normal",
            timing.method or "unknown", elapsed(timing.detectedAt, timing.searchAt),
            elapsed(timing.searchAt, timing.completedAt), elapsed(timing.validatedAt, timing.clickAt),
            elapsed(timing.validatedAt, timing.feedRenderedAt), elapsed(timing.feedRenderedAt, timing.clickAt),
            elapsed(timing.clickAt, GetTime()), elapsed(timing.detectedAt, GetTime()),
            elapsed(timing.completedAt, timing.clickAt), timing.source or "unknown"))
    end

    function S.queueRemainderRetry(p)
        local previous = p.remainder
        if p.units <= 1 or (previous and (previous ~= S.remainderRetry or GetTime() >= previous.expires)) then
            S.remainderRetry = nil
            return
        end
        local retry = {id=p.deal.id, link=p.deal.link, line=p.maxUnit, market=p.market, kind=p.kind,
            failedUnits=p.units, cost=p.expected or p.tolTotal,
            expires=previous and previous.expires or GetTime() + 10}
        S.remainderRetry = retry
        S.liveCandidates = S.liveCandidates or {}
        S.liveCandidates[retry.id] = {id=retry.id, link=retry.link, line=retry.line,
            market=retry.market, kind=retry.kind, t=GetTime(), detectedAt=GetTime(),
            refresh=true, forceSearch=true, remainder=retry}
        diagnostic("remainder retry", string.format("item %d; rejected x%d; fresh search at ceiling %.0f copper; smaller quote requires another BUY press",
            retry.id, retry.failedUnits, retry.line))
    end

    function S.prebuyReady(itemID, line)
        local check = S.prebuyCheck
        return check and check.id == itemID and check.line == line and check.completedAt
            and GetTime() >= check.completedAt and GetTime() - check.completedAt <= 2
            and S.commoditySnapshots[itemID] == check.snapshot
    end

    function S.prebuyGate(r, line, snapshot, source)
        if not cfg.prebuy then return true end
        if source == "live API" and S.prebuyReady(r.itemID, line) then return true end
        local check = S.prebuyCheck
        if check and check.id == r.itemID and not check.finished and GetTime() - check.t < 15 then
            printf("new-search check is queued or loading; wait for completion, then press BUY again.")
            return false
        end
        for _, field in ipairs({"liveCandidate", "autoSearch", "watchSearch"}) do
            if S[field] and S[field].id == r.itemID then
                printf("this item's search is still in progress; press BUY after it finishes.")
                return false
            end
        end
        local units, cost = commodityLot(snapshot, line)
        check = {id=r.itemID, line=line, t=GetTime(), units=units, cost=cost,
            before=snapshot.evidence or "unavailable"}
        S.prebuyCheck = check
        S.liveCandidates = S.liveCandidates or {}
        S.liveCandidates[r.itemID] = {id=r.itemID, line=line, link=r.link,
            market=r.market2, kind=r.kind, refresh=true, prebuy=check,
            t=GetTime(), detectedAt=snapshot.timing and snapshot.timing.detectedAt}
        diagnostic("prebuy search", string.format("item %d; before x%d/%d copper; requesting SendSearchQuery, not RefreshCommoditySearchResults; no purchase until another hardware press", r.itemID, units, cost))
        printf("new item search queued; nothing purchased. Press BUY again within 2s of its completion if the offer remains eligible.")
        S.wakeSweep()
        return false
    end

    function S.completePrebuy(owner, snapshot, reason)
        local check = owner and owner.prebuy
        if not check or check ~= S.prebuyCheck or check.finished then return end
        check.finished = true
        if snapshot then
            check.completedAt, check.snapshot = GetTime(), snapshot
            local units, cost = commodityLot(snapshot, check.line)
            diagnostic("prebuy result", string.format("item %d; before x%d/%d, after x%d/%d copper; first 3 rows before=%s; after=%s; queued %.2fs; search %.2fs (no server timestamp)",
                check.id, check.units, check.cost, units, cost, check.before, snapshot.evidence or "unavailable",
                owner.searchStartedAt - check.t, GetTime() - owner.searchStartedAt))
            printf("new search completed for item %d: x%d under the ceiling. Nothing purchased; press BUY again if still eligible.", check.id, units)
        else
            diagnostic("prebuy result", string.format("item %d; new search %s; no purchase", check.id, reason or "unreadable"))
        end
    end
end

local function prepareCommodityDeal(itemID, link, line, market, kind)
    if not S.ahOpen or not cfg.enabled or not line or commodityFor(itemID) == false then return end
    if S.liveCandidate and S.liveCandidate.id == itemID then return end
    S.liveCandidates = S.liveCandidates or {}
    if not S.liveCandidates[itemID] then
        local inferred = kind or (market and "market" or "watch")
        for _, deal in ipairs(S.deals or {}) do
            if not kind and deal.id == itemID and deal.line == line and not deal.bought then
                inferred = deal.kind or (deal.tier == "VENDOR" and "vendor") or inferred
                break
            end
        end
        S.liveCandidates[itemID] = {kind=inferred, id=itemID, link=link, line=line, market=market,
            t=GetTime(), detectedAt=GetTime(), refresh=true}
    end
end

local function offerKind(itemID, line, kind)
    if kind then return kind end
    for _, deal in ipairs(S.deals) do
        if deal.id == itemID and deal.line == line and not deal.bought then
            return deal.kind or (deal.tier == "VENDOR" and "vendor")
        end
    end
end

function S.purchaseBudget()
    local wallet, reserve, cap = num(GetMoney()), num(cfg.keepGold), num(cfg.maxSpend)
    if not wallet or not reserve or reserve < 0 or not cap or cap < 0 then return 0 end
    return math.max(0, math.min(math.floor(wallet * 0.95), wallet - reserve, cap))
end

function S.salesPolicy(itemID, now)
    if cfg.tsm == false then return nil, nil, "salesvolume", "TSM disabled" end
    if not ForeverSniperTSM or not ForeverSniperTSM.sales then return nil, nil, "salesvolume", "TSM sales unavailable" end
    local data, unknown = ForeverSniperTSM.sales(itemID, now or time())
    if not data or not num(data.daily) or data.daily <= 0 then
        return data, nil, "salesvolume", unknown or "no positive regional daily sales"
    end
    if cfg.sales == false then return data end
    local limit = data.daily and math.floor(data.daily * (cfg.saleShare or 0.10))
    if data.rate and data.rate < (cfg.saleRate or 0.05) then return data, limit, "liquidity" end
    if limit and limit < 1 then return data, limit, "liquidity" end
    return data, limit
end

function S.salesSummary(itemID)
    local data, limit, rejected, unknown = S.salesPolicy(itemID)
    if not data then return "deals blocked; regional sales unknown: " .. (unknown or "no verified data") end
    return string.format("regional sales %s (%.1fh old): avg %s; rate %s; daily/AH %s; exposure cap %s%s (not a sale guarantee)",
        data.region, (time() - data.stamp) / 3600,
        data.average and fmtMoney(data.average) or "unknown",
        data.rate and string.format("%.1f%%", data.rate * 100) or "unknown",
        data.daily and string.format("%.3f", data.daily) or "unknown",
        limit and tostring(limit) or "none", rejected and ("; blocked: " .. (unknown or "low liquidity")) or "")
end

-- For an NPC exit the counterparty is the merchant, not an AH buyer.
-- Never accept a saved offer's market estimate as proof of a vendor payout.
function S.exitPolicy(id, kind, units, cost, reference)
    if kind ~= "vendor" then return S.salesPolicy(id) end
    local payout = num(vendorOf(id))
    if not payout or not num(reference) or not num(units) or not num(cost)
        or units < 1 or cost < 1 then return nil, nil, "vendorprofit" end
    payout = math.min(payout, reference)
    if payout * units - cost < math.max(1, cfg.vendorMin or 5000) then return nil, nil, "vendorprofit" end
    return nil, nil, nil, payout
end

function S.stockAllowance(itemID, salesLimit)
    local cap = db.stockLimits[tostring(itemID)]
    if cap == nil then cap = cfg.maxStock end
    cap = num(cap)
    if not cap or cap < 0 or cap % 1 ~= 0 then return nil, "stockinfo" end
    if salesLimit then cap = math.min(cap == 0 and math.huge or cap, salesLimit) end
    if cap == 0 and not salesLimit then return math.huge end
    local getter = C_Item and C_Item.GetItemCount or GetItemCount
    if not getter then return nil, "stockinfo" end
    local ok, held = pcall(getter, itemID, true)
    held = ok and num(held)
    if not held or held < 0 or held % 1 ~= 0 then return nil, "stockinfo" end
    if not S.sellingOwnedUpdated or GetTime() < S.sellingOwnedUpdated
        or GetTime() - S.sellingOwnedUpdated > 20 then return nil, "stockinfo" end
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumOwnedAuctions and ah.GetOwnedAuctionInfo) then return nil, "stockinfo" end
    local read, count = pcall(ah.GetNumOwnedAuctions)
    count = read and num(count)
    if not count or count < 0 or count % 1 ~= 0 then return nil, "stockinfo" end
    for i = 1, count do
        local good, row = pcall(ah.GetOwnedAuctionInfo, i)
        if not good or type(row) ~= "table" or not row.itemKey or not num(row.itemKey.itemID) then
            return nil, "stockinfo"
        end
        if row.itemKey.itemID == itemID then
            local qty = num(row.quantity)
            if not qty or qty < 0 or qty % 1 ~= 0 then return nil, "stockinfo" end
            held = held + qty
        end
    end
    local pending = num(db.stockPending[tostring(itemID)] or 0)
    if not pending or pending < 0 or pending % 1 ~= 0 then return nil, "stockinfo" end
    return math.max(0, cap - held - pending)
end

local function commodityPositionTerms(itemID, line, units, cost, market, kind, snapshot, lot, policy)
    line = num(line)
    if not line or line <= 0 then return nil, "invalid" end
    local liveUnits, liveCost, first, competing, competingUnits
    if lot then
        liveUnits, liveCost, first, competing, competingUnits = lot.units, lot.cost, lot.first, lot.competing, lot.competingUnits
    else
        liveUnits, liveCost, first, competing, competingUnits = commodityLot(snapshot, line)
    end
    if not num(liveUnits) or not num(liveCost) then return nil, "invalid" end
    if (units and (not num(units) or units < liveUnits)) or (cost and (not num(cost) or cost < liveCost)) then return nil, "grown" end
    if liveUnits < 1 then return nil, "empty" end
    kind = offerKind(itemID, line, kind) or (market ~= nil and "market" or "watch")
    local sales, salesLimit, salesReason
    if policy then sales = policy.sales
    else
        local payout
        sales, salesLimit, salesReason, payout = S.exitPolicy(itemID, kind, liveUnits, liveCost, market)
        if kind == "vendor" then market = payout end
    end
    if salesReason then return nil, salesReason end
    local allowance, stockReason
    if policy then allowance = policy.allowance else allowance, stockReason = S.stockAllowance(itemID, salesLimit) end
    if not allowance then return nil, stockReason end
    if liveUnits > allowance then return nil, "stocklimit" end
    if kind == "market" or kind == "dump" then
        local info = infoOf(itemID)
        if info.quality == -1 or info.stackable == nil then
            requestItemLoad(itemID)
            return nil, "iteminfo"
        end
        if not info.stackable then return nil, "stackable" end
        if info.quality < (cfg.quality or 1) then return nil, "quality" end
        if kind == "market" and (cfg.overhang or 0) > 0 and competingUnits > cfg.overhang then
            return nil, "overhang"
        end
    end
    if market == nil and (kind == "market" or kind == "dump" or kind == "vendor") then return nil, "invalid" end
    local deposit = kind == "vendor" and 0 or (depositPerUnit(itemID, true) or math.ceil(liveCost / liveUnits * 0.05))
    local reserve = deposit * liveUnits
    if not num(reserve) or reserve < 0 then return nil, "invalid" end
    local budget = policy and policy.budget or S.purchaseBudget()
    if liveCost + reserve > budget then return nil, "budget" end
    local profit, resale
    if market ~= nil then
        market = num(market)
        if not market or market <= 0 then return nil, "invalid" end
        if kind ~= "vendor" and sales and sales.average then market = math.min(market, sales.average) end
        resale = kind ~= "vendor" and competing and math.min(market, competing - 1) or market
        profit = math.floor(liveUnits * resale * (kind == "vendor" and 1 or (1 - (cfg.cut or 0.05))) - liveCost - reserve)
        if not num(profit) then return nil, "invalid" end
        if profit < math.max(1, kind == "vendor" and (cfg.vendorMin or 5000) or (cfg.profit or 0)) then return nil, "profit" end
    end
    return {units=liveUnits, cost=liveCost, reserve=reserve, walletCap=budget - reserve, profit=profit, first=first, resale=resale, kind=kind}
end

function S.optimizedCommodityTerms(itemID, line, market, kind, snapshot)
    if kind ~= "market" and kind ~= "dump" then
        return commodityPositionTerms(itemID, line, nil, nil, market, kind, snapshot)
    end
    line = num(line)
    if not line or line < 1 then return nil, "invalid" end
    local sales, salesLimit, salesReason = S.salesPolicy(itemID)
    if salesReason then return nil, salesReason end
    local allowance, stockReason = S.stockAllowance(itemID, salesLimit)
    if not allowance then return nil, stockReason end
    local policy = {allowance=allowance, budget=S.purchaseBudget(), sales=sales}
    -- Only fresh-history candidates reach this path. An empty order book never
    -- invents an exit price; the existing market reference remains the upper bound.
    return ForeverSniperDepthOptimizer.choose(snapshot.tiers, math.floor(line), function(ceiling, lot)
        return commodityPositionTerms(itemID, ceiling, nil, nil, market, kind, snapshot, lot, policy)
    end)
end

function S.remainderTerms(itemID, line, units, cost, market, kind, snapshot)
    local retry = snapshot.remainder
    if not retry or retry ~= S.remainderRetry or retry.id ~= itemID or GetTime() >= retry.expires then return nil, "loading" end
    if units and (not num(units) or units < 1 or units % 1 ~= 0)
        or cost and (not num(cost) or cost < 1 or cost % 1 ~= 0) then return nil, "invalid" end
    line = math.min(line, retry.line)
    local available, _, first, competing, competingUnits = commodityLot(snapshot, line)
    if available < 1 then return nil, "empty" end
    -- A new search may still contain the rejected quantity. Reduce it on each
    -- hardware retry; the new server quote, not this sizing rule, authorizes cost.
    local limit = available < retry.failedUnits and available or math.max(1, math.floor(retry.failedUnits / 2))
    limit = math.min(limit, units or limit)
    local tiers = {}
    for _, tier in ipairs(snapshot.tiers) do tiers[#tiers + 1] = tier end
    table.sort(tiers, function(a, b) return a.price < b.price end)
    local selected, total = 0, 0
    for _, tier in ipairs(tiers) do
        if tier.price > line or selected >= limit then break end
        local quantity = math.min(tier.quantity, limit - selected)
        selected, total = selected + quantity, total + quantity * tier.price
    end
    if total > math.min(cost or retry.cost, retry.cost) then return nil, "grown" end
    -- Partial recovery keeps the approved exit estimate, not a claim that the
    -- cheap floor was cleared. Remaining cheap units still count as competition.
    local lot = {units=selected, cost=total, first=first, competing=competing,
        competingUnits=competingUnits + available - selected}
    local terms, reason = commodityPositionTerms(itemID, line, selected, total,
        market and math.min(market, retry.market or market), kind, snapshot, lot)
    if terms then terms.line = line end
    return terms, reason
end

local function commodityOfferTerms(itemID, line, units, cost, market, kind)
    line = num(line)
    if not line or line <= 0 then return nil, "invalid" end
    local snapshot, reason, source = commodityTiersForBuy(itemID)
    if not snapshot then return nil, reason end
    local terms, rejected
    local retry = S.remainderRetry
    if retry and retry.id == itemID and not snapshot.remainder then return nil, "loading" end
    if snapshot.remainder then
        terms, rejected = S.remainderTerms(itemID, line, units, cost, market, kind, snapshot)
    else
        terms, rejected = commodityPositionTerms(itemID, line, units, cost, market, kind, snapshot)
    end
    return terms, rejected, snapshot, source
end

local function purchaseAPIAvailable()
    return C_AuctionHouse and type(C_AuctionHouse.StartCommoditiesPurchase) == "function"
        and type(C_AuctionHouse.ConfirmCommoditiesPurchase) == "function"
end

local function commodityOfferReady(itemID, link, line, units, cost, market, kind)
    if not purchaseAPIAvailable() then return false end
    if db.unsettledPurchase or db.blacklist[itemID] or commodityFor(itemID) ~= true then return false end
    local terms, reason = commodityOfferTerms(itemID, line, units, cost, market, kind)
    if reason == "loading" or reason == "unreadable" or reason == "grown" then prepareCommodityDeal(itemID, link, line, market, kind) end
    return terms ~= nil, reason
end

-- LOOPHOLE LAYER (TOS-legal edges): queue-fronting by 1 copper, deposit
-- math, hour-of-day arbitrage, and stack-size premium. All use data we
-- already sweep; none break any rule - they are just math most players
-- cannot be bothered to do.

lastMinOf = function(itemID)
    local snapshot = S.commoditySnapshots[itemID]
    if not snapshot or GetTime() < snapshot.t or GetTime() - snapshot.t > COMMODITY_SNAPSHOT_AGE then return nil end
    local minimum
    for _, tier in ipairs(snapshot.tiers) do
        if tier.quantity > 0 then minimum = math.min(minimum or tier.price, tier.price) end
    end
    return minimum
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
        local ok, name = pcall(anyGetItemInfo, link)
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
local commodityActionState

local function addPositionTooltip(units, cost, line, market, profit, itemID)
    if market then GameTooltip:AddLine("exit reference: " .. fmtMoney(market), 0.7, 0.7, 0.7) end
    if units and cost then
        GameTooltip:AddLine(string.format("complete position: %d units, purchase %s (deposit reserve extra if relisting)",
            units, fmtMoney(cost)), 1, 0.82, 0.3, true)
    end
    if line then GameTooltip:AddLine("deal line: " .. fmtMoney(line), 0.3, 1, 0.45) end
    if profit then GameTooltip:AddLine("estimated position net: " .. fmtSignedMoney(profit), 0.3, 1, 0.45) end
    if itemID then GameTooltip:AddLine(S.salesSummary(itemID), 0.7, 0.7, 0.7, true) end
end

local function renderPopup()
    if not popup then return end
    -- prune dead entries: a deal the sweep marked GONE (or bought, or older
    -- than 10 minutes) stops claiming a BUY button in the popup
    for i = #popupRows, 1, -1 do
        local d = popupRows[i]
        local alive = false
        if (d.t and time() - d.t > 600) or select(3,S.exitPolicy(d.itemID,d.kind,d.units,d.cost,d.market)) then
            table.remove(popupRows, i)
        else
            for _, dd in ipairs(S.deals) do
                if dd.id == d.itemID and not dd.bought and not dd.gone then
                    d.offer, alive = dd, true
                    break
                end
            end
            if not alive then table.remove(popupRows, i) end
        end
    end
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
        row.cost = data.cost
        row.line = data.line
        row.market = data.market
        row.kind = data.kind
        row.offer = data.offer
        row.positionProfit = data.profit
        local label, ready, hint = commodityActionState(data.itemID, data.link, data.line, data.units, data.cost, data.market, data.kind)
        row.buyHint = hint
        row.buyBtn:SetEnabled(ready)
        row.buyBtn:SetText(label)
        row:Show()
    end
    for i = #popupRows + 1, #popup.rows do popup.rows[i]:Hide() end
    if cfg.popup and #popupRows > 0 then popup:Show() else popup:Hide() end
end

local canQuery, lastQueryAt

local function queryPacing()
    if not S.queryPacing then
        S.queryPacing = {interval=1, requests={}, busyEpisodes=0, busySeconds=0}
    end
    return S.queryPacing
end

local function observeQueryPressure(busy)
    local p, now = queryPacing(), GetTime()
    if busy then
        if not p.busySince then
            p.busySince = now
            p.busyEpisodes = p.busyEpisodes + 1
        end
    elseif p.busySince then
        p.busySeconds = p.busySeconds + math.max(0, now - p.busySince)
        p.busySince = nil
    end
end

local function queryRequestCount()
    local p, now = queryPacing(), GetTime()
    for i = #p.requests, 1, -1 do
        if p.requests[i] > now or now - p.requests[i] >= 60 then table.remove(p.requests, i) end
    end
    return #p.requests
end

local function noteQueryAttempt()
    local p, now = queryPacing(), GetTime()
    queryRequestCount()
    push(p.requests, 120, now)
    p.nextAt = math.max(now, p.nextAt or 0) + p.interval
    lastQueryAt = now
end

function S.queryReadyAt(urgent)
    local p = queryPacing()
    local due = math.max(lastQueryAt + p.interval, p.nextAt or 0)
    if urgent then
        -- Borrow one pacing slot for a just-detected bargain, then repay it.
        -- The rolling cap prevents the loan crossing a minute boundary twice.
        due = math.max(lastQueryAt + 0.01, due - p.interval)
    end
    -- Addition/subtraction can round differently at the exact minute boundary.
    if queryRequestCount() >= 60 then due = math.max(due, p.requests[1] + 60 + 0.001) end
    return due
end

local function requestItemSearch(itemID, commodity, separateOwner, forceSearch)
    local ah = C_AuctionHouse
    local key = ah.MakeItemKey and ah.MakeItemKey(itemID) or {itemID=itemID}
    local has = not forceSearch and ah.HasSearchResults and ah.HasSearchResults(key)
    S.searchMethods = S.searchMethods or {}
    if has and commodity == true and ah.RefreshCommoditySearchResults then
        S.searchMethods[itemID] = "refresh commodity"
        ah.RefreshCommoditySearchResults(itemID)
    elseif has and commodity == false and ah.RefreshItemSearchResults then
        S.searchMethods[itemID] = "refresh item"
        ah.RefreshItemSearchResults(key)
    else
        S.searchMethods[itemID] = "new item search"
        local sort = Enum and Enum.AuctionHouseSortOrder
        ah.SendSearchQuery(key, {{sortOrder=sort and sort.Price or 0, reverseSort=false}}, separateOwner)
    end
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
    if S.pending or S.buying or S.liveCandidate or S.autoSearch or S.watchSearch or not canQuery() then
        printf("an auction request is busy - wait before inspecting another item.")
        return
    end
    local commodity = commodityFor(itemID)
    local pending = {itemID=itemID, link=link, t=GetTime(), units=units, commodity=commodity}
    S.pending = pending
    noteQueryAttempt()
    local ok, e = pcall(requestItemSearch, itemID, commodity, false)
    if not ok then
        if S.pending == pending then S.pending = nil end
        err("inspection search", e)
        printf("search failed: %s", tostring(e):sub(1, 200))
        return
    end
    C_Timer.After(10, function()
        if S.pending ~= pending then return end
        S.pending = nil
        printf("inspection search timed out - live scanning can resume.")
    end)
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
-- The SNIPE card approves a complete position. BUY uses an event-completed
-- snapshot, never a browse estimate; scanner callbacks cannot start a buy.

local confirmFrame

local function buildConfirm()
    if confirmFrame then return confirmFrame end
    local f = CreateFrame("Frame", "ForeverSniperConfirm", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(440, 240)
    f:SetPoint("CENTER")
    f:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "ForeverSniperConfirm")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.TitleText:SetText("Forever Sniper - purchase")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOP", 0, -36)
    f.body:SetWidth(400)
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.state:SetPoint("BOTTOM", 0, 44)
    f.state:SetWidth(400)
    f.state:SetHeight(34)
    f.state:SetTextColor(1, 0.82, 0.3)
    f:SetScript("OnHide", function(self)
        local q = self.q
        if q and q.snipeDeal then
            if S.snipe and S.snipe.current == q.snipeDeal then S.snipe.current = nil end
            self.q = nil
        end
    end)
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

local function throttleGate()
    -- the AH message throttle: a purchase sent while it is busy is thrown
    -- away silently by the server (ForeverForge's readyToBuy - same rule),
    -- so every purchase checks this first
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady then
        local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if not ok or (ready ~= true and ready ~= false) then return false, "unavailable" end
        return ready, ready == false and "busy" or nil
    end
    return false, "unavailable"
end

local function showConfirm(q)
    local f = buildConfirm()
    f.q = q
    f.buy:SetEnabled(true)
    f.state:SetText("")
    f.buy:SetScript("OnClick", function(self)
        local q2 = self:GetParent().q
        if not q2 then self:GetParent():Hide() return end

        if q2.commodity then
            quickBuy({ itemID = q2.itemID, link = q2.link, line = q2.line or q2.unit,
                units = q2.units, cost = q2.cost, market2 = q2.market })
            return
        end

        printf("individual-listing purchases are not validated; use the native Auction House to buy this item.")
        self:GetParent().q = nil
        self:GetParent():Hide()
    end)
    f.body:SetText(q.body or "")
    f.buy:SetText("Purchase")
    f:Show()
end

local function startBuyAll()
    -- Multiple commodity quotes cannot share one hardware press safely.
    -- Reuse the full-wall buyer instead of the old speculative batch path.
    if S.buyBest then S.buyBest() end
    return
end

local function buildPopup()
    popup = CreateFrame("Frame", "ForeverSniperPopup", UIParent, "BasicFrameTemplateWithInset")
    popup:SetSize(440, 246)
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
    popup.TitleText:SetText("Forever Sniper - complete positions")
    popup.rows = {}

    for i = 1, 10 do
        local row = CreateFrame("Button", nil, popup)
        row:SetSize(410, 19)
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -34 - (i - 1) * 20)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local icon = row:CreateTexture(nil, "OVERLAY")
        icon:SetSize(16, 16)
        icon:SetPoint("LEFT")
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        text:SetJustifyH("LEFT")
        text:SetWidth(300)
        text:SetWordWrap(false)
        row.icon, row.text = icon, text
        local buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        buyBtn:SetSize(52, 18)
        buyBtn:SetPoint("RIGHT")
        buyBtn:SetText("Buy")
        row.buyBtn = buyBtn
        buyBtn:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if r.itemID and r.line then
                -- ONE PRESS: Start rides this click, the quote auto-confirms
                -- from the event within the fresh deal line
                quickBuy({ itemID = r.itemID, link = r.link, line = r.line,
                           units = r.units or 1, cost = r.cost, market2 = r.market, kind = r.kind, offer = r.offer })
            end
        end)
        row:SetScript("OnClick", function(self)
            if self.itemID then searchListing(self.itemID, self.link, self.units) end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.link then GameTooltip:SetHyperlink(self.link) else GameTooltip:SetItemByID(self.itemID) end
            addPositionTooltip(self.units, self.cost, self.line, self.market, self.positionProfit, self.itemID)
            if self.buyHint then GameTooltip:AddLine(self.buyHint, 1, 0.82, 0.3, true) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
-- learned market. Feed SELL prepares the native form; explicit batch relisting
-- retains its submission path.
-- Post mechanics live-proven by Auctionator on this client:
--   C_AuctionHouse.PostItem(itemLocation, duration, quantity, bid, buyout)
--   C_AuctionHouse.PostCommodity(itemLocation, duration, quantity, unitPrice)

local function carriedStack(bag, slot)
    if not C_Container.GetContainerItemInfo then return end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    local qty = num(type(info) == "table" and info.stackCount or info)
    if qty and qty > 0 and qty % 1 == 0 then
        return qty, type(info) == "table" and info.isLocked or false
    end
end

local function findInBags(itemID)
    if C_Container == nil or C_Container.GetContainerNumSlots == nil then return nil end
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
        local n = C_Container.GetContainerNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                local id = C_Container.GetContainerItemID(bag, slot)
                if id == itemID then
                    local qty, locked = carriedStack(bag, slot)
                    if qty and not locked then return bag, slot, qty end
                end
            end
        end
    end
    return nil
end

-- Submit one available bag stack. A successful call is not a posting receipt.
function S.nativeSellActive()
    local ah = AuctionHouseFrame
    if not ah or (ah.IsShown and not ah:IsShown()) then return false end
    -- Third-party tabs can leave native frames marked shown after switching away.
    if ah.selectedTab then
        if ah.SellTab and ah.Tabs then
            if ah.Tabs[ah.selectedTab] ~= ah.SellTab then return false end
        elseif ah.selectedTab ~= 2 then return false end
    end
    local frame = ah and ah.CommoditiesSellFrame
    if frame and frame:IsShown() and frame:GetItem() then return true end
    frame = ah and ah.ItemSellFrame
    return frame and frame:IsShown() and frame:GetItem() ~= nil or false
end

do
    local function clearPreparedSell(ah, frame, loc)
        if frame:GetItem() ~= loc then return end
        frame.PostButton:Disable()
        ah:ClearPostItem()
    end

    local function populateSellPanel(ah, frame, loc, qty, unitPrice, duration, isCommodity, approved)
        ah:SetPostItem(loc)
        -- SetPostItem may decline locked items or an active multisell.
        if frame:GetItem() ~= loc or not frame:IsShown() then return false end
        if not isCommodity then
            frame.BuyoutModeCheckButton:SetChecked(true)
            frame.BuyoutModeCheckButton:UpdateState()
        end
        frame.QuantityInput:SetQuantity(qty)
        -- Both native forms take a per-item price, not the stack total.
        frame.PriceInput:SetAmount(unitPrice)
        frame.Duration:SetDuration(duration)
        if frame.Duration.Dropdown and frame.Duration.Dropdown.GenerateMenu then
            frame.Duration.Dropdown:GenerateMenu()
        end
        frame:UpdatePostState()
        return frame:GetItem() == loc and frame:IsShown() and S.nativeSellActive()
            and frame.QuantityInput:GetQuantity() == qty
            and frame.PriceInput:GetAmount() == unitPrice and frame.Duration:GetDuration() == duration
            and (isCommodity or frame.BuyoutModeCheckButton:GetChecked() == true)
            and approved()
    end

    function S.prepareNativeSell(loc, qty, unitPrice, duration, isCommodity, approved)
        local ah = AuctionHouseFrame
        local frame = ah and (isCommodity and ah.CommoditiesSellFrame or ah.ItemSellFrame)
        if not (type(approved) == "function" and ah and ah.SetPostItem and ah.ClearPostItem and frame and frame.GetItem and frame.IsShown
            and frame.QuantityInput and frame.QuantityInput.SetQuantity and frame.QuantityInput.GetQuantity
            and frame.PriceInput and frame.PriceInput.SetAmount and frame.PriceInput.GetAmount
            and frame.Duration and frame.Duration.SetDuration and frame.Duration.GetDuration and frame.UpdatePostState
            and frame.PostButton and frame.PostButton.Disable)
            or (not isCommodity and not (frame.BuyoutModeCheckButton
                and frame.BuyoutModeCheckButton.SetChecked and frame.BuyoutModeCheckButton.GetChecked
                and frame.BuyoutModeCheckButton.UpdateState)) then
            printf("native sell controls unavailable - nothing submitted.")
            return false
        end
        local ok, ready = pcall(populateSellPanel, ah, frame, loc, qty, unitPrice, duration, isCommodity, approved)
        if not ok or not ready then
            local cleared, cleanupError = pcall(clearPreparedSell, ah, frame, loc)
            if not cleared then err("ClearPreparedSell", cleanupError) end
            if not ok then
                err("PrepareNativeSell", ready)
                printf("native sell form error: %s. Nothing submitted.", tostring(ready):sub(1, 160))
            else printf("native sell panel, filled fields or selling permission changed - nothing submitted.") end
            return false
        end
        printf("sell form ready: %d units at %s each, %dh. Review the fields, then click the game's Post button to list.",
            qty, fmtMoney(unitPrice), duration == 1 and 12 or 48)
        return true
    end
end

local function sellAt(itemID, unitPrice, prepareOnly)
    if not S.ahOpen then
        printf("open the Auction House first - selling needs the window up.")
        return false
    end
    if C_AuctionHouse == nil then return false end
    if S.snipePending or db.unsettledPurchase then
        printf("selling paused: purchase unresolved. Check /fsn purchase before listing.")
        return false
    end
    local ready, readinessReason = throttleGate()
    if not ready then
        printf(readinessReason == "unavailable" and "selling paused: auction readiness unavailable."
            or "selling paused: auction throttle busy. Wait for readiness, then click LIST again.")
        return false
    end
    unitPrice = num(unitPrice)
    if not unitPrice or unitPrice <= 0 or unitPrice % 1 ~= 0 then return false end
    local bag, slot, qty = findInBags(itemID)
    if bag == nil then
        local info = infoOf(itemID)
        printf("%s is not in your bags - nothing to list.", info.name or ("item " .. itemID))
        return false
    end
    local loc = ItemLocation and ItemLocation.CreateFromBagAndSlot(bag, slot)
    if loc == nil then return false end
    local function approvedStack()
        -- Validation/native callbacks can move the stack or revoke permission.
        -- Do not silently select its replacement or adopt a changed quantity.
        local id = C_Container.GetContainerItemID(bag, slot)
        local currentQty, locked = carriedStack(bag, slot)
        if id ~= itemID or currentQty ~= qty or locked or not throttleGate() then return false end
        return S.ahOpen and not S.snipePending and not db.unsettledPurchase
    end
    local total = num(unitPrice * qty)
    if not total or total <= 0 or total % 1 ~= 0 then
        printf("invalid stack total - nothing submitted.")
        return false
    end
    if not C_AuctionHouse.IsSellItemValid then
        printf("auctionability API unavailable - nothing submitted.")
        return false
    else
        -- This client API takes an explicit displayError flag (as used by Auctionator).
        local okV, valid = pcall(C_AuctionHouse.IsSellItemValid, loc, false)
        if not okV or valid ~= true then
            if not okV then
                err("IsSellItemValid", valid)
                printf("auctionability check failed: %s. Nothing submitted.", tostring(valid):sub(1, 160))
            else
                printf("%s is not verified as auctionable (API returned %s) - nothing submitted.",
                    infoOf(itemID).name or ("item " .. itemID), tostring(valid))
            end
            return false
        end
    end
    local isCommodity
    if C_AuctionHouse.GetItemCommodityStatus then
        local okC, st = pcall(C_AuctionHouse.GetItemCommodityStatus, loc)
        if okC then
            local values = Enum and Enum.ItemCommodityStatus
            if st == true or st == (values and values.Commodity or 2) then isCommodity = true
            elseif st == false or st == (values and values.Item or 1) then isCommodity = false end
        end
    end
    if isCommodity == nil then
        printf("cannot determine commodity status - nothing submitted.")
        return false
    end
    local post = isCommodity and C_AuctionHouse.PostCommodity or nil
    if not isCommodity then post = C_AuctionHouse.PostItem end
    if not post then printf("posting API unavailable for this item type - nothing submitted.") return false end
    -- Disappearance is not proof of sales; use it only as a duration heuristic.
    local vel = absorbVelocity(itemID)
    local duration = (vel and vel < 120) and 1 or 3
    local depositTxt = ""
    local calculateDeposit = isCommodity and C_AuctionHouse.CalculateCommodityDeposit or nil
    if not isCommodity then calculateDeposit = C_AuctionHouse.CalculateItemDeposit end
    if calculateDeposit then
        local okD, dep = pcall(calculateDeposit, isCommodity and itemID or loc, duration, qty)
        dep = okD and num(dep) or nil
        local okW, wallet = pcall(GetMoney)
        wallet = okW and num(wallet) or nil
        if not dep or dep < 0 or not wallet or wallet < dep then
            printf("posting paused: deposit unavailable or unaffordable.")
            return false
        end
        depositTxt = " (deposit " .. fmtMoney(dep) .. ")"
    end
    local checked, approved = pcall(approvedStack)
    if not checked then err("SellApproval", approved) end
    if not checked or not approved then
        printf("selling state or carried stack changed - nothing submitted. Review and try again.")
        return false
    end
    if prepareOnly then
        return S.prepareNativeSell(loc, qty, unitPrice, duration, isCommodity, approvedStack)
    end
    local ok, e
    if isCommodity then
        ok, e = pcall(post, loc, duration, qty, unitPrice)
    else
        ok, e = pcall(post, loc, duration, qty, nil, total)
    end
    if ok then
        if e == true then
            printf("posting requires confirmation; complete it in the Auction House sell panel.")
            return false
        end
        local _, tr = smartPrice(itemID, unitPrice)
        local trendTxt = ""
        if tr > 0.05 then trendTxt = " (recent observed prices rose)"
        elseif tr < -0.05 then trendTxt = " (recent observed prices fell)" end
        printf("submitted |cffffd100%d x %s|r at |cffffd100%s each|r (%s total) - %dh%s%s. Check your auctions for completion.",
            qty, infoOf(itemID).name or ("item " .. itemID),
            fmtMoney(unitPrice), fmtMoney(total), duration == 1 and 12 or 48, depositTxt, trendTxt)
        S.session.postSubmitted = (S.session.postSubmitted or 0) + 1
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
    if tier == "VENDOR" then actionText = "compare vendor value"
    elseif market and market > 0 then actionText = "resale reference " .. fmtMoney(math.floor(market)) end
    toastFrame.detail:SetText(fmtMoney(price) .. "  market " .. fmtMoney(market or 0)
        .. "  est net " .. fmtSignedMoney(profit or 0) .. "\n|cffffd100> " .. actionText .. "|r")
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
local feedFrame, feedRows, feedStatus, feedEmpty
local FEED_ROWS, FEED_ROW_H, FEED_W = 14, 26, 700
local feedDirty, feedLastRefresh, feedRefreshWake = false, 0, nil
local buyFailUntil = {} -- itemID -> failed purchases rest for a while

-- Only a live-validated position can reserve scanner time. Persisted feed
-- rows and browse estimates must never stop discovery after a reload.
local function focusedDeal()
    local focus = S.dealFocus
    if not focus then return end
    local d = focus.deal
    local present = false
    for _, deal in ipairs(S.deals) do if deal == d then present = true break end end
    if not present or d.bought or d.gone or db.blacklist[d.id] or time() - focus.started >= 600
        or (buyFailUntil[d.id] and GetTime() < buyFailUntil[d.id]) then
        S.dealFocus = nil
        return
    end
    local terms, reason = commodityOfferTerms(d.id, d.line, d.units, d.cost, d.market, d.kind)
    if not terms and reason ~= "loading" and reason ~= "unreadable" then
        d.gone, S.dealFocus = true, nil
        return
    end
    -- A missing reply cannot hold discovery forever. BUY still requires its
    -- own fresh completed snapshot throughout this bounded recovery window.
    local snapshot = S.commoditySnapshots[d.id]
    if not terms and (not snapshot or GetTime() - snapshot.t >= 35) then
        d.gone, S.dealFocus = true, nil
        return
    end
    return d
end

local function focusDeal(d)
    if focusedDeal() or d.gone or d.bought or commodityFor(d.id) ~= true then return end
    if buyFailUntil[d.id] and GetTime() < buyFailUntil[d.id] then return end
    if commodityOfferTerms(d.id, d.line, d.units, d.cost, d.market, d.kind) then
        S.dealFocus = {deal=d, started=time()}
    end
end

-- ONE-PRESS BUY: Start rides the caller's hardware press (button click or
-- bound key), the quote confirms itself from the event (this client's rule:
-- Start needs a press, Confirm does not). Tolerance-checked against the deal
-- snapshot - over the cap it is refused, never overpaid.
commodityActionState = function(itemID, link, line, units, cost, market, kind)
    if S.snipePending then
        return S.snipePending.confirmed and "Result" or "Quote", false,
            "A purchase is awaiting its quote or server outcome."
    end
    if db.unsettledPurchase then return "Lock", false, "Purchase outcome unknown. Check mail, bags and gold, then /fsn purchase." end
    if not S.ahOpen then return "AH", false, "Open the Auction House to buy." end
    if not cfg.enabled then return "Off", false, "Scanner disabled. Use /fsn on to resume." end
    if db.blacklist[itemID] then return "Block", false, "This item is blacklisted. Nothing will be purchased." end
    if commodityFor(itemID) == false then return "AH", false, "Individual-listing purchases require the native Auction House." end
    if not purchaseAPIAvailable() then return "N/A", false, "Commodity purchasing APIs are unavailable on this client." end
    if buyFailUntil[itemID] and GetTime() < buyFailUntil[itemID] then
        return "Rest", false, "Purchase cooldown after an unsuccessful attempt. Wait before retrying."
    end
    local ready, readinessReason = throttleGate()
    if not ready then
        return readinessReason == "unavailable" and "N/A" or "Busy", false, readinessReason == "unavailable"
            and "Auction House readiness is unavailable. Buying remains paused."
            or "The Auction House throttle is busy."
    end
    local ready, reason = commodityOfferReady(itemID, link, line, units, cost, market, kind)
    if reason == "salesvolume" or reason == "liquidity" then return "Sales", false, S.salesSummary(itemID) end
    if reason == "budget" then return "Cost", false, "The complete position plus deposit reserve exceeds your wallet or spend cap." end
    if reason == "stocklimit" then return "Stock", false, "The complete position exceeds your per-item stock limit, including uncollected purchases." end
    if reason == "stockinfo" then return "Stock", false, "Stock data is unavailable or stale. Refresh owned auctions with /fsn sell; buying remains blocked." end
    if reason == "profit" then return "Net", false, "Estimated net after competition, cut and deposit is below your profit floor." end
    if reason == "invalid" then return "Hold", false, "Position data is invalid. Nothing will be purchased." end
    if reason == "iteminfo" then return "Info", false, "Item quality or stack metadata is still loading. Nothing will be purchased." end
    if reason == "quality" then return "Qual", false, "This item no longer meets your market quality floor." end
    if reason == "stackable" then return "Type", false, "Market flips require verified stackable items." end
    if reason == "overhang" then return "Stock", false, "Complete live competing stock exceeds your overhang limit." end
    if reason == "empty" then return "Gone", false, "No units remain below the approved ceiling." end
    if ready and cfg.prebuy then
        return S.prebuyReady(itemID, line) and "Buy" or "Check", true,
            "New-search test: first press searches; press again within 2s of completion to start a guarded quote."
    end
    local snapshot = S.commoditySnapshots[itemID]
    if ready and snapshot and snapshot.remainder then
        return "Retry", true, "Buy the smaller recovery offer at the original ceiling. Each retry needs a new press and quote."
    end
    return ready and "Buy" or "Load", ready,
        ready and "One click buys this complete position after the live quote passes validation."
            or "Waiting for validated live tiers. The scanner prepares these automatically."
end
-- (quickBuy and markDealGone are forward-declared at the top of the file)

local function retirePurchase(reason)
    local p = S.snipePending
    if not p then return end
    -- Cancel may synchronously emit another quote. Retire ownership first so
    -- that callback cannot confirm the purchase we are cancelling.
    S.snipePending = nil
    S.purchaseResult(p, (p.confirmed and "outcome unknown: " or "") .. reason)
    if p.confirmed then
        -- Keep this across a normal reload. Outcome events carry no request ID,
        -- so only this session's owner may reconcile a late server event.
        p.reason = reason
        db.unsettledPurchase = p
        S.outcomeOwner = p
    else
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
end

local function purchaseDetails(p)
    if type(p) ~= "table" or type(p.deal) ~= "table" then return end
    local id, units, total = num(p.deal.id), num(p.units), num(p.total)
    if not id or id < 1 or id % 1 ~= 0 or not units or units < 1 or units % 1 ~= 0
        or not total or total < units or total % 1 ~= 0 then return end
    return id, units, total
end

local function retireSnipePresentation()
    local f = _G.ForeverSniperConfirm
    local d = f and f.q and f.q.snipeDeal
    local approved = d and f.q.approved
    -- A mutable deal can refresh while its displayed approval stays unchanged.
    local expired = approved and approved.t and time() - approved.t > 600
    if d and (not S.offerAvailable(d) or expired) then
        if S.snipe and S.snipe.current == d then S.snipe.current = nil end
        f.q = nil
        f:Hide()
    end
    local current = S.snipe and S.snipe.current
    if current and (not S.offerAvailable(current) or (current.t and time() - current.t > 600)) then
        S.snipe.current = nil
    end
    if f and f:IsShown() and f.q and f.q.snipeDeal and f.q.approved then
        local a = f.q.approved
        local label, ready, hint = commodityActionState(a.itemID, a.link, a.line, a.units, a.cost, a.market2, a.kind)
        f.buy:SetText(strupper(label))
        f.buy:SetEnabled(ready)
        f.state:SetText(hint)
    end
end

local function refreshDealPresentation()
    retireSnipePresentation()
    if S.feedRefresh then S.feedRefresh() end
    renderPopup()
end

function S.refreshPurchasePresentation()
    refreshDealPresentation()
    if S.refreshBuyButtons then S.refreshBuyButtons() end
    if S.refreshSelling then S.refreshSelling() end
end

function S.offerAvailable(offer)
    if not offer then return true end -- non-UI callers still validate complete tiers
    if offer.gone or offer.bought or select(3,S.exitPolicy(offer.id,offer.kind,offer.units,offer.cost,offer.market)) then return false end
    for _, d in ipairs(S.deals) do if d == offer then return true end end
    return false
end

function S.dismissDeal(itemID)
    local observed = S.observedOffers and S.observedOffers[itemID]
    if observed then
        S.seen[tostring(itemID) .. ":" .. tostring(observed.price)] = time()
        S.observedOffers[itemID] = nil
    end
    if S.remainderRetry and S.remainderRetry.id == itemID then S.remainderRetry = nil end
    for _, d in ipairs(S.deals) do if d.id == itemID then d.gone = true end end
    for _, field in ipairs({"liveCandidate", "autoSearch", "watchSearch"}) do
        if S[field] and S[field].id == itemID then S[field] = nil end
    end
    if S.liveCandidates then S.liveCandidates[itemID] = nil end
    if S.dealFocus and S.dealFocus.deal.id == itemID then S.dealFocus = nil end
    if S.snipePending and not S.snipePending.confirmed and S.snipePending.deal.id == itemID then
        retirePurchase("deal skipped")
    end
end

-- Share Clear/wipe cleanup without adding to this chunk's Lua local limit.
function S.clearFeedDeals()
    S.remainderRetry = nil
    if S.snipePending and not S.snipePending.confirmed then retirePurchase("feed cleared") end
    for i = #S.deals, 1, -1 do
        S.dismissDeal(S.deals[i].id)
        S.deals[i] = nil
    end
    S.dealFocus = nil
    S.liveCandidate, S.liveCandidates = nil, nil
    refreshDealPresentation()
end

local function finishPurchase(p, source)
    if type(p) ~= "table" or not p.confirmed or db.unsettledPurchase ~= p then return end
    local id, units, total = purchaseDetails(p)
    if not id then
        printf("stored purchase details are invalid; buying stays locked. Verify the outcome before /fsn purchase failed.")
        return
    end
    S.purchaseResult(p, source)
    db.unsettledPurchase, S.outcomeOwner, S.snipePending = nil, nil, nil
    S.remainderRetry = nil
    S.session.spent = (S.session.spent or 0) + total
    S.session.buys = (S.session.buys or 0) + 1
    S.boughtAt[tostring(id)] = {t=time(), price=total / units, source=source, kind=p.kind, ceiling=p.maxUnit}
    db.purchases = db.purchases or {}
    push(db.purchases, 200, {t=time(), id=id, units=units, total=total, source=source, kind=p.kind, ceiling=p.maxUnit})
    local stockKey = tostring(id)
    db.stockPending[stockKey] = (num(db.stockPending[stockKey]) or 0) + units
    S.commoditySnapshots[id] = nil
    S.sellingOwnedDisplay = nil -- a newly settled ceiling changes the owned-listing filter
    for _, d in ipairs(S.deals) do
        if d.id == id and not d.bought then d.bought = true end
    end
    printf("BOUGHT %d x %s for %s (%s).", units, p.deal.link or ("item " .. id), fmtMoney(total), source)
    S.refreshPurchasePresentation()
end

markDealGone = function(itemID, minPrice)
    local hit = false
    for _, d in ipairs(S.deals) do
        if d.id == itemID and not d.bought and not d.gone and minPrice > (d.line or d.unit or 0) then
            d.gone = true
            hit = true
        end
    end
    if hit then refreshDealPresentation() end
end

quickBuy = function(r)
    if not (r.itemID and r.line) then return end
    if not S.offerAvailable(r.offer) then printf("that displayed position was retired - nothing purchased.") return end
    if not S.ahOpen or not cfg.enabled then printf("open the auction house with the scanner enabled first.") return end
    if S.batchSearch then printf("a summary search is in progress - press BUY again after it finishes.") return end
    if db.blacklist[r.itemID] then printf("that item is blacklisted - nothing purchased.") return end
    if S.snipePending or S.quote or (S.batchBuy and S.batchBuy.pending) then
        printf("a purchase is already in progress - wait for its quote.")
        return
    end
    if r.gone then
        printf("that deal is gone - the sweep marked it dead (prices moved).")
        return
    end
    if r.t and (time() - r.t) > 600 then
        printf("that deal is %dm old - stale. Waiting for a fresh one (they keep coming).",
            math.floor((time() - r.t) / 60 + 0.5))
        return
    end
    if buyFailUntil[r.itemID] and GetTime() < buyFailUntil[r.itemID] then
        printf("%s is resting - its last purchase failed %ds ago.",
            r.link or ("item " .. r.itemID),
            math.floor(GetTime() - buyFailUntil[r.itemID] + 180))
        return
    end
    local isComm = commodityFor(r.itemID)
    if isComm == nil then
        printf("item type is not loaded yet - search the item in the AH and retry BUY.")
        return
    end
    if db.unsettledPurchase then
        printf("a confirmed purchase has an unknown outcome. Check mail and /fsn purchase before buying again.")
        return
    end
    if not isComm then
        printf("this is an individual listing, not a commodity; buy it in the AH until listing purchases are validated.")
        return
    end
    if not purchaseAPIAvailable() then
        printf("commodity purchase API unavailable - nothing started.")
        return
    end
    if not throttleGate() then
        printf("the AH message throttle is busy - press BUY again in a moment.")
        return
    end
    -- LIVE TIER SIZING: buy exactly the units CURRENTLY priced at or under
    -- the deal line - cheapest first, wallet-capped. The old code quoted the
    -- whole wall at blended tiers, which is how it tried to buy everything.
    local b = db.book[r.itemID]
    local med = b and freshMedian(b.s, time(), (cfg.freshMins or 45) * 60, 1) or nil
    local line = r.line
    if not line or line <= 0 then
        line = med and select(1, dealLine(med, r.itemID)) or nil
    end
    if not line or line <= 0 then
        printf("no deal line known for %s yet - click the row once to search it.", r.link or ("item " .. r.itemID))
        return
    end
    local terms, reason, snapshot, source = commodityOfferTerms(r.itemID, line, r.units, r.cost, r.market2, r.kind)
    if not terms then
        if reason == "loading" or reason == "unreadable" or reason == "grown" then prepareCommodityDeal(r.itemID, r.link, line, r.market2, r.kind) end
        if reason == "empty" then markDealGone(r.itemID, math.huge) end
        local messages = {
            loading="this offer is still preparing its complete price tiers; BUY will be ready when loading finishes.",
            unreadable="unreadable live price data - nothing purchased.",
            grown="the full lot grew beyond the displayed offer - refreshing it, nothing purchased.",
            empty="no units remain under the approved line - nothing purchased.",
            budget="full deal plus deposit reserve exceeds the budget - no partial wall purchased.",
            stocklimit="full deal exceeds your per-item stock limit - nothing purchased.",
            liquidity="fresh regional sales are below your liquidity policy - nothing purchased.",
            salesvolume="no verified positive regional daily sales - nothing purchased.",
            vendorprofit="verified NPC payout does not cover the purchase and vendor profit floor.",
            stockinfo="stock data is unavailable or stale - refresh /fsn sell before buying.",
            profit="full live deal does not clear the profit floor after fees - nothing purchased.",
            iteminfo="item eligibility is still loading - nothing purchased.",
            quality="item quality is below your market floor - nothing purchased.",
            stackable="market flips require verified stackable items - nothing purchased.",
            overhang="complete live competing stock exceeds your overhang limit - nothing purchased.",
        }
        printf("%s", messages[reason] or "invalid offer data - nothing purchased.")
        return
    end
    local buyUnits, expected = terms.units, terms.cost
    line = terms.line or line
    if not S.prebuyGate(r, line, snapshot, source) then return end
    -- Match the native buy display's sanitized average, including mixed tiers.
    -- This request argument does not replace the exact total and unit quote caps.
    local priceIncrement = C_AuctionHouse.SupportsCopperValues and not C_AuctionHouse.SupportsCopperValues() and 100 or 1
    local requestUnitPrice = math.ceil(expected / buyUnits / priceIncrement) * priceIncrement
    S.prebuyCheck = nil -- A completed check authorizes only one quote attempt.
    S.purchaseSequence = (S.purchaseSequence or 0) + 1
    if snapshot then
        diagnostic("purchase tiers", string.format("item %d; attempt %d; %s; completed age %.2fs; read age %.2fs; %d tiers; approved x%d/%d copper; first 3 rows item:unit:quantity:owned:auctionID=%s",
            r.itemID, S.purchaseSequence, source, GetTime() - snapshot.t, GetTime() - (snapshot.readAt or snapshot.t),
            #snapshot.tiers, buyUnits, expected, snapshot.evidence or "unavailable"))
    end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    S.snipePending = {
        deal = { id = r.itemID, link = r.link }, units = buyUnits,
        tolTotal = expected, maxUnit = line, expected = expected,
        requestUnitPrice = requestUnitPrice,
        walletCap = terms.walletCap, reserve = terms.reserve, t = GetTime(),
        market = r.market2, kind = terms.kind,
        offer = r.offer,
        attempt = S.purchaseSequence, timing = S.purchaseTiming(snapshot, source),
        remainder = snapshot and snapshot.remainder,
    }
    local pending = S.snipePending
    C_Timer.After(6, function()
        if S.snipePending ~= pending then return end
        retirePurchase("response timed out")
        buyFailUntil[r.itemID] = GetTime() + 10
        printf(pending.confirmed and "purchase outcome unknown; further buys are locked. Check mail and /fsn purchase." or "purchase quote timed out; nothing confirmed.")
        if S.feedRefresh then S.feedRefresh() end
    end)
    diagnostic("purchase request", string.format("attempt %d; item %d x%d; request unit %d copper; expected total %d copper",
        pending.attempt, r.itemID, buyUnits, requestUnitPrice, expected))
    local ok, e = pcall(C_AuctionHouse.StartCommoditiesPurchase, r.itemID, buyUnits, requestUnitPrice)
    if not ok then
        err("StartCommoditiesPurchase", e)
        -- A callback can submit the quote before the API raises. Never discard
        -- that confirmed owner's uncertainty or a newer purchase's state.
        if S.snipePending == pending then retirePurchase("purchase start API error") end
        buyFailUntil[r.itemID] = GetTime() + 10
        if db.unsettledPurchase then printf("purchase outcome unknown after API error; check /fsn purchase.")
        elseif pending.confirmed then printf("purchase callback already reported an outcome; the start API also raised an error.")
        else printf("purchase start failed; nothing confirmed.") end
        if S.feedRefresh then S.feedRefresh() end
        return
    end
    printf("one-press buy: %d x %s under %s/ea (~%s) - quote auto-confirms at or under the line.",
        buyUnits, r.link or ("item " .. r.itemID), fmtMoney(line), fmtMoney(expected))
end

-- KEY BINDINGS: the platform gives every purchase one hardware press - bind
-- it and the best open deal is one keystroke away (ForeverForge's "bind a
-- key to go faster"). /fsn bind buy <key> | /fsn bind skip <key>
-- LOT COMBINER: same-item deals merge into one affordable group. The
-- commodity purchase is Start(itemID, units) anyway, so three deals on one
-- item are one position at a blended price - and the wallet only counts
-- groups it can buy WHOLE (a partial wall can't be flipped: the rest of the
-- wall anchors the price at your cost)
local function collectDealGroups(forBuy)
    local walletCap = math.floor((GetMoney() or 0) * 0.95)
    local groups, order = {}, {}
    for _, cand in ipairs(S.deals) do
        if not cand.bought and not cand.gone and not select(3,S.exitPolicy(cand.id,cand.kind,cand.units,cand.cost,cand.market)) and num(cand.cost) and cand.cost > 0
            and num(cand.units) and cand.units > 0 and num(cand.unit) and cand.unit > 0 then
            local previous = groups[cand.id]
            -- Observations may overlap. Actual lots combine only from a
            -- single complete live tier list, never by adding snapshots.
            if not previous or (cand.t or 0) > (previous.t or 0) then groups[cand.id] = cand end
        end
    end
    local evaluated = {}
    for _, cand in pairs(groups) do
        local terms, reason = commodityOfferTerms(cand.id, cand.line, cand.units, cand.cost, cand.market, cand.kind)
        if (not forBuy or terms) and (terms and terms.cost or cand.cost) <= math.min(walletCap, cfg.maxSpend or 0)
            and time() - (cand.t or 0) <= 300 and not db.blacklist[cand.id]
            and reason ~= "budget" and reason ~= "profit" and reason ~= "empty" and reason ~= "invalid"
            and reason ~= "quality" and reason ~= "stackable" and reason ~= "overhang" then
            order[#order + 1] = cand
            evaluated[cand] = terms
        end
    end
    table.sort(order, function(a, b)
        return ((evaluated[a] or a).profit or 0) > ((evaluated[b] or b).profit or 0)
    end)
    return order, evaluated
end

local function feedBestBuy()
    -- the best affordable GROUP: highest total profit wins; items cooling
    -- down from a failed buy are skipped
    local order, evaluated = collectDealGroups(true)
    local retry = S.remainderRetry
    if retry and GetTime() >= retry.expires then retry = nil end
    local best
    for _, g in ipairs(order) do
        local cooling = buyFailUntil[g.id] and GetTime() < buyFailUntil[g.id]
        if not cooling and commodityFor(g.id) == true and (not retry or retry.id == g.id) then best = g break end
    end
    if not best then
        printf("no fresh deal to buy right now - the sweep is on it, press again in a moment.")
        return
    end
    local terms = evaluated[best]
    quickBuy({ itemID = best.id, link = best.link, line = terms.line or best.line, units = terms.units,
                cost = terms.cost, market2 = best.market, kind = best.kind, t = best.t, offer = best })
end
local function feedBestSkip()
    local d = collectDealGroups()[1]
    if not d then return end
    S.dismissDeal(d.id)
    for i = #S.deals, 1, -1 do
        if S.deals[i].id == d.id then
            table.remove(S.deals, i)
        end
    end
    refreshDealPresentation()
    printf("skipped the top deal.")
end
local bindBuyBtn = CreateFrame("Button", "ForeverSniperBestBuyBtn", UIParent)
S.buyBest = feedBestBuy
bindBuyBtn:SetScript("OnClick", function() feedBestBuy() end)
local bindSkipBtn = CreateFrame("Button", "ForeverSniperBestSkipBtn", UIParent)
bindSkipBtn:SetScript("OnClick", function() feedBestSkip() end)

local function recentGateReasons()
    local g = S.gateSummary
    if not g or not g.at or time() < g.at or time() - g.at >= 300 then return nil, {} end
    local reasons = {}
    for reason in pairs(g.counts) do reasons[#reasons + 1] = reason end
    table.sort(reasons, function(a, b)
        if g.counts[a] == g.counts[b] then return a < b end
        return g.counts[a] > g.counts[b]
    end)
    return g, reasons
end

local function historyReadiness()
    local now = time()
    local cached = S.historyReadiness
    if cached and now >= cached.at and now - cached.at < 5
        and cached.book == db.book and cached.need == cfg.armAfter and cached.age == cfg.freshMins then return cached end
    local ready, warming, stale = 0, 0, 0
    for _, b in pairs(db.book) do
        local median, count = freshMedian(b.s or {}, now, (cfg.freshMins or 45) * 60, cfg.armAfter)
        if median then ready = ready + 1
        elseif count > 0 then warming = warming + 1
        else stale = stale + 1 end
    end
    cached = {at=now, book=db.book, need=cfg.armAfter, age=cfg.freshMins,
        ready=ready, warming=warming, stale=stale}
    S.historyReadiness = cached
    return cached
end

local function feedOverview(visibleCount)
    local stage, guidance = "Scanning", "Complete positions only. Limits remain unchanged."
    local ready, readinessReason = throttleGate()
    if S.snipePending then
        stage, guidance = "Purchase pending", "Waiting for a quote or server outcome. No second purchase will start."
    elseif db.unsettledPurchase then
        stage, guidance = "BUY LOCKED", "Check mail, bags and gold, then use /fsn purchase to reconcile."
    elseif not S.ahOpen then
        stage, guidance = "Auction House closed", "Open the Auction House to resume scanning and buying."
    elseif not cfg.enabled then
        stage, guidance = "Scanner disabled", "Use /fsn on to resume. Buying is disabled."
    elseif S.scanning or S.harvestOwner or S.harvestTicker then
        stage = "Learning full snapshot"
    elseif S.deepScan then
        stage = "Deep discovery"
    elseif S.liveCandidate then
        stage = "Validating a complete position"
    elseif S.autoSearch or S.watchSearch then
        stage = "Checking live item tiers"
    elseif S.batchSearch then
        stage, guidance = "Waiting for batch summaries", "An owned summary request is in flight. Complete live tiers are still required before buying."
    elseif S.sweeping then
        stage = "Waiting for discovery results"
    elseif not ready then
        stage = readinessReason == "unavailable" and "AH readiness unavailable" or "Waiting for AH throttle"
        guidance = readinessReason == "unavailable"
            and "The readiness API failed or returned an unknown value. Searches remain paused for safety."
            or "The shared AH system is busy. This does not identify who caused the wait."
    elseif S.dealFocus and S.dealFocus.buyWindowUntil and GetTime() < S.dealFocus.buyWindowUntil then
        stage = "Buy opportunity"
    elseif lastQueryAt and GetTime() - lastQueryAt < queryPacing().interval then
        stage = "Scanner pacing"
    elseif countKeys(db.book) == 0 then
        stage = "Learning local prices"
    end
    if S.ahOpen and cfg.enabled and not S.snipePending and not db.unsettledPurchase and focusedDeal() then
        guidance = stage == "Buy opportunity"
            and "Routine searches briefly yield for your click. The live quote and all risk checks still apply."
            or "Discovery continues while the displayed deal receives bounded refresh priority."
    end
    local ss = S.sweepStats or {}
    local g, reasons = recentGateReasons()
    local decision = g and reasons[1] and string.format("Top recent decision: %s (%dx)", reasons[1], g.counts[reasons[1]])
        or "No recent decisions yet."
    local status = string.format(
        "|cffffd100%s|r | %d visible positions\nAuto checks %d/%d completed | discovery %d | rows %d | book %d\n%s\nCap %s | market floor %s | %d buys | spent %s | /fsn why",
        stage, visibleCount, ss.autoCompleted or 0, ss.autoSent or 0, ss.sent or 0, ss.rows or 0, countKeys(db.book),
        decision, fmtMoney(cfg.maxSpend or 0), fmtMoney(cfg.profit or 0), S.session.buys or 0, fmtMoney(S.session.spent or 0))
    local p = queryPacing()
    local history = historyReadiness()
    status = status .. string.format("\nFS search attempts %d/60s | routine spacing %.1fs | shared readiness waits %d",
        queryRequestCount(), p.interval, p.busyEpisodes)
    local progress = string.format("Live item checks %d/%d completed | %d individual targets | discovery %d\nFS search attempts %d/60s | routine spacing %.1fs",
        ss.autoCompleted or 0, ss.autoSent or 0, ss.autoUnique or 0, ss.sent or 0, queryRequestCount(), p.interval)
    local learning = string.format("Local history: %d ready | %d learning | %d stale\nLocal fallback needs %d time-spaced observations. Verified TSM references bypass warm-up.",
        history.ready, history.warming, history.stale, cfg.armAfter)
    local empty = "|cffffd100" .. stage .. "|r\n\nNo qualifying complete positions to show.\n" .. guidance
        .. "\n\n" .. progress .. "\n\n" .. learning
        .. "\n\n" .. decision .. "\nDecision counts include repeated checks, not unique listings."
        .. "\n\n/fsn why: filters and examples   |   /fsn status: scan progress\nLOAD waits for live validation. BUY starts one guarded purchase."
    return status, empty
end

local function refreshFeed()
    if not feedFrame or not feedFrame:IsShown() then feedDirty = true return end
    -- throttled: a burst of deals refreshes once per quarter second, not per alert
    local now = GetTime()
    if now - feedLastRefresh < 0.25 then
        feedDirty = true
        if not feedRefreshWake then
            local wake = {}
            feedRefreshWake = wake
            after(math.max(0.01, feedLastRefresh + 0.25 - now), function()
                if feedRefreshWake ~= wake then return end
                feedRefreshWake = nil
                if feedDirty then refreshFeed() end
            end)
        end
        return
    end
    feedRefreshWake = nil
    feedLastRefresh = now
    feedDirty = false
    -- COMBINE LOTS: same-item deals merge into one affordable group (the
    -- commodity buy is Start(itemID, units) anyway). Only groups the wallet
    -- can buy WHOLE are offered - a partial wall can't be flipped
    local order = collectDealGroups()
    for i = 1, FEED_ROWS do
        local row = feedRows[i]
        local d = order[i]
        if d then
            d.unit = d.units > 0 and math.floor(d.cost / d.units + 0.5) or 0
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
            row.kind = d.kind or (d.tier == "VENDOR" and "vendor") or (d.market and "market" or "watch")
            row.units, row.cost = d.units or 1, d.cost or nil
            row.positionProfit = d.profit
            row.offer = d
            row.gone = d.gone and true or nil
            -- the action label: what to DO with this deal
            if d.tier == "VENDOR" then
                row.action:SetText("|cffffd100VENDOR|r")
            elseif d.market and d.market > 0 then
                row.action:SetText("|cff7cff4fAH " .. fmtMoney(math.floor(d.market)) .. "|r")
            else
                row.action:SetText("|cff9d9d9dwatch|r")
            end
            row.buyBtn:SetShown(not d.bought and not d.gone)
            row.sellBtn:SetShown(not d.gone and row.kind ~= "vendor" and d.market ~= nil)
            local label, ready, hint = commodityActionState(d.id, d.link, d.line, d.units, d.cost, d.market, row.kind)
            row.buyBtn:SetEnabled(ready)
            row.buyBtn.fs:SetText(strupper(label))
            row.buyHint = hint
            if d.gone then
                row.action:SetText("|cff888888GONE|r")
                row.name:SetTextColor(0.45, 0.45, 0.45)
            elseif d.bought then
                row.name:SetTextColor(0.5, 0.5, 0.5)
            else
                -- freshness: bright = just spotted, dimmer as the deal ages
                local age = time() - (d.t or time())
                local sc = (age < 60) and 1 or ((age < 300) and 0.82 or 0.62)
                row.name:SetTextColor(sc, sc, sc)
            end
            row.t = d.t
            row:Show()
            local snapshot = S.commoditySnapshots[d.id]
            local timing = snapshot and snapshot.timing
            if ready and not d.gone and not d.bought and timing and timing.validatedAt and not timing.feedRenderedAt then
                -- UI submission time, not a screen-paint or player-observation timestamp.
                timing.feedRenderedAt = GetTime()
            end
        else
            row:Hide()
        end
    end
    local status, empty = feedOverview(math.min(#order, FEED_ROWS))
    if feedEmpty then
        feedEmpty:SetShown(#order == 0)
        feedEmpty:SetText(empty)
    end
    if feedStatus then
        feedStatus:SetText(status)
    end
end

-- Deferred redraws own their deadline independently of the scanner tick.
S.feedRefresh = refreshFeed -- runtime hook for code defined above the feed
function S.refreshBuyButtons()
    -- Readiness windows can be shorter than the full feed's repaint interval.
    -- Update only the existing rows, without rebuilding or changing their offers.
    for _, row in ipairs(feedRows) do
        if row:IsShown() and row.itemID then
            local label, ready, hint = commodityActionState(row.itemID, row.link, row.line,
                row.units, row.cost, row.market2, row.kind)
            row.buyBtn:SetEnabled(ready and not row.gone)
            row.buyBtn.fs:SetText(strupper(label))
            row.buyHint = hint
        end
    end
end
local function feedTick()
    retireSnipePresentation()
    S.refreshBuyButtons()
    if feedDirty or (S.ahOpen and GetTime() - feedLastRefresh >= 3) then
        refreshFeed()
        renderPopup()
    end
end

-- (markDealGone is defined above, next to quickBuy - the forward declaration
-- at the top of the file makes it visible to every caller)

-- SNIPE MODE (BilisFlippingCompanion-style): press SNIPE once, it hunts
-- with the sweep; when a deal lands it PAUSES and puts ONE deal in front of
-- you with BUY / SKIP. BUY executes from the lot snapshot the sweep just
-- gathered: commodity quote -> tolerance check (live total vs snapshot,
-- cfg.tolerance %) -> confirm rides the BUY press's intent; if the quote
-- exceeds tolerance it aborts instead of overpaying. SKIP resumes hunting.
S.snipe = { active = false, current = nil }

local function snipeResume()
    S.snipe.current = nil
end

local function snipeOffer(d)
    retireSnipePresentation()
    if not S.snipe.active or S.snipe.current then return end
    if not d or d.bought or d.gone or not d.id then return end
    -- Bilis-parity: snipe prompt is for commodity flips (snapshot buyable)
    local isComm = commodityFor(d.id)
    if not isComm then return end
    local _, ready = commodityActionState(d.id, d.link, d.line, d.units, d.cost, d.market, d.kind)
    if not ready then return end
    local terms = commodityOfferTerms(d.id, d.line, d.units, d.cost, d.market, d.kind)
    if not terms then return end
    S.snipe.current = d
    local units, cost, dep = terms.units, terms.cost, terms.reserve
    local f = buildConfirm()
    f.q = { snipeDeal = d, units = units,
            approved = {itemID=d.id, link=d.link, line=d.line, units=units,
                 cost=cost, market2=d.market, kind=offerKind(d.id, d.line, d.kind) or (d.market and "market" or "watch"), t=d.t, offer=d},
            tolTotal = math.floor(cost * (1 + (cfg.tolerance or 5) / 100)) }
    f.buy:SetText("BUY")
    f.cancel:SetText("SKIP")
    f.buy:SetScript("OnClick", function(self)
        local q = self:GetParent().q
        self:GetParent().q = nil
        self:GetParent():Hide()
        snipeResume()
        if not q or not q.snipeDeal then return end
        if q.snipeDeal.bought or q.snipeDeal.gone then return end
        quickBuy(q.approved)
    end)
    f.cancel:SetScript("OnClick", function(self)
        local q = self:GetParent().q
        if q and q.snipeDeal then S.dismissDeal(q.snipeDeal.id) end
        self:GetParent().q = nil
        self:GetParent():Hide()
        snipeResume()
        refreshDealPresentation()
    end)
    local profitText = terms.profit and ("est profit |cff7cff4f+" .. fmtMoney(terms.profit) .. "|r")
        or "Absolute watch: resale profit is not estimated."
    f.body:SetText(string.format(
        "|cffffd100SNIPE - COMPLETE POSITION|r\n%s\n%d units at %s average each\nbuy ~%s + deposit ~%s = ~%s out of pocket\n%s",
        d.link or ("item " .. d.id), units, fmtMoney(math.floor(cost / units)),
        fmtMoney(cost), fmtMoney(dep), fmtMoney(cost + dep), profitText))
    f:Show()
    retireSnipePresentation()
end

local function updateExistingDeal(itemID, link, unit, market, sweep)
    for i, d in ipairs(S.deals) do
        if d.id == itemID and not d.bought then
            -- Quiet rediscovery may replace a retired row, but must never
            -- reactivate approvals that still hold the old table.
            if d.gone then
                d = {id=itemID, link=d.link, bought=false}
                S.deals[i] = d
            end
            d.link, d.unit, d.market = link or d.link, unit, market
            d.units, d.cost, d.profit, d.line = sweep.units, sweep.cost, sweep.profit, sweep.line
            d.kind, d.t, d.gone = sweep.kind, time(), nil
            focusDeal(d)
            d.tier = sweep.kind == "vendor" and "VENDOR" or sweep.kind == "dump" and "DUMP" or tierOf(market, unit)
            for _, row in ipairs(popupRows) do
                if row.itemID == itemID then
                    row.units, row.cost, row.unit, row.market = sweep.units, sweep.cost, unit, market
                    row.line, row.t = sweep.line, time()
                    row.profit, row.kind = sweep.profit, sweep.kind
                end
            end
            return true
        end
    end
    return false
end

local function addDeal(tier, itemID, link, unit, market, sweep, isNew)
    if updateExistingDeal(itemID, link, unit, market, sweep) then refreshFeed() return end
    local deal = {
        id = itemID, link = link, unit = unit, market = market, tier = tier, kind = sweep and sweep.kind,
        profit = sweep and sweep.profit, units = sweep and sweep.units,
        cost = sweep and sweep.cost, line = sweep and sweep.line,
        isNew = isNew, t = time(), bought = false,
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
    focusDeal(deal)
    while #S.deals > MAX_FEED do table.remove(S.deals) end
    refreshFeed()
    snipeOffer(deal)
end

local function buildFeed()
    if feedFrame then return end
    local TITLE_H, HEADER_H = 32, 18
    local bodyTop = TITLE_H + HEADER_H + 6
    feedFrame = CreateFrame("Frame", "ForeverSniperFeed", UIParent)
    feedFrame:SetSize(FEED_W, bodyTop + FEED_ROWS * FEED_ROW_H + 110)
    feedFrame:SetPoint("LEFT", UIParent, "LEFT", 16, 0)
    feedFrame:SetMovable(true)
    feedFrame:EnableMouse(true)
    feedFrame:RegisterForDrag("LeftButton")
    tinsert(UISpecialFrames, "ForeverSniperFeed") -- ESC closes the feed
    -- Closing this window is temporary; it opens again on the next AH visit.
    feedFrame:SetClampedToScreen(true)
    feedFrame:SetScript("OnShow", function() refreshFeed() end)
    feedFrame:SetScript("OnDragStart", feedFrame.StartMoving)
    feedFrame:SetScript("OnDragStop", feedFrame.StopMovingOrSizing)
    local bg = feedFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints() bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)
    local title = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("|cffff7d0aForever Sniper|r - deals (profit first)")

    -- header-band buttons: one anchor each, no overlaps (Close / Clear / BUY ALL)
    local function bandBtn(width, xOff, text, cr, cg, cb, onClick)
        local btn = CreateFrame("Button", nil, feedFrame)
        btn:SetSize(width, 20) btn:SetPoint("TOPRIGHT", xOff, -6)
        local bbg = btn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints() bbg:SetColorTexture(0.14, 0.14, 0.18, 0.95)
        btn:SetScript("OnEnter", function() bbg:SetColorTexture(0.22, 0.22, 0.30, 1) end)
        btn:SetScript("OnLeave", function() bbg:SetColorTexture(0.14, 0.14, 0.18, 0.95) end)
        btn.fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.fs:SetAllPoints() btn.fs:SetText(text) btn.fs:SetTextColor(cr, cg, cb)
        btn:SetScript("OnClick", onClick)
        return btn
    end
    bandBtn(44, -6, "Close", 0.9, 0.9, 0.9, function() feedFrame:Hide() end)
    bandBtn(48, -54, "Clear", 1, 0.8, 0.6, function()
        S.clearFeedDeals()
        printf("feed cleared.")
    end)
    -- One complete commodity lot per hardware press.
    bandBtn(62, -106, "Buy best", 0.3, 1, 0.3, function() startBuyAll() end)
    bandBtn(62, -172, "Selling", 0.55, 0.75, 1, function() S.showSelling() end)

    -- column headers live in their own band and use the SAME internal
    -- offsets as the rows, so label and column can never drift apart
    local hh = CreateFrame("Frame", nil, feedFrame)
    hh:SetSize(FEED_W - 16, HEADER_H)
    hh:SetPoint("TOPLEFT", feedFrame, "TOPLEFT", 8, -TITLE_H - 4)
    local function col(x, w, label, right)
        local h = hh:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        h:SetPoint("LEFT", x, 0) h:SetWidth(w or 60)
        h:SetJustifyH(right and "RIGHT" or "LEFT")
        h:SetTextColor(0.55, 0.55, 0.6)
        h:SetText(label)
    end
    col(60, 150, "item")
    col(213, 70, "avg/unit", true)
    col(286, 70, "exit ref", true)
    col(359, 28, "off", true)
    col(390, 48, "tier")
    col(443, 78, "est net", true)
    local act = hh:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    act:SetPoint("RIGHT", -80, 0) act:SetWidth(58) act:SetJustifyH("RIGHT")
    act:SetTextColor(0.55, 0.55, 0.6) act:SetText("action")
    local divider = feedFrame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 8, -TITLE_H - HEADER_H - 4)
    divider:SetSize(FEED_W - 16, 1)
    divider:SetColorTexture(0.28, 0.28, 0.34, 0.9)

    feedRows = {}
    for i = 1, FEED_ROWS do
        local row = CreateFrame("Button", nil, feedFrame)
        row:SetSize(FEED_W - 16, FEED_ROW_H)
        row:SetPoint("TOPLEFT", feedFrame, "TOPLEFT", 8, -bodyTop - (i - 1) * FEED_ROW_H)
        local rbg = row:CreateTexture(nil, "BACKGROUND")
        rbg:SetAllPoints()
        local stripe = (i % 2 == 0)
        rbg:SetColorTexture(0.07, 0.07, 0.10, stripe and 0.6 or 0.35)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20) row.icon:SetPoint("LEFT", 2, 0)
        row.newBadge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.newBadge:SetPoint("LEFT", 26, 0) row.newBadge:SetText("|cffff4444NEW|r")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", 60, 0) row.name:SetWidth(150)
        row.name:SetJustifyH("LEFT") row.name:SetWordWrap(false)
        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("LEFT", 213, 0) row.price:SetWidth(70) row.price:SetJustifyH("RIGHT")
        row.market = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.market:SetPoint("LEFT", 286, 0) row.market:SetWidth(70) row.market:SetJustifyH("RIGHT")
        row.pct = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.pct:SetPoint("LEFT", 359, 0) row.pct:SetWidth(28) row.pct:SetJustifyH("CENTER")
        row.tier = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.tier:SetPoint("LEFT", 390, 0) row.tier:SetWidth(48)
        row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.profit:SetPoint("LEFT", 443, 0) row.profit:SetWidth(78) row.profit:SetJustifyH("RIGHT")
        row.action = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.action:SetPoint("RIGHT", -80, 0) row.action:SetWidth(58) row.action:SetJustifyH("RIGHT")
        row.sellBtn = CreateFrame("Button", nil, row)
        row.sellBtn:SetSize(36, 18) row.sellBtn:SetPoint("RIGHT", -44, 0)
        local sbg = row.sellBtn:CreateTexture(nil, "BACKGROUND")
        sbg:SetAllPoints() sbg:SetColorTexture(0.15, 0.25, 0.45, 0.9)
        row.sellBtn.fs = row.sellBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.sellBtn.fs:SetAllPoints() row.sellBtn.fs:SetText("SELL")
        row.sellBtn.fs:SetTextColor(0.55, 0.75, 1)
        row.sellBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Prepare sale")
            GameTooltip:AddLine("Fills the native AH item, quantity, price and duration. Review, then click Post to list.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row.sellBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.sellBtn:SetScript("OnClick", function(self)
            local r = self:GetParent()
            if r.kind == "vendor" then
                printf("this is a vendor exit - sell it at a merchant, not the Auction House.")
                return
            end
            if r.itemID and r.market2 then
                local isComm = commodityFor(r.itemID)
                local sp, tr, why = smartPrice(r.itemID, r.market2, isComm)
                if why then printf("|cff888888%s.|r", why) end
                sellAt(r.itemID, sp, true)
            end
        end)
        row.buyBtn = CreateFrame("Button", nil, row)
        row.buyBtn:SetSize(36, 18) row.buyBtn:SetPoint("RIGHT", -4, 0)
        local bbg = row.buyBtn:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints() bbg:SetColorTexture(0.15, 0.4, 0.15, 0.9)
        row.buyBtn.fs = row.buyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.buyBtn.fs:SetAllPoints() row.buyBtn.fs:SetText("BUY")
        row.buyBtn.fs:SetTextColor(0.3, 1, 0.3)
        row.buyBtn:SetScript("OnClick", function(self)
            quickBuy(self:GetParent())
        end)
        row:SetScript("OnClick", function(self)
            if self.itemID then searchListing(self.itemID, self.link, nil) end
        end)
        -- hover: highlight + item tooltip (what it is, what it's worth)
        row:SetScript("OnEnter", function(self)
            rbg:SetColorTexture(0.16, 0.16, 0.22, 0.9)
            if not self.itemID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.link then GameTooltip:SetHyperlink(self.link) else GameTooltip:SetItemByID(self.itemID) end
            addPositionTooltip(self.units, self.cost, self.line, self.market2, self.positionProfit, self.itemID)
            local volatility = bookVolatility(self.itemID)
            if volatility then
                GameTooltip:AddLine(string.format("observed price variation: %.0f%% (not expected profit)", volatility * 100), 0.7, 0.7, 0.7)
            end
            local pace = soldPaceOf(self.itemID)
            if pace then
                GameTooltip:AddLine("estimated stock decline rate ~" .. pace .. "/day (not confirmed sales)", 0.7, 0.7, 0.7)
            end
            local vel = absorbVelocity(self.itemID)
            if vel then
                GameTooltip:AddLine(string.format("observed below-line disappearance: %.0fs average (not sale time)", vel), 0.7, 0.7, 0.7)
            end
            if self.t then
                GameTooltip:AddLine("spotted: " .. math.floor((time() - self.t) + 0.5) .. "s ago", 0.55, 0.55, 0.55)
            end
            GameTooltip:AddLine("click: search it in the AH", 0.55, 0.55, 0.55)
            if self.buyHint then GameTooltip:AddLine(self.buyHint, 1, 0.82, 0.3, true) end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            rbg:SetColorTexture(0.07, 0.07, 0.10, stripe and 0.6 or 0.35)
            GameTooltip:Hide()
        end)
        row:Hide()
        feedRows[i] = row
    end

    feedEmpty = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    feedEmpty:SetPoint("CENTER", feedFrame, "CENTER", 0, 8)
    feedEmpty:SetWidth(FEED_W - 60)
    feedEmpty:SetJustifyH("CENTER")
    feedEmpty:SetText("|cffbbbbbbNo validated deals yet.|r\n\nThe scanner learns local prices and checks complete affordable positions.\nUse |cffffd100/fsn status|r for progress or |cffffd100/fsn why|r for discovery filters.\n|cff888888LOAD prepares live tiers. BUY starts one guarded purchase. No hits does not mean you should loosen your limits.|r")

    feedStatus = feedFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    feedStatus:SetPoint("BOTTOMLEFT", 10, 6)
    feedStatus:SetWidth(FEED_W - 20)
    feedStatus:SetHeight(100)
    feedStatus:SetJustifyH("LEFT")
    feedStatus:SetTextColor(0.55, 0.55, 0.6)
    feedStatus:SetText("|cff888888the sweep starts when the auction house opens - deals land here, best profit first.|r")
end
local function alertDeal(tier, itemID, link, unit, market, sweep, isNew)
    -- cosmetic functions are pcall'd: a sound/flash/toast failure must
    -- NEVER block addDeal - the deal is the point, the cosmetics are sugar
    pcall(playTierSound, tier)
    pcall(flashScreen, tier)
    pcall(showToast, tier, itemID, unit, market, sweep and sweep.profit)
    addDeal(tier, itemID, link, unit, market, sweep, isNew)
end

-- Bounded five-minute diagnostic windows include automatic checks as well as
-- browse discovery. Counts are decisions/observations, not unique auctions.
local function recordGate(source, reason, itemID, extra)
    local now = time()
    local g = S.gateSummary
    if not g or now < g.at or now - g.at >= 300 then
        g = {at=now, counts={}, examples={}}
        S.gateSummary = g
    end
    local key = source .. ": " .. reason
    g.counts[key] = (g.counts[key] or 0) + 1
    if itemID then
        g.examples[key] = (infoOf(itemID).name or ("item " .. itemID)) .. (extra or "")
    end
end

local function fireAlert(kind, itemID, link, unit, market, sweep, isNew)
    if not cfg.enabled or db.blacklist[itemID] then return end
    local _, _, salesReason = S.exitPolicy(itemID, kind, sweep and sweep.units, sweep and sweep.cost, market)
    if salesReason then recordGate("offer", salesReason, itemID) return end
    if (kind == "market" or kind == "dump") and (not sweep or (num(sweep.profit) or 0) < math.max(1, cfg.profit or 0)) then
        recordGate("offer", "estimated net below floor", itemID)
        return
    end
    unit = num(unit)
    if sweep then
        sweep.units, sweep.cost = num(sweep.units), num(sweep.cost)
    end
    -- SANITY GATE: no 0c deals, no 0-unit lots, no nil prices. Every deal
    -- source funnels through here - this one guard blocks garbage from
    -- browse rows, search results, watch rules, the dump detector, the
    -- vendor flip and the replicate scan alike.
    if not itemID then return end
    if not unit or unit < 1 then return end
    if not sweep or not sweep.units or sweep.units < 1 then return end
    if not sweep.cost or sweep.cost < 1 then return end
    if not sweep.verified then
        -- Browse quantity includes expensive tiers. Validate live depth
        -- before exposing an actionable lot or claiming its profit.
        S.liveCandidates = S.liveCandidates or {}
        local queued = S.liveCandidates[itemID]
        if queued and queued.remainder then return end
        local detectedAt = GetTime()
        if queued then detectedAt = queued.detectedAt end
        S.liveCandidates[itemID] = { kind = kind, id = itemID, link = link,
            line = sweep.line or unit, market = market, profit = sweep.profit,
            detectedAt = detectedAt,
            t = queued and queued.t or GetTime(), refresh = queued and queued.refresh,
            prebuy = queued and queued.prebuy, forceSearch = queued and queued.forceSearch }
        if not queued then recordGate("offer", "queued for live tiers", itemID) end
        return
    end
    recordGate("offer", "validated position", itemID)
    sweep.kind = kind
    if updateExistingDeal(itemID, link, unit, market, sweep) then
        local observed = S.observedOffers and S.observedOffers[itemID]
        if observed and observed.returned and observed.price == unit then
            observed.absent, observed.returned, observed.at = nil, nil, time()
            S.seen[tostring(itemID) .. ":" .. tostring(unit)] = observed.at
        end
        refreshFeed()
        renderPopup()
    end
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
    S.seen[tostring(itemID) .. ":" .. tostring(unit)] = now
    S.observedOffers = S.observedOffers or {}
    S.observedOffers[itemID] = {price=unit, at=now}

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
    if kind == "vendor" then
        action = "|cffffd100vendor value reference|r - no AH relist assumed"
    elseif market and market > 0 then
        action = "|cffffd100AH resale reference " .. fmtMoney(math.floor(market)) .. "|r - resale is not guaranteed"
    else
        action = "|cff9d9d9dyour watch rule|r"
    end
    do -- the Bilis module is gone: this feed always presents its deals
        if market and market > 0 then
            printf("|cffff4d00DEAL|r %s - |cffffd100%d units|r at or under %s: |cffffd100%s total|r (avg %s, resale reference %s); estimated net %s. %s",
                label, sweep.units, fmtMoney(sweep.line or unit), fmtMoney(sweep.cost),
                fmtMoney(math.floor(sweep.cost / sweep.units + 0.5)), fmtMoney(market),
                fmtMoney(sweep.profit or 0), action)
        else
            if sweep.units > 1 then
                printf("|cffff4d00DEAL|r %s - |cffffd100%d units|r at or under %s: |cffffd100%s total|r (|cff9d9d9dwatch rule|r)",
                    label, sweep.units, fmtMoney(unit), fmtMoney(sweep.cost))
            else
                printf("|cffff4d00DEAL|r %s - %s  (|cff9d9d9dwatch rule|r)", label, fmtMoney(unit))
            end
        end
        playAlertSound()
    end

    -- WoWSniper-parity: tiered sound/flash/toast + the deal feed
    local tier = (kind == "vendor") and "VENDOR" or (kind == "dump") and "DUMP" or tierOf(market, unit)
    alertDeal(tier, itemID, link, unit, market, sweep, isNew)

    if cfg.popup then
        for i = #popupRows, 1, -1 do
            if popupRows[i].itemID == itemID then table.remove(popupRows, i) end
        end
        local icon
        local ok, iid, _, _, _, iconFile
        if C_Item and C_Item.GetItemInfoInstant then
            ok, iid, _, _, _, iconFile = pcall(C_Item.GetItemInfoInstant, link or itemID)
        else
            ok, iid, _, _, _, iconFile = pcall(GetItemInfoInstant, link or itemID)
        end
        if ok and iconFile then icon = iconFile end
        table.insert(popupRows, 1, {
            itemID = itemID, link = link, label = label, unit = unit,
            market = market, icon = icon, t = time(),
            units = sweep.units, cost = sweep.cost, profit = sweep.profit,
            line = sweep.line or unit, kind = kind,
        })
        while #popupRows > 10 do table.remove(popupRows) end
        renderPopup()
    end
end

-- The scan ------------------------------------------------------------------------

function S.stopSnapshot()
    local ticker = S.harvestTicker
    S.harvestTicker, S.scanning, S.replicateRequest, S.deepScanPending = nil, false, nil, nil
    S.harvestOwner, S.harvestProgress = nil, nil
    if ticker then ticker:Cancel() end
end

function S.resumeDeferredDeepScan()
    if not S.deepScanPending then return end
    S.deepScanPending = nil
    if cfg.enabled and S.ahOpen then startDeepScan(true) end
end

local function completeScan(reason)
    if not S.scanning then return end
    local owner = {}
    S.harvestOwner = owner
    S.scanning = false
    S.replicateRequest = nil
    S.lastScan = time()

    local n = 0
    do
        local ok, v = pcall(C_AuctionHouse.GetNumReplicateItems)
        if ok then n = math.floor(num(v) or 0) end
    end
    if S.harvestOwner ~= owner then return end
    if n <= 0 then
        S.harvestOwner, S.harvestProgress = nil, nil
        err("scan", "completed with 0 listings via " .. tostring(reason))
        if S.ahOpen then after(cfg.every, requestReplicate) end
        S.resumeDeferredDeepScan()
        return
    end
    S.harvestProgress = {processed=0, total=n}

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
    -- (the deferred deep scan at the tail calls the global startDeepScan,
    -- assigned by the engine further down this file)
    local function finishScan()
    if S.harvestOwner ~= owner then return end

    -- Market deals: a new listing below the trusted reference's deal ceiling. The
    -- whole depth under that line is swept (every unit of every cheap listing,
    -- so stackables come as one lot), and the deal only fires if the estimated
    -- resale profit - market after the AH cut, minus cost - clears the floor.
    local deals = 0
    do -- Trusted references can qualify candidates on the first full snapshot.
        for _, c in ipairs(cands) do
            if not db.blacklist[c.id] and c.unit >= cfg.minUnit then
                local med = S.marketReference(c.id, t)
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
                            db.watch[tostring(c.id)] = w
                            db.watch["n:" .. name] = nil
                        end
                    end
                end
                local ceiling = w and watchMaxFor(c.id, w)
                if ceiling and c.unit <= ceiling then
                    local units, cost = 0, 0
                    for _, L in ipairs(depth[c.id] or {}) do
                        if L.unit <= ceiling then
                            units = units + L.count
                            cost = cost + L.count * L.unit
                        end
                    end
                    if units == 0 then units, cost = c.count or 1, c.unit end
                    fireAlert("watch", c.id, c.link, c.unit, nil,
                        { units = units, cost = cost, line = ceiling })
                    deals = deals + 1
                end
            end
        end
    end

    -- Learn last so this scan's own deals cannot drag the median toward themselves.
    if S.harvestOwner ~= owner then return end
    mergeIntoBook(curMins, t)

    S.prevList = curSeen
    S.scansDone = S.scansDone + 1
    db.stats.scans = S.scansDone
    db.stats.lastScan = t
    db.stats.lastListings = n
    db.stats.book = countKeys(db.book)
    S.replicateLearned = true
    S.harvestOwner, S.harvestProgress = nil, nil

    if not cfg.quiet and (firstScan or deals > 0) then
        if firstScan then
            printf("scan 1 done: %d listings, %d items learned. Verified TSM references are live; local fallback needs %d time-spaced observations.",
                n, db.stats.book, cfg.armAfter)
        else
            printf("scan %d: %d listings, %d new, %d deal%s.", S.scansDone, n, #cands, deals, deals == 1 and "" or "s")
        end
    end

    if S.ahOpen then after(900, requestReplicate) end
    -- a deep scan that was deferred for this dump runs now, on fresh data
    S.resumeDeferredDeepScan()
    end -- finishScan

    -- 250 rows per tick, Auctionator's ProcessBatch cadence
    local rowIndex = 0
    local function harvestBatch()
        local step = 0
        while rowIndex < n and step < 250 do
            if S.harvestOwner ~= owner then return end
            rowIndex = rowIndex + 1
            local i = rowIndex
            local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18 =
                pcall(C_AuctionHouse.GetReplicateItemInfo, i)
            if S.harvestOwner ~= owner then return end
            if not ok then
                err("replicate:" .. i, a1)
            else
                local itemID, count, buyout, link, quality
                if foreverLayout then
                    itemID, count, buyout = num(a17), num(a3), num(a10)
                    if C_AuctionHouse.GetReplicateItemLink then
                        local okL, l = pcall(C_AuctionHouse.GetReplicateItemLink, i)
                        if S.harvestOwner ~= owner then return end
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
        S.harvestProgress.processed = rowIndex
        return rowIndex >= n
    end
    local done = harvestBatch()
    if S.harvestOwner ~= owner then return end
    if done then
        finishScan()
    else
        local ticker
        ticker = C_Timer.NewTicker(0, function()
            if S.harvestOwner ~= owner then ticker:Cancel() return end
            local finished = harvestBatch()
            if S.harvestOwner ~= owner then ticker:Cancel() return end
            if finished then
                ticker:Cancel()
                if S.harvestTicker == ticker then S.harvestTicker = nil end
                finishScan()
            end
        end)
        S.harvestTicker = ticker
    end
end

-- Scan engine, mirroring Auctionator's server-proven shape:
--   * one request per 15 minutes of our own (CanInitiate cooldown)
--   * completion events finish the scan; a bounded wait releases live sweeps
--     if the snapshot never arrives, without bypassing the request cooldown
--   * pre-check: harvest data another addon already delivered instead of
--     requesting over it (a fresh request clears the delivered rows and the
--     server grants one list per session - live-traced 2026-10-11)
--   * rows are harvested in 250-row batches (Auctionator's ProcessBatch)
local SCAN_COOLDOWN = 15 * 60

function requestReplicate()
    if not cfg.enabled or not S.ahOpen or S.scanning or S.harvestOwner or S.harvestTicker or S.deepScan then return end
    if focusedDeal() then return end
    if S.nativeSellActive() then return end
    if S.snipePending or db.unsettledPurchase or S.pending or S.buying or S.quote
        or S.autoSearch or S.watchSearch or S.liveCandidate or S.batchSearch or not throttleGate() then return end
    if C_AuctionHouse == nil then return end
    if S.lastScan and time() - S.lastScan < math.min(cfg.every, 60) then return end
    local okN, n = pcall(C_AuctionHouse.GetNumReplicateItems)
    n = okN and math.floor(num(n) or 0) or 0
    if n > 0 and not S.replicateLearned then
        dbg("replicate data present: n=" .. n .. " - harvesting, no new request")
        local request = {}
        S.replicateRequest, S.scanning = request, true
        after(3, function()
            -- let an in-flight delivery settle; the event may beat the timer
            if S.replicateRequest == request and S.scanning then completeScan("present") end
        end)
        return true
    end
    if S.lastRequest and time() - S.lastRequest < SCAN_COOLDOWN then
        dbg("request cooldown: " .. (time() - S.lastRequest) .. "s since last, waiting for the event or other data")
        return
    end
    S.lastRequest = time()
    local request = {}
    S.replicateRequest, S.scanning = request, true
    local ok, e = pcall(C_AuctionHouse.ReplicateItems)
    dbg("ReplicateItems: ok=" .. tostring(ok) .. " ret=" .. tostring(e))
    if not ok then
        err("ReplicateItems", e)
        -- A throwing client call may already have submitted the request. Keep
        -- its cooldown, and never retire an owner installed by a callback.
        if S.replicateRequest == request then S.replicateRequest, S.scanning = nil, false end
        recordGate("snapshot", "request failed", nil)
        return
    end
    after(20, function()
        if S.replicateRequest ~= request or not S.scanning then return end
        S.replicateRequest, S.scanning = nil, false
        if not cfg.enabled or not S.ahOpen then return end
        printf("initial price snapshot did not arrive within 20s - resuming live sweeps.")
        S.resumeDeferredDeepScan()
    end)
    return true
end


-- scanner monitor: the always-visible heartbeat page (WoWSniper's scan view) --
-- Auto-shows with the AH: what the sniper is doing RIGHT NOW - sweeping,
-- paused (and why), counters, and the last category hunted. If this window
-- is quiet, something is wrong; /fsn says the same in text.
local scanPage, scanPageLines, scanPageStats

local function buildScanPage()
    if scanPage then return end
    scanPage = CreateFrame("Frame", "ForeverSniperScanPage", UIParent)
    scanPage:SetSize(344, 152)
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
    -- status line (colored by state) + a divider under it
    scanPageLines = {}
    scanPageLines[1] = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scanPageLines[1]:SetPoint("TOPLEFT", 12, -28)
    scanPageLines[1]:SetWidth(320)
    scanPageLines[1]:SetJustifyH("LEFT")
    scanPageLines[1]:SetText("|cff888888...|r")
    local divider = scanPage:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 12, -46)
    divider:SetSize(320, 1)
    divider:SetColorTexture(0.28, 0.28, 0.34, 0.9)
    -- stat grid: three rows of label-over-value cells, aligned in columns
    scanPageStats = {}
    local labels = {
        { "sweeps", "rows read", "yields" },
        { "book items", "deals", "buys" },
        { "committed", "submitted", "watch rules" },
    }
    for rowI = 1, 3 do
        for colI = 1, 3 do
            local x = 12 + (colI - 1) * 110
            local lab = scanPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lab:SetPoint("TOPLEFT", x, -54 - (rowI - 1) * 32)
            lab:SetTextColor(0.55, 0.55, 0.6)
            lab:SetText(labels[rowI][colI])
            local val = scanPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            val:SetPoint("TOPLEFT", x, -67 - (rowI - 1) * 32)
            val:SetWidth(100)
            val:SetJustifyH("LEFT")
            val:SetTextColor(1, 0.82, 0.3)
            scanPageStats[(rowI - 1) * 3 + colI] = val
        end
    end
end

local function updateScanPage()
    if not scanPage or not scanPage:IsShown() then return end
    local ss = S.sweepStats or { sent = 0, rows = 0, yields = 0 }
    local statusText, r, g, b
    if db.unsettledPurchase and not S.snipePending then
        statusText = "BUYING LOCKED - check /fsn purchase"
        r, g, b = 1, 0.35, 0.3
    elseif S.snipePending then
        statusText = S.snipePending.confirmed and "PURCHASE SUBMITTED - awaiting result" or "BUY QUOTE - awaiting price"
        r, g, b = 1, 0.82, 0.3
    elseif not cfg.enabled then
        statusText = "DISABLED - /fsn on to resume"
        r, g, b = 0.55, 0.55, 0.55
    elseif S.ahOpen and S.nativeSellActive() then
        statusText = "SELL FORM - review fields, then click Post"
        r, g, b = 1, 0.82, 0.3
    elseif S.scanning or S.harvestOwner or S.harvestTicker then
        statusText = S.harvestTicker and "LEARNING - harvesting full snapshot" or "LEARNING - waiting for full snapshot"
        if S.harvestProgress then
            statusText = string.format("LEARNING - snapshot %d / %d rows", S.harvestProgress.processed, S.harvestProgress.total)
        end
        r, g, b = 0.4, 0.8, 1
    elseif S.deepScan then
        statusText = string.format("DEEP SCAN - %s (page %d, %d rows)",
            S.deepScan.cat.name, S.deepScan.pages or 0, S.deepScan.rows or 0)
        r, g, b = 0.4, 0.8, 1
    elseif not S.ahOpen then
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
    scanPageStats[1]:SetText(tostring(ss.sent or 0))
    scanPageStats[2]:SetText(tostring(ss.rows or 0))
    scanPageStats[3]:SetText(tostring(ss.yields or 0))
    scanPageStats[4]:SetText(tostring(db.stats.book or 0))
    scanPageStats[5]:SetText(tostring(db.stats.deals or 0))
    scanPageStats[6]:SetText(tostring(S.session.buys or 0))
    scanPageStats[7]:SetText(fmtMoney(S.session.spent or 0))
    scanPageStats[8]:SetText(tostring(S.session.postSubmitted or 0))
    scanPageStats[9]:SetText(tostring(countKeys(db.watch)))
end

-- Owned-listing price checks are advisory. Only an explicitly armed command
-- can request cancellations; the learned median is not a live undercut quote.
local undercutTicker
local function checkUndercuts()
    if not S.ahOpen or not cfg.undercut then return end
    if focusedDeal() then return end
    if GetTime() - (S.lastUndercutQuery or 0) < 1.0 then return end
    -- Share ownership, native-form protection and spacing with manual refresh.
    if S.requestSellingOwned() then S.lastUndercutQuery = GetTime() end
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
do
    local weights, total = {}, 0
    for i, cat in ipairs(SCAN_CATEGORIES) do weights[i], total = 0, total + cat.priority end
    -- Smooth weighted rotation avoids spending consecutive discovery slots on
    -- the same class while preserving each class's share of a full pass.
    for slot = 1, total do
        local best
        for i, cat in ipairs(SCAN_CATEGORIES) do
            weights[i] = weights[i] + cat.priority
            if not best or weights[i] > weights[best] then best = i end
        end
        rotationList[slot] = SCAN_CATEGORIES[best]
        weights[best] = weights[best] - total
    end
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

if db.boughtAt == nil then db.boughtAt = S.boughtAt end -- one table, two views
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
local function isNewListing(itemID, price)
    local k = tostring(itemID) .. ":" .. tostring(price)
    -- Admission, not an unvalidated browse sighting, starts the quiet period.
    -- A rejected/too-large wall may become affordable at the same unit price.
    return not S.seen[k] or time() - S.seen[k] >= 60
end

-- Only a complete, membership-checked batch can treat an omitted key as absent.
-- Keep the alert cooldown; re-arm validation only on a witnessed floor return.
function S.observeBatchFloor(id, floor)
    local o = S.observedOffers and S.observedOffers[id]
    if not o then return end
    if time() - o.at >= 60 then
        S.observedOffers[id] = nil
    elseif not floor or floor > o.price then
        o.absent = true
    elseif o.absent and floor == o.price then
        S.seen[tostring(id) .. ":" .. tostring(floor)] = nil
        o.absent, o.returned = nil, true
    end
end

-- request the client to cache an item's info; quality checks pass next sweep
requestItemLoad = function(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local throttleReady, pagePending = true, false
lastQueryAt = 0
local sweepCount, watchCursor = 0, 0
S.sweepStats = { sent = 0, rows = 0, yields = 0, lastRows = 0 }

function S.noteRevisit(id)
    S.checkedAt = S.checkedAt or {}
    S.revisitByID = S.revisitByID or {}
    local now, previous = GetTime(), S.checkedAt[id]
    local stats = S.sweepStats
    if previous then
        stats.revisitLast = math.max(0, now - previous)
        S.revisitByID[id] = stats.revisitLast
        stats.revisitMax = math.max(stats.revisitMax or 0, stats.revisitLast)
        stats.revisitCount = (stats.revisitCount or 0) + 1
        stats.revisitTotal = (stats.revisitTotal or 0) + stats.revisitLast
    end
    S.checkedAt[id] = now
end

S.autoChecked = {}
local function nextAutoTarget(pool, cooldown)
    local now, best, bestScore = time(), nil, nil
    local budget = S.purchaseBudget()
    for rawID in pairs(pool or db.book) do
        local b = db.book[rawID] or {}
        local id = tonumber(rawID)
        local commodity = id and commodityFor(id)
        if pool and id and commodity == nil then requestItemLoad(id) end
        if id and not watchByID[id] and not db.blacklist[id] and commodity == true then
            local market = S.marketReference(id, now)
            local line = market and dealLine(market, id)
            local elapsed = GetTime() - (S.autoChecked[id] or -60)
            local eligible = market and market >= cfg.minUnit and line <= budget and elapsed >= (cooldown or 10)
            local info = eligible and infoOf(id)
            if info and info.stackable ~= false and (info.quality == -1 or info.quality >= (cfg.quality or 1)) then
                -- Depletion is demand evidence, not confirmed sales. Aging keeps
                -- less active items in rotation rather than starving them forever.
                local velocity = absorbVelocity(id)
                local movement = movementScore(id, now)
                if velocity and velocity > 0 and #(b.v or {}) >= 2
                    and b.velocityAt and now >= b.velocityAt and now - b.velocityAt <= 1800 then
                    movement = movement + math.min(4, 300 / velocity)
                end
                local samples = b.s or {}
                local stamp, price = num(samples[#samples - 1]), num(samples[#samples])
                local proximity = 1
                if stamp and stamp <= now and now - stamp <= 120 and price and price > 0 then
                    -- A recent near-line sighting merits a recheck, not approval.
                    -- Bound the boost so aging can still bring other items forward.
                    proximity = 1 + 2 * math.max(0, math.min(1, (market - price) / math.max(1, market - line)))
                end
                local score = elapsed * (1 + movement + math.min(3, math.log(1 + market / 10000))) * proximity
                if not bestScore or score > bestScore or (score == bestScore and id < best.id) then
                    best = {id=id, market=market, line=line}
                    bestScore = score
                end
            end
        end
    end
    return best
end

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

-- Querying while Blizzard's own browse tab is up can crash its ScrollBox.
-- THE TRUTH about "is the user on it": the selected TAB, not frame flags.
-- Auctionator's tab set keeps other pages marked shown/visible, so frame
-- checks false-positived and paused the sweep permanently. The Browse page
-- is tab 1 ("Buy") - any other selected tab is safe to query under.
local function blizzardBrowseActive()
    local ahf = AuctionHouseFrame
    if not (ahf and ahf.IsShown and ahf:IsShown()) then return false end
    local sel = ahf.selectedTab
    if sel and sel ~= 1 then return false end -- another tab is up: safe
    local brf = ahf.BrowseResultsFrame
    return (brf and brf.IsVisible and brf:IsVisible()) and true or false
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

canQuery = function(paging, urgent)
    if not cfg.enabled or not S.ahOpen then return false end
    if S.batchSearch then return false end
    if S.nativeSellActive() then return false end
    if S.scanning or S.harvestOwner or S.harvestTicker then return false end
    if S.snipePending or db.unsettledPurchase or S.quote or (S.batchBuy and S.batchBuy.pending) then return false end
    local ready = throttleGate()
    observeQueryPressure(not ready)
    if not ready then return false end
    if pagePending and not paging then
        if GetTime() - lastQueryAt < 5 then return false end
        pagePending = false -- dropped browse request: allow a fresh query
    end
    -- The live API is authoritative. Shared SENT/QUEUED events can leave the
    -- cached flag false when a ready event is missing or arrives out of order.
    throttleReady = true
    if (not urgent and GetTime() - lastQueryAt < queryPacing().interval)
        or GetTime() < S.queryReadyAt(urgent) then
        S.wakeSweep()
        return false
    end
    return true
end

local function sendTargetSearch(field, target)
    target.t = GetTime()
    target.searchStartedAt = target.t
    if field == "liveCandidate" and target.detectedAt then
        local stats = S.sweepStats
        stats.queueLast = math.max(0, target.t - target.detectedAt)
        stats.queueMax = math.max(stats.queueMax or 0, stats.queueLast)
    end
    target.commodity = commodityFor(target.id)
    S[field] = target
    noteQueryAttempt()
    -- Own the request before invoking the client: custom clients can deliver
    -- a cached response synchronously from RefreshCommoditySearchResults.
    local ok, e = pcall(requestItemSearch, target.id, target.commodity, true, target.prebuy ~= nil or target.forceSearch == true)
    if not ok then
        if S[field] == target then S[field] = nil end
        err("target search", e)
        recordGate("search", "request failed", target.id)
    end
    return ok
end

local function discoveryScope(cat)
    S.discoveryScopes = S.discoveryScopes or {}
    local state = S.discoveryScopes[cat.classID]
    if not state then state = {visits=0, cursor=0, sorts={}}; S.discoveryScopes[cat.classID] = state end
    state.visits = state.visits + 1
    local filter, label = {classID=cat.classID}, cat.name
    if state.visits % 2 == 0 and type(C_AuctionHouse.GetAuctionItemSubClasses) == "function" then
        local ok, values = pcall(C_AuctionHouse.GetAuctionItemSubClasses, cat.classID)
        local ids, seen = {}, {}
        if ok and type(values) == "table" then
            for _, value in ipairs(values) do
                local id = num(value)
                if id and id >= 0 and id % 1 == 0 and not seen[id] then
                    ids[#ids + 1] = id; seen[id] = true
                end
            end
        end
        table.sort(ids)
        if #ids > 0 then
            state.cursor = state.cursor % #ids + 1
            filter.subClassID = ids[state.cursor]
            label = label .. " / subclass " .. filter.subClassID
        end
    end
    local key = filter.subClassID or "all"
    state.sorts[key] = (state.sorts[key] or 0) + 1
    return filter, label, state.sorts[key] % 2 == 0
end

local function processBrowseRows(rows, added, source)
    rebuildWatch()
    -- each page arrives as EVERY result so far: walk only the rows we have
    -- not seen yet (a fresh result set resets browseRecorded before the call)
    -- the gate log ACCUMULATES across the result set: an added page with no
    -- new rows must not wipe the "why" report (it used to reset on every
    -- page, so /fsn why usually read empty)
    if not added or not S.gateLog then
        S.gateLog = { at = time(), counts = {}, examples = {} }
    end
    local function why(reason, itemID, extra)
        S.gateLog.counts[reason] = (S.gateLog.counts[reason] or 0) + 1
        recordGate(source or "discovery", reason, itemID, extra)
        if #S.gateLog.examples < 6 and itemID then
            S.gateLog.examples[#S.gateLog.examples + 1] =
                (infoOf(itemID).name or ("item " .. itemID)) .. ": " .. reason .. (extra or "")
        end
    end
    local mins, t = {}, time()
    local first = added and (S.browseRecorded or 0) + 1 or 1
    for i = first, #rows do
        local r = rows[i]
        local key = num(r.itemKey and r.itemKey.itemID)
        local price = num(r.minPrice)
        local qty = num(r.totalQuantity) or 0
        if key and price and price > 0 then
            mins[key] = price
            if qty and qty > 0 then
                noteStack(key, qty)
                trackSold(key, qty, time())
            end
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
                -- guaranteed profit, but it still has to be WORTH the click:
                -- a 2s fang with 1s of vendor margin is noise, not a deal
                if est >= (cfg.vendorMin or 5000) then
                    fireAlert("vendor", key, nil, price, sell,
                        { units = qty, cost = price * qty, profit = est, line = sell - 1 })
                else
                    why("vendor margin under floor", key,
                        " (" .. fmtMoney(est) .. " est vs " .. fmtMoney(cfg.vendorMin or 5000) .. " floor)")
                end
            end
        -- WATCH RULES: absolute price targets, evaluated on EVERY browsed
        -- row - fixed prices, "under vendor" and "under DE value" modes.
        -- This is what makes hits constant instead of rotation-limited.
        local wr = watchByID[key]
        -- if a watch rule exists in db but the index is stale (just set),
        -- rebuild on the spot - watch rules must fire IMMEDIATELY, not on
        -- the next sweep rotation
        if not wr and db.watch and db.watch[tostring(key)] then
            rebuildWatch()
            wr = watchByID[key]
        end
        local wmax = wr and watchMaxFor(key, wr) or nil
        if wr and wmax and price <= wmax and isNewListing(key, price) then
            fireAlert("watch", key, nil, price, nil,
                { units = qty, cost = price * qty, line = wmax })
        end
        -- cheapest sort shows the true floor: open deals on this item priced
        -- above it are dead (the cheap ones got bought) - mark them gone
        if S.sweepStats.lastSort == "cheapest" then
            markDealGone(key, price)
        end
            do
                local med = S.marketReference(key, t)
                local dealLinePx = nil
                if not med then
                    why("no fresh market reference", key)
                elseif med < cfg.minUnit then
                    why("market under floor", key)
                else
                    dealLinePx = dealLine(med, key)
                    if price > dealLinePx then
                        local _, mult = dealLine(med, key)
                        why("not cheap enough", key, " (" .. fmtMoney(price) .. " vs line " .. fmtMoney(math.floor(dealLinePx)) .. " @" .. math.floor((1 - mult) * 100 + 0.5) .. "% off)")
                    end
                end
                if key == 4338 then
                end
                absorbTrack(key, med ~= nil and dealLinePx ~= nil and price <= dealLinePx, t)
                if med and med >= cfg.minUnit and dealLinePx and price <= dealLinePx and price >= 1 then
                    -- listability gates: verifiable quality (uncached items get a
                    -- load request and pass on the NEXT sweep - the client caches
                    -- item info asynchronously), a market not buried under
                    -- competing stock, and a NEW listing
                    local q = qualityOf(key)
                    local overhang = cfg.overhang or 0
                    -- Browse quantity spans all prices. It can identify the
                    -- existing dump heuristic, but only full live tiers can
                    -- establish how much stock sits ABOVE the deal ceiling.
                    local crowded = overhang > 0 and qty > overhang
                    local stackable = infoOf(key).stackable
                    if stackable == false then
                        why("not stackable", key)
                    elseif stackable == nil or q == -1 then
                        -- unknown (stackable or quality): load and pass next
                        -- sweep - never a hard block, just not this sweep
                        requestItemLoad(key)
                        why("item info loading", key)
                    elseif q < (cfg.quality or 1) then
                        why("quality below floor", key)
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
                    elseif not isNewListing(key, price) then
                        why("recently alerted at this price", key)
                    else
                        local line = dealLine(med, key)
                        local cost = qty * price
                        local est = math.floor(qty * med * (1 - cfg.cut) - cost)
                        fireAlert("market", key, nil, price, med,
                            { units = qty, cost = cost, profit = est, line = line }, true)
                    end
                end
            end
        end
    end
    if next(mins) then mergeIntoBook(mins, t) end
    S.browseRecorded = #rows
end

do
    -- Seed only, not buy prices or proof of live commodity eligibility. Selected
    -- from the 2026-11-17 Forever-EU sales / Normal Horde price feed (115 mats).
    S.targetedItems = {
        [12360]=true, [12363]=true, [14047]=true, [4306]=true, [8170]=true, [15416]=true, [14344]=true, [4338]=true, [3858]=true, [4304]=true,
        [10620]=true, [2592]=true, [13468]=true, [3860]=true, [2841]=true, [12359]=true, [4234]=true, [7078]=true, [13463]=true, [14256]=true,
        [2772]=true, [2776]=true, [2838]=true, [2840]=true, [2775]=true, [4235]=true, [3575]=true, [2770]=true, [7076]=true, [13466]=true,
        [7910]=true, [15417]=true, [7912]=true, [3859]=true, [13465]=true, [12365]=true, [11176]=true, [8845]=true, [7911]=true, [3577]=true,
        [11137]=true, [2771]=true, [7067]=true, [7082]=true, [2842]=true, [2452]=true, [10939]=true, [7080]=true, [16203]=true, [3821]=true,
        [16204]=true, [11083]=true, [4625]=true, [3819]=true, [8838]=true, [11175]=true, [11178]=true, [11135]=true, [3576]=true, [8836]=true,
        [3818]=true, [8169]=true, [4232]=true, [8846]=true, [6037]=true, [11177]=true, [8831]=true, [3820]=true, [16202]=true, [8839]=true,
        [1206]=true, [10938]=true, [7068]=true, [1705]=true, [7077]=true, [1529]=true, [3369]=true, [3357]=true, [13464]=true, [3864]=true,
        [11134]=true, [7070]=true, [12800]=true, [12803]=true, [7069]=true, [1210]=true, [12808]=true, [11174]=true, [12799]=true, [8150]=true,
        [12364]=true, [783]=true, [7909]=true, [14343]=true, [13467]=true, [7079]=true, [9262]=true, [7075]=true, [7972]=true, [7081]=true,
        [8171]=true,
    }

    function S.targetedPool()
        if not ForeverSniperTSM or type(ForeverSniperTSM.marketIdentity) ~= "function" then return nil end
        local market, region = ForeverSniperTSM.marketIdentity()
        if market == "normal-horde" and region == "forever-eu" then return S.targetedItems end
    end

    function S.targetedStatus()
        local total, checked = 0, 0
        for id in pairs(S.targetedItems) do
            total = total + 1
            if S.targetedSeen and S.targetedSeen[id] then checked = checked + 1 end
        end
        return string.format("%s; Normal Horde / Forever-EU seed %d materials; %d distinct batch checks this session; %s",
            cfg.targeted and "on" or "off", total, checked,
            S.targetedPool() and "market verified" or "market unverified or mismatched (targeted searches paused)")
    end
end

do
    function S.failBatch(reason)
        S.batchSearch = nil
        S.batchDisabled = reason
        S.sweepStats.batchFailures = (S.sweepStats.batchFailures or 0) + 1
        recordGate("batch", reason)
        S.wakeSweep()
    end

    function S.startBatch()
        if not cfg.batch or S.batchDisabled or S.deepScan or blizzardBrowseActive()
            or type(C_AuctionHouse.SearchForItemKeys) ~= "function"
            or type(C_AuctionHouse.MakeItemKey) ~= "function"
            or type(C_AuctionHouse.HasFullBrowseResults) ~= "function" then return false end
        S.batchChecked = S.batchChecked or {}
        local candidates, now = {}, GetTime()
        local priorityPool = not cfg.targeted and S.targetedPool() or nil
        local pool = db.book
        if cfg.targeted then
            pool = S.targetedPool()
            if not pool then return false end
        end
        for rawID in pairs(pool) do
            local id = num(rawID)
            local commodity = id and commodityFor(id)
            if cfg.targeted and id and commodity == nil then requestItemLoad(id) end
            local checked = id and (S.batchChecked[id] or -60)
            if id and id > 0 and id % 1 == 0 and not watchByID[id] and not db.blacklist[id] and commodity == true then
                local market = S.marketReference(id)
                if market and market >= cfg.minUnit then
                    candidates[#candidates + 1] = {id=id, checked=checked}
                end
            end
        end
        -- Keep broad coverage, but revisit the market-matched material seed
        -- more often. At least 25 slots remain for oldest-first coverage.
        table.sort(candidates, function(a, b)
            if a.checked ~= b.checked then return a.checked < b.checked end
            return a.id < b.id
        end)
        local keys, ids = {}, {}
        local priorityIDs = {}
        local function add(candidate)
            local id = candidate.id
            local ok, key = pcall(C_AuctionHouse.MakeItemKey, id)
            if ok and type(key) == "table" and key.itemID == id and not ids[id] then
                keys[#keys + 1], ids[id] = key, true
                if priorityPool and priorityPool[id] then priorityIDs[id] = true end
            end
        end
        local priorityCount = 0
        for _, candidate in ipairs(candidates) do
            if priorityPool and priorityPool[candidate.id] then
                priorityCount = priorityCount + 1
                if #keys < 75 then add(candidate) end
            end
        end
        for _, candidate in ipairs(candidates) do
            if #keys >= 100 then break end
            if not ids[candidate.id] then add(candidate) end
        end
        S.sweepStats.batchEligible = #candidates
        S.sweepStats.batchPriorityEligible = priorityCount
        if #keys == 0 then return false end
        -- Own the browse channel before calling into clients with cached replies.
        S.sweeping = false
        S.batchSearch = {t=now, ids=ids, count=#keys, targeted=cfg.targeted, priorityIDs=priorityIDs}
        noteQueryAttempt()
        S.sweepStats.batchSent = (S.sweepStats.batchSent or 0) + 1
        local ok = pcall(C_AuctionHouse.SearchForItemKeys, keys, {})
        if not ok then S.failBatch("submission failed; individual fallback") end
        return true -- failed submissions still consume the pacing slot
    end

    function S.readBatch()
        local owner = S.batchSearch
        if not owner then return false end
        if not S.ahOpen or not cfg.enabled then S.batchSearch = nil return true end
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        local fullOK, full = pcall(C_AuctionHouse.HasFullBrowseResults)
        if not ok or type(rows) ~= "table" or not fullOK or full ~= true then
            S.failBatch("unreadable or incomplete summary; individual fallback")
            return true
        end
        local seen = {}
        for _, row in ipairs(rows) do
            local id = type(row) == "table" and type(row.itemKey) == "table" and num(row.itemKey.itemID)
            local price = type(row) == "table" and num(row.minPrice)
            local quantity = type(row) == "table" and num(row.totalQuantity)
            if not id or not owner.ids[id] or seen[id] or not price or price < 0
                or price % 1 ~= 0 or not quantity or quantity < 0 or quantity % 1 ~= 0 then
                S.failBatch("unexpected summary rows; individual fallback")
                return true
            end
            seen[id] = quantity > 0 and price or 0
        end
        S.batchSearch = nil
        local stats, completedAt = S.sweepStats, GetTime()
        for id in pairs(owner.ids) do
            local floor = seen[id]
            S.observeBatchFloor(id, floor and floor > 0 and floor or nil)
            local previous = S.batchChecked[id]
            if previous and completedAt >= previous then
                local gap = completedAt - previous
                stats.batchRevisitLast = gap
                stats.batchRevisitMax = math.max(stats.batchRevisitMax or 0, gap)
                stats.batchRevisitCount = (stats.batchRevisitCount or 0) + 1
                stats.batchRevisitTotal = (stats.batchRevisitTotal or 0) + gap
                local lane = owner.priorityIDs and owner.priorityIDs[id] and "priority" or "coverage"
                stats.batchLanes = stats.batchLanes or {}
                local metric = stats.batchLanes[lane] or {count=0,total=0,max=0}
                metric.count, metric.total, metric.max = metric.count + 1, metric.total + gap, math.max(metric.max, gap)
                stats.batchLanes[lane] = metric
            end
            S.batchChecked[id] = completedAt
            S.noteRevisit(id)
            if owner.targeted then
                S.targetedSeen = S.targetedSeen or {}
                S.targetedSeen[id] = true
            end
        end
        stats.batchCompleted = (stats.batchCompleted or 0) + 1
        stats.batchKeys = (stats.batchKeys or 0) + owner.count
        stats.batchRows = (stats.batchRows or 0) + #rows
        stats.batchLatency = GetTime() - owner.t
        -- Reuse existing candidate gates. Summary quantities never become a
        -- purchase snapshot; fireAlert still queues complete live tier checks.
        local sort = stats.lastSort
        stats.lastSort = "batch"
        processBrowseRows(rows, false, "batch")
        S.fastValidationCandidate = nil
        for id in pairs(owner.ids) do
            local candidate = S.liveCandidates and S.liveCandidates[id]
            if candidate and not candidate.refresh and not candidate.prebuy and not candidate.remainder then
                candidate.forceSearch = true
                if not S.fastValidationCandidate or S.candidatePriority(candidate) > S.candidatePriority(S.fastValidationCandidate) then
                    S.fastValidationCandidate = candidate
                end
            end
        end
        stats.lastSort = sort
        S.wakeSweep()
        return true
    end

    function S.candidatePriority(candidate)
        local age = math.max(0, GetTime() - candidate.t)
        local profit = math.max(0, candidate.profit or 0)
        local sales = S.salesPolicy(candidate.id)
        local liquidity = sales and sales.rate and sales.daily
            and math.min(2, sales.rate * math.log(1 + sales.daily)) or 0
        -- A bounded value boost cannot starve older candidates indefinitely.
        return age + math.min(5, math.log(1 + profit / 10000)) + liquidity
    end

    function S.fastValidation()
        local candidate = S.fastValidationCandidate
        if not candidate or not S.liveCandidates or S.liveCandidates[candidate.id] ~= candidate
            or not candidate.detectedAt or GetTime() - candidate.detectedAt >= 1
            or db.blacklist[candidate.id] or (not cfg.targeted and S.discoveryDue)
            or cfg.prebuy or S.remainderRetry or S.deepScan
            or S.liveCandidate or S.autoSearch or S.watchSearch or focusedDeal() then return end
        if cfg.targeted then
            local pool = S.targetedPool()
            if not pool or not pool[candidate.id] then return end
        end
        return candidate
    end
end

local function sweepQuery()
    if S.snipePending or S.pending or S.buying then return end
    if S.batchSearch and GetTime() - S.batchSearch.t >= 5 then
        S.failBatch("summary timed out; individual fallback")
    end
    -- Expiry is local housekeeping, not a query. A busy AH must not retain
    -- dead owners or hide the real wait behind a checking-item label.
    for _, field in ipairs({"liveCandidate", "autoSearch", "watchSearch"}) do
        local owner = S[field]
        if owner and GetTime() - owner.t >= 10 then
            S[field] = nil
            S.sweepStats.timeouts = (S.sweepStats.timeouts or 0) + 1
            recordGate("search", "timed out", owner.id)
        end
    end
    local fast = S.fastValidation()
    if fast then
        if not canQuery(nil, true) then return end
        local saved = math.max(0, S.queryReadyAt() - GetTime())
        S.sweepStats.validationAdvanced = (S.sweepStats.validationAdvanced or 0) + 1
        S.sweepStats.validationSaved = (S.sweepStats.validationSaved or 0) + saved
        S.liveCandidates[fast.id], S.fastValidationCandidate = nil, nil
        sweepCount = sweepCount + 1
        if not cfg.targeted and sweepCount % 4 == 0 then
            S.discoveryDue = true
            S.sweepStats.discoveryBorrowed = (S.sweepStats.discoveryBorrowed or 0) + 1
        end
        sendTargetSearch("liveCandidate", fast)
        return
    end
    if not canQuery() then return end
    if C_AuctionHouse == nil then return end
    if (cfg.maxStock > 0 or next(db.stockLimits) or (cfg.sales == true and cfg.tsm ~= false))
        and (not S.sellingOwnedUpdated or GetTime() - S.sellingOwnedUpdated > 15)
        and (not S.stockRefreshAt or GetTime() - S.stockRefreshAt >= 5)
        and not (S.liveCandidate or S.autoSearch or S.watchSearch) then
        S.stockRefreshAt = GetTime()
        if S.requestSellingOwned() then return end
    end
    for _, field in ipairs({"liveCandidate", "autoSearch", "watchSearch"}) do
        local owner = S[field]
        if owner then
            if owner.needsPage then
                owner.needsPage = false
                noteQueryAttempt()
                local ok, e = pcall(C_AuctionHouse.RequestMoreCommoditySearchResults, owner.id)
                if not ok then
                    err("commodity page", e)
                    recordGate("search", "page request failed", owner.id)
                    if S[field] == owner then S[field] = nil end
                end
            end
            return
        end
    end
    local targetedPool
    if cfg.targeted then
        targetedPool = S.targetedPool()
        if not targetedPool then return end
    end
    local prebuy = cfg.prebuy and S.prebuyCheck
    if prebuy and prebuy.completedAt and GetTime() - prebuy.completedAt <= 2 then
        S.wakeSweep(prebuy.completedAt + 2 + 0.01)
        return
    end
    if prebuy and not prebuy.finished and not prebuy.completedAt
        and GetTime() - prebuy.t < 15 and not db.blacklist[prebuy.id] then
        local candidate = S.liveCandidates and S.liveCandidates[prebuy.id]
        rebuildWatch()
        if candidate and candidate.prebuy == prebuy
            and (not cfg.targeted or targetedPool[prebuy.id] or watchByID[prebuy.id]) then
            -- The hardware press already used the click opportunity. Dispatch
            -- its check before waiting for another click or routine discovery.
            S.liveCandidates[prebuy.id] = nil
            sendTargetSearch("liveCandidate", candidate)
            return
        end
    end
    local retry = S.remainderRetry
    if retry then
        local candidate = S.liveCandidates and S.liveCandidates[retry.id]
        rebuildWatch()
        if GetTime() >= retry.expires or db.blacklist[retry.id]
            or (cfg.targeted and not targetedPool[retry.id] and not watchByID[retry.id]) then
            S.remainderRetry = nil
            if candidate and candidate.remainder == retry then S.liveCandidates[retry.id] = nil end
        elseif candidate and candidate.remainder == retry then
            S.liveCandidates[retry.id] = nil
            sendTargetSearch("liveCandidate", candidate)
            return
        end
    end
    local focus = focusedDeal()
    if focus and S.dealFocus then
        local priority = S.dealFocus
        if not priority.buyWindowUntil then priority.buyWindowUntil = GetTime() + 5 end
        -- One bounded human-click opportunity per focus, starting only once the
        -- live API is ready. Never abandon owned pages or pause discovery forever.
        if GetTime() < priority.buyWindowUntil then
            S.wakeSweep(priority.buyWindowUntil)
            return
        end
    end
    sweepCount = sweepCount + 1
    local discoveryDue = not cfg.targeted and S.discoveryDue
    S.discoveryDue = nil
    if focus and sweepCount % 4 == 3 and not discoveryDue and not next(S.liveCandidates or {}) then
        local snapshot = S.commoditySnapshots[focus.id]
        local priority = S.dealFocus
        if (not snapshot or GetTime() - snapshot.t >= 15)
            and (not priority.lastRefresh or GetTime() - priority.lastRefresh >= 15) then
            -- Submission errors and timeouts do not grant another immediate
            -- attempt. This is per-deal refresh spacing, not adaptive pacing.
            priority.lastRefresh = GetTime()
            sendTargetSearch("liveCandidate", {id=focus.id, link=focus.link,
                line=focus.line, market=focus.market, kind=focus.kind, refresh=true})
            return
        end
    end
    rebuildWatch()
    local watchKey, watchID, watchRule
    local targetSlot = cfg.targeted or (not discoveryDue and sweepCount % 4 ~= 0)
    if not discoveryDue and (targetSlot or (not S.deepScan and not blizzardBrowseActive()
        and C_AuctionHouse.SendBrowseQuery)) then
        local oldest
        for id, candidate in pairs(S.liveCandidates or {}) do
            if cfg.targeted and not targetedPool[id] and not watchByID[id] then
                -- A mode change must not dispatch old broad-discovery candidates.
                S.liveCandidates[id] = nil
            elseif GetTime() - candidate.t >= 30 then
                S.liveCandidates[id] = nil
                recordGate("preparation", "expired before search", id)
            elseif not oldest or S.candidatePriority(candidate) > S.candidatePriority(oldest)
                or (S.candidatePriority(candidate) == S.candidatePriority(oldest) and candidate.id < oldest.id) then
                oldest = candidate
            end
        end
        if oldest then
            -- Borrow only one discovery slot, then repay it before any more
            -- candidates. Fresh bargains save a round trip without starving coverage.
            if not targetSlot then
                S.discoveryDue = true
                S.sweepStats.discoveryBorrowed = (S.sweepStats.discoveryBorrowed or 0) + 1
            end
            S.liveCandidates[oldest.id] = nil
            sendTargetSearch("liveCandidate", oldest)
            return -- failed attempts also consume a pacing slot
        end
    end
    -- Three monitoring slots per discovery slot, with at most one outstanding
    -- borrowed slot. Watch rules precede speculative checks.
    if sweepCount % 4 == 1 then watchKey, watchID, watchRule = nextWatchKey() end
    if targetSlot and C_AuctionHouse.SendSearchQuery then
        local key, id, w = watchKey, watchID, watchRule
        if not key and S.startBatch() then return end
        local target = not key and nextAutoTarget(targetedPool, cfg.targeted and 0 or nil) or nil
        if target then id = target.id end
        if key or target then
            local request = target or {id=id, maxPrice=w.maxPrice, rule=w}
            local ok = sendTargetSearch(target and "autoSearch" or "watchSearch", request)
            if ok then
                if target then
                    if not S.autoChecked[id] then S.sweepStats.autoUnique = (S.sweepStats.autoUnique or 0) + 1 end
                    S.autoChecked[id] = GetTime()
                    S.sweepStats.autoSent = (S.sweepStats.autoSent or 0) + 1
                end
                S.sweepStats.lastTarget = id
            end
            return
        end
    end
    if cfg.targeted then return end -- never silently fall back to broad discovery
    if S.deepScan then return end -- deep scan retains browse ownership, not item searches
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
    if C_AuctionHouse.SendBrowseQuery == nil then return end
    local cat = nextCategory()
    local filter, scope, alternateSort = discoveryScope(cat)
    local timeSorted = alternateSort and Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.TimeLeft ~= nil
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        local so = Enum.AuctionHouseSortOrder.Price or Enum.AuctionHouseSortOrder.Buyout
        if timeSorted then
            -- Vary discovery beyond the cheapest page. Remaining duration is
            -- not listing age: sellers can choose different auction durations.
            so = Enum.AuctionHouseSortOrder.TimeLeft
        end
        if so then sorts = { { sortOrder = so, reverseSort = timeSorted and true or false } } end
    end
    local query = {
        searchString = "",
        sorts = sorts,
        filters = {},
        itemClassFilters = { filter },
    }
    S.sweepStats.lastSort = timeSorted and "time left" or "cheapest"
    noteQueryAttempt()
    pagePending, S.sweeping = true, true
    S.sweepStats.lastCat = scope
    local ok, e = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then
        pagePending, S.sweeping = false, false
        err("SendBrowseQuery", e)
        return
    end
    S.sweepStats.sent = S.sweepStats.sent + 1
    updateScanPage()
    -- the deal feed's footer mirrors the sweep live: the two windows are one
    -- engine, and the footer must never sit on its build-time text
    if feedFrame and feedFrame:IsShown() then refreshFeed() end
    dbg("sweep sent: " .. scope)
end

local function maybeMorePages()
    -- Routine discovery always releases after one page, including when a deep
    -- scan is waiting to acquire the browse connection.
    pagePending, S.sweeping = false, false
    S.wakeSweep()
end

-- DEEP SCAN (/fsn deepscan, auto every 15 min with the AH open): page every
-- listing of each scan category into the book. Modeled on ForeverForge's
-- Auto-paging up to 40 pages per category. Every page evaluates candidates;
-- live item validation continues between pages without replacing browse state.
local DEEP_MAX_PAGES, DEEP_INTERVAL = 40, 900
local deepSend, deepNext, deepMore

local function deepAbort(say)
    local d = S.deepScan
    S.deepScan = nil
    if d and d.ticker then d.ticker:Cancel() end
    if say then printf("deep scan aborted - the auction house closed.") end
    updateScanPage()
end

deepNext = function()
    local d = S.deepScan
    if not d then return end
    local nxt = SCAN_CATEGORIES[(d.idx or 1) + 1]
    if not nxt then
        local secs = math.floor(GetTime() - (d.started or GetTime()) + 0.5)
        db.lastDeepScan = time()
        S.deepScan = nil
        if d.ticker then d.ticker:Cancel() end
        updateScanPage()
        printf("|cffffd100Deep scan done|r: %s rows across %d categories in %ds - the book is primed.",
            tostring(d.rows or 0), d.idx or 0, secs)
        return
    end
    d.idx, d.cat, d.pages, d.received = d.idx + 1, nxt, 0, false
    deepSend()
end

deepMore = function()
    local d = S.deepScan
    if not d then return end
    d.wantsPage = true
end

local function deepPage()
    local d = S.deepScan
    if not d then return end
    d.wantsPage = false
    local full = false
    local okF, f = pcall(C_AuctionHouse.HasFullBrowseResults)
    if okF then full = (f == true) end
    if full or (d.pages or 0) >= DEEP_MAX_PAGES then deepNext() return end
    d.pages = (d.pages or 0) + 1
    d.lastReq = GetTime()
    noteQueryAttempt()
    local ok, e = pcall(C_AuctionHouse.RequestMoreBrowseResults)
    if not ok and S.deepScan == d then
        d.pages = d.pages - 1
        d.wantsPage = true
        err("deep scan page", e)
    end
end

deepSend = function()
    local d = S.deepScan
    if not d or not d.cat then return end
    d.needsSend = true
    if S.autoSearch or S.watchSearch or S.liveCandidate or S.pending or S.buying or not canQuery() then return end
    d.needsSend = false
    d.received, d.wantsPage = false, false
    S.sweeping = false
    d.lastReq = GetTime()
    noteQueryAttempt()
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    local ok, e = pcall(C_AuctionHouse.SendBrowseQuery, {
        searchString = "",
        sorts = sorts,
        filters = {},
        itemClassFilters = { { classID = d.cat.classID } },
    })
    if not ok and S.deepScan == d then
        d.needsSend = true
        err("deep scan query", e)
    end
    updateScanPage()
end

startDeepScan = function(force)
    if S.deepScan then
        printf("deep scan already running - %s (page %d).", S.deepScan.cat.name, S.deepScan.pages or 0)
        return
    end
    if not S.ahOpen then
        printf("open the auction house first.")
        return
    end
    if S.scanning or S.harvestOwner or S.harvestTicker then
        -- the replicate dump owns the AH connection: a browse query sent now
        -- comes back EMPTY (proven live: "0 rows across 4 categories in 2s")
        S.deepScanPending = true
        printf("the full-scan dump is still landing - the deep scan will start right after it.")
        return
    end
    local age = time() - (db.lastDeepScan or 0)
    if not force and age < DEEP_INTERVAL then
        printf("the book was deep-scanned %d min ago (auto again at 15) - /fsn deepscan runs it now.",
            math.floor(age / 60 + 0.5))
        return
    end
    if blizzardBrowseActive() then
        avoidBrowseTab()
        if blizzardBrowseActive() then
            printf("deep scan paused: switch away from the AH Browse tab before starting it.")
            return
        end
    end
    S.deepScan = { idx = 1, cat = SCAN_CATEGORIES[1], pages = 0, rows = 0, started = GetTime() }
    printf("deep scan: paging every %s listing into the book (item checks continue between pages)...",
        SCAN_CATEGORIES[1].name)
    S.deepScan.ticker = C_Timer.NewTicker(0.5, function()
        local d = S.deepScan
        if not d then return end
        if not S.ahOpen then deepAbort(true) return end
        if not cfg.enabled then deepAbort(false) return end
        if S.snipePending or db.unsettledPurchase then
            -- Pause the deep-scan lifetime as well as requests. Do not time
            -- out an otherwise healthy scan while a purchase is unresolved.
            local now = GetTime()
            d.started = d.started + now - (d.pauseTick or now)
            d.pauseTick = now
            return
        end
        if d.pauseTick then
            d.started = d.started + GetTime() - d.pauseTick
            d.pauseTick = nil
        end
        if not cfg.enabled or GetTime() - d.started > 120 then
            deepAbort(false)
            printf("deep scan stopped: disabled or no completion within two minutes.")
            return
        end
        if blizzardBrowseActive() then return end -- the crash guard applies here too
        updateScanPage()
        -- Item searches can interrupt between browse pages, but never replace
        -- the deep scan's browse result set or race its next page request.
        if S.autoSearch or S.watchSearch or S.liveCandidate or S.pending or S.buying or not canQuery(true) then return end
        local prebuy = cfg.prebuy and S.prebuyCheck
        if prebuy and prebuy.completedAt and GetTime() - prebuy.completedAt <= 2 then return end
        -- Reserve time for live validations and the same bounded click window
        -- as the routine scheduler. Browse pages retain their existing owner.
        if focusedDeal() and S.dealFocus then
            local focus = S.dealFocus
            if not focus.buyWindowUntil then focus.buyWindowUntil = GetTime() + 5 end
            if GetTime() < focus.buyWindowUntil then return end
        end
        if GetTime() - (d.lastReq or 0) < 4 then return end
        for _, candidate in pairs(S.liveCandidates or {}) do
            if GetTime() - candidate.t < 30 then return end
        end
        if d.needsSend then deepSend() return end
        if d.wantsPage then deepPage() return end
        -- a page request the server dropped sends no event: re-request, or
        -- move on when the category is full
        if GetTime() - (d.lastReq or 0) > 2 then
            local okF, f = pcall(C_AuctionHouse.HasFullBrowseResults)
            if d.received and ((okF and f == true) or (d.pages or 0) >= DEEP_MAX_PAGES) then
                deepNext()
            else
                if not d.received then
                    deepSend()
                else
                    deepPage()
                end
            end
        end
    end)
    deepSend()
end

function S.wakeSweep(notBefore)
    if not S.sweepTicker or not S.ahOpen or not cfg.enabled then return end
    local now = GetTime()
    local due = math.max(now + 0.01, S.queryReadyAt(S.fastValidation() ~= nil), notBefore or 0)
    if S.sweepWake and S.sweepWake.at <= due then return end
    local owner = S.sweepTicker
    local wake = {at=due}
    S.sweepWake = wake
    -- Defer even synchronous cached replies. Coalesce event bursts and share
    -- the same spacing gate with the watchdog and every other query lane.
    after(due - now, function()
        if S.sweepWake ~= wake then return end
        S.sweepWake = nil
        if S.sweepTicker ~= owner or not S.ahOpen or not cfg.enabled then return end
        sweepQuery()
        feedTick()
        updateScanPage()
    end)
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
    S.wakeSweep()
    dbg("live sweep armed: ready-driven queries, fallback tick " .. period .. "s")
end

local stopRelisting -- forward: defined with the batch-relist block below

local function stopSweeping()
    S.remainderRetry = nil
    observeQueryPressure(false)
    S.sweepWake = nil
    if not S.ahOpen or not cfg.enabled then S.batchSearch = nil end
    if S.sweepTicker then
        S.sweepTicker:Cancel()
        S.sweepTicker = nil
    end
    if undercutTicker then
        undercutTicker:Cancel()
        undercutTicker = nil
    end
    stopRelisting()
    S.sweeping = false
    pagePending = false
end


-- BATCH RELIST: /fsn relist plans the batch, /fsn relist go posts every held
-- flip at its smart price - all at once, inside the command you typed. No
-- timers, no pacing, nothing designed to look like anything other than what
-- it is: one player command, one immediate batch.
stopRelisting = function()
    -- batch posts are immediate now; there is no queue left to stop
end

local function startRelisting(queue)
    if #queue == 0 then
        printf("nothing to relist - no priced holdings found in your bags.")
        return
    end
    local posted = 0
    for i = 1, #queue do
        if not S.ahOpen then break end
        local itemID = queue[i]
        local b = db.book[itemID]
        local med = b and freshMedian(b.s, time(), (cfg.freshMins or 45) * 60, cfg.armAfter) or nil
        if med then
            local isComm = commodityFor(itemID)
            local sp = smartPrice(itemID, med, isComm)
            if sellAt(itemID, sp) then posted = posted + 1 end
        end
    end
    printf("relist: %d of %d submissions sent. Check your auctions for completion.", posted, #queue)
end

-- Last-paid references cannot establish the acquisition cost of current bags.
-- Compare only priced holdings; unknown market values are not zero proceeds.
local function holdingsSnapshot()
    local rows, byID = {}, {}
    if C_Container == nil or C_Container.GetContainerNumSlots == nil then return rows end
    local t = time()
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
        local n = C_Container.GetContainerNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                local id = C_Container.GetContainerItemID(bag, slot)
                if id and (db.boughtAt[tostring(id)] or db.boughtAt[id]) then
                    local bought = db.boughtAt[tostring(id)] or db.boughtAt[id]
                    local paid = type(bought) == "table" and num(bought.price)
                    local qty, locked = carriedStack(bag, slot)
                    if qty and paid and paid > 0 then
                        local row = byID[id]
                        if row then
                            row.qty = row.qty + qty
                            row.available = row.available + (not locked and qty or 0)
                        else
                            local b = db.book[id]
                            local med = b and freshMedian(b.s, t, (cfg.freshMins or 45) * 60, cfg.armAfter) or nil
                            row = {id=id, qty=qty, available=not locked and qty or 0,
                                paid=paid, boughtAt=bought.t or 0, med=med, kind=bought.kind}
                            byID[id], rows[#rows + 1] = row, row
                        end
                    end
                end
            end
        end
    end
    return rows
end

do
    local frame, rows, page, mode = nil, {}, 1, "bags"
    local pageSize = 8
    local expiryTimer, expiryStamp

    local function stopOwnedExpiry()
        if expiryTimer then expiryTimer:Cancel() end
        expiryTimer, expiryStamp = nil, nil
    end

    local function syncOwnedExpiry(fresh)
        if mode ~= "owned" or not fresh then stopOwnedExpiry() return end
        if expiryTimer and expiryStamp == S.sellingOwnedUpdated then return end
        stopOwnedExpiry()
        expiryStamp = S.sellingOwnedUpdated
        -- One deadline, not a polling ticker. Cancellation still checks freshness.
        expiryTimer = C_Timer.NewTimer(math.max(0.05, 20.05 - (GetTime() - expiryStamp)), function()
            expiryTimer, expiryStamp = nil, nil
            S.refreshSelling()
        end)
    end

    local function queryOwned(beforeQuery)
        if beforeQuery and beforeQuery() == false then return false end
        C_AuctionHouse.QueryOwnedAuctions({})
        return true
    end

    function S.requestSellingOwned(beforeQuery)
        if not S.ahOpen then return false, "open the Auction House first" end
        if S.nativeSellActive() then return false, "native sell form prepared; finish or clear it first" end
        if S.snipePending or db.unsettledPurchase then return false, "purchase unresolved; check /fsn purchase" end
        if S.pending or S.buying or S.quote or (S.batchBuy and S.batchBuy.pending) then
            return false, "purchase or inspection busy"
        end
        if S.scanning or S.harvestOwner or S.harvestTicker then return false, "snapshot busy" end
        if S.autoSearch or S.watchSearch or S.liveCandidate or S.deepScan or S.batchSearch then return false, "scanner search busy" end
        local ready, reason = throttleGate()
        if not ready then return false, reason == "unavailable" and "auction readiness unavailable" or "auction throttle busy" end
        if not (C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions) then return false, "owned query API unavailable" end
        if (S.sellingOwnedRequest and GetTime() - S.sellingOwnedRequest < 1)
            or GetTime() - lastQueryAt < queryPacing().interval
            or GetTime() < S.queryReadyAt() then return false, "query spacing; wait before retrying" end
        S.sellingOwnedRequest = GetTime()
        noteQueryAttempt()
        local ok, submitted = pcall(queryOwned, beforeQuery)
        if not ok then err("QueryOwnedAuctions", submitted) return false, "owned query API failed; see /fsn errors" end
        if not submitted then return false, "cancellation permission revoked" end
        return true
    end

    function S.lowOwnedSnapshot()
        local result = {}
        if not S.ahOpen or not S.sellingOwnedUpdated or GetTime() - S.sellingOwnedUpdated > 20
            or not (C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetOwnedAuctionInfo) then return result end
        local ok, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
        n = ok and num(n) or nil
        if not n or n < 0 or n % 1 ~= 0 then return result end
        local seen = {}
        for i = 1, n do
            local read, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
            if read and type(info) == "table" then
                local id = info.itemKey and info.itemKey.itemID
                local bought = id and (S.boughtAt[tostring(id)] or S.boughtAt[id])
                local cap = type(bought) == "table" and num(bought.ceiling)
                local qty, total, auctionID = num(info.quantity), num(info.buyoutAmount), num(info.auctionID)
                if cap and cap > 0 and cap % 1 == 0 and bought.kind ~= "vendor" and qty and qty > 0 and qty % 1 == 0
                    and total and total > 0 and total % 1 == 0 and total / qty <= cap
                    and auctionID and auctionID > 0 and auctionID % 1 == 0 and not seen[auctionID]
                    and (info.status == nil or info.status == 0) then
                    seen[auctionID] = true
                    result[#result + 1] = {id=id, auctionID=auctionID, qty=qty, unit=total / qty, ceiling=cap}
                end
            end
        end
        table.sort(result, function(a, b) return a.auctionID < b.auctionID end)
        return result
    end

    local function cancelLowOwned(auctionID, itemID, ceiling, unit, qty)
        -- Re-read the exact row and approved ceiling at the hardware click.
        for _, h in ipairs(S.lowOwnedSnapshot()) do
            if h.auctionID == auctionID and h.id == itemID and h.ceiling == ceiling
                and h.unit == unit and h.qty == qty then
                S.sellingCancelSent = S.sellingCancelSent or {}
                local sent = S.submitCancellation(auctionID, S.sellingCancelSent)
                if sent then
                    printf("cancellation submitted for auction %d. Collect returned items from mail, then use LIST in Bought items.", auctionID)
                else printf("cancellation not sent: check readiness, eligibility and previous requests.") end
                S.refreshSelling()
                return sent
            end
        end
        printf("owned listing changed or expired - Refresh before canceling.")
        S.sellingOwnedDisplay = nil
        S.refreshSelling()
        return false
    end

    function S.cancelLowOwned(auctionID, itemID, ceiling, unit, qty)
        if S.sellingCancelBusy or not unit or not qty then return false end
        -- Own the entire attempt, including getters and synchronous UI callbacks.
        S.sellingCancelBusy = true
        local ok, sent = pcall(cancelLowOwned, auctionID, itemID, ceiling, unit, qty)
        S.sellingCancelBusy = nil
        if not ok then err("CancelLowOwned", sent) return false end
        return sent
    end

    function S.listHolding(itemID)
        local bought = S.boughtAt[tostring(itemID)] or S.boughtAt[itemID]
        if type(bought) ~= "table" or bought.kind == "vendor" then return false end
        local b = db.book[itemID]
        local med = b and freshMedian(b.s, time(), (cfg.freshMins or 45) * 60, cfg.armAfter)
        if not med then printf("no fresh market reference yet - let the scanner learn before listing.") return false end
        local price = smartPrice(itemID, med, commodityFor(itemID))
        if sellAt(itemID, price, true) then
            if frame then frame:Hide() end -- leave the native fields and Post button unobstructed
            return true
        end
        return false
    end

    function S.refreshSelling()
        if not frame or not frame:IsShown() then stopOwnedExpiry() return end
        local holdings = mode == "bags" and holdingsSnapshot() or {}
        table.sort(holdings, function(a, b)
            if a.boughtAt ~= b.boughtAt then return a.boughtAt > b.boughtAt end
            return a.id < b.id
        end)
        -- Cache display rows only. CANCEL always re-reads live owned rows and permissions.
        local freshOwned = S.sellingOwnedUpdated and GetTime() - S.sellingOwnedUpdated <= 20
        syncOwnedExpiry(freshOwned)
        if freshOwned and not S.sellingOwnedDisplay then S.sellingOwnedDisplay = S.lowOwnedSnapshot() end
        local owned = freshOwned and S.sellingOwnedDisplay or {}
        local entries = mode == "history" and (db.purchases or {}) or (mode == "owned" and owned or holdings)
        local pages = math.max(1, math.ceil(#entries / pageSize))
        page = math.max(1, math.min(page, pages))
        frame.heading:SetText(mode == "history" and "Bought items - purchase history" or
            (mode == "owned" and "Bought items - low owned listings" or "Bought items - in your bags"))
        frame.bagsTab:SetEnabled(mode ~= "bags")
        frame.ownedTab:SetEnabled(mode ~= "owned")
        frame.historyTab:SetEnabled(mode ~= "history")
        if S.sellingOwnedUpdated and GetTime() - S.sellingOwnedUpdated <= 20 then
            frame.ownedHint:SetText(string.format("%d owned listing(s) at/below the bought deal ceiling. On AH to review/cancel.", #owned))
        else frame.ownedHint:SetText("Owned listings not checked recently. Refresh, then use On AH to review.") end
        frame.pageText:SetText(string.format("%d / %d", page, pages))
        frame.previous:SetEnabled(page > 1) frame.next:SetEnabled(page < pages)
        frame.empty:SetText(mode == "history" and "No settled purchases yet." or
            (mode == "owned" and "No matching listings in fresh owned results. Refresh to check. Older buys may have no recorded ceiling."
                or "No purchased item types in your bags. Collect your mail, then Refresh."))
        frame.empty:SetShown(#entries == 0)
        for i, row in ipairs(rows) do
            local index = (page - 1) * pageSize + i
            local h = entries[mode == "history" and (#entries - index + 1) or index]
            row.itemID = h and h.id or nil
            row.auctionID, row.ceiling = h and h.auctionID, h and h.ceiling
            row.unit, row.qty = h and h.unit, h and h.qty
            if h then
                local info = infoOf(h.id)
                row.name:SetText(info.link or info.name or ("item " .. h.id))
                if mode == "history" then
                    row.detail:SetText(string.format("%s | %d units | %s total | %s",
                        date("%m/%d %H:%M", h.t or 0), h.units, fmtMoney(h.total), h.source or "settled"))
                    row.list:Hide()
                elseif mode == "owned" then
                    local pending = S.sellingCancelSent and S.sellingCancelSent[h.auctionID]
                    row.detail:SetText(string.format("On AH: %d | %s each | deal ceiling: %s", h.qty, fmtMoney(h.unit), fmtMoney(h.ceiling)))
                    row.list:SetText(pending and "Sent" or "CANCEL")
                    row.list:SetEnabled(not pending and not S.snipePending and not db.unsettledPurchase)
                    row.list:Show()
                else
                    local price = h.med and smartPrice(h.id, h.med, commodityFor(h.id))
                    local reason = h.kind == "vendor" and "Vendor exit" or
                        (h.available == 0 and "Stack locked" or (not price and "Need fresh price" or nil))
                    row.detail:SetText(string.format("Bags: %d | last paid: %s each | %s", h.qty, fmtMoney(h.paid),
                        reason or ("list: " .. fmtMoney(price) .. " each")))
                    row.list:SetEnabled(S.ahOpen and not reason and not S.snipePending and not db.unsettledPurchase)
                    row.list:SetText("LIST")
                    row.list:Show()
                end
                row:Show()
            else row:Hide() end
        end
    end

    local function button(parent, text, width, x, y, callback)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(width, 22) b:SetPoint("TOPRIGHT", x, y) b:SetText(text)
        b:SetScript("OnClick", callback)
        return b
    end

    local function setMode(value)
        mode, page = value, 1
        S.refreshSelling()
    end

    function S.showSelling(automatic)
        if automatic and not next(S.boughtAt) and #(db.purchases or {}) == 0 then return end
        if not frame then
            frame = CreateFrame("Frame", "ForeverSniperSelling", UIParent)
            frame:SetSize(620, 456) frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -100)
            frame:SetClampedToScreen(true) frame:SetMovable(true) frame:EnableMouse(true)
            frame:RegisterForDrag("LeftButton")
            frame:SetScript("OnDragStart", frame.StartMoving)
            frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
            tinsert(UISpecialFrames, "ForeverSniperSelling")
            local bg = frame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints() bg:SetColorTexture(0.05, 0.05, 0.07, 0.97)
            frame.heading = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.heading:SetPoint("TOPLEFT", 12, -12)
            button(frame, "Close", 50, -8, -6, function() frame:Hide() end)
            frame.refresh = button(frame, "Refresh", 62, -62, -6, function()
                if mode == "owned" then
                    local ok, reason = S.requestSellingOwned()
                    if not ok then printf("owned refresh not sent: %s.", reason) end
                end
                S.refreshSelling()
            end)
            frame.bagsTab = button(frame, "Bags", 68, -540, -36, function() setMode("bags") end)
            frame.ownedTab = button(frame, "On AH", 68, -466, -36, function() setMode("owned") end)
            frame.historyTab = button(frame, "History", 68, -392, -36, function() setMode("history") end)
            for i = 1, pageSize do
                local row = CreateFrame("Frame", nil, frame)
                row:SetSize(596, 36) row:SetPoint("TOPLEFT", 12, -74 - (i - 1) * 37)
                row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                row.name:SetPoint("TOPLEFT", 0, 0) row.name:SetWidth(510) row.name:SetJustifyH("LEFT")
                row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.detail:SetPoint("TOPLEFT", 0, -18) row.detail:SetWidth(510) row.detail:SetJustifyH("LEFT")
                row.list = button(row, "LIST", 60, 0, -4, function()
                    if row.auctionID then S.cancelLowOwned(row.auctionID, row.itemID, row.ceiling, row.unit, row.qty)
                    else S.listHolding(row.itemID) end
                end)
                rows[i] = row
            end
            frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            frame.empty:SetPoint("TOPLEFT", 12, -94) frame.empty:SetWidth(590)
            frame.previous = button(frame, "Prev", 50, -120, -376, function() page = page - 1 S.refreshSelling() end)
            frame.next = button(frame, "Next", 50, -8, -376, function() page = page + 1 S.refreshSelling() end)
            frame.pageText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            frame.pageText:SetPoint("TOPRIGHT", -66, -382)
            frame.ownedHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            frame.ownedHint:SetPoint("TOPLEFT", 12, -406) frame.ownedHint:SetWidth(596) frame.ownedHint:SetJustifyH("LEFT")
            local note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            note:SetPoint("BOTTOMLEFT", 12, 10) note:SetWidth(596) note:SetJustifyH("LEFT")
            note:SetText("Matches purchased item types, not tracked inventory. LIST fills one carried stack; click native Post to list.")
            frame.sellRows = rows
            frame:SetScript("OnShow", S.refreshSelling)
            frame:SetScript("OnHide", stopOwnedExpiry)
        end
        mode = "bags" page = 1
        frame:Show() S.refreshSelling()
    end
end

local function printPortfolio()
    local rows = holdingsSnapshot()
    if #rows == 0 then
        printf("no priced holdings in your bags - buy something first.")
        return
    end
    local totalPaid, totalNow, unpriced = 0, 0, 0
    printf("|cffffd100carried holdings|r - %d item type(s); last-paid references, not cost basis:", #rows)
    for _, h in ipairs(rows) do
        local name = infoOf(h.id).name or ("item " .. h.id)
        if h.med then
            local proceeds = math.floor(h.med * h.qty * (1 - (cfg.cut or 0.05)))
            local difference = proceeds - h.paid * h.qty
            totalPaid = totalPaid + h.paid * h.qty
            totalNow = totalNow + proceeds
            local tr = bookTrend(h.id)
            local vel = absorbVelocity(h.id)
            local advice
            if proceeds < h.paid * h.qty then
                advice = "|cffff4d4dbelow last-paid reference after cut|r"
            elseif tr < -0.05 then
                advice = "|cffff8800SELL NOW|r - market sinking, front the queue"
            elseif tr > 0.05 and vel and vel < 120 then
                advice = "|cff7cff4fHOLD|r - rising and hot, let it run"
            elseif vel and vel > 600 then
                advice = "|cff888888slow absorber - consider undercutting to exit|r"
            else
                advice = "|cff888888bank it - flat market|r"
            end
            printf("  |cffffd100%s|r x%d - last paid %s/ea, median %s/ea; estimated difference %s. %s",
                name, h.qty, fmtMoney(h.paid), fmtMoney(math.floor(h.med)), fmtSignedMoney(difference), advice)
        else
            unpriced = unpriced + 1
            printf("  |cffffd100%s|r x%d - last paid %s/ea |cff888888(no fresh market; excluded from comparison)|r",
                name, h.qty, fmtMoney(h.paid))
        end
    end
    local net = totalNow - totalPaid
    printf("priced holdings only: %s last-paid reference, %s estimated after-cut proceeds; difference %s. %d unpriced item type(s) excluded.",
        fmtMoney(totalPaid), fmtMoney(totalNow), fmtSignedMoney(net), unpriced)
    printf("estimates exclude deposits and do not prove sales, inventory cost basis or realized profit.")
end

-- Explicitly armed cancellation requests. API acceptance is not evidence that
-- an auction was cancelled; confirmation still belongs to the client/server.
local cancelArmed = false

function S.submitCancellation(auctionID, sent, requiresEnabled)
    auctionID = num(auctionID)
    if not auctionID or auctionID <= 0 or auctionID % 1 ~= 0 or sent[auctionID]
        or (S.sellingCancelSent and S.sellingCancelSent[auctionID]) or (requiresEnabled and not cfg.enabled)
        or not S.ahOpen or S.snipePending or db.unsettledPurchase or not throttleGate()
        or not (C_AuctionHouse and C_AuctionHouse.CanCancelAuction and C_AuctionHouse.CancelAuction) then return false end
    local ok, allowed = pcall(C_AuctionHouse.CanCancelAuction, auctionID)
    if not ok or allowed ~= true or sent[auctionID] or not S.ahOpen
        or (S.sellingCancelSent and S.sellingCancelSent[auctionID]) or (requiresEnabled and not cfg.enabled)
        or S.snipePending or db.unsettledPurchase or not throttleGate() then return false end
    S.sellingCancelSent = S.sellingCancelSent or {}
    S.sellingCancelSent[auctionID] = true
    sent[auctionID] = true -- an exception may follow server acceptance; do not retry automatically
    local posted, e = pcall(C_AuctionHouse.CancelAuction, auctionID)
    if not posted then err("CancelAuction", e) return false end
    db.stats.cancelRequests = (db.stats.cancelRequests or 0) + 1
    return true
end

local function onOwnedAuctionsUpdated()
    -- Consume permission before display refresh calls any client getters.
    local cancellation = cancelArmed
    cancelArmed = false
    if S.ahOpen then
        S.sellingOwnedUpdated = GetTime()
        S.sellingOwnedDisplay = nil
        S.refreshSelling()
    end
    if not S.ahOpen or not cfg.enabled then return end
    if cancellation and (S.snipePending or db.unsettledPurchase or not throttleGate()) then cancellation = nil end
    if not C_AuctionHouse or C_AuctionHouse.GetNumOwnedAuctions == nil then return end
    local okN, n = pcall(C_AuctionHouse.GetNumOwnedAuctions)
    n = okN and math.floor(num(n) or 0) or 0
    if n == 0 then return end
    local t = time()
    for i = 1, n do
        local okI, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, i)
        if okI and type(info) == "table" then
            local itemID = info.itemKey and info.itemKey.itemID
            local buyout = num(info.buyoutAmount)
            local qty = num(info.quantity)
            if itemID and buyout and buyout > 0 and qty and qty > 0 and qty % 1 == 0 then
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
                            printf("|cffff8800PRICE CHECK|r %s - you list at %s, recent median %s. Verify live listings before canceling.",
                                info.itemLink or (infoOf(itemID).name or ("item " .. itemID)),
                                fmtMoney(unit), fmtMoney(math.floor(med)))
                            playTierSound("SNIPE")
                        end
                        local auctionID = num(info.auctionID)
                        if cancellation and S.submitCancellation(auctionID, cancellation.sent, true) then
                            printf("  cancellation submitted for auction %d; check your auctions before relisting at %s.",
                                auctionID, fmtMoney(math.floor(med)))
                        end
                    end
                end
            end
        end
    end
end

-- The inbox is a current balance, not a durable sales ledger. Reordering or
-- rereading mail must not inflate lifetime proceeds or pretend to establish P&L.
local function scanMailbox()
    if GetInboxNumItems == nil then return end
    local okN, n = pcall(GetInboxNumItems)
    n = okN and math.floor(num(n) or 0) or 0
    local count, proceeds = 0, 0
    for i = 1, n do
        if GetInboxInvoiceInfo then
            local okI, invoiceType, _, _, bid, _, deposit, consignment =
                pcall(GetInboxInvoiceInfo, i)
            if okI and invoiceType == "seller" then
                local received
                if GetInboxHeaderInfo then
                    local okH, _, _, _, _, money = pcall(GetInboxHeaderInfo, i)
                    received = okH and num(money) or nil
                elseif num(bid) and num(deposit) and num(consignment) then
                    received = bid + deposit - consignment
                end
                if received and received >= 0 then
                    count, proceeds = count + 1, proceeds + received
                end
            end
        end
    end
    local previous = db.mailboxSnapshot
    db.mailboxSnapshot = {t=time(), count=count, proceeds=proceeds}
    if count > 0 and (not previous or previous.count ~= count or previous.proceeds ~= proceeds) then
        printf("auction sale mail observed: %d message(s), %s currently attached (not profit).", count, fmtMoney(proceeds))
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
    diagnostic("boot", string.format("login: book=%d seen=%d saved counter=%s enabled=%s runtime DB matches saved global=%s",
        countKeys(db.book or {}), countKeys(db.seen or {}),
        tostring(db.stats and db.stats.book), tostring(cfg.enabled), tostring(db == ForeverSniperDB)))
    db.stats.book = countKeys(db.book)
    -- the desktop app's overnight briefing (file-based, written while the game
    -- was closed): print once, then clear so it never shows twice
    if type(ForeverSniperBriefing) == "table" and ForeverSniperBriefing.lines
        and #ForeverSniperBriefing.lines > 0 then
        printf("|cffffd100overnight briefing|r (from ForeverDesktop):")
        for _, l in ipairs(ForeverSniperBriefing.lines) do
            printf("  |cffc8c8c8%s|r", tostring(l))
        end
        ForeverSniperBriefing = nil
    end
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
        printf("|cffff7d0aWelcome to Forever Sniper|r - local auction deal finder.")
        printf("1. open the Auction House - it learns prices and hunts deals automatically")
        printf("2. type |cffffd100/fsn feed|r for the live deal window (click a row to check prices, BUY to buy)")
        printf("3. |cffffd100VENDOR|r alerts compare purchase costs with the learned vendor value")
        printf("everything else: |cffffd100/fsn help|r")
    else
        printf("armed. /fsn help - visits to the AH build the price book (alert %d%% of market).",
            math.floor(cfg.threshold * 100 + 0.5))
    end
end)

on("PLAYER_LOGOUT", function()
    diagnostic("boot", string.format("logout: book=%d seen=%d enabled=%s",
        countKeys(db.book), countKeys(db.seen or {}), tostring(cfg.enabled)))
end)

-- COEXISTENCE: if ForeverForge Auction is installed, it owns the throttle -
-- our constant sweep would slow their sniper down. We stand down (no sweep,
-- no deep scan) unless you explicitly take over with /fsn on.
local function ffAuctionPresent()
    return _G.ForeverForgeAuction ~= nil or _G.ForeverForge ~= nil
end

on("AUCTION_HOUSE_SHOW", function()
    S.ahOpen = true
    S.sellingOwnedUpdated, S.sellingOwnedRequest = nil, nil
    S.sellingOwnedDisplay = nil
    S.showSelling(true)
    if next(S.boughtAt) then S.requestSellingOwned() end
    S.warnedBrowse = nil -- the yield hint fires once per AH session
    if cfg.scanPage then
        buildScanPage() scanPage:Show() updateScanPage()
    end
    after(0.5, avoidBrowseTab) -- let the frame settle on Browse, then move off it
    if cfg.enabled and C_AuctionHouse then
        if ffAuctionPresent() and not S.ffOverride then
            printf("|cff888888ForeverForge detected - ForeverSniper stands down so its sniper owns the throttle. /fsn on to take over.|r")
        else
            startSweeping()
            after(2, requestReplicate) -- replicate is the book bootstrap, not the feed
            -- NO auto deep scan: it fires while the replicate dump is still
            -- in flight and returns empty (proven live). The sweep's own
            -- category rotation primes the book; /fsn deepscan to re-prime.
        end
    end
    -- the deal feed auto-opens with the auction house (cfg.feedPage)
    if cfg.feedPage ~= false then
        buildFeed()
        if not feedFrame:IsShown() then
            feedFrame:Show()
            refreshFeed()
        end
    end
end)

on("BAG_UPDATE_DELAYED", function() S.refreshSelling() end)

-- UI error capture: Blizzard's own refusals ("not enough gold", "item already
-- sold", ...) are not Lua errors and never reach ErrorTap - they only flash
-- in the red error frame. Hook it, dedupe per session, and hand the text to
-- both our own error log and ErrorTap's relay table so the PC-side watcher
-- ships it to the error inbox exactly like a Lua error.
-- SCOPED 2026-10-12: this hook used to relay EVERY red text - "you need to be
-- closer to interact with that target", "the merchant doesn't want that
-- item", combat spam - each filed as a ForeverSniper error with an empty
-- stack, shipping gameplay noise to the error inbox and waking false AI
-- turns. Our buy/post/cancel calls can only be refused while the AH window
-- is actually open, and only money/AH wording is ours to report.
do
    local seenUiErr = {}
    -- money/AH vocabulary: a red text outside this set is gameplay, not ours.
    -- TIGHTENED 2026-10-12, 2nd pass: the first cut kept "item", "bag",
    -- "mail", "sell", ... and those words appear in ordinary gameplay red
    -- text ("the merchant doesn't want that item", "item is not ready yet") -
    -- the very noise this scoping exists to stop. A refusal is only ours when
    -- the wording itself is AH-specific; a missed refusal is cheap, a false
    -- AI wake is not.
    local AH_WORDS = {
        "auction", "bid", "buyout", "deposit", "gold",
    }
    local function ahRefusal(msg)
        local m = strlower(msg)
        for _, w in ipairs(AH_WORDS) do
            if m:find(w, 1, true) then return true end
        end
        return false
    end
    -- S.ahOpen alone lies if AUCTION_HOUSE_CLOSED ever misses us (event-name
    -- drift like REPLICATE_ITEM_LIST_UPDATE/UPDATED, another addon forcing
    -- the window shut): the flag sticks true and the next gameplay red text
    -- with a matching word ships. Ask the window itself - 8.3-style clients
    -- name it AuctionHouseFrame, older ones AuctionFrame; only a client with
    -- neither frame falls back to the flag.
    local AH_FRAMES = { "AuctionHouseFrame", "AuctionFrame" }
    local function ahActuallyOpen()
        local known = false
        for _, name in ipairs(AH_FRAMES) do
            local fr = _G[name]
            if type(fr) == "table" and type(fr.IsVisible) == "function" then
                known = true
                if fr:IsVisible() then return true end
            end
        end
        return not known and S.ahOpen or false
    end
    local function captureUiError(msg)
        if type(msg) ~= "string" or msg == "" then return end
        if not ahActuallyOpen() then return end  -- AH closed: not our refusal
        if not ahRefusal(msg) then return end  -- unrelated red text
        local key = msg:sub(1, 120)
        if seenUiErr[key] then return end
        seenUiErr[key] = true
        err("ui-error", msg)
        printf("|cffff6666AH/UI error:|r %s", (msg:gsub("|", "/")))
        pcall(function()
            local E = _G and _G.ErrorTapDB
            if E and type(E.relay) == "table" then
                local clean = msg:gsub("[\r\n|\"']", " "):gsub("%s+", " "):sub(1, 300)
                local _, build = GetBuildInfo()
                -- prefixed so the inbox can tell a game refusal (no stack,
                -- no Lua error) from a real traceback at a glance
                E.relay[#E.relay + 1] = table.concat(
                    { time(), tostring(build), "ForeverSniper", 1, "ui-error: " .. clean, "" }, "|")
            end
        end)
    end
    if UIErrorsFrame and hooksecurefunc then
        local ok = pcall(hooksecurefunc, UIErrorsFrame, "AddMessage", function(_, msg)
            captureUiError(msg)
        end)
        if not ok then err("ui-error", "could not hook UIErrorsFrame") end
    end
end

on("AUCTION_HOUSE_CLOSED", function()
    cancelArmed = false
    S.ahOpen = false
    S.sellingOwnedUpdated, S.sellingOwnedRequest, S.sellingCancelSent = nil, nil, nil
    S.sellingOwnedDisplay = nil
    if ForeverSniperSelling then ForeverSniperSelling:Hide() end
    S.dealFocus = nil
    S.autoSearch, S.watchSearch = nil, nil
    S.commoditySnapshots = {}
    S.liveCandidate, S.liveCandidates = nil, nil
    S.stopSnapshot()
    retirePurchase("auction house closed")
    S.outcomeOwner = nil
    S.snipePending, S.quote, S.buying, S.pending, S.batchBuy, S.batch = nil, nil, nil, nil, nil, nil
    deepAbort(false)
    pagePending, throttleReady = false, true
    if feedFrame then feedFrame:Hide() end
    stopSweeping()
    if scanPage then updateScanPage() end
    scanMailbox() -- sales land while trading
    -- compact session summary: what the printer did while you were in there
    local best = S.session.best
    if best and best.profit and best.profit > 0 then
        printf("session: |cffffd100%d buy(s)|r for |cffff4d00%s|r; observed mail proceeds %s (not profit). Best find %s |cff7cff4f+%s|r estimated.",
            S.session.buys or 0, fmtMoney(S.session.spent or 0),
            fmtMoney(db.mailboxSnapshot and db.mailboxSnapshot.proceeds or 0),
            infoOf(best.id).name or ("item " .. best.id), fmtMoney(best.profit))
    end
end)

do
local function readDeepBrowse(added)
    local owner = S.deepScan
    local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
    if S.deepScan ~= owner or not S.ahOpen or not cfg.enabled then return end
    if ok and type(rows) == "table" then
        local extra = added and math.max(0, #rows - (S.browseRecorded or 0)) or #rows
        if not added then S.browseRecorded = 0 end
        processBrowseRows(rows, added, "deep discovery")
        owner.rows = (owner.rows or 0) + extra
        if not added then owner.received = true end
        deepMore()
    end
end

on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    if S.readBatch() then return end
    -- a fresh result set answers our sweep (or any manual search); read it
    if S.deepScan and not S.deepScan.needsSend and S.deepScan.lastReq and C_AuctionHouse.GetBrowseResults then
        readDeepBrowse(false)
        return
    end
    if S.sweeping and C_AuctionHouse.GetBrowseResults then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            dbg("browse results: " .. #rows .. " row(s)")
            S.sweepStats.rows = S.sweepStats.rows + #rows
            S.sweepStats.lastRows = #rows
            S.browseRecorded = 0 -- a fresh answer starts the set over
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
    if S.readBatch() then return end
    -- the next page landed: process it, keep paging until full
    if S.deepScan and not S.deepScan.needsSend and S.deepScan.lastReq and C_AuctionHouse.GetBrowseResults then
        readDeepBrowse(true)
        return
    end
    if S.sweeping and C_AuctionHouse.GetBrowseResults then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            processBrowseRows(rows, true)
        end
        maybeMorePages()
    end
end)
end

-- Event-driven throttle (WoWSniper's approach: never guess, listen)
onOptional("OWNED_AUCTIONS_UPDATED", function() onOwnedAuctionsUpdated() end)
onOptional("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    throttleReady = true
    if S.refreshPurchasePresentation then S.refreshPurchasePresentation() end
    S.wakeSweep()
end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", function()
    throttleReady = true
    if S.refreshPurchasePresentation then S.refreshPurchasePresentation() end
    S.wakeSweep()
end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function() throttleReady = false end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", function() throttleReady = false end)
onOptional("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    if S.batchSearch then S.failBatch("request dropped; individual fallback") end
    throttleReady = true
    pagePending = false -- wake a paced retry rather than waiting for the watchdog
    S.wakeSweep()
end)
onOptional("AUCTION_HOUSE_BROWSE_FAILURE", function()
    if S.batchSearch then S.failBatch("browse failed; individual fallback") end
end)

local function onReplicateUpdated()
    dbg("replicate completion event fired")
    completeScan("event")
end
-- Some clients accept registration of both names but emit only one.
onOptional("REPLICATE_ITEM_LIST_UPDATE", onReplicateUpdated)
onOptional("REPLICATE_ITEM_LIST_UPDATED", onReplicateUpdated)

-- Print the cheapest live listings for the last row clicked.
local function printPending(kind, itemID)
    local p = S.pending
    if not p or GetTime() - p.t > 10 then return end
    if itemID and itemID ~= p.itemID then return end
    if p.commodity == true and kind ~= "commodity" or p.commodity == false and kind ~= "item" then return end
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

on("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local itemID = type(itemKey) == "table" and itemKey.itemID or num(itemKey)
    -- watch-rule search results first: cheapest listing under the rule's
    -- ceiling fires a watch alert immediately
    local ws = S.watchSearch
    if ws and ws.commodity ~= true and (not itemID or itemID == ws.id)
        and GetTime() - ws.t < 10 and C_AuctionHouse.GetItemSearchResultInfo then
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
                    local mx = watchMaxFor(ws.id, ws.rule or { maxPrice = ws.maxPrice })
                    if mx and infoOf(ws.id).stackable == true and unit <= mx then
                        fireAlert("watch", ws.id, info.itemLink,
                            unit, nil, { units = qty, cost = buyout, line = ws.maxPrice })
                    end
                end
            end
        end
        return
    end
    printPending("item", itemID)
end)
-- watch rules checked against LIVE commodity results: the interleaved
-- target rotation re-searches every couple of sweeps, so a listing under
-- the target is alerted within seconds of being posted
local function checkWatchCommodity(itemID)
    rebuildWatch()
    if not watchByID[itemID] then
        rebuildWatch()
        if not watchByID[itemID] then return end
    end
    local w = watchByID[itemID]
    local wmax = watchMaxFor(itemID, w)
    if not wmax then return end -- value target whose value is not known yet
    if not C_AuctionHouse.GetNumCommoditySearchResults then return end
    local okN, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    n = okN and math.floor(num(n) or 0) or 0
    if n <= 0 then return end
    local okR, res = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, 1)
    if not okR or type(res) ~= "table" then return end
    local price = num(res.unitPrice) or num(res.buyoutAmount)
    local qty = num(res.quantity) or 1
    if price and price > 0 and price <= wmax and isNewListing(itemID, price) then
        fireAlert("watch", itemID, res.itemLink, price, nil,
            { units = qty, cost = price * qty, line = wmax })
    end
end

local function onCommodityResults(itemID)
    if not S.ahOpen then return end
    itemID = num(itemID)
    if not itemID or itemID < 1 or itemID % 1 ~= 0 then return end
    S.wakeSweep()
    local waiting = S.liveCandidates and S.liveCandidates[itemID]
    if waiting and waiting.forceSearch and not (S.liveCandidate and S.liveCandidate.id == itemID
        or S.watchSearch and S.watchSearch.id == itemID or S.autoSearch and S.autoSearch.id == itemID) then
        return
    end
    local snapshot, reason, identity = readCommodityTiers(itemID)
    if identity then diagnostic("commodity result identity", identity) end
    if snapshot then
        local previous = S.commoditySnapshots[itemID]
        if previous and previous.remainder == S.remainderRetry then snapshot.remainder = previous.remainder end
        S.commoditySnapshots[itemID] = snapshot
        S.noteRevisit(itemID)
    elseif reason == "unreadable" then
        S.commoditySnapshots[itemID] = nil
    elseif reason == "empty" then
        -- A completed empty reply is not the temporary clearing of a refresh.
        S.commoditySnapshots[itemID] = nil
        markDealGone(itemID, math.huge)
    end
    -- A reply can arrive in the same tick as the request. Paging belongs to
    -- the scheduler so every search lane obeys the same throttle and spacing.
    local owner = S.liveCandidate or S.autoSearch or S.watchSearch
    if owner and owner.id == itemID and reason == "loading" then
        owner.needsPage = type(C_AuctionHouse.RequestMoreCommoditySearchResults) == "function"
        return
    end
    if owner and owner.id == itemID then
        if snapshot then
            snapshot.timing = {detectedAt=owner.detectedAt, searchAt=owner.searchStartedAt,
                method=S.searchMethods and S.searchMethods[itemID]}
        end
        S.completePrebuy(owner, snapshot, reason)
    end
    local target = S.autoSearch
    if target and target.id == itemID then
        S.autoSearch = nil
        if snapshot then
            local quantity, minimum = 0, nil
            for _, tier in ipairs(snapshot.tiers) do
                quantity = quantity + tier.quantity
                if tier.quantity > 0 then minimum = math.min(minimum or tier.price, tier.price) end
            end
            if minimum then
                local recorded = S.browseRecorded
                processBrowseRows({{itemKey={itemID=itemID}, minPrice=minimum, totalQuantity=quantity}}, nil, "automatic check")
                S.browseRecorded = recorded -- an item search is not a browse page
            end
            S.sweepStats.autoCompleted = (S.sweepStats.autoCompleted or 0) + 1
        else
            recordGate("automatic check", reason or "no snapshot", itemID)
        end
    end
    local c = S.liveCandidate
    -- A completed automatic check may just have queued this candidate. Its
    -- event-owned full tiers already satisfy preparation; do not search twice.
    local queued = snapshot and S.liveCandidates and S.liveCandidates[itemID]
    if queued and not queued.prebuy and not queued.remainder and not queued.forceSearch then
        if not c or c.id ~= itemID then c = queued end
        S.liveCandidates[itemID] = nil
    end
    if snapshot and (not c or c.id ~= itemID) then
        c = nil
        -- Fresh complete results also refresh displayed offers when they came
        -- from an automatic/manual search rather than our preparation queue.
        for _, deal in ipairs(S.deals) do
            if deal.id == itemID and not deal.bought and not deal.gone and deal.line then
                c = {id=itemID, link=deal.link, line=deal.line, market=deal.market,
                    kind=offerKind(itemID, deal.line, deal.kind) or (deal.market and "market" or "watch"), refresh=true}
                break
            end
        end
    end
    if cfg.enabled and S.ahOpen and c and c.id == itemID then
        if S.liveCandidate == c then S.liveCandidate = nil end
        if not snapshot then
            recordGate("validation", reason or "no snapshot", itemID)
            return
        end
        local terms, rejected
        if c.remainder or snapshot.remainder then
            snapshot.remainder = c.remainder or snapshot.remainder
            terms, rejected = S.remainderTerms(itemID, c.line, nil, nil, c.market, c.kind, snapshot)
        else
            terms, rejected = S.optimizedCommodityTerms(itemID, c.line, c.market, c.kind, snapshot)
        end
        if terms then
            if c.remainder then
                diagnostic("remainder ready", string.format("item %d; x%d at or under %.0f copper; total %.0f copper; press BUY for a new guarded quote",
                    itemID, terms.units, terms.line, terms.cost))
            end
            snapshot.timing = snapshot.timing or {}
            snapshot.timing.detectedAt = c.detectedAt
            snapshot.timing.validatedAt = GetTime()
            if c.detectedAt then
                local stats = S.sweepStats
                stats.validationLast = math.max(0, GetTime() - c.detectedAt)
                stats.validationMax = math.max(stats.validationMax or 0, stats.validationLast)
                if c.searchStartedAt then
                    stats.responseLast = math.max(0, GetTime() - c.searchStartedAt)
                    stats.responseMax = math.max(stats.responseMax or 0, stats.responseLast)
                end
            end
            fireAlert(c.kind, itemID, c.link, terms.first, terms.resale,
                {units=terms.units,cost=terms.cost,profit=terms.profit,line=terms.line or c.line,verified=true}, true)
        else
            local reasons = {empty="no units below ceiling", budget="complete position exceeds budget",
                profit="net after competition and deposit below floor", invalid="invalid position data",
                quality="quality below floor", stackable="not stackable", iteminfo="item info loading",
                overhang="live competing stock over limit", stocklimit="per-item stock limit reached",
                 liquidity="fresh regional sales below liquidity policy",
                 salesvolume="no verified positive regional daily sales",
                 vendorprofit="insufficient verified NPC profit",
                stockinfo="stock data unavailable or stale"}
            recordGate("validation", reasons[rejected] or rejected, itemID)
            if c.refresh then markDealGone(itemID, math.huge) end
        end
    end
    -- watch rules fire from the LIVE commodity results of our interleaved
    -- target searches - seconds after a target drops under its max
    if S.watchSearch and GetTime() - S.watchSearch.t < 10 and itemID == S.watchSearch.id then
        S.watchSearch = nil
        checkWatchCommodity(itemID)
    end
    printPending("commodity", itemID)
    if S.feedRefresh then S.feedRefresh() end
    renderPopup()
end
on("COMMODITY_SEARCH_RESULTS_UPDATED", onCommodityResults)
onOptional("COMMODITY_SEARCH_RESULTS_ADDED", onCommodityResults)
on("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    -- snipe mode: the BUY press started this quote; confirm only if the live
    -- total is within tolerance of the snapshot, otherwise abort, never overpay.
    -- (This client passes unitPrice AND totalPrice - the total decides.)
    local sp = S.snipePending
    local t = num(totalPrice)
    if sp then
        if sp.confirmed then return end -- ignore duplicate quotes
        local u = num(unitPrice)
        local ceiling = sp.maxUnit or (sp.tolTotal / math.max(1, sp.units))
        local budget = math.min(sp.walletCap or math.huge,
            S.purchaseBudget() - (sp.reserve or 0))
        local age = GetTime() - sp.t
        local rejected
        if not cfg.enabled then rejected = "scanner disabled"
        elseif not S.ahOpen then rejected = "auction house closed"
        elseif db.blacklist[sp.deal.id] then rejected = "item blacklisted"
        elseif not S.offerAvailable(sp.offer) then rejected = "displayed offer retired"
        elseif age > 2 then rejected = "quote older than 2 seconds"
        elseif not u or u < 1 or u % 1 ~= 0 then rejected = "unreadable unit price"
        elseif not t or t < sp.units or t < u or t % 1 ~= 0 then rejected = "unreadable total price"
        elseif u > ceiling then rejected = "unit price above approved ceiling"
        elseif t > sp.tolTotal then rejected = "total above approved purchase cost"
        elseif t > budget then rejected = "total above current budget"
        elseif sp.kind == "vendor" and select(3,S.exitPolicy(sp.deal.id,"vendor",sp.units,t,sp.market)) then
            rejected = "quote below vendor profit floor"
        end
        S.logPurchaseTiming(sp, rejected or "price caps passed")
        if rejected then
            local detail = string.format("%s; item %d x%d; quote unit/total %s/%s copper; caps unit/total/budget %.0f/%.0f/%.0f copper; age %.2fs",
                rejected, sp.deal.id, sp.units, tostring(u), tostring(t), ceiling, sp.tolTotal, budget, age)
            retirePurchase("quote refused: " .. rejected)
            if rejected == "unit price above approved ceiling" or rejected == "total above approved purchase cost" then
                -- The quote contradicts these tiers. Never offer the same cached
                -- bargain again without a new completed search.
                S.commoditySnapshots[sp.deal.id] = nil
                markDealGone(sp.deal.id, math.huge)
                prepareCommodityDeal(sp.deal.id, sp.deal.link, sp.maxUnit, sp.market, sp.kind)
                local candidate = S.liveCandidates and S.liveCandidates[sp.deal.id]
                if candidate then candidate.forceSearch = true end
                S.queueRemainderRetry(sp)
                S.wakeSweep()
            end
            recordGate("purchase", "quote rejected: " .. rejected, sp.deal.id)
            diagnostic("purchase quote", detail)
            printf("quote refused: %s; nothing confirmed. /fsn diagnostics for quote details.", detail)
            if S.feedRefresh then S.feedRefresh() end
            return
        end
        -- The click freezes the exit and position caps, not permission to
        -- ignore policy changes or buy part of a wall that grew in flight.
        local terms, reason = commodityOfferTerms(sp.deal.id, sp.maxUnit, sp.units, sp.expected, sp.market, sp.kind)
        if not terms or terms.units ~= sp.units then
            retirePurchase("quote position rejected: " .. (reason or "quantity changed"))
            recordGate("purchase", "quote rejected: " .. (reason or "quantity changed"), sp.deal.id)
            printf("quote refused: complete position no longer eligible (%s); nothing confirmed.", reason or "quantity changed")
            if S.feedRefresh then S.feedRefresh() end
            return
        end
        sp.confirmed, sp.total, sp.offer = true, t, nil
        db.unsettledPurchase, S.outcomeOwner = sp, sp
        -- Keep ownership until the outcome event; a successful API call
        -- is not evidence that the server completed the purchase.
        local ok, e = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, sp.deal.id, sp.units)
        if not ok then
            err("ConfirmCommoditiesPurchase", e)
            if S.snipePending == sp then retirePurchase("purchase confirmation API error") end
            if db.unsettledPurchase == sp then
                printf("purchase confirmation raised an error; outcome unknown. Check /fsn purchase.")
            end
        elseif db.unsettledPurchase == sp then
            printf("purchase submitted - waiting for the server result.")
        end
        return
    end
end)

-- purchase outcome events (ForeverForge's set, proven on 1.60.1): the
-- Unkeyed outcomes belong only to a purchase confirmed in this AH session.
-- After closing/reloading, uncertain records require explicit reconciliation.
on("COMMODITY_PURCHASE_SUCCEEDED", function()
    finishPurchase(S.outcomeOwner, "server confirmed")
end)
on("COMMODITY_PURCHASE_FAILED", function()
    local p = S.snipePending or S.outcomeOwner
    S.purchaseResult(p, "server reported purchase failed")
    if S.outcomeOwner and db.unsettledPurchase == S.outcomeOwner then
        db.unsettledPurchase, S.outcomeOwner = nil, nil
    end
    if p then
        local id = p.deal and p.deal.id
        if id then buyFailUntil[id] = GetTime() + 180 end
        S.snipePending = nil
        printf("the snipe purchase didn't go through - resuming.")
        S.refreshPurchasePresentation()
    end
end)
on("COMMODITY_PRICE_UNAVAILABLE", function()
    if S.snipePending then
        local id = S.snipePending.deal and S.snipePending.deal.id
        if id then
            buyFailUntil[id] = GetTime() + 120
            markDealGone(id, math.huge) -- no quote at all: the deal is dead
        end
        retirePurchase("price unavailable after submission")
        printf(db.unsettledPurchase and "purchase outcome unknown; check mail and /fsn purchase." or "that price is unavailable - resuming scans.")
    end
end)
on("AUCTION_HOUSE_SHOW_ERROR", function(errText)
    -- an AH error drops any purchase in progress; clear the pending state so
    -- a later quote can never confirm it
    if S.snipePending then
        local id = S.snipePending.deal and S.snipePending.deal.id
        if id then buyFailUntil[id] = GetTime() + 120 end
        retirePurchase("auction house error")
        printf("AH error: %s. %s", tostring(errText):sub(1, 160),
            db.unsettledPurchase and "Outcome remains unknown; check /fsn purchase." or "Nothing confirmed.")
    end
end)

-- merchant learner: the buyback list records what a vendor REALLY paid for
-- everything sold to it - exact vendor prices, no guessing
on("MERCHANT_SHOW", function()
    C_Timer.After(1, function()
        if GetNumBuybackItems == nil or GetBuybackItemLink == nil then return end
        db.vendorVerified = db.vendorVerified or {}
        local n = GetNumBuybackItems() or 0
        for i = 1, n do
            local okI, _, _, price, quantity = pcall(GetBuybackItemInfo, i)
            local okL, link = pcall(GetBuybackItemLink, i)
            local id = okL and link and tonumber(tostring(link):match("item:(%d+)"))
            if okI and num(price) and price > 0 and num(quantity) and quantity > 0 and id then
                db.vendorVerified[tostring(id)] = math.floor(price / quantity)
            end
        end
    end)
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
    stepper(96, "fallback seconds", function() return cfg.sweep end,
        function(v)
            cfg.sweep = math.min(30, math.max(2, math.floor(v)))
            if S.sweepTicker then stopSweeping() startSweeping() end
        end,
        function(v) return tostring(v) .. "s between sweeps" end, 1)
    stepper(152, "spend cap (gold)", function() return cfg.maxSpend / 10000 end,
        function(v) cfg.maxSpend = math.max(1, math.floor(v)) * 10000 end,
        function(v) return math.floor(v + 0.5) .. "g per Buy" end, 25)
    stepper(208, "unit floor (silver)", function() return cfg.minUnit / 100 end,
        function(v) cfg.minUnit = math.max(1, math.floor(v)) * 100 end,
        function(v) return math.floor(v + 0.5) .. "s per unit min" end, 1)
    stepper(264, "profit floor (silver)", function() return cfg.profit / 100 end,
        function(v) cfg.profit = math.max(0, math.floor(v)) * 100 end,
        function(v) return (v < 0.5 and "off" or math.floor(v + 0.5) .. "s min profit") end, 5)
    stepper(320, "snipe tolerance %", function() return cfg.tolerance or 5 end,
        function(v) cfg.tolerance = math.min(50, math.max(0, math.floor(v))) end,
        function(v) return tostring(v) .. "% quote leeway" end, 1)
    stepper(376, "keep gold", function() return cfg.keepGold / 10000 end,
        function(v) cfg.keepGold = math.max(0, math.floor(v)) * 10000 end,
        function(v) return tostring(v) .. "g reserved" end, 1)
    stepper(432, "stock per item", function() return cfg.maxStock end,
        function(v) cfg.maxStock = math.max(0, math.floor(v)) end,
        function(v) return v == 0 and "off" or (tostring(v) .. " units") end, 20)
    optionsFrame:SetHeight(490)
end
-- Slash commands ---------------------------------------------------------------------

local HELP = {
    "/fsn capture once | off - save one local full-game screenshot on the next purchase failure",
    "|cffff7d0aForever Sniper|r - it watches, you buy",
    "|cffffd100core|r",
    "/fsn                  status",
    "/fsn portfolio         carried holdings: last-paid references vs estimated proceeds",
    "/fsn feed             deal window (click a row = live prices, BUY = buy)",
    "/fsn sell             bought items: bags, cheap owned listings and purchase history",
    "/fsn profit           money printer stats (session + lifetime)",
    "/fsn purchase         inspect an unknown purchase outcome; bought|failed reconciles after checking mail",
    "/fsn purchases        recent settled purchase records (not inventory cost basis or profit)",
    "/fsn undercut         guard your listings (alert when undercut)",
    "/fsn cancel           cancel every owned listing above market (relist front)",
    "/fsn relist [go]      plan the batch; add go to post every held flip at its smart price",
    "/fsn options          settings panel",
    "/fsn page             scanner monitor window (toggle)",
    "/fsn deepscan         page every category into the book (auto every 15 min)",
    "/fsn bind buy <key>   one-press buy the best deal (e.g. ctrl-b)",
    "/fsn on | off         enable / disable",
    "/fsn watch <link> 50s watchlist rule (a plain item name works too)",
    "/fsn unwatch <link>|all",
    "|cffffd100tuning|r",
    "/fsn thresh 50        alert at %% of learned market (1-99)",
    "/fsn tsm [on|off|ID]  verified TSM reference status or per-item value",
    "/fsn sales [ID]      inspect regional sales; on/off, rate/share PCT set policy",
    "/fsn sweep 3          fallback tick seconds (2-30); ready events wake paced searches",
    "/fsn batch on|off     experimental 100-key summaries; failures fall back to item checks",
    "/fsn targeted on|off  101 Normal Horde / Forever-EU materials; no routine broad queries",
    "/fsn prebuy on|off    diagnostic new-search test: first press searches, second buys",
    "/fsn max 250g         spend cap per Buy click",
    "/fsn keep 10g         keep this gold untouched (5% wallet buffer also applies)",
    "/fsn stock 200        default per-item exposure cap (0 = off)",
    "/fsn stock <ID> 100   item override; use inherit instead of 100 to remove it",
    "/fsn received <ID>    acknowledge ALL reserved purchases collected; never clears holdings",
    "/fsn min 10s          ignore deals under this per-unit price",
    "/fsn quality 2        minimum rarity for market alerts (0 = any)",
    "/fsn profit 1g        minimum estimated resale profit (0 = off)",
    "/fsn arm 2            scans of history before alerts fire",
    "/fsn fresh 45         minutes a price sample stays fresh (5-480)",
    "/fsn overhang 500     skip deals buried under more units (0 = off)",
    "/fsn every 45 / cut 5 full-scan cadence / assumed AH cut percent",
    "|cffffd100alerts|r - sound, flash, toast, pop, quiet",
    "|cffffd100data|r - alerts, watchlist, shape, errors, diagnostics, wipe book|all",
}

local function usageWatch(rest)
    -- "/fsn watch [Item Link] 3g50s" - the money words come off the end.
    -- Value modes: "... vendor" = a copper under what a vendor pays;
    -- "... de [low|avg|high]" = a copper under its disenchant value.
    local words = { strsplit(" ", (rest:gsub("%s+", " "):gsub("^%s", ""))) }
    local mode, deRoll
    while #words > 0 do
        local lw = strlower(words[#words])
        if lw == "vendor" then
            mode = "vendor" table.remove(words)
        elseif lw == "de" or lw == "low" or lw == "avg" or lw == "high" then
            if lw == "de" then deRoll = deRoll or "low" else deRoll = lw end
            table.remove(words)
        else
            break
        end
    end
    local moneyWords = {}
    while #words > 0 and words[#words]:match("^%d[%dgGsScC]*$") do
        table.insert(moneyWords, 1, table.remove(words))
    end
    local price = parseMoney(table.concat(moneyWords, " "))
    local target = table.concat(words, " ")
    if (not price and not mode and not deRoll) or target == "" then
        printf("usage: /fsn watch <item link or name> <price>   e.g. /fsn watch [Linen Cloth] 50s")
        printf("value modes: /fsn watch [item] vendor   |   /fsn watch [item] de [low|avg|high]")
        return
    end
    local itemID = tonumber(target:match("|Hitem:(%d+)"))
    if itemID then
        local rule = { maxPrice = price }
        if mode then rule.vendorMode = true end
        if deRoll then rule.deRoll = deRoll end
        db.watch[tostring(itemID)] = rule
        local how = mode and "at or under what a vendor pays"
            or (deRoll and ("at or under its DE value (" .. deRoll .. " roll)"))
            or ("at or under " .. fmtMoney(price))
        printf("watching %s %s.", target:match("%[(.+)%]") or target, how)
    else
        local ok, iid
        if C_Item and C_Item.GetItemInfoInstant then
            ok, iid = pcall(C_Item.GetItemInfoInstant, target)
        else
            ok, iid = pcall(GetItemInfoInstant, target)
        end
        if ok and iid then
            local rule = { maxPrice = price }
            if mode then rule.vendorMode = true end
            if deRoll then rule.deRoll = deRoll end
            db.watch[tostring(iid)] = rule
            local how = mode and "at or under what a vendor pays"
                or (deRoll and ("at or under its DE value (" .. deRoll .. " roll)"))
                or ("at or under " .. fmtMoney(price))
            printf("watching %s (item %d) %s.", target, iid, how)
        else
            db.watch["n:" .. strlower(target)] = { name = target, maxPrice = price, vendorMode = mode == "vendor", deRoll = deRoll }
            printf("watching %q by name at or under %s (resolves to an ID on first sighting).", target, fmtMoney(price))
        end
    end
end

-- TEST INTERFACE: a tiny global that lets the test harness verify the
-- pipeline. Only exists for automated testing - no gameplay impact.
if _G.FOREVER_SNIPER_TEST_MODE then
_G.ForeverSniperTest = {
    dealCount = function() return #S.deals end,
    state = S,
    groups = collectDealGroups,
    terms = commodityOfferTerms,
    readTiers = readCommodityTiers,
    commodityFor = commodityFor,
    ready = commodityOfferReady,
    smartPrice = smartPrice,
    optimize = S.optimizedCommodityTerms,
    stockAllowance = S.stockAllowance,
    budget = S.purchaseBudget,
    merge = mergeIntoBook,
    popupRows = popupRows,
    quickBuy = quickBuy,
    offer = snipeOffer,
    autoTarget = nextAutoTarget,
    discoveryScope = discoveryScope,
    stockObservation = trackSold,
    movementScore = movementScore,
    freshMedian = freshMedian,
    volatility = bookVolatility,
    trend = bookTrend,
    signedMoney = fmtSignedMoney,
    rowAt = function(i) return feedRows[i] end,
    toast = function() return toastFrame end,
    queryReady = canQuery,
    checkUndercuts = checkUndercuts,
    sendTarget = sendTargetSearch,
    alert = fireAlert,
    prepare = prepareCommodityDeal,
    deepScan = startDeepScan,
    sweep = sweepQuery,
    resetQueries = function()
        sweepCount, lastQueryAt, pagePending, throttleReady = 0, GetTime() - 2, false, true
        S.queryPacing = nil
        S.sellingOwnedRequest = nil
    end,
    browse = processBrowseRows,
    sellAt = sellAt,
    holdings = holdingsSnapshot,
    confirm = showConfirm,
    inspect = searchListing,
    refresh = refreshFeed,
    overview = feedOverview,
    scanStatus = function()
        buildScanPage()
        local shown = scanPage:IsShown()
        scanPage:Show()
        updateScanPage()
        if not shown then scanPage:Hide() end
        return scanPageLines[1]:GetText()
    end,
    focusedDeal = focusedDeal,
    focusDeal = focusDeal,
    actionState = commodityActionState,
    renderFeed = function()
        feedLastRefresh = GetTime() - 1
        refreshFeed()
        renderPopup()
    end,
    tick = feedTick,
    popup = buildPopup,
    dealAt = function(i) return S.deals[i] end,
    bookCount = function() local n = 0 for _ in pairs(db.book) do n = n + 1 end return n end,
    buy = function(i)
        local d = S.deals[i or 1]
        if d then
            quickBuy({ itemID = d.id, link = d.link, line = d.line,
                      units = d.units, cost = d.cost, market2 = d.market, kind = d.kind, t = d.t })
            return true
        end
        return false
    end,
    errors = function() return SIM_ERRORS or {} end,
}
end

SLASH_FOREVERSNIPER1 = "/fsn"
SLASH_FOREVERSNIPER2 = "/foreversniper"
SlashCmdList.FOREVERSNIPER = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = strlower(cmd or "")

    if cmd == "help" or cmd == "?" then
        for _, line in ipairs(HELP) do print("  " .. line) end

    elseif cmd == "capture" then
        S.captureFailure = rest == "once" and type(Screenshot) == "function" or nil
        printf(S.captureFailure and "next purchase failure will save one full game screenshot locally." or
            "failure capture off. /fsn capture once arms one screenshot; /fsn capture off cancels.")

    elseif cmd == "" or cmd == "status" then
        printf("database: %s; %d book items; spend cap %s; gold reserve %s.",
            db == ForeverSniperDB and "using saved table" or "TABLE MISMATCH",
            countKeys(db.book), fmtMoney(cfg.maxSpend or 0), fmtMoney(cfg.keepGold or 0))
        printf("%s | %d full snapshots done | book %d items | %d alerts fired",
            cfg.enabled and "|cff7cff4fon|r" or "|cffff4d4doff|r",
            S.scansDone, db.stats.book or 0, db.stats.deals or 0)
        printf("market reference: %s. /fsn tsm <itemID> inspects an item's reference.",
            cfg.tsm == false and "TSM disabled; local history only" or ForeverSniperTSM.status(time()))
        printf("AH flips require positive regional daily sales; verified NPC flips use vendor profit instead. Extra sales checks: %s; rate floor %.1f%%, exposure cap %.1f%%. /fsn sales ITEMID inspects coverage.",
            cfg.sales == false and "off" or "on", (cfg.saleRate or 0.05) * 100, (cfg.saleShare or 0.10) * 100)
        local ss = S.sweepStats or { sent = 0, rows = 0, yields = 0 }
        printf("monitor timing: completed-check revisit last/mean/max %.1f/%.1f/%.1fs (%d repeats); detected-to-validated last/max %.1f/%.1fs. Not listing age or a Buy guarantee.",
            ss.revisitLast or 0, (ss.revisitTotal or 0) / math.max(1, ss.revisitCount or 0), ss.revisitMax or 0,
            ss.revisitCount or 0, ss.validationLast or 0, ss.validationMax or 0)
        printf("validation timing: queue wait last/max %.2f/%.2fs; response last/max %.2f/%.2fs; %d discovery slots borrowed (next slot reserved for discovery).",
            ss.queueLast or 0, ss.queueMax or 0, ss.responseLast or 0, ss.responseMax or 0,
            ss.discoveryBorrowed or 0)
        printf("urgent validation: %d dispatches; %.2fs total pacing wait avoided, repaid before routine searches. Rolling limit 60 attempts/60s.",
            ss.validationAdvanced or 0, ss.validationSaved or 0)
        printf("batch discovery: %s; %d sent, %d completed, %d keys covered, %d rows, %d failures; last response %.2fs.",
            S.batchDisabled or (cfg.batch and "enabled (experimental)" or "off"),
            ss.batchSent or 0, ss.batchCompleted or 0, ss.batchKeys or 0,
            ss.batchRows or 0, ss.batchFailures or 0, ss.batchLatency or 0)
        printf("batch revisit last/mean/max %.2f/%.2f/%.2fs (%d repeated item checks). Includes scheduling and server waits, not listing age.",
            ss.batchRevisitLast or 0, (ss.batchRevisitTotal or 0) / math.max(1, ss.batchRevisitCount or 0),
            ss.batchRevisitMax or 0, ss.batchRevisitCount or 0)
        printf("batch allocation: %d eligible; %d market-matched priority materials; up to 75 priority keys plus at least 25 oldest-first keys per broad batch. Unused priority slots return to coverage.",
            ss.batchEligible or 0, ss.batchPriorityEligible or 0)
        for _, lane in ipairs({"priority", "coverage"}) do
            local metric = ss.batchLanes and ss.batchLanes[lane]
            if metric then printf("%s batch revisit mean/max %.2f/%.2fs (%d repeats).", lane,
                metric.total / math.max(1, metric.count), metric.max, metric.count) end
        end
        printf("targeted list: %s. /fsn targeted on|off", S.targetedStatus())
        printf("prebuy new-search test: %s; timing evidence in /fsn diagnostics. No server snapshot age is available.", cfg.prebuy and "on (two presses)" or "off (normal one-press)")
        printf("automatic item checks: %d sent, %d completed, %d distinct targets; last target: %s (stock movement is not confirmed sales).",
            ss.autoSent or 0, ss.autoCompleted or 0, ss.autoUnique or 0, tostring(ss.lastTarget or "none"))
        if cfg.targeted then
            printf("routine broad discovery is off; targeted list searches share the existing request budget.")
        else
            printf("last discovery scope: %s; sort: %s. Routine discovery alternates broad categories and available subcategories, one page per query.",
                ss.lastCat or "none", ss.lastSort or "none")
        end
        local owner = S.liveCandidate or S.autoSearch or S.watchSearch
        local ready, readinessReason = throttleGate()
        local readiness = ready and "ready" or (readinessReason == "busy" and "waiting" or "unavailable")
        printf("query throttle: %s; item owner: %s; item timeouts: %d; purchase: %s.",
            readiness, owner and (tostring(owner.id) .. " (" .. math.floor(GetTime() - owner.t) .. "s)") or "none",
            ss.timeouts or 0, S.snipePending and "in progress" or (db.unsettledPurchase and "unknown outcome, buying locked" or "idle"))
        printf("native sell: %s; inspection: %s; deep scan: %s.",
            S.nativeSellActive() and "prepared (queries paused)" or "inactive",
            S.pending and string.format("item %s (%ds)", tostring(S.pending.itemID),
                math.max(0, math.floor(GetTime() - S.pending.t))) or "idle",
            S.deepScan and "active" or "idle")
        printf("full snapshot: %s; request cooldown %ds. Live item checks and discovery learn independently.",
            S.harvestProgress and string.format("harvesting %d/%d rows", S.harvestProgress.processed, S.harvestProgress.total)
                or (S.scanning and "awaiting reply" or "idle"),
            S.lastRequest and math.max(0, math.ceil(SCAN_COOLDOWN - (time() - S.lastRequest))) or 0)
        local focus = focusedDeal()
        if focus then
            local snapshot = S.commoditySnapshots[focus.id]
            printf("deal priority: %s; discovery continues between bounded refreshes; completed tiers %.0fs old.",
                focus.link or (infoOf(focus.id).name or ("item " .. focus.id)),
                snapshot and math.max(0, GetTime() - snapshot.t) or 0)
            local label, _, hint = commodityActionState(focus.id, focus.link, focus.line,
                focus.units, focus.cost, focus.market, focus.kind)
            printf("focused Buy: %s; %s Routine click window: %.1fs remaining.", label, hint,
                math.max(0, (S.dealFocus.buyWindowUntil or GetTime()) - GetTime()))
        end
        local p = queryPacing()
        printf("FS live-search attempts: %d in the last 60s; routine spacing %.1fs; urgent validation can borrow one slot. Shared readiness waits: %d; observed wait span %.1fs. Shared waits do not identify their source.",
            queryRequestCount(), p.interval, p.busyEpisodes,
            p.busySeconds + (p.busySince and math.max(0, GetTime() - p.busySince) or 0))
        local history = historyReadiness()
        printf("Local history: %d ready, %d learning, %d stale; local fallback requires %d time-spaced observations. Verified TSM references need no local warm-up. Neither proves a deal.",
            history.ready, history.warming, history.stale, cfg.armAfter)
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
            printf("last full snapshot %s: %d listings. threshold %d%% of market, every %ds, arm after %d, floor %s.",
                date("%m-%d %H:%M", db.stats.lastScan), db.stats.lastListings or 0,
                math.floor(cfg.threshold * 100 + 0.5), cfg.every, cfg.armAfter, fmtMoney(cfg.minUnit))
        else
            printf("no full snapshot completed; live sweeps and automatic checks learn independently. /fsn why shows recent decisions.")
        end
        printf("profit gate: quality %s, %d%% AH cut, minimum profit %s.",
            cfg.quality == 0 and "any" or (cfg.quality .. "+"),
            math.floor(cfg.cut * 100 + 0.5), cfg.profit > 0 and fmtMoney(cfg.profit) or "off")
        printf("spend cap per Buy click: |cffffd100%s|r. every purchase is your click - never automatic.",
            fmtMoney(cfg.maxSpend))
        printf("gold reserve %s; default per-item stock cap %s; %d item override(s). /fsn stock for limits and uncollected reservations.",
            fmtMoney(cfg.keepGold), cfg.maxStock == 0 and "off" or tostring(cfg.maxStock), countKeys(db.stockLimits))
        printf("AH window %s. %d watch rules, %d blacklisted. /fsn help for everything.",
            S.ahOpen and "open" or "closed", countKeys(db.watch), countKeys(db.blacklist))

    elseif cmd == "on" then
        cfg.enabled = true
        if ffAuctionPresent() then
            S.ffOverride = true -- your call: our sweep runs even beside ForeverForge
            printf("enabled - taking the throttle back from ForeverForge while the AH is open. /fsn off to stand down again.")
        else
            printf(S.ahOpen and "enabled - live scanning resumed." or "enabled. open the AH to scan.")
        end
        if S.ahOpen and C_AuctionHouse then startSweeping() end
        refreshDealPresentation()
        updateScanPage()
    elseif cmd == "off" then
        cancelArmed = false
        cfg.enabled = false
        S.ffOverride = nil
        S.liveCandidate, S.liveCandidates = nil, nil
        S.autoSearch, S.watchSearch = nil, nil
        S.stopSnapshot()
        stopSweeping()
        deepAbort(false)
        retirePurchase("scanner disabled")
        S.snipePending, S.quote, S.buying, S.pending = nil, nil, nil, nil
        refreshDealPresentation()
        updateScanPage()
        printf("disabled.")

    elseif cmd == "purchases" then
        local records = db.purchases or {}
        if #records == 0 then printf("no settled purchase records yet.") end
        for i = math.max(1, #records - 9), #records do
            local record = records[i]
            printf("%d x item %d for %s (%s).", record.units, record.id, fmtMoney(record.total), record.source)
        end
        printf("up to 200 recent records retained. User-reconciled outcomes are assertions; this is not inventory cost basis or profit.")

    elseif cmd == "purchase" then
        local p = db.unsettledPurchase
        if not p then printf("no unsettled purchase recorded.") return end
        if S.snipePending then printf("purchase still in progress - wait for the server outcome.") return end
        if rest == "bought" then
            finishPurchase(p, "user reconciled")
        elseif rest == "failed" then
            db.unsettledPurchase, S.outcomeOwner = nil, nil
            printf("purchase marked failed by you. Buying unlocked; no spend recorded.")
            S.refreshPurchasePresentation()
        else
            local id, units, total = purchaseDetails(p)
            if id then printf("unknown purchase: %d x item %d for %s (%s).", units, id, fmtMoney(total), p.reason or "response missing")
            else printf("stored purchase details are invalid; buying remains locked. Do not mark bought without valid details.") end
            printf("verify mail, bags and gold first; then /fsn purchase bought OR /fsn purchase failed. These are your assertions, not server verification.")
        end

    elseif cmd == "keep" then
        local text = rest:gsub("%s", ""):lower()
        local value = not text:find("[^%dgsc]") and parseMoney(text)
        if text:match("^0+[gsc]?$") then value = 0 end
        if value and value >= 0 then
            cfg.keepGold = math.floor(value)
            refreshDealPresentation()
            printf("gold reserve set to %s. The existing 5%% wallet buffer also applies.", fmtMoney(cfg.keepGold))
        else printf("usage: /fsn keep 10g (0 = no additional reserve)") end

    elseif cmd == "stock" then
        if rest == "" then
            printf("default stock cap %s; client-known bags/bank + fresh owned auctions + reserved purchases.",
                cfg.maxStock == 0 and "off" or tostring(cfg.maxStock))
            for id, cap in pairs(db.stockLimits) do printf("item %s: cap %d", id, cap) end
            for id, qty in pairs(db.stockPending) do printf("item %s: %d units reserved until /fsn received %s", id, qty, id) end
            printf("collect older mail before enabling caps. Reservations can double-count collected purchases until acknowledged.")
            return
        end
        local target, amount = rest:match("^(.-)%s+(%S+)$")
        if target then
            local id = tonumber(target:match("item:(%d+)") or target)
            local cap = tonumber(amount)
            if id and id > 0 and id % 1 == 0 and (amount == "inherit" or (cap and cap >= 0 and cap % 1 == 0)) then
                db.stockLimits[tostring(id)] = amount ~= "inherit" and cap or nil
                printf("item %d stock cap: %s.", id, amount == "inherit" and "inherited" or tostring(cap))
            else printf("usage: /fsn stock <item ID or link> <units|inherit>") return end
        else
            local cap = tonumber(rest)
            if not cap or cap < 0 or cap % 1 ~= 0 then printf("usage: /fsn stock 200 (0 = off)") return end
            cfg.maxStock = cap
            printf("default per-item stock cap %d (0 = off). Collect older mail before enabling caps.", cap)
        end
        refreshDealPresentation()
        if S.ahOpen then S.requestSellingOwned() end

    elseif cmd == "received" then
        local id = tonumber(rest:match("item:(%d+)") or rest)
        if not id or id <= 0 or id % 1 ~= 0 then printf("usage: /fsn received <item ID or link>, only after collecting ALL reserved purchases") return end
        if S.snipePending or db.unsettledPurchase then printf("resolve the pending purchase first; reservations unchanged.") return end
        db.stockPending[tostring(id)] = nil
        refreshDealPresentation()
        printf("item %d reservations cleared by your acknowledgment. Bags/bank and owned auctions still count toward its cap.", id)

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

    elseif cmd == "sales" then
        local option, value = rest:match("^(%S+)%s*(.-)$")
        if option == "on" and value == "" then cfg.sales = true
        elseif option == "off" and value == "" then cfg.sales = false
        elseif option == "rate" or option == "share" then
            local percent = tonumber(value)
            if not percent or percent ~= percent or percent <= 0 or percent > 100 then printf("usage: /fsn sales rate|share <percent 0-100, exclusive of 0>") return end
            if option == "rate" then cfg.saleRate = percent / 100 else cfg.saleShare = percent / 100 end
        elseif option then
            local id = tonumber(rest)
            if not id or id <= 0 or id % 1 ~= 0 then printf("usage: /fsn sales [on|off|rate PCT|share PCT|itemID]") return end
            printf("item %d: %s", id, S.salesSummary(id))
            return
        end
        printf("extra sales checks %s: rate floor %.1f%%; exposure share %.1f%%. AH flips require positive daily sales; profitable NPC exits are exempt.",
            cfg.sales == false and "off" or "on", (cfg.saleRate or 0.05) * 100, (cfg.saleShare or 0.10) * 100)

    elseif cmd == "tsm" then
        if rest == "on" then cfg.tsm = true
        elseif rest == "off" then cfg.tsm = false
        elseif rest ~= "" then
            local id = tonumber(rest)
            if not id or id <= 0 or id % 1 ~= 0 then printf("usage: /fsn tsm [on|off|itemID]") return end
            local value, source = S.marketReference(id)
            printf("item %d reference: %s (%s).", id, value and fmtMoney(value) or "unavailable", source or "no trusted reference")
            local checked = S.checkedAt and S.checkedAt[id]
            local revisit = S.revisitByID and S.revisitByID[id]
            printf("item %d monitoring: last completed check %s; last revisit interval %s.", id,
                checked and string.format("%.1fs ago", math.max(0, GetTime() - checked)) or "not observed",
                revisit and string.format("%.1fs", revisit) or "not yet measured")
        end
        printf("TSM reference: %s", cfg.tsm == false and "disabled; local history only" or ForeverSniperTSM.status(time()))

    elseif cmd == "batch" then
        if rest == "on" or rest == "off" then
            cfg.batch = rest == "on"
            -- Do not abandon ownership mid-reply. Turning off stops new batches;
            -- the current request completes or times out through its usual gates.
            if cfg.batch and not S.batchSearch then S.batchDisabled = nil end
            printf("batch discovery %s (experimental; full live tiers still required).", cfg.batch and "on" or "off")
            S.wakeSweep()
        else printf("usage: /fsn batch on|off; current: %s", cfg.batch and "on" or "off") end

    elseif cmd == "prebuy" then
        if rest == "on" or rest == "off" then
            cfg.prebuy = rest == "on"
            S.prebuyCheck = nil
        elseif rest ~= "" then printf("usage: /fsn prebuy [on|off]") end
        printf("prebuy new-search test %s. First BUY press searches, second starts a guarded quote within 2s of completion; no automatic purchase after search.", cfg.prebuy and "on" or "off")

    elseif cmd == "targeted" then
        if rest == "on" or rest == "off" then
            cfg.targeted = rest == "on"
            -- Keep in-flight owners and saved watches. The next scheduling slot
            -- uses the new mode without inheriting a broad-discovery debt.
            S.discoveryDue = nil
            S.wakeSweep()
        elseif rest ~= "" then
            printf("usage: /fsn targeted [on|off]")
        end
        printf("targeted list: %s. Existing watches and purchase safeguards remain active.", S.targetedStatus())

    elseif cmd == "sweep" then
        local v = tonumber(rest)
        if v and v >= 2 and v <= 30 then
            cfg.sweep = math.floor(v)
            if S.sweepTicker then stopSweeping(); startSweeping() end
            printf("fallback sweep tick every %ds; ready events wake searches with the existing minimum spacing.", cfg.sweep)
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
        local g, reasons = recentGateReasons()
        if not g then
            printf("no recent decision data - open the AH and wait a few seconds.")
        else
            printf("decisions over %ds (window up to 5 min; repeated checks are not unique listings):", time() - g.at)
            for i, reason in ipairs(reasons) do
                printf("  |cffffd100%dx|r %s", g.counts[reason], reason)
                if i <= 6 and g.examples[reason] then printf("  e.g. %s", g.examples[reason]) end
            end
        end

    elseif cmd == "profit" and rest ~= "" then
        local v = rest == "0" and 0 or parseMoney(rest)
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
                local ok, name = pcall(anyGetItemInfo, tonumber(key) or key)
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
                local ok, iid = pcall(anyGetItemInfoInstant, strtrim(rest))
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
        elseif requestReplicate() then printf("snapshot requested or cached snapshot queued for learning.")
        else printf("snapshot not started: scanner busy, disabled, throttled or on cooldown. /fsn status shows progress.") end

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

    elseif cmd == "relist" then
        if not S.ahOpen then printf("open the AH first.") return end
        if C_Container == nil or C_Container.GetContainerNumSlots == nil then
            printf("this client cannot scan bags.") return
        end
        local queue, seen = {}, {}
        local t = time()
        for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
            local n = C_Container.GetContainerNumSlots(bag)
            if n and n > 0 then
                for slot = 1, n do
                    local id = C_Container.GetContainerItemID(bag, slot)
                    if id and not seen[id] then
                        seen[id] = true
                        local b = db.book[id]
                        if b and freshMedian(b.s, t, (cfg.freshMins or 45) * 60, cfg.armAfter) then
                            queue[#queue + 1] = id
                        end
                    end
                end
            end
        end
        if #queue == 0 then
            printf("nothing to relist - no priced holdings found in your bags.")
        elseif strlower(strtrim(rest or "")) ~= "go" then
            printf("|cffffd100%d item type(s)|r priced. /fsn relist go submits one available stack per type; check your auctions afterwards.",
                #queue)
        else
            startRelisting(queue)
        end

    elseif cmd == "portfolio" then
        printPortfolio()

    elseif cmd == "cancel" then
        if not S.ahOpen then printf("open the AH first.") return end
        if not cfg.enabled then printf("cancellation paused: scanner disabled.") return end
        local request = {sent={}}
        local ok, reason = S.requestSellingOwned(function()
            if not cfg.enabled or not S.ahOpen or S.snipePending or db.unsettledPurchase then return false end
            cancelArmed = request
            printf("cancellation requested for eligible listings above the recent median; submissions are not completion.")
        end)
        if not ok then
            if cancelArmed == request then cancelArmed = false end
            printf("cancellation query not sent: %s.", reason)
            return
        end
        after(3, function() if cancelArmed == request then cancelArmed = false end end)

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

    elseif cmd == "bind" then
        -- /fsn bind buy ctrl-b  (or skip) - the key IS the hardware press
        local what, key = rest:match("^(%S*)%s*(.-)$")
        what = strlower(what or "")
        if (what ~= "buy" and what ~= "skip") or key == "" then
            printf("usage: /fsn bind buy <key>  e.g. /fsn bind buy ctrl-b  (or skip, mousewheelup)")
            return
        end
        local frame = (what == "skip") and "ForeverSniperBestSkipBtn" or "ForeverSniperBestBuyBtn"
        if SetBinding(strupper(key), "CLICK " .. frame .. ":LeftButton") then
            pcall(SaveBindings, (GetCurrentBindingSet and GetCurrentBindingSet()) or 1)
            printf("%s bound to %s - press it with deals on the feed.", what, strupper(key))
        else
            printf("could not bind %s - that key is taken; pick another.", strupper(key))
        end

    elseif cmd == "deepscan" then
        startDeepScan(true)

    elseif cmd == "snipe" then
        -- the Bilis engine is gone: sniping is the feed's own SNIPE deals -
        -- a card with BUY / SKIP pops for every deal (bound keys welcome)
        buildFeed()
        if not feedFrame:IsShown() then feedFrame:Show() end
        printf("sniping runs from the feed: BUY or SKIP each deal card as it pops.")

    elseif cmd == "sell" or cmd == "selling" then
        S.showSelling()
        S.requestSellingOwned()

    elseif cmd == "feed" then
        buildFeed()
        if feedFrame:IsShown() then
            feedFrame:Hide()
            printf("deal feed hidden.")
        else
            feedFrame:Show()
            cfg.feedPage = true
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
        printf("recorded: %d deal(s) flagged, %d vendor flip(s) worth |cffffd100%s|r estimated. Last inbox observation: %d sale mail(s), %s attached (not profit).",
            st.deals or 0, st.vendorDeals or 0, fmtMoney(st.vendorProfit or 0),
            db.mailboxSnapshot and db.mailboxSnapshot.count or 0, fmtMoney(db.mailboxSnapshot and db.mailboxSnapshot.proceeds or 0))
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
        printRecordedLog(false)

    elseif cmd == "diagnostics" then
        printRecordedLog(true)

    elseif cmd == "wipe" then
        if rest == "book" then
            db.book = {}
            db.stats.book = 0
            S.refreshSelling()
            printf("price book cleared.")
        elseif rest == "all" then
            if S.snipePending or db.unsettledPurchase then
                printf("resolve the active/unknown purchase before wiping data. See /fsn purchase.")
                return
            end
            S.clearFeedDeals()
            cancelArmed = false
            deepAbort(false)
            S.stopSnapshot()
            S.replicateLearned = nil
            S.autoSearch, S.watchSearch, S.pending, S.buying, S.quote = nil, nil, nil, nil, nil
            S.commoditySnapshots, S.autoChecked = {}, {}
            S.gateSummary, S.historyReadiness = nil, nil
            for key in pairs(buyFailUntil) do buyFailUntil[key] = nil end
            -- Rebuild the SavedVariables global from scratch so the logout
            -- write starts clean instead of holding the orphaned old table.
            ForeverSniperDB = {}
            db = ForeverSniperDB
            db.config = {}
            for k, v in pairs(DEFAULTS) do db.config[k] = v end
            cfg = db.config
            db.book, db.watch, db.blacklist, db.errors, db.alerts, db.stats, db.shape = {}, {}, {}, {}, {}, {}, nil
            db.diagnostics = {}
            db.deals, db.lastAlert, db.seen, db.boughtAt = {}, {}, {}, {}
            S.deals, S.lastAlert, S.seen, S.boughtAt = db.deals, db.lastAlert, db.seen, db.boughtAt
            rebuildWatch()
            S.prevList, S.scansDone = nil, 0
            S.sellingOwnedUpdated, S.sellingOwnedRequest, S.sellingOwnedDisplay = nil, nil, nil
            S.refreshSelling()
            printf("everything cleared. /reload for a clean slate.")
        else printf("usage: /fsn wipe book|all") end

    else
        printf("unknown command %q. /fsn help", cmd)
    end
end



-- (The Bilis sniper bridge was removed with the module: the feed's own
-- SNIPE deals and BUY / SKIP cards are the sniping interface.)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    initialize()
end)
