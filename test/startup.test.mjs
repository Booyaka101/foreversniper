import test from 'node:test';
import { run, source } from './lua.mjs';

test('startup waits for its own restored database and binds runtime state to it', () => run(`
  local frames={}
  function CreateFrame()
    local f={events={},scripts={}}
    function f:RegisterEvent(event) self.events[event]=true end
    function f:UnregisterEvent(event) self.events[event]=nil end
    function f:SetScript(event,fn) self.scripts[event]=fn end
    function f:Hide() end
    frames[#frames+1]=f
    return f
  end
  function GetMoney() return 1000 end
  function GetTime() return 100 end
  function time() return 100 end
  SlashCmdList={}
  FOREVER_SNIPER_TEST_MODE=true
  local early={}
  ForeverSniperDB=early
  local function loadAddon(...)
    ${source}
  end
  loadAddon("ForeverSniper")
  assert(not next(early) and not SlashCmdList.FOREVERSNIPER)
  local function loaded(name)
    local f=frames[1]
    if f.events.ADDON_LOADED then f.scripts.OnEvent(f,"ADDON_LOADED",name) end
  end
  loaded("TradeSkillMaster")
  assert(not next(early) and not ForeverSniperTest)
  local book={}
  for id=1,1233 do book[id]={} end
  local saved={book=book,config={maxSpend=150,keepGold=900,enabled=false},
    deals={},seen={},unsettledPurchase={confirmed=true},tunedClassic=true}
  ForeverSniperDB=saved
  loaded("ForeverSniper")
  assert(not next(early) and ForeverSniperDB==saved and saved.book==book and #book==1233)
  local runtime=ForeverSniperTest
  assert(runtime.state.deals==saved.deals and runtime.state.seen==saved.seen)
  assert(runtime.budget()==100 and saved.config.enabled==false and saved.unsettledPurchase.confirmed)
  saved.config.keepGold=0
  assert(runtime.budget()==150)
  loaded("ForeverSniper")
  assert(ForeverSniperTest==runtime)
`));
