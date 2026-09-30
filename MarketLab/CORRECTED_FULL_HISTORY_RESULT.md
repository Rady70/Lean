# SingleAnchor corrected full-history characterization - Phase D result record

Status: **executed and classified EXPECTED** - the corrected untouched
full-history run of the frozen baseline values under the finalized Phase B
broker-forced-liquidation model, executed 2026-09-30 from the clean reviewed
`master` revision and qualified by the repository's authoritative
corrected-full-history classifier. This is **Phase D**, a new and separately
identified current-model characterization. It neither rewrites nor replaces the
Phase A pre-liquidation record ([BASELINE_RUN_RESULT.md](BASELINE_RUN_RESULT.md)),
which remains unchanged historical evidence.

```text
reviewed revision:            23110c08b03cb9decc9ab48626eda17158063339 (clean)
baseline contract:            MarketLab/config/baseline-contract.json (unchanged; the run did not modify it)
baseline contract SHA-256:    0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a
corrected contract:           MarketLab/config/corrected-full-history-contract.json (unchanged)
corrected contract SHA-256:   d97b3c9b375ed2e53a2af784618a90e4db5e5ab9c627ffc9f0638a8c245cd44f
model revision:               marketlab-single-anchor-broker-liquidation-v1
Stop Out model:               BrokerLiquidation
run window:                   2019-01-01 00:00 UTC .. 2026-06-30 23:59:59 UTC
processed history:            the complete qualified stream (2019-01-01T23:00:07.151Z .. 2026-06-30T23:59:59.678Z)
classification:               EXPECTED (completed full stream; invalidCount 0)
parameter optimization:       NOT STARTED
```

## 1. Run identity and evidence

The retained execution is one authorized local backtest under the corrected
full-history contract's exact run procedure, launched from the clean reviewed
`master` and classified with `Test-SingleAnchorCorrectedFullHistory.ps1`. The
compact run artifacts are committed under
[`evidence/20260930-corrected-full-history/`](evidence/20260930-corrected-full-history/)
with a `manifest.json` that lists every committed artifact's path, SHA-256, byte
size, origin and role, and the retained-not-committed files with their hashes.
Git and GitHub provide no independent run ledger, so this repository record is
the preserved evidence of the retained execution; it does not and cannot prove
the absence of discarded local attempts.

| Artifact (committed copy) | SHA-256 | Notes |
|---|---|---|
| `baseline-build.json` | `32c6a110ec9a7e88ff38941174da0c3b198a78ce76e7a0fe752ea389c6de5983` | source-bound Release build receipt for the reviewed commit; generated `2026-09-30T21:41:38Z`; .NET SDK 10.0.401, runtime 10.0.12 |
| `corrected-history-preflight.json` | `6d0156253821204d941a4e17004e3a624823e630d49bf4e88cf1b728c996eadb` | `PREFLIGHT-PASS`; 2,332/2,332 partitions hash-verified |
| `marketlab-run-invocation.json` | `82d2743bfe91dd9b639623ceeec33dd7097477144bcb4c92f19fb678a84d014b` | pre-run evidence generated `2026-09-30T21:42:12Z`; corrected descriptor/pins, clean checkout, exact launcher argv, runtime hashes |
| `marketlab-run-outcome.json` | `7a24975400d7365f043616e5b473c2502824545cab9a654cf5eb72a2bbd44636` | post-run evidence generated `2026-09-30T23:32:20Z`; LEAN exit 0, helper exit 0, engine-error audit performed, zero engine errors, runtime/binaries unchanged |
| `corrected-full-history-classification.json` | `cf187fd8be1acc18147f0d1e0eb6529f51f46b6750904c0ea1e2357a2ce075a5` | classification `EXPECTED`, `invalidCount` 0; full-stream delivery and 407/407 failed-request reconciliation |
| `strategy-results.json` | `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad` | the complete persisted strategy result (1,602,034 bytes): delivery evidence, every closed basket with `LegTrace`/`LiquidationTrace`, all Stop Out episodes/forced liquidations, rejection traces, research account and final open-basket state |
| `data-monitor-report-20260930233218632.json` | `22cf9ddcf89042d5d8695b0c891c2966c449fa5ce0a78ecb4501db0658e2eb98` | engine request counts (2,741 total: 2,334 succeeded, 407 failed) |
| `failed-data-requests-20260930214213300.txt` | `8fbe25d6b23f33220557fc23a376df5a69eb042066b2b3cf91088b476e50ee34` | the 407 failed request lines |
| `succeeded-data-requests-20260930214213300.txt` | `a4f3f9a070c3dd0d1e9a246c6c367af1e84d3682405e4d355e6212b75806d5db` | the succeeded request lines |
| `run-parameters.txt` | `878ffe0998115388339ae8b81d6420ea2ce093df86617ff4a88f854e9578161b` | the exact 30-value `single-anchor-*` parameter string |

