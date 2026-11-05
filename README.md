# Forever Sniper

Auction deal sniper for **WoW: Forever 1.60.1** (interface `16001`). It learns
prices from full auction-house scans and alerts the moment something is listed
under market value — sound, chat line, and a popup whose rows can inspect or
**buy the whole lot in one press**.

## How it works

1. **Learn** — every time you open the AH, the addon pulls the full listing
   snapshot (`C_AuctionHouse.ReplicateItems`) and records each item's cheapest
   unit price. Market value = median of the last 8 scan minimums, so one
   mislisted 1c item cannot define a market.
2. **Snipe** — each scan is diffed against the previous one. A *newly listed*
   auction at or under `threshold`% of market (default 50%) triggers a **depth
   sweep**: every unit of that item currently listed under the price line,
   totalled into one lot — "240 units under market, 58g total" — so
   stackables are bought as one purchase, not one listing at a time.
3. **Profit gate** — a deal only fires if the sweep's estimated resale profit
   (market value after the AH cut, minus cost) clears the floor
    (`/fsn profit 10s` to set a floor) and the item clears the rarity floor
   (`/fsn quality 1` — gray filtered by default). No more junk pings.
4. **Watchlist** — absolute rules that fire from the very first scan:
   `/fsn watch [Linen Cloth] 50s`. Swept against the rule's own ceiling, no
   profit guess — the rule is the decision.

Alerts arm after 2 scans of history by default (`/fsn arm N`), so day one is
for learning, not for guessing.

The existing one-time Classic-economy migration sets the profit gate to zero,
the minimum unit price to 1s and the threshold to 50%. Inspect `/fsn` and set
your preferred profit floor explicitly. This update does not change that migration.

## Quick start

**Buying:** every purchase happens strictly inside a click you make on an
alert row's **Buy** button — never automatically, never on a timer (Blizzard's
hardware-event gate on the purchase calls is the security model, and it is
honored). A Buy click:

1. re-searches the item live and re-computes what is under your price line
   *right now* — stale alert data is never trusted,
2. buys every unit under the line, cheapest first, bounded by the spend cap
   (`/fsn max 100g` default),
3. for commodities (stackables), opens the quantity-filled purchase for your
   final press; for item listings it buys out directly on your click and
   reports exactly what was spent.

```
/fsn                  status
/fsn thresh 50        alert at <= 50% of market
/fsn every 45         scan cadence while the AH is open (15-900s)
/fsn profit 1g        minimum estimated resale profit per deal (0 = off)
/fsn quality 2        rarity floor for market alerts (0 any .. 4 epic)
/fsn cut 5            AH cut assumed in profit estimates (percent)
/fsn max 250g         spend cap per Buy click
/fsn watch [Item] 3g  absolute price rule, swept across all units under it
/fsn ignore [Item]    silence a false-deal item forever
/fsn help             everything
```

## Installation

Copy `ForeverSniper.lua` and `ForeverSniper.toc` into
`World of Warcraft/_forever_/Interface/AddOns/ForeverSniper/`, then restart WoW.
Keep your existing `WTF` files to preserve learned prices and settings.

## Desktop briefing

With Node.js 22 or newer, run the optional helper **only while all WoW clients
are closed**:

```powershell
node tools/forever-desktop.mjs --wow-root "D:/WoW/World of Warcraft"
```

It discovers a single account's `ForeverSniper.lua` under `_forever_/WTF/Account`.
If several accounts have sniper data, select one explicitly:

```powershell
node tools/forever-desktop.mjs --sv "D:/WoW/World of Warcraft/_forever_/WTF/Account/YOUR_ACCOUNT/SavedVariables/ForeverSniper.lua"
```

The helper adds a briefing for next login without rewriting the price database.
It keeps a `.desktop-bak` backup and a per-account `.desktop-state.json` beside
the selected SavedVariables file. It refuses writes when a WoW client is running,
process detection fails, input is malformed, another helper holds the lock, or
the source changes during analysis. There is no `--force` bypass. Keep the game
closed until the helper exits; its lock cannot prevent you from launching WoW.

Price changes and listing disappearances describe observations, not guaranteed
sales or profit. Recheck live prices before buying.

## Development

Run the dependency-free desktop regression tests with Node.js 22 or newer:

```powershell
node --test test/*.test.mjs
```

CI also runs the addon linter and simulator. Tests use synthetic SavedVariables,
not your real account data. Passing them is not a substitute for an in-game check.

## Client compatibility notes

- Every `C_AuctionHouse` call is pcall-wrapped; failures are recorded for
  `/fsn errors`, and the addon goes quiet instead of throwing mid-AH.
- `/fsn shape` shows what the replicate API actually returned, so a changed
  return order is visible without guessing.
- If the completion event never fires, a stability watchdog calls the scan
  done once the listing count holds still for 6 seconds.
