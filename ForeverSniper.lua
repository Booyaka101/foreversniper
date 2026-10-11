-- ForeverSniper.lua — auction deal sniper for the WoW: Forever beta.
--
-- How it works
--   * While the auction house window is open, the addon keeps requesting the
--     full-listing snapshot (C_AuctionHouse.ReplicateItems) on a cadence.
--   * Every completed scan does two jobs:
--       1. LEARN — per item, remember this scan's cheapest unit price. The
--          "market value" of an item is the median of the last 8 scan
--          minimums, so one mislisted 1c item cannot define a market.
--       2. SNIPE — diff the scan against the previous one. When a NEW listing
--          appears at or under threshold% of market, the whole DEPTH of that
--          item under the line is swept — every unit of every cheap listing,
--          totalled. A deal only fires if the estimated resale profit of the
--          sweep (market after the AH cut, minus cost) clears the profit
--          floor and the item clears the quality floor. Stackables report as
--          one lot ("240 units under market, 58g total"), not one listing at
--          a time. Watchlist rules (any [item] under [price]) sweep the same
--          way against the rule's own price ceiling.
--
-- Buying: every purchase this addon makes happens strictly inside a click you
-- made on a Buy button. Blizzard gates the purchase calls behind hardware
-- events on purpose — that gate is the whole security model, and it is
-- honored here: no timers, no event-driven purchases, no automation of any
-- kind. Each click is bounded by a spend cap, and prices are re-checked fresh
-- at click time, so a stale alert can never buy. Commodities open the filled
-- purchase for your final press; item listings buy out directly on your
-- click, cheapest first, and say exactly what they spent.
--
-- The beta moves week to week, so every C_AuctionHouse call is pcall-wrapped
-- and a failure is recorded in db.errors (the gap is data, ForeverBeacon
-- style). If an API changes shape, the addon goes quiet — mid-AH errors are
-- worse than silence.

local ADDON = ...

-- Database --------------------------------------------------------------------

local DEFAULTS = {
    enabled   = true,    -- master switch
    threshold = 0.50,    -- deal if unit price <= 50% of learned market
    every     = 45,      -- seconds between full scans while the AH is open
    sweep     = 3,       -- seconds between live browse sweeps (the sniper feed)
    armAfter  = 2,       -- learned samples required before market alerts fire
    minUnit   = 1000,    -- ignore deals under 10s per unit (vendor-junk floor)
    quality   = 1,       -- market alerts need this quality or better (0 = any)
    cut       = 0.05,    -- AH cut assumed when estimating resale profit
    profit    = 10000,   -- deals must clear this much estimated profit (0 = off)
    maxSpend  = 1000000, -- spend cap per Buy click (100g default)
    sound     = true,
    popup     = true,
    quiet     = false,   -- suppress per-scan summaries
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
local cfg = db.config

local CAPS = { errors = 200, alerts = 60, samples = 8, book = 12000 }

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
local DEBUG = true
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

local function mergeIntoBook(curMins, t)
    local bookN = countKeys(db.book)
    for key, unit in pairs(curMins) do
        local b = db.book[key]
        if not b then
            b = { lastSeen = t, s = {} }
            db.book[key] = b
            bookN = bookN + 1
        end
        b.lastSeen = t
        local s = b.s
        s[#s + 1] = t
        s[#s + 1] = unit
        while sampleCount(s) > CAPS.samples do
            table.remove(s, 1)
            table.remove(s, 1)
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
    lastAlert  = {},    -- itemID -> { t, price }
    pending    = nil,   -- { itemID, link, t } awaiting search results to print
    buying     = nil,   -- { itemID, link, line, market, commodity, t } active Buy click
    quote      = nil,   -- { itemID, units, total } live commodity quote
    boughtAt   = {},    -- itemID -> { t, price } purchase cooldown
}

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
        printf("C_AuctionHouse is gone on this client — cannot search.")
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
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverse = false } }
    end
    local ok, e = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
    if not ok then
        err("SendSearchQuery", e)
        printf("search failed: %s", tostring(e):sub(1, 200))
        return
    end
    S.pending = { itemID = itemID, link = link, t = GetTime(), units = units }
    if units and units > 1 then
        printf("searching %s — buy the whole sweep: |cffffd100%d units|r is every one under your line.",
            link or ("item " .. tostring(itemID)), units)
    else
        printf("searching %s — cheapest listings print below; the buy is yours to click.",
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
    f.TitleText:SetText("Forever Sniper — purchase")
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
                        "%d x %s — fetching the exact total ...\n(press Confirm when it appears)",
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
                printf("spend cap %s reached — skipped the rest. /fsn max to raise it.", fmtMoney(cfg.maxSpend))
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
        end
        if misses > 0 then
            printf("%d listing%s already gone — the re-scan will catch anything left.",
                misses, misses == 1 and "" or "s")
        end
        if bought == 0 and misses == 0 then
            printf("nothing was under the line anymore — someone beat you to it.")
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
    if not S.ahOpen then printf("the AH window closed — buy aborted.") return end

    if kind == "commodity" then
        -- Commodity results: price points, cheapest first. Take every unit
        -- under the line, cheapest first, stopping at the spend cap.
        local units, cost = 0, 0
        local i = 1
        while true do
            local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, i)
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
            printf("nothing under %s anymore — someone beat you to it.", fmtMoney(b.line))
            return
        end
        showConfirm({
            commodity = true, itemID = b.itemID, link = b.link,
            units = units, unit = math.floor(cost / units),
            body = string.format("%d x %s — every unit under %s\nestimated total |cffffd100%s|r (cap %s)",
                units, b.link or ("item " .. b.itemID), fmtMoney(b.line), fmtMoney(cost), fmtMoney(cfg.maxSpend)),
        })
        return
    end

    -- Item listings: capture every listing under the line, cheapest first,
    -- capped. The Purchase press buys them; nothing executes here.
    local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults)
    n = okN and math.floor(num(n) or 0) or 0
    local list, units, cost = {}, 0, 0
    for i = 1, n do
        local ok, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, i)
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
        printf("nothing under %s anymore — someone beat you to it.", fmtMoney(b.line))
        return
    end
    showConfirm({
        commodity = false, itemID = b.itemID, link = b.link, line = b.line,
        units = units, list = list,
        body = string.format("%d units of %s — %d listing%s under %s\ntotal |cffffd100%s|r%s",
            units, b.link or ("item " .. b.itemID), #list, #list == 1 and "" or "s",
            fmtMoney(b.line), fmtMoney(cost),
            list.capped and string.format("  (cap %s hit)", fmtMoney(cfg.maxSpend)) or ""),
    })
