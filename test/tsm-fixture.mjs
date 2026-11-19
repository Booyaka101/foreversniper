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

export const salesEnvironment = `
WOW_PROJECT_ID=99; WOW_PROJECT_CAMELOT=99
Enum={GameRule={HardcoreRuleset=1,RPRuleset=2,PvPRuleset=3}}
local hardcore=false
C_GameRules={IsGameRuleActive=function(rule) return rule==1 and hardcore or false end}
local portal='EU'
local function GetCVar(key) assert(key=='Portal'); return portal end
`;

export const salesAPI = `
values.dbregionsaleavg=9000; values.dbregionsalerate=0.25; values.dbregionsoldperday=1000
TSM_API.GetCustomPriceValue=function(expression,item)
  assert(item=='i:123'); calls=calls+1
  local value
  if expression=='1000 * dbregionsalerate + 1' then
    value=values.dbregionsalerate; return value and math.floor(value*1000+1+0.5)
  elseif expression=='1000 * dbregionsoldperday + 1' then
    value=values.dbregionsoldperday; return value and math.floor(value*1000+1+0.5)
  end
  value=values[expression]; return value and math.floor(value+0.5)
end
local function salesFeed(stamp,scope)
  observed('AUCTIONDB_REGION_SALE',scope or 'Forever-EU',
    'return {downloadTime='..(stamp or now)..',fields={"itemString","regionSale","regionSoldPerDay","regionSalePercent"},data={}}')
end
`;
