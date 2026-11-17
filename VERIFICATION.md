# Depth optimiser verification

## Targeted material-list trial, November 17, 2026

Branch: `feat/targeted-materials`, based on PR #11 commit
`06806cff829fb0c8c393fd48526673aaac6b3ba2`. No installation, saved-variable
edits, threshold changes, release or purchase-policy changes are included.

- Added opt-in `/fsn targeted on|off`: fixed 101-material Normal Horde / Forever-EU
  seed, up to 100 keys per summary, oldest-completed-first with no ten-second
  batch cooldown and no routine broad-category discovery.
- Seed IDs exactly match the read-only shortlist generated from 115 known mats,
  regional sales feed `2026-11-17T01:02:06Z` and Normal Horde market/recent feed
  `2026-11-17T05:18:53Z`. Selection and limitations are documented in README.
- `npm test`: 183 tests passed, including 101-key coverage, candidate preparation,
  same-pool fallback, unknown commodity warming, scope rejection, pacing,
  opt-in persistence, mode changes, ownership and purchase locks.
- Static checker: zero errors and warnings. Strict load/lifecycle simulation:
  clean, with existing unknown-event notices. `git diff --check`: passed.
- Logs: `C:/Users/cbosc/AppData/Local/Temp/opencode/forever-targeted-{tests,lint,sim}.log`.

Actual live eligibility, full-list revisit times, available-at-click bargains and
realized profit remain unmeasured. This list is not automatically reranked. The
known extended AH-scenario failures below are not claimed as a passing gate.
CI on the exact PR commit and owner approval remain required before deployment.

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

### Owner-authorized test deployment and quote diagnostics

The owner subsequently requested a test deployment. PR #9 commit `16b6bf9`
passed CI run `43885700112` and was installed from a git archive with verified
runtime hashes, a verified prior-runtime backup and unchanged SavedVariables hash.
Receipt: `D:/WoW/AddonBackups/ForeverSniper/pre-tsm-sales-20261116-222736/deployment-receipt.json`.
The PR remains unmerged and no release was created.

The owner then reported two generic quote refusals for 11 units of item 2592
under 14 copper/unit (154 copper total). This message originates before the sales
policy revalidation. Neither the screenshot nor the on-disk saved file establishes
which guard failed. The follow-up replaces the combined boolean with equivalent,
ordered rejection reasons and logs numeric unit/total quotes, approved caps,
current budget and quote age to chat and `/fsn diagnostics`. No permission,
price, age, stock, profit, outcome or sales-policy limit is relaxed.

All 154 local tests pass, including a regression covering each of the ten
unchanged quote guards and retained diagnostic evidence. Static lint has zero
errors/warnings and strict load/lifecycle simulation is clean. The actual live
cause remains unresolved pending the next quote's evidence; this is a diagnostic
repair, not a claim that purchases are fixed. The owner was told this diagnostic
update would be deployed only after its exact-commit CI passes.

### Contradicted quote invalidation

The deployed diagnostic build (`0d97cd9`, passing CI run `43891207857`) showed
item 2592 x13 approved at 25 copper each / 325 total, but quoted at 159 copper
each / 2070-2079 total within 0.22-0.35 seconds. A subsequent native browse
screenshot showed Wool Cloth at 155 copper each. This establishes an obsolete
cheap offer relative to the purchase quote and native browse, not a timeout or
sales-policy rejection. It does not establish why the initial search had the
cheap tiers (removed auctions, delayed cache updates or another source).

Confirmed retry defect: above-cap quotes were cancelled but left their offers
and cached complete tiers available for another click. Price-contradicted quotes
now discard that item's snapshot, mark its offers gone and queue normal paced
revalidation at the original ceiling/exit caps. No price, budget or policy ceiling
is raised. Non-price refusals keep existing behavior. Unknown outcomes stay locked.

Local validation: 157 tests passed, lint zero errors/warnings, strict load/lifecycle
simulation clean. Production-path regression reproduces the reported 13 x25 /2070
case, blocks a second click and cache-only readiness, then feeds a fresh 155-copper
result and verifies the original offer remains rejected. Additional tests cover
independent unit/total overruns, item-local invalidation, unchanged refresh caps,
late quotes and non-price refusals. Deployment remains gated on exact-commit CI;
the original search/quote divergence still requires live observation.

### Live tier identity validation

The owner reported the same mismatch on item 2772: 21 units approved at 2 copper
each /42 total, quoted at 274 copper each /5754 total in 0.25 seconds. Native and
TSM screens showed roughly 296-298 copper, not 2 copper. With our scanner disabled
and the native commodity panel refreshed, a raw API dump returned `itemID=2772`,
`unitPrice=296`, `quantity=173`, `numOwnerItems=0`, `auctionID=123030736`, matching
the native price tier. Earlier active-scanner dumps were empty; these do not
establish an API signature error. The standard two-argument getter works.

