# Phase D corrected full-history evidence (2026-09-30)

This directory preserves the source-bound evidence of the corrected untouched
full-history SingleAnchor characterization (Phase D) under the finalized Phase B
broker-forced-liquidation model.

- `manifest.json` - reviewed revision, contract identities, every committed
  artifact's path/SHA-256/byte size/origin/role, the retained-but-not-committed
  artifacts with their hashes, and the notes.
- `baseline-build.json` - the source-bound Release build receipt for the
  reviewed commit `23110c08b03cb9decc9ab48626eda17158063339` (clean checkout,
  frozen baseline contract hash, complete runtime dependency set).
- `corrected-history-preflight.json` - the mandatory corrected preflight
  receipt copied into the run: descriptor and frozen pins, 2,332/2,332
  qualified partitions hash-verified, source-bound build.
- `marketlab-run-invocation.json` - the helper's pre-run evidence: resolved
  inputs, the 30 effective `single-anchor-*` values, exact launcher argv,
  contract/preflight/build hashes, clean repository HEAD and the qualified
  runtime binary hashes.
- `marketlab-run-outcome.json` - the post-run outcome: LEAN exit 0, helper
  exit 0, engine-error audit performed with zero engine `ERROR::` lines,
  407 failed data requests, unchanged runtime artifacts and the results
  SHA-256.
- `corrected-full-history-classification.json` - the authoritative
  classification (`EXPECTED`, `invalidCount` 0): current-model full-stream
  delivery (2,332 partitions, 413,750,130 quotes, global semantic digest) and
  the 407/407 failed-request reconciliation (406 expected source-absent
  calendar days + 1 enumerated auxiliary request; zero unexpected).
- `strategy-results.json` - the complete persisted strategy result
  (SHA-256 `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`,
  1,602,034 bytes): delivery evidence, every closed basket with its
  `LegTrace`/`LiquidationTrace`, all five Stop Out episodes and 65 forced
  liquidations, the rejection traces, the research account and the final
  open-basket state.
- `data-monitor-report-20260930233218632.json`, `failed-data-requests-20260930214213300.txt`,
  `succeeded-data-requests-20260930214213300.txt` - the engine's request
  accounting (2,741 total: 2,334 succeeded, 407 failed).
- `run-parameters.txt` - the exact 30-value parameter string passed to the run.

## Method and source binding

One authorized execution of the real LEAN Release host on the qualified
Dukascopy XAUUSD data folder over the full frozen `2019-01-01 .. 2026-06-30`
window with the frozen strategy/account/margin values and the frozen session
map, launched with the corrected-full-history contract's exact command
(`run-backtest.ps1 -RunEvidence -CorrectedHistoryContract ...`) and classified
by `Test-SingleAnchorCorrectedFullHistory.ps1`. The run processed the complete
qualified stream; LEAN exited 0 with the engine-error audit performed and zero
engine `ERROR::` lines. The reviewed source revision, the build receipt, the
runtime pin, the data identity and the session-map identity are bound
throughout the evidence chain.

## Behavior-invariance evidence

The reviewed Phase C bounded qualification (`evidence/20260928-phase-b-march-2020/`,
source revision `d92580d74feafe7d42da0307fa979f493e1d085d`) covers the common
window. In this full run:

- every closed basket in the common window (Sequences 1..278) is **identical
  in a deep JSON comparison** to its Phase C record (278/278 compared, zero
  mismatches);
- all four common Stop Out episodes are **identical in the same deep JSON
  comparison** to the Phase C episodes;
- basket #276 reproduces the reviewed trigger state, the 30 forced closes over
  four episodes (-25,051.42100 realized) and the Escape close at
  `2020-04-13T18:24:10.475` with lifetime +30.65700.

The full run then continues with a fifth episode: basket #279 is fully
liquidated at `2020-06-17T09:32:50.569` (35 forced closes, -25,662.42300), the
final balance becomes -90.41800, and basket #280 stays anchored-but-unfunded to
the end of the qualified data (346,942,369 `InsufficientMargin` first-entry
attempts in two episodes). The complete interpretation is in
[../../CORRECTED_FULL_HISTORY_RESULT.md](../../CORRECTED_FULL_HISTORY_RESULT.md).
