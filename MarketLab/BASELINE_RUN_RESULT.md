# SingleAnchor first untouched full-history baseline - qualified result

Status: **complete** - one authoritative run of the frozen baseline contract,
executed 2026-09-28 and qualified by the repository's mandatory post-run
classification. The run ended in the approved PR #3 modeled terminal path
(`AccountStopOut`, reason `MarginLevel`) on 2020-03-23 during the COVID gold
crash. This document records the run, its evidence chain and its results. It is
a configuration characterization, not a performance or profitability claim, and
it authorizes nothing.

```text
reviewed revision:            5c1649d741ba2ec0a113c2c47255dbac637b5465
baseline contract:            config/baseline-contract.json
contract SHA-256:             0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a
run window:                   2019-01-01 00:00 UTC .. 2026-06-30 23:59:59 UTC
processed history:            2019-01-01T23:00:07.151Z .. 2020-03-23T12:06:26.292Z
termination:                  AccountStopOut (MarginLevel) - approved PR #3 terminal path
failed-data classification:   EXPECTED (PASS)
parameter optimization:       NOT STARTED
```

## 1. Run identity and evidence chain

The run is one local backtest under the frozen contract, launched exactly once
with the rendered invocation of
[`config/baseline-contract.json`](config/baseline-contract.json) (see
[BASELINE_CONTRACT.md](BASELINE_CONTRACT.md) section 4). The reviewed revision
is the finalized remote `master` recorded through PR #16. All artifacts below
are retained locally in the run directory; the SHA-256 values identify them.

| Artifact | Value |
|---|---|
| run directory | `MarketLab\output\20260928-135348-SingleAnchorVNextAlgorithm` |
| reviewed commit | `5c1649d741ba2ec0a113c2c47255dbac637b5465`, clean checkout (`repositoryDirty: false`) |
| build configuration | `Release`; .NET SDK 10.0.401; runtime `Microsoft.NETCore.App 10.0.12`, `--roll-forward Disable` |
| build receipt `baseline-build.json` | generated `2026-09-28T13:52:02Z`, SHA-256 `241b644cd9100b97980fb8d85b215dcbf57728acb6db55dd0648e4933c09cdfa` |
| preflight `baseline-preflight.json` | `PREFLIGHT-PASS`, 2,332/2,332 partitions hash-verified, manifest `a147f20a5b59bfc6cdb0c3cd785e84636bf40665c8203c119a18da6774ab8757`, SHA-256 `1832112b181d713c751e13022644f36b43b16ce369a6bd86afbbaacd380fe5a4` |
| invocation `marketlab-run-invocation.json` | generated `2026-09-28T13:53:48Z`, contract and register pin verified before launch, SHA-256 `36609b1e453e0e5a3520b5dda5202e71806439bcf796a6d2ccaf0ce9f6cde1ad` |
| outcome `marketlab-run-outcome.json` | generated `2026-09-28T14:00:58Z`, LEAN exit 1, helper exit 1, engine-error audit performed, SHA-256 `521c103811d72e8b8a8a426162e90b8e7f372fda815e54bd6d7350acc22947d7` |
| classification `baseline-failed-data-classification.json` | generated `2026-09-28T14:05:41Z`, qualification `EXPECTED`, invalidCount 0, SHA-256 `e08ee2ec41fe075f44894f4c65508611d46366ed30a25529890985255d660e5c` |
| strategy results `storage/single-anchor/results.json` | SHA-256 `8962043b29084ef4405de1c1df7a19fb669d0ec84e6c3b8ddcb76a159df1ef0b` |
| console capture (auxiliary) | `baseline-run-console-20260928-135339.stdout.log` SHA-256 `0fe447c1b4feda3c71a3a4cb934b04c54296c3538d4353f9d3afe7bc1b38d319`; `.stderr.log` SHA-256 `36a20c1e01628139f542fb8818e016d9a15c006fc784deb34c4c0cda1e7b6d4a` |

Data provenance: continuous tree `E:\MarketLab\data\lean\xauusd-dukascopy`,
composition manifest SHA-256
`a147f20a5b59bfc6cdb0c3cd785e84636bf40665c8203c119a18da6774ab8757`, replay
qualification record SHA-256
`e9c72d1abf15b1cc6ae9c2d2ff793c49091a26b2439258341c2d32a793632c8d` (equal to
the tracked `replay.record_sha256`), session-map SHA-256
`33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949`,
market-hours SHA-256
`325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e`,
symbol-properties SHA-256
`7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed`. The
413,750,130-row qualification was not replayed; the tree was verified by
hashing all 2,332 native partitions against the composition manifest.

