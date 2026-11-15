# Forever Sniper

Local auction deal finder for WoW: Forever. It learns prices from auction
observations, validates complete live commodity tiers, and presents positions
you can choose to buy. TradeSkillMaster is not required.

## Scan scheduling

Server-ready and result events wake the scanner without waiting for its fallback
timer. Event bursts are coalesced and deferred, including synchronous cached
replies. Every query still passes the existing minimum one-second spacing,
server-readiness, ownership, native-form, and purchase-lock checks. `/fsn sweep`
sets the fallback tick (2-30 seconds), not the event-driven request interval.

Routine scheduling alternates target checks and discovery opportunities instead
of allocating only one discovery slot in four. Watches retain one slot in four.
Weighted categories are spread across the rotation rather than clustered.
A displayed deal can use a target slot for a refresh no more often than once
every 15 seconds; it no longer pauses unrelated discovery. An in-flight search
can finish its pages before the next search starts. Deep discovery also continues
with a displayed deal, but pending or unresolved purchases still stop queries.

This trades some automatic target-check slots per cycle for broader discovery.
Server delays, pagination, stock refreshes, history availability, and other addons
still affect coverage. These scheduling changes do not establish a measured
live-client detection speed or guarantee winning a contested listing.

## Depth-based deal selection

Market and dump candidates compare every complete price-tier prefix below the
existing approved ceiling. The highest estimated net profit wins; ties favour
less capital committed. Equal-price rows stay together. The optimiser never
raises the ceiling, splits a tier to fit a budget, or invents a higher resale
price when no competing listing exists.

Estimates use the lower of the supplied fresh market reference and the next
competing price minus one copper, less the configured AH cut and deposit reserve.
They are estimates, not proof of demand or realised profit. Existing quality,
competition, profit, complete-result, and freshness checks still apply. Absolute
watch rules and vendor exits retain their existing full-lot selection.

## Spending and stock controls

```text
/fsn keep 10g             reserve at least 10g
/fsn max 100g             existing per-purchase spend cap
/fsn stock 200            default exposure cap of 200 units per item
/fsn stock 2589 100        override Linen Cloth to 100 units
/fsn stock 2589 inherit   remove the override
/fsn stock 2589 0         disable the cap for this item
/fsn stock                show settings and uncollected-purchase reservations
/fsn received 2589        acknowledge ALL reserved Linen Cloth purchases collected
```

Item links also work instead of numeric IDs. `keep` and the default stock cap
start at zero, so upgrading does not silently impose new limits. Options exposes
the reserve and default stock cap; item overrides use slash commands.

The purchase budget is the smallest of the spend cap, 95% of your wallet, and
your wallet minus the explicit reserve. The purchase **plus** relist deposit
reserve must fit. The original 5% wallet buffer remains in force.

Stock caps count client-reported inventory (including bank items known to the
client), fresh owned-auction quantities, and persistent reservations for purchases
settled by this version. This is not a complete account-wide inventory. Collect
older purchase mail before enabling caps. Unavailable inventory or owned-auction
data blocks capped items rather than assuming zero holdings. The scanner refreshes
owned auctions through its existing query pacing while caps are enabled.

Reservations are deliberately conservative: they survive reloads and may
double-count collected items until you acknowledge receipt. Only use
`/fsn received <ID>` after collecting **all** that item's reserved purchases.
It clears reservations, not inventory or owned-auction counts, and refuses to run
while a purchase outcome is unresolved. Selling or consuming items does not
automatically clear these reservations.

## Purchase safeguards

A hardware Buy press approves one complete commodity position. Stock and budget
are checked before starting and again when the live quote arrives. The existing
price, age, ownership, enable/disable, and unknown-outcome locks remain in place.
Only a server outcome (or the existing explicit user reconciliation) settles a
purchase and reserves its units. API acceptance alone is not a purchase receipt.
Individual-listing purchases remain disabled.

```text
/fsn feed             live deal window
/fsn watch [Item] 3g  absolute price rule
/fsn profit 10s       minimum estimated net profit
/fsn sell             selling view and owned-auction refresh
/fsn purchase         inspect an unresolved purchase
/fsn help             all commands
```

## Development

Version **0.6.50** preserves the owner's installed **0.6.49** as its baseline,
including changes that were absent from the older main branch. Saved data is
preserved when installing the release.

```text
npm ci
npm test
node <path-to-wow-addon-sim>/wow-addon-sim.mjs . --strict
```

Tests execute production Lua with Fengari, including depth selection, all risk
gates, quote-time policy changes, complete-search events, and outcome accounting.
They also compare the optimiser against exhaustive prefix evaluation. Simulation
cannot establish the real client's protected-call contract or live trading results.
