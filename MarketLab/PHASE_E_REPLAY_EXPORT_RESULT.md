# SingleAnchor Phase E authoritative replay export - result record

Status: **implemented, corrected after independent review, and ready for
re-review** - the Phase E authoritative replay export was implemented in
`Rady70/Lean`, corrected for the independent-review findings, produced again by
one execution of the frozen corrected-full-history model, and qualified by the
repository's corrected-full-history classifier (`EXPECTED`) and the strengthened
Phase E package verifier. Phase E is additive: it does not rewrite the Phase D
characterization, the Phase A/B/C records or any frozen value.

```text
Phase E implementation revision:  a2941581c02462a190f4d4289f371aed409cb1e3 (clean at run time)
build receipt:                    MarketLab/output/baseline-build.json (SHA-256 f1344cd814892126b2f661522c2c4a1f7e361e94cd7b5639dc05d202fcb4987d)
baseline contract:                MarketLab/config/baseline-contract.json (unchanged; SHA-256 0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a)
corrected contract:               MarketLab/config/corrected-full-history-contract.json (unchanged; SHA-256 d97b3c9b375ed2e53a2af784618a90e4db5e5ab9c627ffc9f0638a8c245cd44f)
model revision:                   marketlab-single-anchor-broker-liquidation-v1
Stop Out model:                   BrokerLiquidation
run window:                       2019-01-01 .. 2026-06-30 (the frozen window)
execution:                        2026-10-01T22:18:31Z .. 2026-10-02T00:02:39Z (6,248 s); LEAN exit 0, helper exit 0, engine ERROR:: audit performed with 0 engine errors
classification:                   EXPECTED (invalidCount 0)
Phase D binding:                  the run's storage/single-anchor/results.json is byte-identical to the Phase D artifact (SHA-256 bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad)
package contract:                 marketlab-single-anchor-replay-package-v1
package sha256:                   5dcd8bfaffe76c9d2c8eec002073f62fe18b5d0d40b0602dbad0e59f6846097a
events / event snapshots / periodic samples: 1,454 / 1,452 / 98,866
verifier:                         PASS, 22,942 checks (21,406 authoritative payload-parity comparisons), Phase D binding enforced
candle cache contract:            marketlab-xauusd-m1-candle-cache-v1
candle cache content_sha256:      ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d
candle cache verification:        verify-candles PASS (2,332/2,332 partitions), verify-candle-composition PASS (4 parts, 10/10 checks)
```

## 1. Implementation and provenance

The Phase E implementation adds, without changing any strategy or account
semantics:

- `MarketLab/src/SingleAnchor/ReplayPackage.cs` - the package contract,
  metadata records, canonical UTC/decimal formatting and hashing, plus the
  fail-closed publisher (payloads before manifest; a failed payload suppresses
  the manifest);
- `MarketLab/src/SingleAnchor/ReplayRecorder.cs` - the recorder that observes
  the engine's existing events and the research account's existing observations
  and writes `events.jsonl`, per-year `telemetry-YYYY.jsonl` and
  `manifest.json` under `single-anchor/replay/`;
- the host wiring in `SingleAnchorVNextAlgorithm.cs` (the recorder replaces the
  account as the engine's observer only after the account itself has observed
  the same event; the account remains the engine's risk guard; the package is
  attempted only after `results.json` persisted) and four read-only accessors
  on the research account;
- an observational `HardBreakevenActivated` engine event raised at the existing
  hard-BE mode transition, before the first tail attempt is sized or placed, so
  the activation telemetry snapshot is the exact pre-attempt state;
- `MarketLab/scripts/Test-SingleAnchorReplayPackage.ps1` - the strengthened
  package verifier (authoritative parity, periodic rule, Phase D binding) and
  `MarketLab/tests/Test-SingleAnchorReplayPackageVerifier.ps1` - the verifier
  mutation tests;
- `MarketLab/REPLAY_PACKAGE.md` - the package contract.

The package is emitted by the same run that persists the authoritative
`results.json`; it is additive object-store output and does not replace or
modify that result. The recorder is fault-guarded: a recorder defect refuses the
package build instead of aborting the strategy run.

### 1.1 Independent-review corrections (this revision)

- **Hard-BE activation snapshot.** Previously the recorder reconstructed the
  activation inside the entry event, so the activation snapshot already
  contained the post-fill leg. The engine now publishes
  `HardBreakevenActivated` at the real transition (before sizing/placement) and
  the recorder snapshots it there. All **11/11** activation snapshots in this
  package are pre-attempt (the following entry adds exactly one position), with
  focused C# tests for the filled and rejected tail paths.