Not committed, because they are large or duplicated by the machine-generated
evidence above (each is identified by its SHA-256 in the manifest): the engine
`log.txt` (472 KB), the algorithm log (315 KB), the LEAN result packets
(`SingleAnchorVNextAlgorithm.json`, 1.4 MB, and its 23 KB summary; LEAN placed
no orders) and the two helper console captures (392 KB / 73 KB).

Frozen parameters: all 30 `single-anchor-*` values were passed explicitly and
matched against the frozen contract before launch; the persisted
`strategy-results.json` parameter block records the resolved values
(`StepPercent 0.25`, `BaseLot 0.10`, `NormalTradeCount 4`,
`HardBreakevenCeilingPercent 4.478`, `ProjectedSpread 0.50`,
`InitialBalance 20,000 USD`, margin enabled, and so on). The persisted margin
parameters are contract size 100, leverage 500, Margin Call 50%, Stop Out 20%.
The session map identity is `33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949`
(1,935 sessions, 90 source files, 413,750,130 source rows). No LEAN order was
placed; the LEAN portfolio statistics are empty by design.

## 2. Pre-run gates

| Gate | Result |
|---|---|
| authoritative build (`Build-SingleAnchorBaseline.ps1 -ReviewedCommit 23110c08b...`) | PASS; receipt binds the clean reviewed tree `d47ed28f0aeee732cdb9e88ecd8b89a5b413a7e1` and the frozen contract |
| contract/register verification (`Get-SingleAnchorBaselineInvocation.ps1`) | PASS; computed contract SHA-256 equals the register pin |
| corrected preflight (`Test-SingleAnchorCorrectedFullHistory.ps1 -Preflight`) | PASS; descriptor and frozen pins, clean reviewed checkout, source-bound build and 2,332/2,332 partitions hash-verified |
| mandatory pre-launch corrected preflight in the helper | PASS (re-run immediately before launch; the helper bound the record by SHA-256) |
| launch | one retained authoritative launch from the clean reviewed commit with the descriptor's exact command |

## 3. Execution

The helper wrote `marketlab-run-invocation.json` at `21:42:12Z`; the pinned
.NET 10.0.12 runtime and the exact launcher argv are recorded there. LEAN
launched at `21:42:12Z` and exited at `23:32:18Z`; the run took **6,606.3 s**
(about 110.1 minutes). LEAN exited 0, the helper exited 0, the engine-error
audit was performed and found **zero engine `ERROR::` lines**; the post-run
artifact re-hash was unchanged. The engine's data monitor counted 2,741
requests: 2,334 succeeded, 407 failed (all reconciled below).

Progress was observed from the engine's `log.txt` by following the latest
simulated event timestamp and the latest requested source partition; the
engine does not expose live quote-level progress.

## 4. Processed history

| Metric | Value |
|---|---|
| delivered/processed quotes | 413,750,130 |
| strategy-eligible quotes | 412,402,479 |
| quote-only session-buffer quotes | 1,347,651 |
| non-quote ticks unused | 0 |
| delivered day partitions | 2,332 |
| first delivered quote | `2019-01-01T23:00:07.151Z` |
| last processed quote | `2026-06-30T23:59:59.678Z` (bid 4005.485 / ask 4006.185) |
| delivered-stream semantic digest | `sha256:231cf63850cd033ea8167ab7d0017bdfbd7744f40412c1a899c2b9d98942886a` |

The current-model verifier classified the delivery as
`phase-b-full-stream`: the complete qualified population, the qualified
first/last quotes and the global semantic digest all reconcile
(`globalSemanticDigestVerified: true`).

## 5. Results

### 5.1 Baskets