Frozen parameters: all 30 `single-anchor-*` values were passed explicitly and
the helper matched them against the contract before launch; the persisted
`results.json` parameter block records the resolved values (`StepPercent 0.25`,
`BaseLot 0.10`, `NormalTradeCount 4`, `HardBreakevenCeilingPercent 4.478`,
`ProjectedSpread 0.50`, `InitialBalance 20,000 USD`, margin enabled, and so on).
No LEAN order was placed; the LEAN portfolio statistics are empty by design.

## 2. Pre-run gates

| Gate | Result |
|---|---|
| authoritative build (`Build-SingleAnchorBaseline.ps1`) | PASS; receipt binds the clean reviewed tree `cf1f4d8a1db496648d09898c43d54e3d61ba33bf` and the contract |
| contract/register verification (`Get-SingleAnchorBaselineInvocation.ps1`) | PASS; computed contract SHA-256 equals the register pin |
| qualified continuous-tree preflight (`Test-SingleAnchorBaselineFailedData.ps1 -Preflight`) | PASS; 2,332/2,332 partitions, auxiliary databases and session map hash-verified |
| `-DryRun` (same checks, LEAN not launched, no run directory) | PASS |
| authoritative launch | once, from the clean reviewed commit, with the rendered contract invocation |

## 3. Execution and progress

The helper wrote `marketlab-run-invocation.json` at `13:53:48Z` and the engine
launched immediately after. LEAN exited at `14:00:57Z`; the run took 429.2 s
(about 7.2 minutes). Progress was observed from the engine's `log.txt` by
following the latest simulated event timestamp; quote-level progress is not
exposed live by the engine.

| Wall-clock observation | Last simulated time reached | Approximate period progress |
|---|---|---|
| 13:55:47Z | 2019-07-02 | ~6.7% of 2019-01-01..2026-06-30 |
| 14:00:26Z | 2020-03-06 | 15.74% |
| 14:00:57Z (termination) | 2020-03-23 12:06:26.292 | 16.33% |

No margin-call entry block, insufficient-margin rejection, session-map or
data-quality stop, or runtime error occurred before the terminal stop-out.

## 4. Processed history

| Metric | Value |
|---|---|
| delivered/processed quotes | 51,304,749 |
| strategy-eligible quotes | 51,153,339 |
| quote-only session-buffer quotes | 151,410 |
| non-quote ticks unused | 0 |
| processed day partitions | 383 |
| first delivered quote | `2019-01-01T23:00:07.151Z` |
| last processed quote | `2020-03-23T12:06:26.292Z` (bid 1505.618 / ask 1506.182) |
| delivered-prefix semantic digest | `sha256:3d8e029ee67cf9257804f71c648172ee5ea291407dcf7cf334963558803c52ce` |

The classifier verified the complete preceding-partition digests and the exact
delivered prefix of the terminal day (`deliveryVerification.mode:
qualified-prefix`, `terminalDayPrefixRead: true`); 383 partitions and the
51,304,749-quote count reconcile exactly with the per-partition records.

## 5. Results

### 5.1 Baskets

- Total baskets anchored: **276** (275 closed, 1 open at termination).
- Close reasons of the 275 closed baskets: Trailing 205, Escape 70.
- Depth histogram (deepest placed trade of every basket; the open basket ends
  at depth 36):

| Depth | 1 | 2 | 3 | 4 | 5 | 8 | 10 | 14 | 15 | 17 | 24 | 25 | 36 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Baskets | 205 | 37 | 21 | 3 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 | 1 |

- Closed baskets (275) closing after N trades: 1 trade 205 (74.55%), 2 trades
  37 (13.45%), 3 trades 21 (7.64%), 4 trades 3 (1.09%); 5+ trades 9 (3.27%),
  of which 10+ trades 7 (2.55%). Including the still-open basket: 5+ 10/276
  (3.62%), 10+ 8/276 (2.90%).
- Maximum depth: **36** (the open basket; also the deepest closed basket is 25).
- Longest closed basket duration from first entry: 8,441,437.342 s (97.70
  days), basket #17 anchored `2019-03-08T13:30:35.289Z`. The open basket #276
  had been running 591,452.926 s (6.84 days) since its first entry.
