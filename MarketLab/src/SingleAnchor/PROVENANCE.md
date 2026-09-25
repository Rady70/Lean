# Retired-source provenance for PR 2

The retired repositories are reference material, not runtime dependencies, and
no retired code is loaded or executed by MarketLab. This file records every
retired repository behaviour or contract that was materially adapted for the
PR 2 research account and bounded analytics. The MarketLab result is much
smaller than the retired components: only the account-value semantics, the
observation ordering, the run-level metric definitions and the per-basket
record contract were used, and all of them were reimplemented in C# against the
existing `Basket`/`BasketEconomics` model. No position-owning account object, no
Python runtime and no generic analytics framework was migrated.

## Pinned sources

| Repository | Commit |
|---|---|
| `Rady70/quant_research_platform` | `a5b64625a549da6d136f3491f7219fbddffdd35d` |
| `Rady70/single_anchor_research` | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` |

## Adapted behaviours

| Source repository | Source commit | Source path | Destination path | Adaptations |
|---|---|---|---|---|
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | `quant_research/account.py` (`AccountView`/`PositionView`; balance changes only on close, realized accumulates from closes, unrealized is the executable mark, equity = balance + unrealized) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` (`SingleAnchorResearchAccount`) | Semantics only. The retired `Account` owns positions and mutates balance; MarketLab keeps `Basket`/`BasketLeg` as the only position truth and reads `SingleAnchorEngine.RealizedProfit` as the only realized authority. Balance is `InitialBalance + realized`; floating P/L is the existing C# `BasketEconomics.ExecutableProfit` (adverse close prices, slippage and round-trip commission); equity is their sum. `Account`/`Position`/`_commit_*` and the position-ID registry were not copied. |
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | `quant_research/runtime.py` (`_SinkRuntimeCursor.step`: revalue the account before decisions on every accepted quote; commit opens/closes serially; observe after execution; finalize with a final mark) | `MarketLab/src/SingleAnchor/SingleAnchorEngine.cs` observation points, `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Adapted to the existing engine's event sequence: observe every processed quote before exit evaluation, observe again after a filled leg, observe after a close is final, and observe the end-of-data mark from the host. The retired cursor's order placement, position allocation and execution commits were not migrated. |
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | `quant_research/results.py` (`_SummaryAccumulator._observe_equity`: peak equity and maximum drawdown seeded at the initial value, strict improvement, observed on quotes and after execution) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Peak equity / maximum equity drawdown keep the retired seed-and-strict-improvement rule. Observation points follow this project's engine, and the values are exact `decimal` money, not binary64 floats. |
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | `quant_research/analytics.py` (`BalanceDrawdownAnalytics`, `PositionPLAnalytics` unrealized extrema, `QuantityExposureAnalytics`, `AnalyticsSink` bounded retention) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Adapted: peak balance / maximum balance drawdown (seeded at the initial balance, strict improvement); floating extrema observed only while a leg is open and initialized by the first such observation; current and maximum open positions, gross lots and absolute net lots; closed positions/fills/turnover/duration analytics were not needed by the approved PR 2 metric list and were not migrated. Retention follows the retired fixed-scalar rule plus one compact record per closed basket; no ordered per-basket profit lists and no snapshot history. |
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | `docs/platform/MIGRATION_INVARIANTS.md`, `docs/reference/GLOSSARY.md` (normative account wording: balance is the initial cash plus the complete realized net executable P/L recognized once at each close; equity is the current balance plus the current unrealized net executable P/L; costs are charged once; financing is included when configured) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Used as the semantic contract for the definitions in section 9.1 of the implementation note. This project has no financing (non-zero swap is rejected, section 4 of the note) and no second cost charge: the floating mark and the realized close use the same configured execution model, so equity is continuous across a close. |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | `src/single_anchor_sim/models.py` (`BasketSummary`, `BasketSnapshot`, `BasketAccounting`, `BacktestResult`) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` (`BasketResearchRecord`, `ResearchAccountSummary`) | Field contract adapted: basket start/end times, duration, first side, entry count, deepest trade number, maximum gross/absolute-net lots, maximum floating loss/profit, close reason, realized P/L, initial/final balance and equity, peak/drawdown values, final exposure. The retired arithmetic-only lot fields were replaced by this project's exact/normalized/placed tail-lot maxima and hard-BE/rejection fields, which the retired repository does not have. |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | `src/single_anchor_sim/engine.py` (basket extrema updated on the close tick before the close; floating extrema initialized from the first open-position snapshot; trackers reset on close) | `MarketLab/src/SingleAnchor/SingleAnchorEngine.cs` observation points, `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Adapted: the account observes the incoming quote before an exit can remove the basket, so the close tick contributes to the basket extrema; the extrema initialize at the first open-leg observation, not at zero; the active accumulator resets when the basket closes. The retired engine's strategy logic was not migrated (this project's vNext C# engine is authoritative). |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | `src/single_anchor_sim/backtest_execution.py` (`OnlineBacktestMetrics`: max gross/abs-net over every snapshot, floating extrema only while positions are open, drawdown over every equity point) | `MarketLab/src/SingleAnchor/ResearchAccount.cs` | Adapted to the run-level maxima of section 9.3 with exact decimals and this project's observation points. |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | `tests/test_basket_close_execution.py`, `tests/test_basket_snapshots.py`, `tests/test_backtest_runner.py` (close-tick extrema, first-observation floating extrema, balance/equity identities, drawdown expectations) | `MarketLab/tests/SingleAnchor/ResearchAccountTests.cs` | Test conventions and observation-order assertions were used as the model for the new tests; no test code was copied. Expected values are recomputed for this project's strategy and cost model. |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | `src/single_anchor_sim/broker.py` (adverse fills and per-lot commission in the executable mark) | `MarketLab/src/SingleAnchor/BasketEconomics.cs` (pre-existing) | Semantic cross-check only: the executable floating mark and the realized close already existed in MarketLab and use the configured execution model; no retired cost code was migrated. |

## Used as semantic reference only (no behaviour copied)

| Repository | Commit | Relevance |
|---|---|---|
| quant_research_platform | `a5b64625a549da6d136f3491f7219fbddffdd35d` | Bounded-retention discipline (fixed scalar state, no quote/snapshot history, no account snapshots for the default sink) shaped the retention rules of section 9.5. Its margin/leverage absence also matches this phase's boundary (margin is PR 3). |
| single_anchor_research | `0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a` | Reproducibility conventions (exact decimal formatting, deterministic projection comparisons) shaped the parity tests; its execution-accounting tests demonstrated the close-tick observation ordering. |

## Deliberately not migrated

Not brought over: any position-owning `Account` or second position registry;
Python/runtime adapters; generic run/experiment/replay/artifact frameworks; the
Parquet/tick-archive stack and composition machinery; strategy reducers or
per-tick snapshot histories; margin, leverage or stop-out state (PR 3); and any
per-basket profit lists or equity-curve writers. They either own state that the
strategy ledger already owns, solve broader problems than PR 2, or belong to
later roadmap phases.