end

local function buySweep(itemID, link, line, market)
    if C_AuctionHouse == nil then
        printf("C_AuctionHouse is gone on this client — cannot buy.")
        return
    end
    if not S.ahOpen then
        printf("open the auction house window first.")
        return
    end
    if not line or line <= 0 then
        printf("no price line recorded for this alert — re-scan and try again.")
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
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverse = false } }
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

local function fireAlert(kind, itemID, link, unit, market, sweep)
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
    push(db.alerts, CAPS.alerts, {
        t = now, kind = kind, id = itemID, unit = unit, market = market,
        units = sweep.units, cost = sweep.cost, profit = sweep.profit,
    })

    local label = link or ("item " .. tostring(itemID))
    if market and market > 0 then
        if sweep.units > 1 then
            printf("|cffff4d00DEAL|r %s — |cffffd100%d units|r under %s: |cffffd100%s total|r (avg %s, market %s) |cff7cff4f+%s profit|r",
                label, sweep.units, fmtMoney(math.floor(sweep.cost / sweep.units + 0.5)),
                fmtMoney(sweep.cost), fmtMoney(math.floor(sweep.cost / sweep.units + 0.5)),
                fmtMoney(market), fmtMoney(sweep.profit or 0))
        else
            printf("|cffff4d00DEAL|r %s — %s  (market %s, |cff7cff4f-%d%%|r, |cff7cff4f+%s|r)",
                label, fmtMoney(unit), fmtMoney(market),
                math.floor((1 - unit / market) * 100 + 0.5),
                fmtMoney(math.floor(market * (1 - cfg.cut) - unit)))
        end
    else
        if sweep.units > 1 then
            printf("|cffff4d00DEAL|r %s — |cffffd100%d units|r at or under %s: |cffffd100%s total|r (|cff9d9d9dwatch rule|r)",
                label, sweep.units, fmtMoney(unit), fmtMoney(sweep.cost))
        else
            printf("|cffff4d00DEAL|r %s — %s  (|cff9d9d9dwatch rule|r)", label, fmtMoney(unit))
        end
    end
    playAlertSound()

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
    -- resale profit — market after the AH cut, minus cost — clears the floor.
    local deals = 0
    if not firstScan then
        for _, c in ipairs(cands) do
            if not db.blacklist[c.id] and c.unit >= cfg.minUnit
                and (c.q == nil or c.q >= cfg.quality) then
                local b = db.book[c.id]
                if b and sampleCount(b.s) >= cfg.armAfter then
                    local med = medianOfSamples(b.s)
                    if med and med >= cfg.minUnit and c.unit <= cfg.threshold * med then
                        local line = cfg.threshold * med
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
                                    { units = units, cost = cost, profit = profit, line = line })
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
    -- cloth reads as one lot, but no profit guess — the rule IS the decision.
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
        dbg("replicate data present: n=" .. n .. " — harvesting, no new request")
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

