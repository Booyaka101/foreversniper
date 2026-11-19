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
The live readiness API is authoritative: stale SENT/QUEUED event flags do not add
a five-second delay after the server reports ready. The feed distinguishes owned
batch/browse replies from idle shared-throttle waits.

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

## Experimental batch discovery

`/fsn batch on` enables known-commodity summary searches of up to 100 unique item
keys per request. It is **on by default** for the owner-approved rollout; Forever's
live response semantics still need validation. Existing explicit off settings are
preserved. `/fsn batch off` stops new batches; an in-flight request keeps
ownership until it completes or times out. `/fsn status` reports sent/completed
batches, requested keys in completed batches (including repeat visits), returned
rows, failures, and the last response time.

Batches use automatic target opportunities after queued candidates, watches and
due displayed-deal refreshes. Broad category discovery keeps its reserved slots
to find unfamiliar items. Keys with fresh market history rotate oldest-check-first
with a minimum ten-second revisit interval. Deep scans retain their own browse
channel; batch requests do not run alongside them. Item checks resume when no
batch keys are due or the required APIs are absent.

Unreadable, incomplete, unexpected or duplicate rows, submission errors, dropped
requests and five-second timeouts disable batches for the current UI session.
Individual checks then resume through the usual readiness and spacing gates.
After investigating the failure, `/fsn batch on` can explicitly retry. Empty,
complete replies are accepted because none of the requested items may be listed.
The browse events have no request token; membership checks reject foreign keys
but cannot prove ownership against another addon's overlapping search. Avoid
running competing scanners during live validation.

Summary rows go through existing candidate gates, never directly into purchase
snapshots. Complete live tiers, quote checks, stock limits and reserves remain
mandatory. In-flight batches block purchases, inspection, full-scan requests and
sell-query preparation. Candidate validation uses age plus a bounded estimated
profit boost; summary profit is only a priority hint, not validated earnings.
There is no 1% change cutoff: unchanged summaries and small quantity changes
remain eligible on later visits. Existing duplicate-alert checks still apply.

Local tests establish scheduling and fallback behaviour, not a live speedup.
During the default-on rollout, compare batches on/off with the same
known items: completed keys per minute, revisit delays, candidate-to-alert time,
timeouts and stale-result rejections. Last response time is not listing age.

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

### Candidate selection and history

#### Continuous monitoring and pricing mistakes

The routine scheduler now reserves three of every four available query slots for
monitoring, with the fourth reserved for broad discovery. Queued bargains receive
the next monitoring slot ahead of speculative searches. Existing owned result
pages and the bounded five-second focused Buy window still take precedence.
These are scheduling priorities, not faster server requests or instant alerts.

Batch summaries revisit up to 100 known eligible items per request. Oldest checks
lead, with a bounded five-second priority boost for a fresh near-reference-floor
sighting. The existing ten-second per-item batch cooldown remains. Unknown items
still enter through broad discovery and full/deep scans, not a guessed item list.
Every deep-scan page now evaluates candidates before learning its own prices;
complete live tiers are still mandatory before admission. Deep browse requests
are spaced at least four seconds apart and yield to queued validation and the
focused click window. They retain browse ownership, so batches resume after the
deep scan rather than destroying its page set. Deep scans remain time-bounded.

`/fsn status` reports completed-check revisit last/mean/max and observed
candidate-to-validation delays. `/fsn tsm <itemID>` also shows that item's last
completed check and last revisit interval. These measurements do not establish
listing age, sale demand, or guaranteed detection-to-Buy time. Server readiness
and purchase locks can still delay a valid opportunity. No listing-created event
or promise of beating other buyers is implied.

#### TSM-backed first-scan discovery

When TSM and its AppHelper are enabled, Forever Sniper can use verified realm
prices immediately, without waiting for its local history to warm up. The first
browse sighting and the first full snapshot can both queue candidates. Deals
still require complete live commodity results and all existing risk checks.

The starting reference is the lower valid `DBMarket` / `DBRecent` value, provided
its realm/faction feed was downloaded within 12 hours. A valid `DBHistorical`
value downloaded within 48 hours can lower it, but cannot bootstrap an item by
itself. Mature, fresh local history also caps the reference. These are conservative
policy limits, not a guarantee of demand, sale price, or profit. Regional and
alternate-realm prices do not bootstrap candidates.

Forever market identity follows TSM's ruleset mapping (`Normal`, `PvP`,
`Roleplay`, `Roleplay PvP` or `Hardcore`) plus faction, not the physical realm
name. Missing or unreadable ruleset APIs fail closed rather than guessing Normal.
Provider status identifies the selected scope and separately reports stale,
future-dated, unmatched or unobserved timestamps.

Prices come from `TSM_API.GetCustomPriceValue`. Because that API exposes no data
timestamp, a read-only secure hook observes AppHelper's realm/faction metadata
while it loads. It does not execute the data payload, replace TSM functions, or
change TSM settings. Unknown layouts, data loaded before the observer, missing
prices, errors, stale or future timestamps all fall back to local history. The
verified layout is TSM 4.15.7's Forever realm feeds, which include stackables;
other feed layouts are not guessed. TSM is optional and is loaded before our
observer; AppHelper is deliberately not declared as an optional dependency so
its data can be observed when it subsequently loads.