- Close counts by depth are from `researchBaskets`; every basket carries its
  full leg, rejection and skipped-entry traces in `results.json`.

### 5.2 Floating P/L, lots and hard-BE

| Metric | Value |
|---|---|
| worst executable floating loss (account) | -25,320.42700 USD |
| best executable floating profit (account) | +327.00000 USD |
| maximum gross lots | 62.76 |
| maximum absolute net lots | 3.84 |
| maximum individual placed lot | 7.24 (open basket, trade 36) |
| hard-BE activation | 10 baskets (10/276 = 3.6232%; first hard-BE trade was trade 5 in all 10) |
| largest exact required tail lot (Q_BE) | 7.238649314248985 |
| largest normalized required tail lot | 7.24 |
| largest placed tail lot | 7.24 |
| hard-BE infeasible attempts / episodes | 0 / 0 |
| hard-BE rejection reasons/outcomes | none recorded |
| distinct rejected entries / attempts | 0 / 0 |

Skipped executable marks: 0, so the floating extrema are complete. The
hard-BE verification record confirms the sizer was verified under the
configured execution model (`StrategyDefinitionResolved: true`,
`HardBEVerifiedUnderConfiguredExecutionModel: true` with the configured
target-spread assumption `0.50` and zero slippage/commission).

### 5.3 Margin, drawdown and account state

| Metric | Value |
|---|---|
| Margin Call observations | 35 |
| Margin Call episodes | 19 |
| Margin Call blocked attempts / episodes | 0 / 0 |
| InsufficientMargin attempts / episodes | 0 / 0 |
| minimum margin level reached | 17.229779578062128554190460520% (at the stop-out quote) |
| maximum used margin | 1,157.8848069189189189189189189 USD |
| minimum free margin | -958.3838069189189189189189189 USD |
| maximum equity drawdown | 25,336.98700 USD (peak equity 25,536.48800, trough 199.50100) |
| maximum balance drawdown | 0.00000 USD (every closed basket realized a profit) |
| starting balance | 20,000.00000 USD |
| ending balance | 25,519.92800 USD |
| realized P/L | +5,519.92800 USD |
| end-of-run executable floating P/L | -25,320.42700 USD |
| end-of-run mark-to-market equity | 199.50100 USD |

The account entered Margin Call (margin level at or below 50%) in 19 distinct
episodes (35 observation quotes) while the March 2020 basket was open. No new
entry was attempted while the call was active, so no entry was blocked; the
engine counted zero `MarginCallBlockedAttempts`, consistent with the open
basket already having reached trade 36 and its next entry (trade 37) not
having triggered before the stop-out.

### 5.4 Terminal outcome

- **AccountStopOut**, condition **MarginLevel**, at simulated
  `2020-03-23T12:06:26.292Z` (bid 1505.618 / ask 1506.182).
- Reason: margin level fell to 17.229779578062128554190460520%, below the 20%
  Stop Out threshold; no broker liquidation sequence is simulated, the run
  stops with the account state recorded on the tripping quote.
- Account state at stop-out: equity 199.50100 USD, balance 25,519.92800 USD,
  floating -25,320.42700 USD, used margin 1,157.8848069189189189189189189 USD,
  free margin -958.3838069189189189189189189 USD, 36 open positions.
- The engine logged exactly one expected terminal-exception line and zero
  unrelated engine `ERROR::` lines (LEAN exit 1, helper exit 1).

### 5.5 Final unresolved basket

Basket #276 was still open at the stop-out; nothing about it is fabricated.

| Field | Value |
|---|---|
| anchor | 1503.75 at `2020-03-16T15:47:17.769Z` (upper 1507.509375, lower 1499.990625; hard-BE boundaries 1436.412075 / 1571.087925) |
| first entry | Sell 0.10 at `2020-03-16T15:48:53.366Z` |
| entries / deepest placed / deepest attempted trade | 36 / 36 / 36 |
| open positions at termination | 36 |
| buy / sell / gross / net lots | 33.30 / 29.46 / 62.76 / +3.84 |
| hard-BE mode | active since trade 5; trailing never activated; peak profit 0.00000 |
| raw / exit / executable profit | -25,320.42700 / -25,320.42700 / -25,320.42700 USD |
| step money | 1,443.60000 USD |
| next trade number | 37 |
| full state | all 36 leg traces, the empty rejection trace and the research snapshot are persisted in `results.json` (`openBasket`, `researchOpenBasket`) |