- Total baskets anchored: **280** (279 closed: 278 strategy closes and one
  broker liquidation; plus basket #280 anchored and never funded).
- Close reasons of the 279 closed records: Trailing 207, Escape 71,
  `BrokerLiquidation` 1.
- Entries opened: 555 legs.
- Depth histogram (historical entries of every closed record):

| Depth | 1 | 2 | 3 | 4 | 5 | 8 | 10 | 14 | 15 | 17 | 24 | 25 | 35 | 36 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Baskets | 207 | 37 | 21 | 3 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |

- Maximum depth: **36** (basket #276; the fully liquidated basket #279 had 35).
- Longest closed basket from anchor to close: 8,441,681.85 s (97.70 days,
  basket #17).
- Maximum individual placed lot: **7.24** (basket #276, trade 36).
- Hard-BE mode activated in **11** closed baskets; the hard-BE verification
  record confirms the sizer resolved and was verified under the configured
  execution model (`StrategyDefinitionResolved: true`,
  `HardBEVerifiedUnderConfiguredExecutionModel: true`).
- Maximum gross lots 62.76; maximum absolute net lots 26.99; maximum open
  positions 36.

### 5.2 Stop Out and forced liquidation

There were **5 Stop Out episodes** with **65 forced liquidations** and
**-50,713.84400 USD** total forced-liquidation realized P/L:

| # | Basket | Trigger (UTC) | Trigger bid/ask | Forced closes | Realized | Outcome |
|---|---|---|---|---|---|---|
| 1 | 276 | `2020-03-23T12:06:26.292` | 1505.618 / 1506.182 | 20 | -23,446.84700 | MarginRestored |
| 2 | 276 | `2020-03-23T12:06:32.137` | 1505.615 / 1506.625 | 8 | -1,404.21800 | MarginRestored |
| 3 | 276 | `2020-03-23T12:06:38.717` | 1505.508 / 1506.162 | 1 | -98.19600 | MarginRestored |
| 4 | 276 | `2020-03-23T12:06:54.330` | 1505.298 / 1505.802 | 1 | -102.16000 | MarginRestored |
| 5 | 279 | `2020-06-17T09:32:50.569` | 1714.215 / 1716.235 | 35 | -25,662.42300 | AllPositionsLiquidated |

Episode 5 is the decisive event of the full-history characterization: basket
#279's entire surviving inventory was broker-liquidated at the triggering
quote. At the trigger the account showed balance 25,572.00500, floating
-25,662.42300, equity -90.41800, used margin 1,047.1003203334568358651352353,
free margin -1,137.5183203334568358651352353, margin level
-8.635084742520728065799590270% with 35 open positions; after the episode the
account held balance -90.41800, floating 0.00000, equity -90.41800, used margin
0.00000 and zero open positions. Each forced close records the exact immutable
leg identity, side, lot, entry price/time, executable forced-close price/time,
its realized P/L and the account state before/after in `strategy-results.json`
(`researchMargin.StopOutEpisodes`) and in the basket's `LiquidationTrace`. No
least-profitable ordering is left for a consumer to recompute.

### 5.3 Account telemetry and final state

| Metric | Value |
|---|---|
| starting balance | 20,000.00000 USD |
| peak balance | 25,572.00500 USD |
| final balance | **-90.41800 USD** |
| final equity | -90.41800 USD |
| final floating P/L | 0.00000 USD |
| realized P/L | **-20,090.41800 USD** |
| maximum balance drawdown | 26,573.35300 USD |
| peak equity / maximum equity drawdown | 25,584.17500 / 25,674.59300 USD |
| maximum executable floating profit / loss | +25,082.07800 / -25,662.42300 USD |
| maximum used margin | 9,265.979556 USD |
| minimum free margin | -9,356.397556 USD |
| minimum margin level | -8.635084742520728065799590270% |
| final open positions / gross lots / absolute net lots | 0 / 0.00 / 0.00 |
| Margin Call observations / episodes | 348 / 23 |
| Margin Call blocked attempts / episodes | 0 / 0 |

Every value above is the research account's own authoritative record
(`researchAccount`, `researchMargin`). Forced-liquidation realized P/L reaches
the balance exactly once per forced close; the account's floating mark is
survivor-only, so no forced P/L is double counted.

### 5.4 Open basket at end of authoritative data

Basket **#280** was anchored at `2020-06-17T09:32:50.619` (anchor 1714.304,
upper 1718.58976, lower 1710.01824) and its first entry could never be
financed. At the end of the qualified history it is truthfully recorded as an
open basket with **zero historical entries and zero open positions**
(`HistoricalEntries` 0, `OpenPositions` 0, `NextTradeNumber` 1, empty
`LegTrace` and `LiquidationTrace`). No exit was fabricated at the final candle.
The final account state is therefore distinguished exactly as required:
baskets 1..278 closed normally, basket #279 fully broker-liquidated, and basket
#280 still open (unfunded) at the end of the authoritative data.

### 5.5 Entry rejections

The run records **2 distinct rejected-entry episodes** with **346,942,369
rejected attempts** (all `InsufficientMargin` on trade 1 of basket #280),
mechanically retried on eligible quotes because the frozen account could not
finance the projected post-fill inventory:

| First attempt (UTC) | Last attempt (UTC) | Side | Attempts |
|---|---|---|---|
| `2020-06-17T10:58:24.776` | `2026-06-30T23:59:59.678` | Buy | 335,561,606 |
| `2021-03-02T03:18:08.907` | `2022-11-10T13:19:52.856` | Sell | 11,380,763 |

The first attempt's recorded message is explicit: "Trade 1 Buy of 0.10 lots
was not placed: the research account cannot finance the projected post-fill
inventory (projected used margin 34.37264, projected free margin -124.79064).
No leg was added and the trade may be retried on a later eligible quote." No
rejection was converted into an execution, and `skippedFirstEntryQuotes` is 0.
The attempt count is a mechanical eligible-quote retry count, not a count of
distinct orders.

### 5.6 Margin Call

The account entered Margin Call (margin level at or below 50%) in 23 episodes
(348 observation quotes) while positions were open. A Margin Call observation
**blocked no entry and liquidated no position** (`MarginCallBlockedAttempts` 0);
Margin Call remains distinct from Stop Out in the result fields, and only Stop
Out invoked broker liquidation.

## 6. Acceptance case: the corrected former basket #276

Basket #276 reproduces the reviewed Phase C/bounded-model sequence exactly,
now inside the full-history run and without any special-casing:

- anchor 1503.750 at `2020-03-16T15:47:17.769Z`; 36 historical entries
  (0.10/0.20/0.30/0.40 arithmetic then 32 hard-BE tail entries; maximum placed
  lot 7.24);
- the first Stop Out trigger reproduces the Phase A trigger state exactly:
  quote sequence 51,304,749 at `2020-03-23T12:06:26.292Z` (bid 1505.618 /
  ask 1506.182), balance 25,519.92800, floating -25,320.42700, equity
  199.50100, used margin 1,157.8848069189189189189189189, margin level
  17.229779578062128554190460520%, 36 open positions;
- four episodes force-close 30 positions in the exact recorded order (20, 8,
  1, 1; ordinals and immutable trade numbers in `LiquidationTrace`), realizing
  -25,051.42100 in total; the survivors are 6 positions;
- the basket later closes by **Escape** at `2020-04-13T18:24:10.475`
  (bid 1721.098 / ask 1721.212) with lifetime `RawProfit`/`ExitProfit`/
  `RealizedProfit` **+30.65700** and `LiquidatedRealizedProfit` -25,051.42100;
- the partial-liquidation continuation, hard-BE state and lifetime economics
  are therefore fully reconstructible from the exported records without
  recomputing any SingleAnchor decision.

## 7. Behavior-invariance check against the reviewed Phase C bounded run

The reviewed Phase C bounded qualification
([`evidence/20260928-phase-b-march-2020/`](evidence/20260928-phase-b-march-2020/))
was produced by the same model revision over `2019-01-01 .. 2020-04-30`. A
deterministic deep comparison of the two persisted results shows:

- all **278** closed-basket records in the common window (Sequences 1..278)
  are **identical in a deep JSON comparison, zero mismatches**;
- all **4** common Stop Out episodes are **identical in the same deep JSON
  comparison**;
- the common account/strategy path is unchanged; the full run only continues
  beyond the bounded window (episode 5, basket #280).

This is the behavior-invariance evidence for the full execution; it is not a
claim that the whole 90-month run is byte-reproducible across arbitrary
re-executions, and no second full-history run was performed or is claimed.

## 8. Post-run qualification

`Test-SingleAnchorCorrectedFullHistory.ps1 -RunDirectory <run> -ReviewedCommit
23110c08b...` returned **EXPECTED** (exit 0), `invalidCount` 0:

- corrected descriptor `d97b3c9b...`, frozen baseline contract `0882b7ab...`
  and the register pin verified; clean repository HEAD `23110c08b...`
  (`repositoryDirty: false`);
- run build receipt and corrected preflight re-verified and bound by SHA-256;
  the launcher argv reconstructed exactly; the host ran under the pinned .NET
  10.0.12 runtime; algorithm assembly and launcher match the source-bound
  receipt artifacts; post-run runtime/artifact hashes unchanged;
- current-model full-stream delivery verified: 2,332 partitions, 413,750,130
  quotes, qualified first/last quotes, global semantic digest
  (`deliveryVerification.mode: phase-b-full-stream`);
- outcome shape verified: completed full stream, LEAN exit 0 / helper exit 0,
  engine-error audit performed with 0 engine errors, no declared terminal
  exception; the result names `marketlab-single-anchor-broker-liquidation-v1`
  and `BrokerLiquidation`;
- all 407 failed data requests reconcile exactly with the data monitor and the
  qualified tree: 406 expected source-absent calendar days (an always-open
  XAUUSD/dukascopy identity has no weekend partitions) plus the 1 enumerated
  auxiliary benchmark-hour request; 0 unexpected missing qualified partitions,
  0 out-of-window requests, 0 post-horizon requests, 0 unknown requests,
  0 unrequested absences within the horizon, 0 accounting mismatches,
  0 contract/evidence mismatches.

The classification record is the authoritative PASS of the retained run
(`qualification: EXPECTED`, `invalidCount: 0`). Re-auditing later means checking
out the reviewed commit `23110c08b...` with a clean tree and re-running the
classifier against the run directory; documentation/evidence commits after the
run do not invalidate the evidence but do require that checkout for a fresh
audit.

## 9. Interpretation and limitations

- This is the corrected full-history characterization of the frozen strategy
  under the finalized broker-liquidation model. It is a result description,
  not evidence of profitability or of a viable production strategy.
- The frozen account survived the four March 2020 partial-liquidation episodes
  on basket #276 (which later closed at +30.65700 lifetime), but basket #279
  was fully liquidated on `2020-06-17`, taking the balance to -90.41800 USD.
  From then on the frozen first-entry financing rule could never fund another
  entry: basket #280 stayed anchored-but-unfunded and the remaining six years
  of qualified history contain no new positions.
- The result is single-instrument XAUUSD CFD, USD research account, and a
  modeling simplification of the live EUR account; no EUR conversion exists
  and none should be inferred.
- The Phase B model limitations apply unchanged (one forced close per loop
  iteration at the triggering quote, no intrabar or extra-liquidity model,
  forced-close failure is terminal, post-fill exit deferral; see
  [SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md](SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md)
  section 14.6).
- The 346,942,369 rejected attempts are eligible-quote retry counts, not
  distinct orders; they document the frozen model's mechanical behavior after
  the account could no longer finance a first entry.
- One execution is retained. The reviewed common-window deep JSON equality
  with the Phase C bounded run is the invariance evidence; no second
  full-history run was performed and no byte-identical full-run determinism is
  claimed.

## 10. What did not change

- No source code, strategy parameter, account/margin value, execution economic,
  liquidation rule or data identity was modified for or by this run; the run
  executed the frozen contracts as written.
- `MarketLab/config/baseline-contract.json` and
  `MarketLab/config/corrected-full-history-contract.json` are unchanged by this
  result; the run consumed them and did not modify them.
- No historical data was modified; the 413,750,130-row source qualification was
  not rerun. The run read the already-qualified continuous tree.
- The Phase A pre-liquidation record, the Phase B implementation and its
  evidence, and the reviewed Phase C bounded qualification evidence are
  unchanged and were not rewritten.
- No parameter optimization, sweep, walk-forward, holdout selection or
  sensitivity analysis was performed.
- Phase E (authoritative replay export) and later phases have not started.
