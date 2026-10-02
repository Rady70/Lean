# Corrected Phase E authoritative replay export evidence (2026-10-01/02)

This directory preserves the compact, source-bound evidence of the corrected
Phase E authoritative replay export for the finalized SingleAnchor research
path, after the independent-review corrections.

- `manifest.json` - reviewed revision, contract identities, the Phase D/Phase E
  result binding, every committed artifact's path/SHA-256/byte size/origin/role,
  the retained-but-not-committed artifacts with their hashes, and the notes.
- `baseline-build.json` - the source-bound Release build receipt for the
  corrected Phase E revision
  `a2941581c02462a190f4d4289f371aed409cb1e3` (clean checkout, frozen baseline
  contract hash, complete runtime dependency set).
- `corrected-history-preflight.json` - the mandatory corrected-full-history
  preflight receipt copied into the run (2,332/2,332 partitions hash-verified).
- `marketlab-run-invocation.json` / `marketlab-run-outcome.json` - the helper's
  pre-run and post-run evidence: exact launcher argv, contract/preflight/build
  hashes, clean repository head, exit codes, engine-error audit, data-monitor
  result, unchanged runtime artifacts and the results SHA-256.
- `corrected-full-history-classification.json` - the authoritative
  classification (`EXPECTED`, `invalidCount` 0): full qualified stream delivery
  and the 407/407 failed-request reconciliation.
- `replay-package-verification.json` - the strengthened Phase E package
  verifier PASS record (30,467 checks, 28,917 authoritative payload-parity
  comparisons, `resultsBoundToPhaseD: true`; byte-reproducible).
- `replay-manifest.json` - the authoritative replay package manifest: run
  identity, event/telemetry counts, per-file hashes and the package fingerprint
  `5dcd8bfaffe76c9d2c8eec002073f62fe18b5d0d40b0602dbad0e59f6846097a`.
- `replay-events.jsonl` - the complete authoritative replay event stream
  (1,454 events; SHA-256
  `2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`; unchanged
  from the first export because only the hard-BE telemetry snapshots changed).
- `replay-telemetry-sample.jsonl` - a bounded exact-string account-telemetry
  sample: the first 20 rows of 2019, the first 5 rows of 2020, the single
  event-snapshot rows of 2021 and 2026, plus each of the 11
  `hard_breakeven_activated` snapshots and the snapshot of the immediately
  following entry event. The activation/entry pairs directly show the
  pre-attempt state (4 open positions) and the post-entry state (5) in the
  committed bytes (the full 45 MB of shards remain local).
- `candle-cache-manifest.json`, `candle-cache-verification.json`,
  `candle-composition-verification.json` and `candle-parts/part?-manifest.json` -
  the derived full M1 candle-cache manifest (90 monthly CSVs, 2,655,664 rows,
  content SHA-256
  `ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d`, manifest
  SHA-256 `75f1d241...`, qualification-record binding `e9c72d1a...`), the
  fail-closed source/cache verification PASS (9/9 checks, 2,332/2,332 partition
  zip hashes), the composition PASS (10/10 checks) proving the final cache is
  the contiguous month-aligned union of the four **re-derived** part caches, and
  the byte-identical part manifests themselves. The four source ranges were
  regenerated with the corrected generator: 90/90 monthly records equal the
  final cache bytes (the CSV bytes were not changed).

## Method and binding

One execution of the frozen corrected-full-history command (the Phase D contract
unchanged) with the corrected Phase E implementation revision `a2941581c...`,
launched through `MarketLab\scripts\run-backtest.ps1 -RunEvidence` and classified
by `Test-SingleAnchorCorrectedFullHistory.ps1` as `EXPECTED`. The run's
`storage/single-anchor/results.json` is **byte-identical** to the Phase D
artifact `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`, so
the replay package is derived from the exact finalized Phase D state. The
package was then verified against that binding by the strengthened
`MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1`, whose authoritative
parity comparisons, derivations, ordering checks and mutation behavior are
exercised by `MarketLab\tests\Test-SingleAnchorReplayPackageVerifier.ps1`
(36/36 mutations rejected, 2/2 positive failed-run fixtures verified).

## Review corrections in this revision

- The engine publishes an observational `HardBreakevenActivated` event at the
  real hard-BE transition, before the first tail attempt is sized or placed; all
  11/11 activation snapshots in this package are pre-attempt (committed in the
  telemetry sample with their immediately following attempt snapshots).
- The verifier compares the replay stream against the authoritative
  `results.json` structures (anchors, entries, forced liquidations with
  before/after state and same-quote ordering, Stop Out episodes, rejections,
  hard-BE and trailing activations, Margin Call transitions, manifest
  identity/outcome/file order, run-end provenance/account/margin state and the
  complete failure identity under the `max(lastProcessedQuote, failureQuote)`
  rule), binds every event snapshot to the event time/quote, derives the
  hard-BE pre-attempt inventory and trailing thresholds from parity-verified
  data, asserts the causal lifecycle order, and enforces the real 300-second
  periodic rule.
- Package publication is fail-closed: results first, payloads before the
  manifest, a failed payload suppresses the manifest.
- Candle generation is fail-closed on the qualified source identity; the cache
  bytes were re-derived from the qualified source (90/90 monthly records
  matched), the rebuilt manifest binds the PASS qualification record, and
  `verify-candles`/`verify-candle-composition` certify it.
- The committed part manifests are byte-identical to the verified files, and
  the verification record is byte-reproducible (no absolute path).
- Third review: the snapshot-binding loop no longer skips entry and
  forced-liquidation events (post-entry/post-close derived inventory, trigger
  quote, run-start/run-end quote identity); the event-type whitelist, the
  unique run boundary pair, the one-to-one trailing lifecycle, the
  `first_entry_skipped`/`SkippedFirstEntryTrace` binding, the rejection-recap
  order and the hard-BE-violation failure mapping are enforced; exact-string
  coverage includes the remaining event classes and the manifest parameter
  blocks; Margin Call conditions and the account-arithmetic identities are
  checked (tolerance `1e-20`).

The Phase A-D evidence, the frozen contracts and the qualified data identity are
unchanged. The 413,750,130-row historical-data qualification was not rerun, no
parameter was optimized and no hosted CI was dispatched. The full telemetry
shards, engine logs, LEAN result packets, helper console capture and the candle
cache itself remain local run artifacts identified by SHA-256 in `manifest.json`.

The full record is
[../../PHASE_E_REPLAY_EXPORT_RESULT.md](../../PHASE_E_REPLAY_EXPORT_RESULT.md);
the package contract is [../../REPLAY_PACKAGE.md](../../REPLAY_PACKAGE.md).
