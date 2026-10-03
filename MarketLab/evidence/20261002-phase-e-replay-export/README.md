# Corrected Phase E authoritative replay export evidence (2026-10-01/02; signed-net re-run 2026-10-03)

This directory preserves the compact, source-bound evidence of the corrected
Phase E authoritative replay export for the finalized SingleAnchor research
path, after the independent-review corrections and the later export-only
signed-net telemetry addition (Phase F's review decision).

- `manifest.json` - reviewed revision, contract identities, the Phase D/Phase E
  result binding, every committed artifact's path/SHA-256/byte size/origin/role,
  the retained-but-not-committed artifacts with their hashes, and the notes.
- `baseline-build.json` - the source-bound Release build receipt for the
  signed-net revision `f1bdc8fbc949bc3470deaaf8d16d013df7a1c473` (clean
  checkout, frozen baseline contract hash, complete runtime dependency set).
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
  verifier PASS record (133,754 checks, 132,204 authoritative payload-parity
  comparisons, `resultsBoundToPhaseD: true`; byte-reproducible), including the
  required signed `netLots`, the `absoluteNetLots = |netLots|` identity and the
  derived-inventory sign parity.
- `replay-manifest.json` - the authoritative replay package manifest: run
  identity, event/telemetry counts, per-file hashes and the package fingerprint
  `d145a49b548fe9356f1355d33df3329f87ce667cd15b367369219b8f27a9ccb4`.
- `replay-events.jsonl` - the complete authoritative replay event stream
  (1,454 events; SHA-256
  `2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`; unchanged
  because the signed-net addition changes only telemetry serialization).
- `replay-telemetry-sample.jsonl` - a bounded exact-string account-telemetry
  sample with the same 49 rows as the earlier revision (the first 20 rows of
  2019, the first 5 rows of 2020, the single event-snapshot rows of 2021 and
  2026, plus each of the 11 `hard_breakeven_activated` snapshots and the
  snapshot of the immediately following entry event), now carrying the exported
  signed `netLots` alongside `grossLots`/`absoluteNetLots`.
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
by `Test-SingleAnchorCorrectedFullHistory.ps1` as `EXPECTED`; the export-only
signed-net addition was then implemented and the same command was re-executed
at revision `f1bdc8fbc...` (launched 2026-10-03T14:31:24Z, LEAN elapsed 5,201 s,
`EXPECTED`, zero engine errors). Each run's
`storage/single-anchor/results.json` is **byte-identical** to the Phase D
artifact `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`, so
the replay package is derived from the exact finalized Phase D state. The
package was then verified against that binding by the strengthened
`MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1`, whose authoritative
parity comparisons, derivations, ordering checks and mutation behavior are
exercised by `MarketLab\tests\Test-SingleAnchorReplayPackageVerifier.ps1`
(57/57 mutations rejected, 4/4 positive failed-run fixtures verified).

## Review corrections in this revision

- Signed-net export addition (Phase F review decision): the research account now
  exposes `CurrentNetLots` from the same observation that computes the absolute
  value, the recorder writes `netLots` in every event and periodic telemetry
  snapshot, and the verifier requires the field, checks `absoluteNetLots =
  |netLots|` on every row and checks the sign against its derived basket
  inventory. Export-only: no strategy, margin, liquidation, sizing or trade
  behavior changed, `results.json` remains byte-identical to Phase D, and only
  telemetry serialization changed (`events.jsonl` byte-identical).

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
- Sixth review (focused cleanup): the terminal hard-BE violation semantics are enforced
  (the single diagnostic key must be exactly one leg of the final open basket, without a
  normal entry event, bound to that leg's side/lot/fill/time/quote, with no live event after
  it except run-end recaps), the terminal-violation fixture matches the engine's
  throw-before-EntryOpened path, a producer-level C# recorder test covers the same path, the
  NegativeEquity fixture triggers on a genuinely net-flat (zero used margin, undefined level)
  inventory whose second forced close is a MarginLevel close with coherent basket-close
  economics, the terminal diagnostic snapshot is the exact post-fill account state, and the
  base fixture's retained rejection counts and episode outcome are corrected. The suite is 54 mutations with four positive fixtures; the real package, verifier
  record and evidence counters are unchanged.
- Fourth review: Margin Call transitions also require
  `equity = balance + floatingProfit`; Stop Out validation is reason-specific
  (`MarginLevel` vs `NegativeEquity`, mirroring `EvaluateSurvival`); the
  verifier enforces the one-active-basket lifecycle, live/telemetry quote
  monotonicity and range, run-start time, the manifest
  `securityType`/account/margin flags, `delivered` presence and per-file/row
  year identity, `sizingOutcome` by regime, rejection
  `sizingOutcome`/`maximumVolume`, positive-only `eventCounts` keys and the
  bidirectional hard-BE violation mapping. The base fixture is a
  contract-consistent synthetic verifier fixture (producer-contract ledger/parity/
  account identities with quotes constructed for the exercised rules), the suite
  is 54 mutations, and the four positive fixtures include a NegativeEquity Stop
  Out and a terminal hard-BE violation whose faulting leg stays in the open basket
  state without a normal entry event.

The Phase A-D evidence, the frozen contracts and the qualified data identity are
unchanged. The 413,750,130-row historical-data qualification was not rerun, no
parameter was optimized and no hosted CI was dispatched. The full telemetry
shards, engine logs, LEAN result packets, helper console capture and the candle
cache itself remain local run artifacts identified by SHA-256 in `manifest.json`.

The full record is
[../../PHASE_E_REPLAY_EXPORT_RESULT.md](../../PHASE_E_REPLAY_EXPORT_RESULT.md);
the package contract is [../../REPLAY_PACKAGE.md](../../REPLAY_PACKAGE.md).
