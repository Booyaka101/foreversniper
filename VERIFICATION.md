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
