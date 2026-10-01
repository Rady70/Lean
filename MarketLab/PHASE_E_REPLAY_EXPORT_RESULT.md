# SingleAnchor Phase E authoritative replay export - result record

Status: **implemented and ready for independent review** - the Phase E
authoritative replay export was implemented in `Rady70/Lean`, produced by one
execution of the frozen corrected-full-history model and qualified by the
repository's corrected-full-history classifier (`EXPECTED`) and the Phase E
package verifier. Phase E is additive: it does not rewrite the Phase D
characterization, the Phase A/B/C records or any frozen value.

```text
Phase E implementation revision:  c29770ef78a9ad85e3061460bde3ff664e764048 (clean at run time)
build receipt:                    MarketLab/output/baseline-build.json (SHA-256 b0ec58516a3ca53442451bb616f5f2814c5319a4c59b268985a3dcf607880fea)
baseline contract:                MarketLab/config/baseline-contract.json (unchanged; SHA-256 0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a)
corrected contract:               MarketLab/config/corrected-full-history-contract.json (unchanged; SHA-256 d97b3c9b375ed2e53a2af784618a90e4db5e5ab9c627ffc9f0638a8c245cd44f)
model revision:                   marketlab-single-anchor-broker-liquidation-v1
Stop Out model:                   BrokerLiquidation
run window:                       2019-01-01 .. 2026-06-30 (the frozen window)
execution:                        2026-10-01T11:59:52Z .. 2026-10-01T13:34:15Z (5,663 s); LEAN exit 0, helper exit 0, engine ERROR:: audit performed with 0 engine errors
classification:                   EXPECTED (invalidCount 0)
Phase D binding:                  the run's storage/single-anchor/results.json is byte-identical to the Phase D artifact (SHA-256 bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad)
package contract:                 marketlab-single-anchor-replay-package-v1
package sha256:                   8f77bdd16dc06593f87af5fe84b761f2f0a9e0ff7b4ee2f33956e6a1837f6a00
events / event snapshots / periodic samples: 1,454 / 1,452 / 98,866
candle cache contract:            marketlab-xauusd-m1-candle-cache-v1
candle cache content_sha256:      ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d
candle cache manifest SHA-256:    265ae887d65ba044e8d5bd9615b303eedd20d0b440342ceb16cbd5322f231b92
```

## 1. Implementation and provenance

The Phase E implementation adds, without changing any strategy or account
semantics:

- `MarketLab/src/SingleAnchor/ReplayPackage.cs` - the package contract,
  metadata records, canonical UTC/decimal formatting and hashing;
- `MarketLab/src/SingleAnchor/ReplayRecorder.cs` - the recorder that observes
  the engine's existing events and the research account's existing observations
  and writes `events.jsonl`, per-year `telemetry-YYYY.jsonl` and
  `manifest.json` under `single-anchor/replay/`;
