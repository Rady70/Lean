# Phase E authoritative replay export evidence (2026-10-01)

This directory preserves the compact, source-bound evidence of the Phase E
authoritative replay export for the finalized SingleAnchor research path.

- `manifest.json` - reviewed revision, contract identities, the Phase D/Phase E
  result binding, every committed artifact's path/SHA-256/byte size/origin/role,
  the retained-but-not-committed artifacts with their hashes, and the notes.
- `baseline-build.json` - the source-bound Release build receipt for the Phase E
  revision `c29770ef78a9ad85e3061460bde3ff664e764048` (clean checkout, frozen
  baseline contract hash, complete runtime dependency set).
- `corrected-history-preflight.json` - the mandatory corrected-full-history
  preflight receipt copied into the run (2,332/2,332 partitions hash-verified).
- `marketlab-run-invocation.json` / `marketlab-run-outcome.json` - the helper's
  pre-run and post-run evidence: exact launcher argv, contract/preflight/build
  hashes, clean repository head, exit codes, engine-error audit, data-monitor
  result, unchanged runtime artifacts and the results SHA-256.
- `corrected-full-history-classification.json` - the authoritative
  classification (`EXPECTED`, `invalidCount` 0): full qualified stream delivery
  and the 407/407 failed-request reconciliation.
- `replay-package-verification.json` - the Phase E package verifier PASS record
  (1,537 checks, `resultsBoundToPhaseD: true`).
- `replay-manifest.json` - the authoritative replay package manifest: run
  identity, event/telemetry counts, per-file hashes and the package fingerprint
  `8f77bdd16dc06593f87af5fe84b761f2f0a9e0ff7b4ee2f33956e6a1837f6a00`.
- `replay-events.jsonl` - the complete authoritative replay event stream
  (1,454 events; SHA-256
  `2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`).
- `replay-telemetry-sample.jsonl` - a bounded exact-string account-telemetry
  sample: the first 20 rows of 2019, the first 5 rows of 2020 and the single
  event-snapshot rows of 2021 and 2026 (the full 45 MB of shards remain local).
- `candle-cache-manifest.json` - the derived full M1 candle-cache manifest
  (90 monthly CSVs, 2,655,664 candle rows, content SHA-256
  `ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d`).

## Method and binding

One execution of the frozen corrected-full-history command (the Phase D contract
unchanged) with the Phase E implementation revision `c29770ef...`, launched
through `MarketLab\scripts\run-backtest.ps1 -RunEvidence` and classified by
`Test-SingleAnchorCorrectedFullHistory.ps1` as `EXPECTED`. The run's
`storage/single-anchor/results.json` is **byte-identical** to the Phase D
artifact `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`, so
the replay package is derived from the exact finalized Phase D state. The
package was then verified against that binding by
`MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1`.

The Phase A-D evidence, the frozen contracts and the qualified data identity are
unchanged. The 413,750,130-row historical-data qualification was not rerun, no
parameter was optimized and no hosted CI was dispatched. The full telemetry
shards, engine logs, LEAN result packets, helper console capture and the candle
cache itself remain local run artifacts identified by SHA-256 in `manifest.json`.

The full record is
[../../PHASE_E_REPLAY_EXPORT_RESULT.md](../../PHASE_E_REPLAY_EXPORT_RESULT.md);
the package contract is [../../REPLAY_PACKAGE.md](../../REPLAY_PACKAGE.md).
