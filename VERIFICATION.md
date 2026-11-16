# Depth optimiser verification

## Scope

Branch: `feat/forever-depth-optimizer`. Baseline commit `31902e9` preserves
the approved installed 0.6.49 Lua and TOC. That import is intentionally separate
from the feature commit because the installed addon was ahead of tracked main.
The implementation pass did not modify the live installation or saved variables.

## Completed checks

- `npm test`: 22 tests passed. Production Lua compilation, complete-tier
  optimisation, 100 exhaustive-prefix comparisons, complete-search events,
  reserve and stock gates at Buy and quote time, outcome accounting, command
  configuration, and guarded reservation acknowledgements.
- `wow-secret-lint`: zero errors and zero warnings.
- `wow-addon-sim . --strict`: clean load and lifecycle result. The simulator
  reports unknown-event notices for several client-specific events.
- `git diff --check`: passed.
- Read-only baseline comparison: strict AH scenario produces 31 errors both
  before and after the feature, including missing global `tinsert` and subsequent
  nil `feedRows` failures. This scenario is not a passing validation gate.
  Baseline diagnostics were retained locally in
  `C:/Users/cbosc/AppData/Local/Temp/opencode/forever-baseline-ah.log`.

## Review coverage

Reviewed the complete feature diff, optimizer module, owned-query pacing and
freshness contract, money parsing, and purchase settlement integration. Stock
reads are cached only within one optimization; Buy and quote read policy again.
Reservations persist and can conservatively double-count received holdings until
the player explicitly acknowledges collection.

## Remaining gates

- CI must pass on the exact release commit before publication.
- Live-client protected execution and real auction trading are not validated.
- Review the baseline import alongside existing reliability PR #1 before merge.
- The owner subsequently authorized tagging, pushing, release and deployment of
  0.6.50. Deployment must back up installed files and preserve saved variables.

No further simulator investigation is included in this bounded feature pass.

## Scan-latency follow-up

Branch: `fix/forever-scan-latency`, based on released 0.6.50 through `origin/main`.
The owner requested a fix for late deal discovery. This pass does not release,
deploy, change saved data, or change spending and purchase validation policy.

Implemented:

- Coalesced, deferred ready/result-event wakes using the existing pacing gate.
  The fallback ticker remains available when events are missing. Stop/restart
  invalidates queued wakes.
- Alternating target/discovery opportunities, preserving the manual watch slot.
- Smooth weighted category rotation with the existing class shares.
- Bounded displayed-deal refresh priority instead of exclusive scanner ownership.
  In-flight unrelated pages and deep discovery may continue. Purchase locks remain.
- Shared Lua test helpers; the original 22 depth/risk tests remain unchanged in
  behaviour. New deterministic scheduler tests cover dispatch timing, allocation,
  duplicate events, synchronous replies, ownership, deep scans, failure spacing,
  shutdown and all purchase guards.

Inspected the complete feature diff and the relevant scheduler, ready-event,
commodity-result, deep-scan, focus, and Buy snapshot functions. Historical strict
AH scenario failures above remain a known limitation, not a passing gate. Actual
live-client latency and competing-addon effects remain unmeasured.

Final local checks: all 40 tests passed (22 existing, 18 scheduler tests); strict
load/lifecycle simulation passed with existing unknown-event notices; static
checker reported zero errors and warnings; diff whitespace check passed.
Full test output is retained locally as
`C:/Users/cbosc/AppData/Local/Temp/opencode/forever-scan-latency-tests.log`.

Next gates: open a PR and check CI. Do not merge, release or deploy this follow-up
without owner approval. Live latency validation remains outstanding.

## Batch-discovery follow-up

Branch: `feat/forever-batch-discovery`, stacked on PR #3 commit `abbb53f`.
The owner approved implementation following the competitor review, not deployment.

Implemented opt-in 100-key commodity summaries, oldest-check-first key rotation,
retained broad discovery/watch/candidate slots, strict summary membership/shape/
completeness validation, five-second timeout and session-disabled individual
fallback. Candidate ordering adds a bounded profit hint to aging. Summary data
still flows through the existing unverified-candidate path; it cannot create
purchase snapshots. In-flight ownership covers searches, full scans, sell-query
preparation and Buy. Timer restarts retain batch ownership; close/disable clears it.