- **Authoritative event parity in the verifier.** The verifier now compares the
  replay stream against the authoritative `results.json` structures: every
  anchor (`AnchorEvent`), surviving entry (`LegTrace`), forced liquidation
  (`StopOutEpisodes[].Liquidations`, including before/after account state and
  same-quote ordering), Stop Out episode, rejection/summary
  (`RejectionTrace`), hard-BE activation (first tail leg/attempt) and the
  run-end provenance/counters/account/margin state. It also enforces the real
  `telemetryIntervalSeconds` periodic rule. The new mutation test proves 11/11
  deliberate corruptions (changed trade number, fill price, forced-liquidation
  ordinal/price, Stop Out time, same-quote reorder, manifest identity, file
  hash, deleted event, deleted snapshot, over-frequent periodic sample) are
  rejected.
- **Fail-closed package persistence.** The package is only attempted after
  `results.json` persisted; all payloads are saved before the manifest; a failed
  payload suppresses the manifest, so an incomplete package cannot be
  advertised.
- **Fail-closed candle provenance.** Candle generation now requires the
  qualified composition and a PASS qualification record bound to the actual
  composition hash, exact partition-set equality, per-partition `zip_sha256`
  and streaming member name/size/row-count/member-SHA verification. The derived
  cache is certified by `verify-candles` and `verify-candle-composition`.

## 2. Phase D preservation and binding

Phase D is not rerun as a characterization and not rewritten. The corrected
Phase E export run executes the frozen corrected-full-history command with the
Phase E implementation revision, and its persisted `results.json` is
**byte-identical** to the Phase D artifact:

- Phase D artifact SHA-256: `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`;
- Phase E run artifact SHA-256: `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`;
- byte comparison: **identical**.

The package manifest's delivered-stream identity reproduces the Phase D values
exactly (`413,750,130` quotes, semantic digest
`sha256:231cf63850cd033ea8167ab7d0017bdfbd7744f40412c1a899c2b9d98942886a`,
first `2019-01-01T23:00:07.151Z`, last `2026-06-30T23:59:59.678Z`). The Phase A
evidence, Phase B implementation record, Phase C bounded qualification and
Phase D result/evidence are unchanged; `config/baseline-contract.json` and
`config/corrected-full-history-contract.json` are unchanged.

## 3. Package contents and completeness

Authoritative event stream (1,454 events, `events.jsonl` SHA-256
`2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`):

| Event | Count | Cross-check |
|---|---|---|
| `run_started` / `run_ended` | 1 / 1 | run identity and final counters |
| `basket_anchored` | 280 | 278 closed + 1 liquidated + 1 open (`openBasket`) |
| `entry_executed` | 555 | 490 surviving `LegTrace` + 65 `LiquidationTrace` identities |
| `strategy_exit` | 278 | `basketsClosed` (207 Trailing, 71 Escape) |
| `basket_liquidated` | 1 | `basketsLiquidated` (basket #279) |
| `stop_out_triggered` | 5 | `researchMargin.StopOutEpisodes` |
| `forced_liquidation` | 65 | `forcedLiquidations`, each with exact before/after account state |
| `hard_breakeven_activated` | 11 | baskets with hard-BE mode active; all pre-attempt snapshots |
| `trailing_activated` | 207 | the 207 trailing closes |
| `margin_call_entered` / `margin_call_left` | 23 / 23 | 23 episodes, final state inactive |
| `entry_rejected` | 2 | `distinctRejectedEntries` (all `InsufficientMargin`) |
| `entry_rejection_summary` | 2 | run-end recaps of the 346,942,369 compressed attempts |

Account telemetry (98,866 periodic samples plus 1,452 event snapshots, shards
`telemetry-2019/2020/2021/2026.jsonl`) exposes the exact balance, equity,
floating and realized P/L, used/free margin, margin level, Margin Call state,
open positions, gross lots and absolute net lots at every significant event and
at most every 300 simulated seconds while positions are open. No quote row is
exported.

The verifier returned **PASS** on the exact run - 22,942 checks including 21,406
authoritative parity comparisons - with the Phase D binding enforced
(`-ExpectedResultsSha256 bc3958b2...`); its record is
`MarketLab/evidence/20261002-phase-e-replay-export/replay-package-verification.json`
(SHA-256 `7bf06a12c532229ff9f05a2aaeb351c7560900b01b10a8011a403652a52e43a2`).

## 4. Determinism and local validation

- Bounded determinism: two identical bounded executions of the corrected model
  over `2019-01-01..2019-02-15` (including hard-BE activations) produced
  byte-identical `results.json` (`07ab303d...`), `events.jsonl`,
  telemetry and manifest (package
  `344db104429c648645282a719d23f765328dfc41b18e1173ad2eb11300e9326d`);
  both runs passed the strengthened verifier (523 checks).
- Behavior invariance of the corrections: the bounded March 2020 window
  (`results 81ba0304...`, 6,124 verifier checks) and the low-cash rejection
  window (`results 697bd85e...`, 206 checks) are byte-identical to the results
  produced before the corrections, and the full corrected run reproduced the
  Phase D result exactly.
- Focused tests: **314/314** C# tests (17 new Phase E tests including the
  pre-attempt hard-BE activation snapshots on the filled and rejected paths and
  the fail-closed publisher).
