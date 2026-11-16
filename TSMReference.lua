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
    local stamps = timestamps[realmKey()]
    for i = 1, 2 do
        local source = sources[i]
        local stamp = stamps and number(stamps[source.key])
        if stamp and stamp <= now and now - stamp <= source.age then
            return "TSM realm data verified; newest usable market/recent feed within 12 hours"
        end
    end
    return "TSM realm data missing, stale, future-dated or loaded before observer; using local history"
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
