import fs from 'node:fs';

export const provider = fs.readFileSync(new URL('../TSMReference.lua', import.meta.url), 'utf8');
export const fixture = `
local realm,faction='Normal','Alliance'
local function GetRealmName() return realm end
local function UnitFactionGroup() return faction end
local observed
local function hooksecurefunc(name,fn)
  assert(name=='TSM_APPHELPER_LOAD_DATA'); observed=fn
end
TSM_APPHELPER_LOAD_DATA=function() end
local values,calls={dbmarket=10000,dbrecent=11000,dbhistorical=12000},0
TSM_API={GetCustomPriceValue=function(source,item)
  assert(item=='i:123'); calls=calls+1; return values[source]
end}
`;
export const helpers = `
local function feed(tag,field,stamp,scope)
  observed(tag,scope or 'Normal-Alliance',
    'return {downloadTime='..stamp..',fields={"itemString","'..field..'"},data={}}')
end
local function market(stamp,scope)
  feed('AUCTIONDB_NON_COMMODITY_SCAN_STAT','marketValue',stamp or now,scope)
end
local function recent(stamp,scope)
  feed('AUCTIONDB_NON_COMMODITY_DATA','marketValueRecent',stamp or now,scope)
end
local function historical(stamp,scope)
  feed('AUCTIONDB_NON_COMMODITY_HISTORICAL','historical',stamp or now,scope)
end
`;