Inspected the complete production diff plus existing browse candidate processing,
quickBuy, requestItemSearch, replicate ownership, deep-scan dispatch, stop/close,
and slash-command paths. Deterministic tests exercise production batch functions,
browse-event dispatch, pacing/ownership, invalid replies, synchronous replies,
key rotation, fallback, command toggles and purchase blocking. The scheduler test
stubs the downstream candidate processor; the existing depth suite separately
executes real purchase validation. This is not end-to-end live server validation.

Remaining before deployment: live API completeness/event behaviour, competing
scanner interference, coverage/revisit/detection latency measurements. Membership
checks cannot distinguish overlapping searches because browse events have no
request token. Batching remains default-off. Auctionator-style cache-ready retries
and cross-addon coordination are deferred, not claimed as implemented. Existing
baseline AH-scenario failures remain excluded from passing gates.

Final local checks: all 56 tests pass (40 prior tests plus 16 new batch/priority/
purchase regressions), strict load/lifecycle simulation is clean with unknown-event
notices, and the static checker reports zero errors/warnings. Full test output:
`C:/Users/cbosc/AppData/Local/Temp/opencode/forever-batch-tests.log`.
Next action: open a stacked PR against `fix/forever-scan-latency`, check exact-commit
CI and leave both PRs unmerged. No version bump, deployment or saved-data edits.

### Owner-approved enabled deployment

The owner subsequently requested deployment with all new discovery features
enabled. Batch discovery now defaults to true; existing explicit off settings are
preserved. The installed saved configuration has no batch override, so the default
will apply on reload without editing saved data. This approval changes rollout
policy, not the live-validation evidence above. Failure fallback, purchase gates,
stock/reserve settings and query spacing remain unchanged. Deployment must use the
exact updated commit after CI passes, with backup and hash verification.

## Reported throttle-wait follow-up

Branch `fix/forever-throttle-waits`, based on deployed batch commit `6abcc69`.
The user reports spending most time waiting for AH throttle. Read-only inspection
found no persisted live throttle diagnostics; live `/fsn status` output is still
needed to quantify the wait. Installed Auctionator uses the live readiness API
as authoritative, while our canQuery also let a stale SENT/QUEUED event flag veto
ready requests for five seconds. Removed that redundant veto, not live readiness
or one-second spacing. Batch/browse ownership now has explicit feed labels rather
than falling through to the generic throttle message. Purchase stages retain
precedence. Regression tests cover stale/out-of-order events, true busy readiness,
spacing and feed stage classification. No live speedup is claimed.

Bounded pass: inspect readiness and status paths, add regressions, run tests/static/
lifecycle checks and exact-commit CI, open a PR. No deployment or release in this
pass; live status evidence and server-side contention remain unresolved.

Local gates passed: all 61 tests (57 prior plus four wait/status regressions),
strict load/lifecycle simulation with unknown-event notices, static checker with
zero errors/warnings, and diff whitespace check. Full test output is retained at
`C:/Users/cbosc/AppData/Local/Temp/opencode/forever-throttle-tests.log`.
## PR #1 reconciliation onto scanner main

Merged current main into the older reliability branch without changing
`ForeverSniper.lua`, the depth optimiser, scanner tests, package dependencies or
CI gates relative to main. Kept version 0.6.50 and declared the desktop briefing
SavedVariable. Retained the data-only parser and guarded desktop writer, including
account discovery, process checks, lock/recheck/backup and per-account history.
Updated README instructions to describe the helper without old purchase claims.

Replaced obsolete two-click/item-buy tests with nine tests of the current owned
quote lifecycle: cancellation ordering, unknown-outcome locks, unsolicited and
duplicate quotes, exact ceilings, expiry/revocation, changed complete positions,
and unavailable quotes/errors. Existing depth tests retain complete-tier,
stock/reserve and server-only accounting coverage. All 83 tests pass locally;
static checker reports zero errors/warnings; strict load/lifecycle simulation is
clean with known unknown-event notices. Extended AH simulation is not a passing
gate and is not claimed here. No live deployment, release or saved-data write.
## Deal selection and Buy readiness repair, 2026-11-16

