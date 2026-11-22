import test from 'node:test';
import { run, section } from './lua.mjs';

const setup=`
local db={stockPending={['123']=3}}
local cfg,S={enabled=true},{}
local bags={[1]={itemID=123,stackCount=7}}
local sales,cursor,timer={},nil,nil
local qty,paid,mailID,payout=3,300,123,101
local function num(v) return tonumber(v) end
local function printf() end
local function diagnostic() end
local function vendorOf() return payout end
local function GetCursorInfo() if cursor then return "item",cursor.itemID end end
local function InCombatLockdown() return false end
local MerchantFrame={IsShown=function() return true end,selectedTab=1}
local NUM_BAG_SLOTS=0
local C_Timer={After=function(_,f) timer=f end}
local function tick() if timer then local f=timer;timer=nil;f() end end
local C_Item={GetItemCount=function(id)
  local n=0;for _,r in pairs(bags) do if r.itemID==id then n=n+r.stackCount end end;return n
end}
local C_Container={
  GetContainerNumSlots=function() return 3 end,
  GetContainerItemInfo=function(_,s) return bags[s] end,
  PickupContainerItem=function(_,s) cursor,bags[s]=bags[s],cursor end,
  SplitContainerItem=function(_,s,n) assert(n<bags[s].stackCount and not cursor)
    bags[s].stackCount=bags[s].stackCount-n;cursor={itemID=123,stackCount=n} end,
}
local function SellCursorItem() assert(cursor); sales[#sales+1]=cursor.stackCount;cursor=nil end
local function GetInboxNumItems() return qty>0 and 1 or 0 end
local function GetInboxItem() return "cloth",mailID,nil,qty end
local function GetInboxInvoiceInfo() return 'buyer',nil,nil,paid,paid end
${section('-- One-shot quantities,', '\nlocal function finishPurchase')}
local function collect()
  S.vendorMailbox(true);qty=0;bags[1].stackCount=10;S.vendorMailbox(true);S.vendorMailbox(false)
end
local function visit() S.vendorVisit(true);tick();S.vendorBagUpdate();tick();S.vendorVisit(false) end
`;
function check(body){run(setup+body);}

test('pending invoice does not authorize old stock; collecting three sells exactly three once out of ten',()=>check(`
  S.markVendorBuy(123,3,300);visit();assert(#sales==0)
  collect();assert(db.stockPending['123']==nil)
  visit();assert(#sales==1 and sales[1]==3 and bags[1].stackCount==7)
  bags[1].stackCount=25;visit();assert(#sales==1 and not db.vendorLots['123'])
`));
test('wrong invoice and bag-only gains cannot release the mark',()=>check(`
  S.markVendorBuy(123,3,300);paid=200;collect();visit()
  assert(#sales==0 and db.vendorLots['123'].ready==0)
`));
test('mail disappearing without a bag gain leaves existing stock alone',()=>check(`
  S.markVendorBuy(123,3,300);S.vendorMailbox(true);qty=0;S.vendorMailbox(true)
  S.vendorMailbox(false);visit();assert(#sales==0)
`));
test('consumed marked units are not replaced by later acquisitions',()=>check(`
  S.markVendorBuy(123,3,300);collect()
  bags[1].stackCount=7;S.vendorBagUpdate();bags[1].stackCount=10;visit()
  assert(#sales==0)
`));
test('no split space, occupied cursor, unprofitable price and closed visit do not sell',()=>check(`
  S.markVendorBuy(123,3,300);collect()
  bags[2]={itemID=456,stackCount=1};bags[3]=bags[2];visit();assert(#sales==0 and bags[1].stackCount==10)
  bags[3]=nil;cursor={itemID=789};visit();assert(#sales==0 and cursor.itemID==789)
  cursor=nil;payout=100;visit();assert(#sales==0)
  payout=101;S.vendorVisit(true);S.vendorVisit(false);tick();assert(#sales==0)
`));
test('explicit receipt acknowledgement is capped by the purchase and cannot be reused',()=>check(`
  S.markVendorBuy(123,3,300);bags[1].stackCount=10
  S.ackVendorReceipt(123);S.ackVendorReceipt(123);visit()
  assert(sales[1]==3 and #sales==1)
  cfg.autoVendor=false;S.markVendorBuy(123,3,300);assert(not db.vendorLots['123'])
`));