Found a concrete missing check: the production tier reader used requested item ID
to label rows but did not verify each returned row's item ID. On Forever the
verified layout now requires every tier's `itemID` to match the request. Other
clients reject mismatches when a row identity is supplied. A wrong, malformed or
missing Forever identity rejects the entire wall, cannot fall back to a cached
snapshot, and cannot admit a deal or teach automatic price history. Result-event
diagnostics retain requested/returned IDs. No price scaling is introduced.

This closes an attribution gap but a wrong-item row has not yet been captured
during the failing live scan. It is not proof of the incident's root cause.
The quote-contradiction invalidation above is retained so a rejected stale bargain
cannot remain repeatedly buyable from the same snapshot.

Final local checks for the combined repair: 161 tests pass; secret lint zero
errors/warnings; strict load/lifecycle simulation clean. Regressions preserve the
actual 296-copper/173-unit raw values, reject wrong/missing/malformed identities
and mixed-item walls, block Buy and cached fallback, and prevent automatic history
or live admission from a wrong-item cheap result. The initial source of cheap
tiers remains an unresolved live question. No purchase guard has been weakened.

### Fresh bargain scheduling (stacked on PR #9)

Based on deployed `288c993`, isolated branch `feat/fresh-bargain-latency`.
Inspection found two avoidable scheduling waits: a queued candidate could lose
the next pacing slot to discovery (every fourth slot), or to background refresh
of an older focused offer (every fourth slot's third position).

Queued candidates now precede background focused refresh after its existing
five-second click window. A candidate may borrow a discovery slot only when
routine discovery is available. The following eligible scheduling slot is then
reserved for discovery before any additional candidate or speculative check.
There is at most one outstanding borrowed slot; even a failed submission repays
it. No borrowing during deep scans or native browse ownership. Existing candidate
aging/value/liquidity ranking and 30-second expiry are unchanged.

Deterministic scheduler example: after three target slots, a queued bargain now
gets slot four rather than waiting for slot five; discovery moves to slot five.
With continuous queued candidates, discovery occurs in slots five and nine.
This removes one discovery-request wait in that scenario. It is not a measured
live millisecond improvement, a listing-age estimate or a claim of fastest-client
performance. Existing in-flight ownership, pacing limits, stock freshness, click
window, full tiers, price identity, quote ceilings and unknown-outcome locks stay
authoritative. The code does not automatically start purchases.

`/fsn status` now separates detected-to-search queue wait from submitted-search
response time (including pages), alongside detected-to-validation timing. Response
timing is recorded only for a submitted candidate, not for an unsolicited result.
Last/max values are session diagnostics, not matched samples or percentiles; they
do not measure human reaction time or guarantee that Buy is immediately ready.
Live validation should capture these values and Buy readiness under real throttle
pressure before claiming improved successful-purchase rates.

Validation: 167 tests pass, secret lint zero errors/warnings, strict load/lifecycle
simulation clean, and whitespace check clean. New regressions cover borrowing and
repayment under continuous arrivals, failed submissions, throttle/owned-request
gates, candidate-before-background refresh and separate response timing. The full
existing purchase/identity/liquidity suite still passes. Extended AH simulation
remains outside this passing lifecycle gate. No game files or saved data changed;
deployment requires exact-commit CI and owner approval.

### Evidence for repeated cheap-tier / higher-quote mismatch

After the speed build was deployed, the owner reported item 2592 x33 approved
under 34 copper /1122 total, then quoted at 135 copper /4479 total. Quote age was
0.33 seconds. Diagnostics contained the refusal but no result-identity failure.
No wrong-item row or source of the cheap prices was captured. No purchase was
confirmed by this refusal. The subsequent internal auction error is not enough
to establish a root cause.

Important timing distinction: quote age measures Buy-click-to-quote, not price
snapshot age. Existing policy allows a completed snapshot up to 20 seconds old
and fallback to that snapshot if a direct getter returns loading/empty outside
a completed-result event. An hour-old TSM feed can make the reference and ceiling
outdated but does not supply the AH tier quantities used to approve a full lot.
Neither stale TSM data nor stale AH tiers have been established as the cause.

Diagnostic-only branch `fix/commodity-tier-evidence`, stacked on PR #10, records
one purchase-tier entry at the Buy click, before starting the quote. It contains
the live-API versus completed-fallback source, completed-event age, read age,
tier count, approved quantity/cost and the first three raw row scalar values
(item ID, copper unit price, quantity, owned quantity, auction ID when readable).
The raw evidence is copied, bounded to three rows and contains no seller names.
Live API means a direct getter read, not proof of a fresh server response. Local
event/read ages are not listing ages. Existing 50-entry diagnostics retention
applies. No price scaling, thresholds, expiry, fallback or purchase guards change.

Validation: 170 tests pass. New regressions cover direct API reads with a
ten-second-old completed event, loading/empty fallback with preserved caps, raw
copper/auction ID values, bounded evidence and immunity to API row-table mutation.
Secret lint and strict load/lifecycle simulation pass; extended AH simulation is
not claimed. No deployment for this diagnostic branch is authorized yet. The
remaining question is whether the next mismatch uses locally old completed tiers,
fallback, or a direct API read still reporting cheap rows.