Scope: owner reports no deals overnight, then two offers stuck on Wait before
disappearing. Thirty-minute bounded pass: research listing-value methods, trace
candidate admission and history, inspect readiness/UI ordering, add executable
regressions, run local gates and exact-head CI. No deployment or release.

Research completed before edits:

- TSM's official market-value description separates per-snapshot outlier handling
  from time-aggregated history. We do not have its realm/region dataset and do not
  claim our floor median is DBMarket:
  https://support.tradeskillmaster.com/en_US/custom-strings/how-is-auctiondb-market-value-calculated
- TSM explicitly says DBMarket describes listings, not what an item will sell for:
  https://support.tradeskillmaster.com/en_US/custom-strings/which-price-sources-can-i-use-and-what-do-they-mean
- Read the installed Bilis `Sniper.lua`, lines 848-977: it evaluates commodity
  tiers with capital, stock, gap and net-profit policies. Rejected its invented
  next-price fallback when there is no higher tier. Our existing optimiser keeps
  the lower of a real next tier minus one copper and the supplied reference, or
  the reference alone when no higher listing exists. Neither establishes demand.
- Reused prior verified live-readiness API findings. No request-rate increase.

Production-function probes on the deployed baseline showed a 35%-discount lot
could pass existing full-tier risk checks at 2g99s70c estimated net, yet the 50%
discovery prefilter never queued it. Repeated sightings could replace all 30
history observations in five minutes at ten-second intervals. These are synthetic
counterexamples, not measured missed trades on the live AH. The saved account
file was from the prior evening while WoW was running; it cannot prove the live
cause. No real SavedVariables writes were made.

Implementation: once-only 50-to-70 default retune with prior value retained and
an in-game restoration message; preserve other thresholds. Seventy percent is a
conservative policy choice, not an empirically optimal trading rule. Time-spaced
history retains conservative interval minima and de-clusters legacy samples;
future/stale samples and own-relist exclusions remain. Removed the unused legacy
median function and inlined the single sample-count call to remain within Lua's
200-local chunk limit after adding the shared history helper.

Wait finding: feed controls were refreshed on a multi-second schedule while ready
events could schedule a new search after 0.01s. Immediate button updates plus one
bounded five-second focused-offer routine-search window address that race without
bypassing live readiness. Quote/outcome/unknown-lock labels are distinct. In-flight
pages finish first, and routine discovery resumes after the single window.
Live server contention or another buyer can still invalidate an offer.

Regression coverage includes summary-to-live-tier-to-admission with production
functions, strict-threshold restoration, live depth/fees/deposit/budget/stock/
overhang rejection, scan-frequency independence, legacy de-clustering, sustained
declines/expiry, migration, ready-event UI ordering, one-shot click windows and
uninterrupted paging. Existing purchase and outcome tests remain intact.

Local gates: all 101 tests pass; wow-secret-lint reports zero errors and warnings;
strict load/lifecycle simulation passes; git diff --check passes. Extended AH
simulation is not claimed as a gate because of the previously recorded baseline
simulator failures. Live-game confirmation remains pending after deployment.
## TSM first-scan reference integration, 2026-11-16

Bounded pass: verify the installed price API and provenance, wire discovery,
exercise first-sighting and risk regressions, run local gates and exact-head CI.
No merge, deployment, release, live settings changes or SavedVariables writes.

Inspected installed TSM 4.15.7: App/API.lua lines 244-283 exposes public source
evaluation but no update timestamp. AuctionDBConfig.lua lines 22-54 maps DBMarket,
DBRecent and DBHistorical to realm fields. AuctionDB.lua lines 57-67 and 161-210
keeps update times internally and reads downloadTime metadata; it does not impose
our source-specific expiry. AppHelper.lua lines 108-175 and 403-425 routes realm
data by realm plus faction and ignores duplicates. Its loader is reassigned at
login (lines 325-328). The installed AppData.lua contains separate Normal-Alliance
and Normal-Horde market, recent and historical feeds and Forever-EU regional
feeds. No private addon code or saved data was sent to documentation services.