-- Live browse sweep (the sniper feed) ------------------------------------------------
-- Auctionator's IncrementalScan pattern: SendBrowseQuery with an empty string
-- returns the whole market aggregated per item (itemKey, minPrice,
-- totalQuantity), price-sorted so the cheapest listings surface first. Sweeping
-- this every few seconds finds a new cheap listing within seconds of it being
-- posted - unlike replicate, which is one snapshot per session. The book is
-- learned from every sweep, and each row is checked against its own median.

local function processBrowseRows(rows)
    local mins, t = {}, time()
    for _, r in ipairs(rows) do
        local key = num(r.itemKey and r.itemKey.itemID)
        local price = num(r.minPrice)
        local qty = num(r.totalQuantity) or 0
        if key and price and price > 0 then
            mins[key] = price
            local b = db.book[key]
            if b and sampleCount(b.s) >= cfg.armAfter then
                local med = medianOfSamples(b.s)
                if med and med >= cfg.minUnit and price <= cfg.threshold * med then
                    local line = cfg.threshold * med
                    local cost = qty * price
                    local est = math.floor(qty * med * (1 - cfg.cut) - cost)
                    if not S.underLine or S.underLine[key] ~= true then
                        S.underLine = S.underLine or {}
                        S.underLine[key] = true
                        fireAlert("market", key, nil, price, med,
                            { units = qty, cost = cost, profit = est, line = line })
                    end
                elseif S.underLine and S.underLine[key] then
                    S.underLine[key] = nil -- back above the line: re-arm the alert
                end
            end
        end
    end
    if next(mins) then mergeIntoBook(mins, t) end
end

local function sweepQuery()
    if not cfg.enabled or not S.ahOpen or S.sweeping then return end
    if C_AuctionHouse == nil or C_AuctionHouse.SendBrowseQuery == nil then return end
    if C_AuctionHouse.IsThrottledMessageSystemReady then
        local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if ok and ready == false then return end -- client is busy; next tick retries
    end
    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        local so = Enum.AuctionHouseSortOrder.Price or Enum.AuctionHouseSortOrder.Buyout
        if so then sorts = { { sortOrder = so, reverseSort = false } } end -- cheapest first
    end
    S.sweeping = true
    local ok, e = pcall(C_AuctionHouse.SendBrowseQuery,
        { searchString = "", sorts = sorts, filters = {}, itemClassFilters = {} })
    if not ok then
        S.sweeping = false
        err("SendBrowseQuery", e)
    end
end

local function startSweeping()
    if S.sweepTicker or not cfg.enabled then return end
    local period = math.max(tonumber(cfg.sweep) or 3, 2)
    S.sweepTicker = C_Timer.NewTicker(period, sweepQuery)
    after(1, sweepQuery)
    dbg("live sweep armed: every " .. period .. "s")
end

local function stopSweeping()
    if S.sweepTicker then
        S.sweepTicker:Cancel()
        S.sweepTicker = nil
    end
    S.sweeping = false
end

-- Events ---------------------------------------------------------------------------

local f = CreateFrame("Frame")
local handlers = {}
local unknownEvents = {}

-- Register a handler; altEvent is a fallback name for clients that spell the
-- event differently (the Forever client fires REPLICATE_ITEM_LIST_UPDATE,
-- retail fires REPLICATE_ITEM_LIST_UPDATED — one letter cost the whole scan loop)
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

on("PLAYER_LOGIN", function()
    buildPopup()
    if C_AuctionHouse == nil then
        printf("C_AuctionHouse is not on this client; going dormant.")
        return
    end
    if #unknownEvents > 0 then
        err("events", "unknown: " .. table.concat(unknownEvents, ", "))
    end
    printf("armed. /fsn help — visits to the AH build the price book (alert %d%% of market).",
        math.floor(cfg.threshold * 100 + 0.5))
end)

on("AUCTION_HOUSE_SHOW", function()
    S.ahOpen = true
    if cfg.enabled and C_AuctionHouse then
        startSweeping()
        after(2, requestReplicate) -- replicate is the book bootstrap, not the feed
    end
end)

on("AUCTION_HOUSE_CLOSED", function()
    S.ahOpen = false
    S.scanning = false
    stopSweeping()
    if S.harvestTicker then
        S.harvestTicker:Cancel()
        S.harvestTicker = nil
    end
end)

