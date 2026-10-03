# Signed-net Phase E replay-export evidence (2026-10-03)

This directory preserves the compact, source-bound evidence of the export-only
signed-net addition to the Phase E authoritative replay export. It is a **new**
evidence directory: the finalized
[`20261002-phase-e-replay-export`](../20261002-phase-e-replay-export/) record is
unchanged, and the derived M1 candle cache was not touched (its evidence copies
here are byte-identical).

- `manifest.json` - reviewed revision, contract identities, the Phase D/Phase E
  result binding, the signed-net telemetry extension decision, every committed
  artifact's path/SHA-256/byte size/origin/role, the retained-but-not-committed
  artifacts with their hashes, and the notes.
- `baseline-build.json` - the source-bound Release build receipt for the
  signed-net revision `f1bdc8fbc949bc3470deaaf8d16d013df7a1c473`.
- `corrected-history-preflight.json` - the mandatory corrected-full-history
  preflight receipt copied into the run (2,332/2,332 partitions hash-verified).
- `marketlab-run-invocation.json` / `marketlab-run-outcome.json` - the helper's
  pre-run and post-run evidence: exact launcher argv, contract/preflight/build
  hashes, clean repository head, exit codes, engine-error audit, data-monitor
  result, unchanged runtime artifacts and the results SHA-256.
- `corrected-full-history-classification.json` - the authoritative
  classification (`EXPECTED`, `invalidCount` 0) for the re-run.
- `replay-package-verification.json` - the strengthened package verifier PASS
  record (232,620 checks, 231,070 authoritative payload-parity comparisons,
  `resultsBoundToPhaseD: true`, `telemetrySignedNet: true`).
- `replay-manifest.json` - the authoritative replay package manifest (package
  fingerprint `d145a49b548fe9356f1355d33df3329f87ce667cd15b367369219b8f27a9ccb4`).
- `replay-events.jsonl` - the complete authoritative replay event stream
  (1,454 events; SHA-256
  `2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`;
  byte-identical to the original export).
- `replay-telemetry-sample.jsonl` - the same 49 exact-string rows as the
  original sample, now carrying the exported signed `netLots`.
- `candle-cache-manifest.json`, `candle-cache-verification.json`,
  `candle-composition-verification.json` and `candle-parts/part?-manifest.json` -
  byte-identical copies of the unchanged candle evidence from the finalized
  20261002 directory.

## Method and binding

One execution of the frozen corrected-full-history command (the Phase D
contract unchanged) with the export-only signed-net implementation revision
`f1bdc8fbc949bc3470deaaf8d16d013df7a1c473` (launched 2026-10-03T14:31:24Z, LEAN elapsed 5,201 s, LEAN exit
0, helper exit 0, zero engine `ERROR::` lines, classification `EXPECTED`,
407/407 failed data requests reconciled) through
`MarketLab\scripts\run-backtest.ps1 -RunEvidence`. The run's
`storage/single-anchor/results.json` is **byte-identical** to the Phase D
artifact `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`,
and `events.jsonl` is byte-identical to the previous export because only
telemetry serialization changed.

## Replay contract decision

`netLots` is an **additive signed-net telemetry extension** of the
`marketlab-single-anchor-replay-package-v1` contract, not a silent
redefinition. The original finalized v1 package (without `netLots`) remains
valid and passes the extension-aware verifier (131,671 checks, 130,121
payload-parity comparisons). A package that carries the extension must carry it
on every event and periodic row; the verifier then requires the field, checks
`absoluteNetLots = |netLots|` on every row, and checks the sign against its
independently derived basket inventory for event and periodic snapshots alike
(the periodic derivation accepts the state before or after same-quote events,
because a periodic sample may be written on either side of a same-quote event
snapshot).

## Local validation

- Verifier fixture suite (updated): **58/58** mutation cases rejected with
  **4/4** positive failed-run fixtures verified; the added periodic sign-flip
  mutation is rejected through the derived periodic direction parity.
- C# tests: **315/315** (the signed value and its absolute complement are
  asserted by the recorder and account tests).
- The full record is
  [../../PHASE_E_REPLAY_EXPORT_RESULT.md](../../PHASE_E_REPLAY_EXPORT_RESULT.md)
  (section 1.7); the package contract and the extension decision are in
  [../../REPLAY_PACKAGE.md](../../REPLAY_PACKAGE.md).