Design: optional TSM dependency, public prices only, session-only read-only secure
observer for known AppHelper metadata. No payload execution, TSM loader replacement
or TSM data writes. Use the lower usable realm market/recent price (12-hour max
download age), capped by historical (48-hour max) and mature fresh local history.
Historical-only, regional-only, wrong realm/faction, future, unknown or unobserved
feeds cannot bootstrap. Missing TSM/API failures fall back safely. Cache results
for at most 30s (missing values 5s), never beyond contributing feed freshness;
cap cache at 12,000 items. Timing limits are explicit conservative policy choices.

Discovery, automatic targets and batch targeting share the resolver. Full scans
no longer suppress the first pass when a trusted reference exists. Learning still
happens after candidate evaluation and never stores TSM prices as local samples.
Selling, cancellation and portfolio reference policies are unchanged. No pacing,
purchase, quote, outcome or budget safeguard was relaxed.

All 118 tests pass locally. New regressions run production provider, resolver,
browse, full-snapshot, live-tier admission and optimizer paths. They cover empty
book first sightings, conservative caps, API errors/invalid values, freshness and
cache expiry, wrong realm/faction, unknown metadata, no-observer fallback, commands,
batch eligibility before local warm-up, and complete-results/profit/stock/budget/
overhang rejection. Lua compilation includes all three runtime chunks. Lint and
strict load/lifecycle simulation also pass; exact-head CI is checked on the PR.

Remaining live check: `/fsn tsm` must confirm observed realm data after reload;
`/fsn tsm <itemID>` exposes the selected source. Load ordering by another addon
may cause AppHelper data to arrive before our observer; this deliberately leaves
TSM unavailable rather than trusting a timestamp we cannot verify. There is no
claim of first-second results, actual missed-trade recovery or guaranteed resale.
## Continuous monitor scheduler, 2026-11-16

Follow-up authorized scope: implement the monitoring redesign on PR #7, merge
after CI and deploy the exact tested main commit with backup and unchanged saved
data. Bounded pass retains all request-pacing, readiness and purchase safeguards.

Routine scheduling changes from alternating target/discovery slots to three
monitoring slots per reserved discovery slot. Queued bargains precede speculative
rechecks and manual watches precede batches when no bargain is queued. Batch
coverage stays oldest-first with a bounded five-second near-line boost, the same
100-key limit and ten-second per-key cooldown. Unknown items still need discovery;
there is no assumed global item catalogue or server listing-created event.

Deep results now use the shared candidate pipeline before history learning and
only process new rows on added pages. Its ticker yields to fresh candidate queues
and the focused click window and spaces browse requests at least four seconds
apart. Item checks continue; batches cannot replace its owned browse result set.
The existing two-minute bound can stop a partial deep scan, so this is not a claim
of exhaustive all-item coverage each cycle.

Session-only diagnostics record completed-check revisit intervals, per-item last
check/revisit and candidate-detection-to-validation latency. They do not measure
time since listing creation or promise that the Buy API is ready at validation.
Regression tests include the new 3:1 reservation, next-slot bargain priority,
bounded batch hotness, actual revisit measurements, deep page evaluation and
deduplication, live-tier admission and background yielding/spacing. Existing
purchase locks, pagination ownership and server-pressure tests remain mandatory.

Local gates: all 123 tests pass, including all three Lua chunks compiling; secret
lint reports zero errors/warnings; strict load/lifecycle simulation passes. Exact
PR-head and merged-main CI must both pass before deployment. Live timing and the
installed AppHelper observer still require confirmation after `/reload`.
## Forever TSM market identity repair, 2026-11-16

Reported live symptom after PR #7: TSM API present but the generic timestamp
fallback warning appeared. Installed market/recent feeds were only about 48
minutes old at inspection, not outside the 12-hour policy. Read-only inspection
identified a concrete compatibility defect: TSM LibTSMWoW/Source/Util/SessionInfo.lua
lines 13-35 replaces physical realm names with Forever ruleset markets, whereas
our resolver joined raw GetRealmName() with faction. Exact live raw realm and
observer delivery were not available from the screenshot, so a missed loader
callback is not ruled out solely by this diagnosis.

