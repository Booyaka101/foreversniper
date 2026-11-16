-- Public TSM prices, with session-only provenance observed from AppHelper.
-- Never execute its payload, replace its loader, or write to TSM's data.
ForeverSniperTSM = {}
local provider = ForeverSniperTSM
local timestamps, cache, cacheSize = {}, {}, 0
local sources = {
    {key="dbmarket", tag="AUCTIONDB_NON_COMMODITY_SCAN_STAT", field="marketValue", age=43200},
    {key="dbrecent", tag="AUCTIONDB_NON_COMMODITY_DATA", field="marketValueRecent", age=43200},
    {key="dbhistorical", tag="AUCTIONDB_NON_COMMODITY_HISTORICAL", field="historical", age=172800},
}

local function number(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge and value or nil
end

local function realmKey()
    if type(GetRealmName) ~= "function" or type(UnitFactionGroup) ~= "function" then return end
    local realm, faction = GetRealmName(), UnitFactionGroup("player")
    if WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
        -- TSM's Forever feeds are ruleset markets, not physical realm names.
        -- Match its SessionInfo mapping exactly; missing rules cannot mean Normal.
        local rules = Enum and Enum.GameRule
        if not rules or not C_GameRules or type(C_GameRules.IsGameRuleActive) ~= "function" then return end
        local function active(rule)
            if rule == nil then return end
            local ok, value = pcall(C_GameRules.IsGameRuleActive, rule)
            if ok and type(value) == "boolean" then return value end
        end
        local hardcore, rp, pvp = active(rules.HardcoreRuleset), active(rules.RPRuleset), active(rules.PvPRuleset)
        if hardcore == nil or rp == nil or pvp == nil then return end
        if hardcore then realm = "Hardcore"
        elseif rp and pvp then realm = "Roleplay PvP"
        elseif rp then realm = "Roleplay"
        elseif pvp then realm = "PvP"
        else realm = "Normal" end
    end
    if type(realm) == "string" and type(faction) == "string" then
        return string.lower(realm .. "-" .. faction)
    end
end

local function observe(tag, realm, data)
    if type(realm) ~= "string" or type(data) ~= "string" then return end
    -- The installed Forever AppHelper uses realm/faction data even for mats.
    -- Unknown layouts and commodity/region feeds are deliberately not inferred.
    local header = string.sub(data, 1, 512)
    local stamp = tonumber(string.match(header, "^return%s+{downloadTime=(%d+),fields="))
    if not number(stamp) then return end
    for _, source in ipairs(sources) do
        if tag == source.tag and string.find(header, '"' .. source.field .. '"', 1, true) then
            local key = string.lower(realm)
            timestamps[key] = timestamps[key] or {}
            if not timestamps[key][source.key] then
                timestamps[key][source.key] = stamp
                cache, cacheSize = {}, 0
            end
        end
    end
end

local observing = false
if type(TSM_APPHELPER_LOAD_DATA) == "function" and type(hooksecurefunc) == "function" then
    -- OptionalDeps loads TSM first, not AppHelper. If its data was already
    -- loaded by another addon, missing timestamps fail closed to local history.
    observing = pcall(hooksecurefunc, "TSM_APPHELPER_LOAD_DATA", observe)
end

function provider.status(now)
    if type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then
        return "TSM price API unavailable"
    end
    if not observing then return "TSM data timestamp observer unavailable" end
    local key = realmKey()
    if not key then return "TSM market identity unavailable; waiting for realm, faction and ruleset APIs" end
    local stamps = timestamps[key]
    local newest, future
    for i = 1, 2 do
        local source = sources[i]
        local stamp = stamps and number(stamps[source.key])
        if stamp and stamp <= now and now - stamp <= source.age then
            return string.format("TSM realm data verified for %s (%s feed %.1f hours old)", key, source.key, (now - stamp) / 3600)
        end
        if stamp and stamp > now then future = true
        elseif stamp then newest = math.max(newest or 0, stamp) end
    end
    if newest then
        return string.format("TSM market/recent data stale for %s (newest %.1f hours old; limit 12); using local history", key, (now - newest) / 3600)
    end
    if future then return "TSM market/recent timestamp is future-dated for " .. key .. "; using local history" end
    local observed = {}
    for scope in pairs(timestamps) do observed[#observed + 1] = scope end
    table.sort(observed)
    if #observed > 0 then
        return "TSM market/recent data missing for " .. key .. "; observed " .. table.concat(observed, ", ") .. "; using local history"
    end
    return "TSM market/recent timestamps missing for " .. key .. "; AppHelper may have loaded before observer; using local history"
end

function provider.reference(itemID, now)
    if not number(itemID) or itemID % 1 ~= 0 or not number(now) then return end
    if type(TSM_API) ~= "table" or type(TSM_API.GetCustomPriceValue) ~= "function" then return end
    local realm = realmKey()
    local stamps = timestamps[realm]
    if not stamps then return end
    local previous = cache[itemID]
    if previous and previous.realm == realm and now >= previous.at and now < previous.untilTime then
        return previous.price, previous.label
    end
    local price, label, validUntil
    for i, source in ipairs(sources) do
        local stamp = number(stamps[source.key])
        if stamp and stamp <= now and now - stamp <= source.age and (i < 3 or price) then
            local ok, value = pcall(TSM_API.GetCustomPriceValue, source.key, "i:" .. itemID)
            value = ok and number(value) or nil
            if value and value % 1 == 0 then
                if not price or value < price then price, label = value, "TSM " .. source.key end
                validUntil = math.min(validUntil or math.huge, stamp + source.age)
            end
        end
    end
    if cacheSize >= 12000 then cache, cacheSize = {}, 0 end
    if not cache[itemID] then cacheSize = cacheSize + 1 end
    cache[itemID] = {realm=realm, at=now, untilTime=math.min(now + (price and 30 or 5), validUntil or math.huge),
        price=price, label=label}
    return price, label
end