- PowerShell: launch/build guards 40/40, baseline invocation 12/12,
  failed-data classifier 97/97, trading availability 12/12, corrected-full-
  history classifier tests 160/160, production delivery end-to-end 40 checks,
  and the package-verifier mutation test **11/11**.
- Python historical data: **299/299** tests, including the fail-closed candle
  preflight, `verify-candles` and `verify-candle-composition`.
- The corrected export run classified `EXPECTED` (exit 0, `invalidCount` 0)
  with the complete qualified stream and all 407 failed data requests
  reconciled exactly as in Phase D.

## 5. Candle cache (derived visualization data)

`python -m marketlab_historical_data candles` generated the full M1 cache from
the qualified tree into `E:\MarketLab\data\lean\xauusd-m1-candles`:

- 90 monthly CSVs (2019-01 .. 2026-06), 2,332 partitions and 413,750,130 source
  rows read, 2,655,664 candle rows, 172,160,895 bytes;
- `content_sha256`
  `ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d`; the
  cache manifest (SHA-256 `265ae887d65ba044e8d5bd9615b303eedd20d0b440342ceb16cbd5322f231b92`)
  and every per-file hash are committed;
- derivation: mid-of-best-bid/ask in exact decimal, UTC minutes, non-empty
  minutes only, absent minutes never filled; positive uncrossed quotes, the
  qualified composition, a PASS qualification record bound to the composition
  hash and a UTC `data_time_zone` are preconditions, and every selected
  partition's zip and member hashes/row count are verified while reading;
- because the local command runner terminates a single command at about one
  hour, the cache was produced in four contiguous **month-aligned** ranges and
  merged byte-for-byte with the documented recipe; month independence holds
  only for month-aligned bounds (a mid-month bound is a partial-month file).
  The four part manifests are committed under
  `MarketLab/evidence/20261002-phase-e-replay-export/candle-parts/`, and
  `verify-candle-composition` proves the final cache is their exact contiguous
  union (10/10 checks);
- `verify-candles` certifies the source identity and the cache:
  2,332/2,332 partition zip hashes verified, 9/9 checks. The records are
  `candle-cache-verification.json` and `candle-composition-verification.json`.

## 6. Evidence

Committed compact evidence under
`MarketLab/evidence/20261002-phase-e-replay-export/` (manifest SHA-256
`a8e800c789674a3e19fc9cec49c0e3b254dabd3819bda0ff45684f577ac57ce9`) with a
SHA-256 manifest:

- the run's `baseline-build.json`, `corrected-history-preflight.json`,
  `marketlab-run-invocation.json`, `marketlab-run-outcome.json` and
  `corrected-full-history-classification.json` byte-identical copies;
- the package verifier record (`replay-package-verification.json`) and the
  package manifest (`replay-manifest.json`);
- the complete authoritative event stream (`replay-events.jsonl`) and a bounded
  account-telemetry sample (`replay-telemetry-sample.jsonl`);
- the candle cache manifest, `candle-cache-verification.json`,
  `candle-composition-verification.json` and the four part manifests.

The full telemetry shards (45.2 MB), the engine/algorithm logs, the LEAN result
packets, the run console capture and the candle cache itself remain local run
artifacts identified by SHA-256 in the evidence manifest; the run's
`results.json` is not duplicated because it is byte-identical to the Phase D
artifact committed in the Phase D evidence directory.

## 7. Limitations

- The package requires the research account (`single-anchor-research-account`,
  default true); the frozen Phase E command has it enabled.
- Periodic account telemetry is sampled at most every 300 simulated seconds;
  every significant event has its exact snapshot.
- Individual rejected-entry attempts are not exported (one live event per
  distinct episode plus a run-end recap).
- A recorder fault refuses the package build, and a failed payload suppresses
  the manifest, so the evidence gate cannot certify an incomplete export; the
  strategy run itself is never aborted by the recorder.
- The merge of the four candle parts was performed by the documented recipe and
  is verified by `verify-candle-composition`; the merge itself is not a shipped
  command.
- The long run used a temporary AC power-plan change (standby and display
  disabled). Both original values were captured and restored exactly
  (`STANDBYIDLE` `0x00001c20`, `VIDEOIDLE` `0x00000258`).

## 8. What did not change / not started

- No strategy parameter, account/margin value, execution economic, liquidation
  rule, trade-numbering semantic or data identity changed.
- The 413,750,130-row historical-data qualification was not rerun; no parameter
  optimization or sensitivity sweep occurred; no hosted CI was dispatched.
- The LuxAlgo adaptation (Phases F-H) and the Fincept integration (Phase I)
  have not started.