- `/fsn tsm`: provider status.
- `/fsn tsm <itemID>`: selected reference and its source, including a local cap.
- `/fsn tsm off` / `/fsn tsm on`: persistently disable or enable TSM references.

These realm references change discovery only. Local history is not filled with TSM samples, and
selling/portfolio references keep their existing local-history rules. It does
not increase request rates or import TSM's saved operations. A candidate can
appear when its first live results arrive, not necessarily in the first second.

#### Regional sales and liquidity checks

Fresh TSM Forever regional sales data can tighten market/dump flips:

- `DBRegionSaleAvg` only lowers an existing reference or resale estimate. Regional
  sales alone never create a discovery reference.
- A known `DBRegionSaleRate` below **5%** rejects the flip. This measures regional
  posting success, not the probability that your particular listing sells.
- Known `DBRegionSoldPerDay` limits total exposure to **10%** of average regional
  daily volume per AH, rounded down. Inventory/bank, owned auctions and pending
  purchases all count. A cap below one rejects the flip. Existing manual caps can
  tighten this further; setting a manual cap to zero does not disable sales caps.

These configurable defaults are conservative policy choices, not proven optimum
settings. Regional sale averages aggregate reported Accounting sales and purchases;
they are not a promised exit price on your realm. Daily volume is not realm-specific
or a guarantee of available buyers. Vendor and absolute-price watches are exempt
from market sales policy, but retain existing budgets and manual stock controls.

Sales metadata must be observed for the matching `Forever-<region>` or
`Forever-HC-<region>` feed, no more than 48 hours old and not future-dated.
Missing/stale/unobserved data remains explicitly unknown and retains existing
fallback. Public API queries preserve fractional rates/volume and known zeroes.
Known volume requires fresh readable owned-auction stock, even without manual
stock caps. Complete-tier, Buy and quote-time guards remain authoritative.

- `/fsn sales <itemID>`: inspect coverage, values and liquidity policy.
- `/fsn sales on` / `/fsn sales off`: enable or disable sales checks (default on).
- `/fsn sales rate 5`: set the minimum known rate to 5%.
- `/fsn sales share 10`: cap known exposure at 10% of regional daily/AH volume.

Rate/share accept percentages greater than zero and at most 100. `/fsn tsm off`
also disables sales checks. Tooltips show sales values or why coverage is unknown.
Fresh rate/volume adds at most two seconds of candidate priority; aging still wins.
The addon does not import TSM operations, write its data or increase AH request rates.

The default discovery ceiling is now **70% of the trusted reference**, not
50%. An upgrade retunes exactly the former 50% setting once, records it in
`previousThreshold`, and prints how to restore it: `/fsn thresh 50`. Other saved
thresholds are preserved, and subsequent choices survive reloads. This is a
candidate-selection policy, not a promise that a 30% discount is profitable.
Complete live tiers still determine the position, estimated exit and net profit.

History retains at most 30 observations, spaced at least 90 seconds apart.
Repeated sightings within that interval can lower its price but cannot raise it
or renew its timestamp. Legacy dense samples are also grouped conservatively when
read. This prevents scan frequency from dominating the reference; it does not
create missing history, confirm demand, or preserve old prices indefinitely.
Without usable TSM data, the default two-observation warm-up needs at least
90 seconds of local evidence.
The 45-minute freshness limit still applies.

### Buying a displayed offer

Readiness events update existing Buy buttons immediately instead of waiting for
the full feed repaint. A live-validated focused offer receives one five-second
routine-search pause starting when the scanner can query again. Discovery then
resumes, and in-flight result paging is never abandoned. Other addons and the
server can still make the shared AH busy during that window.

Buy labels distinguish `BUSY` (live AH readiness), `N/A` (readiness unavailable),
`QUOTE`, `RESULT`, and `LOCK` (unknown purchase outcome). `/fsn status` reports
the focused offer's current action and reason. A disappearing offer can genuinely
have sold or become ineligible; the pause is not a reservation of its auctions.

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

## Desktop briefing helper

With every WoW client closed, run the dependency-free helper with Node.js 22 or
newer:

```powershell
node tools/forever-desktop.mjs
node tools/forever-desktop.mjs --sv "D:/path/to/account/SavedVariables/ForeverSniper.lua"
```

By default it discovers accounts under `D:/WoW/World of Warcraft/_forever_`.
Use `--wow-root <path>` for a different installation or `--sv <path>` when more
than one account exists. It refuses writes if WoW is running or process detection
fails; there is no force override. Process detection requires Windows.

The helper parses SavedVariables as data, preserves the database text, and writes
only `ForeverSniperBriefing`. It uses a helper lock, rechecks the process list and
source before replacing the file, and saves a `.desktop-bak` backup plus per-account
`.desktop-state.json` history alongside it. Keep WoW closed throughout the run:
the helper lock cannot prevent the game from starting. Listing disappearances
are observations, not confirmed sales. Recheck live prices before buying.

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