on("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function()
    -- a fresh result set answers our sweep (or any manual search); read it
    if S.sweeping and C_AuctionHouse.GetBrowseResults then
        S.sweeping = false
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            processBrowseRows(rows)
        elseif not ok then
            err("GetBrowseResults", rows)
        end
    end
end)

on("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function()
    -- pages appended after a manual "more results"; the sweep only reads page one
    S.sweeping = false
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
    if kind == "commodity" and C_AuctionHouse.GetCommoditySearchResultInfo then
        local i = 1
        while shown < 3 do
            local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, i)
            if not ok or type(info) ~= "table" then break end
            printf("  %d x %s each", info.quantity or 1, fmtMoney(info.unitPrice or info.buyoutAmount))
            shown = shown + 1
            i = i + 1
        end
    elseif C_AuctionHouse.GetItemSearchResultInfo then
        local ok, n = pcall(C_AuctionHouse.GetNumItemSearchResults)
        n = ok and math.floor(num(n) or 0) or 0
        for i = 1, math.min(n, 3) do
            local ok2, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, i)
            if ok2 and type(info) == "table" then
                printf("  x%d — %s  (buy in the AH window)", info.quantity or 1,
                    fmtMoney(info.buyoutAmount or info.unitPrice))
                shown = shown + 1
            end
        end
    end
    if p.units and p.units > 1 then
        printf("  |cffffd100buy %d units|r — that is every one under your line, one purchase.", p.units)
    end
    if shown == 0 then printf("  results are in — check the AH window; nothing printable.") end
end

on("ITEM_SEARCH_RESULTS_UPDATED", function()
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

-- Slash commands ---------------------------------------------------------------------

local HELP = {
    "|cffffd100Forever Sniper|r — it watches, you buy",
    "/fsn                  status",
    "/fsn on | off         enable / disable scanning",
    "/fsn thresh 50        alert at or under 50% of learned market (default 50)",
    "/fsn every 45         seconds between scans while the AH is open (15-900)",
    "/fsn sweep 3          seconds between live market sweeps (2-30)",
    "/fsn arm 2            scans of history before market alerts fire (1-10)",
    "/fsn min 10s          ignore deals under this per-unit price",
    "/fsn quality 2        market alerts need this rarity or better (0 any, 2 green+)",
    "/fsn cut 5            AH cut assumed when estimating profit (percent)",
    "/fsn profit 1g        deals must clear this estimated resale profit (0 off)",
    "/fsn max 250g         spend cap per Buy click (default 100g)",
    "   row [Buy]          one press: re-checks live prices, buys every unit under",
    "                       your line (commodities open the filled purchase)",
    "/fsn watch <link> 50g watchlist rule; a plain item name works too",
    "/fsn unwatch <link>|all",
    "/fsn ignore <link>    never alert this item (false-deal silencer)",
    "/fsn unignore <link>|all",
    "/fsn scan             force a scan right now (AH window open)",
    "/fsn pop              show/hide the alert popup",
    "/fsn quiet            toggle per-scan summaries",
    "/fsn sound            toggle the alert sound",
    "/fsn watchlist        current rules",
    "/fsn alerts           last 8 alerts",
    "/fsn shape            what the beta's replicate API returned (debug)",
    "/fsn errors           recorded API failures",
    "/fsn wipe book|all    clear the price book / everything",
}

local function usageWatch(rest)
    -- "/fsn watch [Item Link] 3g50s" — the money words come off the end.
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
        if db.stats.lastScan then
            printf("last scan %s: %d listings. threshold %d%% of market, every %ds, arm after %d, floor %s.",
                date("%m-%d %H:%M", db.stats.lastScan), db.stats.lastListings or 0,
                math.floor(cfg.threshold * 100 + 0.5), cfg.every, cfg.armAfter, fmtMoney(cfg.minUnit))
        else
            printf("no scans yet — open the auction house to start learning.")
        end
        printf("profit gate: quality %s, %d%% AH cut, minimum profit %s.",
            cfg.quality == 0 and "any" or (cfg.quality .. "+"),
            math.floor(cfg.cut * 100 + 0.5), cfg.profit > 0 and fmtMoney(cfg.profit) or "off")
        printf("spend cap per Buy click: |cffffd100%s|r. every purchase is your click — never automatic.",
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
                printf("  %s — at or under %s", (key:sub(1, 2) == "n:" and key:sub(3)) or name or ("item " .. key), fmtMoney(w.maxPrice))
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
                    printf("item %d blacklisted — no more alerts.", itemID)
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
            printf("  [%s] %s — %s%s", date("%m-%d %H:%M", a.t), a.link or ("item " .. tostring(a.id)),
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
