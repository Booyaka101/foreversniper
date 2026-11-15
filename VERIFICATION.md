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