Repair matches TSM's ruleset mapping on WOW_PROJECT_CAMELOT: Hardcore first,
then Roleplay PvP, Roleplay, PvP or Normal, with the existing faction suffix.
Missing enums/APIs, throwing calls and non-boolean rules never default to Normal.
Other clients keep physical realm matching. Status now identifies the expected
market and distinguishes missing identity, unmatched/never-observed data, stale
feeds and future timestamps; fresh status includes scope, source and age.
No freshness limit, price reference policy or purchase safeguard changes.

Regressions reproduce the old physical-realm/Normal-feed mismatch and exercise
all ruleset combinations, faction and scope cache isolation, unreadable APIs,
non-Forever behavior, differentiated diagnostics and first-sighting discovery
through complete live-tier admission. The missing-observer fallback remains
intentional; live confirmation after reload is required, not claimed by tests.

Local validation: all 129 tests pass; secret lint reports zero errors/warnings;
strict load/lifecycle simulation passes. Deployment requires successful exact
PR-head and merged-main CI, a runtime backup and unchanged SavedVariables hashes.

## TSM regional sales and liquidity, 2026-11-16

Branch: `feat/tsm-sales-liquidity`, based on deployed PR #8 main (`fc35aa8`).
Scope is implementation, validation and a review PR only. No runtime installation,
SavedVariables, publication switches, release version or deployment changes.

Research verified the installed TSM 4.15.7 Forever regional sale feed has
`regionSale`, `regionSoldPerDay` and `regionSalePercent`, under `Forever-EU`.
Its number-source registration divides stored values by 1000, and the public
custom-price evaluator rounds the final expression. Scaled expressions with a
positive offset preserve fractional rates/volume and distinguish known zero
from missing values. Metadata inspection never executes AppHelper payloads.

Definitions were checked against TSM's official price/value source documentation:

- https://support.tradeskillmaster.com/en_US/custom-strings/which-price-sources-can-i-use-and-what-do-they-mean
- https://support.tradeskillmaster.com/en_US/custom-strings/which-value-sources-can-i-use-and-what-do-they-mean

Policy: matching Forever normal/hardcore regional data, observed and no more than
48 hours old, may lower existing market references/resale estimates. It cannot
bootstrap discovery. Known rates below 5% or volume-derived caps below one reject
market/dump positions. Exposure is capped at 10% of daily regional volume per AH,
rounded down, including held/banked items, owned auctions and pending receipts.
Manual limits may tighten but not loosen this cap. Vendor/absolute watches keep
their existing policies. Defaults are configurable policy choices, not measured
optimal thresholds. Unknown sales data preserves existing fallback behavior.

Review covered provider metadata/scoping/caching, discovery reference selection,
complete-prefix optimization, fresh owned-stock scheduling, guarded Buy and quote
revalidation, bounded candidate priority, commands and tooltip/status diagnostics.
Sales queries use only the public TSM API and do not issue AH requests. Fresh
stock maintenance shares existing paced scheduler slots.

Final local checks: all 153 tests passed (129 prior, 24 added); secret lint zero
errors/warnings; strict load/lifecycle simulation clean with existing unknown-event
notices; diff whitespace check passed. Tests exercise production Lua sections,
provider failure/zero/fractional values, stale/future/mismatched scopes, no regional
bootstrap, live-tier admission/profit, total exposure and complete prefixes,
vendor/watch exemptions, Buy and quote-time policy, commands and bounded priority.
Full test and simulation logs are retained under the approved local temp directory
as `forever-sales-tests.log` and `forever-sales-sim.log`.

Remaining gates: PR review and CI; actual in-game per-item API coverage, observer
delivery, protected execution and resale performance remain unverified. The known
strict AH scenario failures described above were not re-investigated or claimed
as passing. Stop at the review PR; do not merge or deploy this feature in this pass.