- the host wiring in `SingleAnchorVNextAlgorithm.cs` (the recorder replaces the
  account as the engine's observer only after the account itself has observed
  the same event; the account remains the engine's risk guard) and four
  read-only accessors on the research account;
- `MarketLab/scripts/Test-SingleAnchorReplayPackage.ps1` - the package verifier;
- `MarketLab/REPLAY_PACKAGE.md` - the package contract.

The package is emitted by the same run that persists the authoritative
`results.json`; it is additive object-store output and does not replace or
modify that result. The recorder is fault-guarded: a recorder defect refuses the
package build instead of aborting the strategy run, so an incomplete package can
never be certified.

## 2. Phase D preservation and binding

Phase D is not rerun as a characterization and not rewritten. The Phase E export
run executes the frozen corrected-full-history command with the Phase E
implementation revision, and its persisted `results.json` is **byte-identical**
to the Phase D artifact:

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
| `entry_executed` | 555 | `legsOpened` |
| `strategy_exit` | 278 | `basketsClosed` (207 Trailing, 71 Escape) |
| `basket_liquidated` | 1 | `basketsLiquidated` (basket #279) |
| `stop_out_triggered` | 5 | `researchMargin.StopOutEpisodes` |
| `forced_liquidation` | 65 | `forcedLiquidations`, each with exact before/after account state |
| `hard_breakeven_activated` | 11 | baskets that activated hard-BE mode |
| `trailing_activated` | 207 | the 207 trailing closes |
| `margin_call_entered` / `margin_call_left` | 23 / 23 | 23 episodes, final state inactive |
| `entry_rejected` | 2 | `distinctRejectedEntries` (both `InsufficientMargin`) |
| `entry_rejection_summary` | 2 | run-end recaps of the 346,942,369 compressed attempts |

Account telemetry (98,866 periodic samples plus 1,452 event snapshots, shards
`telemetry-2019/2020/2021/2026.jsonl`) exposes the exact balance, equity,
floating and realized P/L, used/free margin, margin level, Margin Call state,
open positions, gross lots and absolute net lots at every significant event and
at most every 300 simulated seconds while positions are open. No quote row is
exported.

The verifier returned **PASS** on the exact run - 1,537 checks - with the Phase D
binding enforced (`-ExpectedResultsSha256 bc3958b2...`); its record is
`MarketLab/evidence/20261001-phase-e-replay-export/replay-package-verification.json`
(SHA-256 `2bce758831e4691b23655ac175fd416ae11e7a9c5a231adc04147ef010f9d621`).

## 4. Determinism and local validation

- Bounded determinism: two identical bounded executions of the same frozen
  model over `2019-01-01..2019-01-03` produced byte-identical `results.json`,
  `events.jsonl`, `telemetry-2019.jsonl` and `manifest.json` (package SHA-256
  `2e1865159d7eb0de095c50865c90df5a9eace5b41b555c6b396acde274e24957` for both).
- Focused tests: **310/310** C# tests, including the replay recorder tests
  (event order/coverage, exact snapshots, periodic bound, Margin Call transitions
  incl. the forced-liquidation path, Stop Out/forced/full liquidation with exact
  before/after values, hard-BE activation ordering, failure-quote identity,
  rejection recaps, manifest/decimals, byte determinism and
  recorder-does-not-change-the-engine outcome).
- PowerShell: launch/build guards 40/40, baseline invocation 12/12, failed-data
  classifier 97/97, trading availability 12/12, corrected-full-history
  classifier tests 160/160, production delivery end-to-end 40 checks.
- Python historical data: **274/274** tests, including the candle contract.
- The full export run classified `EXPECTED` (exit 0, `invalidCount` 0) with the
  complete qualified stream and all 407 failed data requests reconciled exactly
  as in Phase D.

## 5. Candle cache (derived visualization data)

`python -m marketlab_historical_data candles` generated the full M1 cache from
the qualified tree into `E:\MarketLab\data\lean\xauusd-m1-candles`:

- 90 monthly CSVs (2019-01 .. 2026-06), 2,332 partitions and 413,750,130 source
  rows read, 2,655,664 candle rows, 172,160,895 bytes;
- `content_sha256`
  `ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d`; the
  cache manifest (SHA-256
  `265ae887d65ba044e8d5bd9615b303eedd20d0b440342ceb16cbd5322f231b92`) carries
  every per-file hash and a committed copy is under
  `MarketLab/evidence/20261001-phase-e-replay-export/candle-cache-manifest.json`;
- derivation: mid-of-best-bid/ask exact decimal, UTC minutes, non-empty minutes
  only, absent minutes never filled; positive uncrossed quotes and a UTC
  `data_time_zone` are preconditions. The cache is derived visualization data,
  never an authority over the native partitions or the authoritative LEAN
  events;
- operational note: because the local Windows command runner terminates a
  single command at about one hour, the full cache was produced in four
  contiguous partition-date ranges (~23 months each) and merged with a
  verification script that copied every monthly CSV byte-for-byte and
  recomputed the generator's own manifest recipe. Monthly output is independent
  of the requested range; the merged files were re-generated for the first
  (`2019-01`, SHA-256 `d0394a2a...`) and last (`2026-06`, SHA-256 `3913d761...`)
  months as single-range runs and are byte-identical. The generator code itself
  is unchanged and its bounded/real and unit qualifications are in
  `tools/historical-data/README.md` section 10.

## 6. Evidence

Committed compact evidence under
`MarketLab/evidence/20261001-phase-e-replay-export/` with a SHA-256 manifest:

- the run's `baseline-build.json`, `corrected-history-preflight.json`,
  `marketlab-run-invocation.json`, `marketlab-run-outcome.json` and
  `corrected-full-history-classification.json` byte-identical copies;
- the package verifier record (`replay-package-verification.json`) and the
  package manifest (`replay-manifest.json`);
- the complete authoritative event stream (`replay-events.jsonl`) and a bounded
  account-telemetry sample (`replay-telemetry-sample.jsonl`);
- the candle cache manifest (`candle-cache-manifest.json`).

The full telemetry shards (45.4 MB), the engine/algorithm logs, the LEAN result
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
- A recorder fault refuses the package build so the evidence gate cannot
  certify an incomplete export; it never aborts the strategy run.
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