The basket is a normal first four arithmetic trades (0.10/0.20/0.30/0.40 lots)
followed by 32 hard-BE tail entries. Each hard-BE tail entry is sized so the
basket reaches approximately zero P/L if price travels to the hard-BE
boundary; until that boundary is reached the growing inventory floats a loss,
and the account must finance it. During the March 2020 crash the required
tail inventory grew to 7.24 lots on one entry and 62.76 gross lots in total,
and the floating loss exceeded the account's surviving equity before the
boundary was reached.

## 6. Post-run qualification

`Test-SingleAnchorBaselineFailedData.ps1 -RunDirectory <run> -ReviewedCommit
5c1649d7...` returned **EXPECTED** (exit 0):

- contract/register pin verified; invocation evidence verified (contract hash,
  resolved inputs, parameters, allow flags, clean reviewed commit);
- all 2,332 qualified partitions hash-verified against the composition
  manifest; manifest anchored to the tracked replay record;
- 66 failed data requests, 66 lines, data-monitor count 66 (accounting
  matches): 65 expected source-absent calendar days inside the processed
  horizon and the 1 enumerated auxiliary benchmark-hour request; 341
  source-absent days after the terminated horizon recorded as never requested
  because the run ended; 0 unexpected missing qualified partitions, 0
  out-of-window requests, 0 unknown requests, 0 unrequested absences within
  the horizon, 0 accounting mismatches, 0 contract/evidence mismatches;
- engine-error audit performed with 0 engine `ERROR::` lines and exactly 1
  expected `AccountStopOutException` line; runtime binaries unchanged during
  the run;
- delivered-stream evidence verified as the exact qualified prefix
  (51,304,749 quotes, 383 partitions, terminal day prefix read).

The classification record is the authoritative PASS of the run
(`qualification: EXPECTED`, `invalidCount: 0`). Re-auditing this run later
means checking out the reviewed commit `5c1649d7...` with a clean tree and
re-running the classifier against the run directory: the classifier compares
the build receipt with the checkout at that exact commit, so documentation
commits after the run do not invalidate the evidence but do require that
checkout for a fresh audit.

## 7. Interpretation and limitations

- The frozen baseline is characterized as a **survival failure under margin at
  the frozen configuration**: the intact strategy did not survive the March
  2020 gold dislocation, ending through the intended modeled `AccountStopOut`.
  This is a legitimate baseline finding produced by the frozen contract, not
  an implementation failure.
- Realized trading was profitable over the processed window (+5,519.93 USD)
  with zero balance drawdown; the account failed because the open hard-BE
  recovery basket required more equity than the account had while price moved
  against it toward the hard-BE boundary. The hard-BE construction guarantees
  P/L only at the boundary, not the financing capacity to reach it.
- Historical coverage processed is 2019-01-01 through 2020-03-23 only (16.3%
  of the frozen window, 12.40% of the qualified quote population). The
  remainder of the history was never processed because the run terminated.
  This is expected for an `AccountStopOut` run and is recorded, not treated as
  missing data.
- Margin-call mechanics (entry blocking) were never exercised by a blocked
  attempt in this run; the terminal path was the margin-level stop-out.
- This run says nothing about the strategy on the unprocessed history, about
  any other parameter configuration, or about profitability. No parameter
  value was changed, selected or optimized.
- The USD research account is a modeling simplification of the EUR live
  account; no EUR conversion exists and none should be inferred.

## 8. What did not change

- No source code, strategy behaviour, contract, algorithm, margin model,
  research account or execution model was modified for or by this run.
- No historical data was modified; the 413,750,130-row qualification was not
  replayed. The run read the already-qualified continuous tree.
- No parameter optimization, sweep, walk-forward, holdout selection or
  sensitivity analysis was performed.

## 9. Next step

This result requires independent review of this record and its evidence chain
before any further roadmap work. After that review, the approved plan's next
phase is **parameter research only after the baseline audit**
([SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md](SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md)
section 8): define development/validation/untouched-holdout periods or an
approved equivalent and freeze selection criteria before any sweep, with the
survival/feasibility hierarchy (no stop-out, feasible tail behaviour,
acceptable drawdown/exposure, basket-resolution characteristics, profit).
Initial geometry research may study `StepPercent` and
`HardBreakevenCeilingPercent`; `BaseLot` stays frozen by risk policy or is a
separately identified position-scale dimension. None of this has been
started.
