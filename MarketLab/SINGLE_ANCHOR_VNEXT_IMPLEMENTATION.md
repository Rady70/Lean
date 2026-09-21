# SingleAnchor vNext: C# implementation notes

The behavioural specification is
[SINGLE_ANCHOR_VNEXT_STRATEGY.md](SINGLE_ANCHOR_VNEXT_STRATEGY.md); this note only
says where the implementation lives, how it is built and tested, which choices
the specification leaves open and how they were fixed, and what is deferred.
Nothing outside `MarketLab\` is modified; the upstream engine, solution and
projects are unchanged.

## 1. Architecture and where it lives

```text
LEAN (unchanged)            reads the quote-tick files, drives the clock: data/time host only
      |  every valid quote tick, in order
      v
SingleAnchorEngine          the strategy's truth: anchor, levels, alternation, sizing,
      |                     exits, independent hedged basket ledger (BUY and SELL legs kept apart)
      v
ResearchExecutor            deterministic fills from the quote itself: BUY at Ask + slippage,
                            SELL at Bid - slippage; closes at Bid - slippage / Ask + slippage;
                            commission and swap from the same parameters
```

No LEAN order is placed and LEAN's portfolio is never read: LEAN nets one
symbol into one holding, which cannot represent the strategy's gross hedged
basket, so LEAN's orders, equity, drawdown, fees and margin stay empty and are
**not** the strategy's results. The strategy writes its own results (section 6).

| Path | Role |
|---|---|
| `src\SingleAnchor\MarketLab.SingleAnchor.csproj` | class library, `net10.0`, references the unchanged upstream `Algorithm` and `Common` projects; not part of `QuantConnect.Lean.sln` |
| `src\SingleAnchor\SingleAnchorParameters.cs` | every input (specification section 17 plus execution-cost, commission-buffer, volume-step and money-value settings) with validation |
| `src\SingleAnchor\Basket.cs`, `BasketLeg.cs` | the basket ledger: fixed anchor, levels and hard-BE targets, ordered legs (audit), and the constant-time aggregates: BUY/SELL lots, entry notionals, swap total, smallest lot |
| `src\SingleAnchor\BasketEconomics.cs` | constant-time valuations from the aggregates: raw profit (BUY at Bid, SELL at Ask, plus swap), commission buffer, step money, executable profit at given close prices, projected P/L at a hard target |
| `src\SingleAnchor\HardBreakevenSizer.cs`, `VolumeMath.cs` | tail sizing: Q_BE, upward normalization, verification, explicit infeasibility outcomes |
| `src\SingleAnchor\SingleAnchorEngine.cs` | the per-quote state machine (sections 14-16), host-independent; verifies every tail fill; raises typed events; keeps the closed-basket records |
| `src\SingleAnchor\Execution.cs` | the all-or-nothing executor contract, the `ResearchExecutor`, event and result records |
| `src\SingleAnchor\QuoteTickFeed.cs` | hands every LEAN quote tick of a slice to the engine in order; counts unused and invalid ticks |
| `src\SingleAnchor\SingleAnchorVNextAlgorithm.cs`, `ParameterParsing.cs` | the `QCAlgorithm` host: XAUUSD CFD quote ticks, LEAN parameters, event logging, end-of-data mark to market, results file |
| `tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj` | NUnit tests on deterministic synthetic quotes (same NUnit / test SDK versions as upstream's `Tests` project) |

## 2. Build, test, run

Build the engine first as in section 2 of the README (`MarketLab\scripts\build.ps1`),
then, from the checkout root:

```powershell
dotnet build MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj --configuration Release
dotnet test MarketLab\tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj --configuration Release
```

Both projects treat compiler warnings as errors; the NuGet audit warnings
(NU1903/NU1904) come from upstream-pinned transitive packages, stay visible and
are excluded from that rule. Output: `MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll`
(ignored by upstream's `.gitignore` like every `bin\`/`obj\`).

Run under LEAN through the qualified helper; the two inputs the specification
leaves without a value must be given, everything else has the specified default:

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1 `
    -AlgorithmTypeName SingleAnchorVNextAlgorithm `
    -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll `
    -Parameters "single-anchor-step-percent:0.1,single-anchor-base-lot:0.01"
```

The checkout ships upstream's Oanda XAUUSD tick-quote sample,
`Data\cfd\oanda\tick\xauusd\20140501..20140515_quote.zip` (13 UTC days, an
engine fixture like the SPY sample: its research suitability, adjustment
conventions and redistribution terms are not established here). The default
dates `2014-05-02`..`2014-05-14` (New York time) lie inside it, so the run
above exercises the whole path (section 7). With any other data folder set
`single-anchor-start-date` / `single-anchor-end-date` to its coverage; a
missing day is reported by the helper as exit code 3. Missing required
parameters end the run with LEAN exit code 1 and the validation message in
`log.txt`.

## 3. Parameters

LEAN parameter names (config `parameters` object or `-Parameters`), the
specification symbol, and the default. Values are parsed with the invariant
culture; `true`/`false` for booleans.

| LEAN parameter | Specification | Default |
|---|---|---|
| `single-anchor-step-percent` | P (section 2) | none, required |
| `single-anchor-base-lot` | B (section 4) | none, required |
| `single-anchor-normal-trade-count` | Nnormal (section 5) | 4 |
| `single-anchor-hard-be-ceiling-percent` | C (section 6) | 4.478 (research starting value, not an optimum) |
| `single-anchor-escape-enabled`, `-escape-profit-units`, `-escape-minimum-open-positions` | section 11 | true, 0.05, 2 |
| `single-anchor-fixed-tp-units` | U_TP (section 12) | 0 (disabled) |
| `single-anchor-trailing-enabled`, `-trailing-activation-units`, `-trailing-drop-units` | section 13 | true, 0.50, 0.25 |
| `single-anchor-commission-buffer` | CommissionBuffer (section 9), a flat amount per basket | 0 (disabled) |
| `single-anchor-commission-buffer-per-lot` | optional volume-scaled part of the buffer, per lot of gross open volume | 0 (disabled) |
| `single-anchor-point-value-per-lot` | V (section 10) | 100 (XAUUSD: 100 oz per lot, USD account) |
| `single-anchor-volume-step`, `-minimum-volume`, `-maximum-volume` | V_step and broker limits (section 8) | 0.01, 0.01, 100 |
| `single-anchor-commission-per-lot` | round-trip commission per lot: in the executable projection (section 7) and in every realized result | 0 |
| `single-anchor-slippage` | adverse slippage per execution, price units: in the projection and in every fill (section 7) | 0 |
| `single-anchor-use-observed-spread`, `-projected-spread` | spread at the hard target (section 7) | true (spread of the sizing tick), 0 |
| `single-anchor-buy-swap-per-lot-per-day`, `-sell-swap-per-lot-per-day` | swap/financing (sections 7, 9) | 0, 0 (no accrual) |
| `single-anchor-swap-rollover-time`, `-triple-swap-day` | rollover clock for swap; the time as `HHmm`/`HHmmss` (LEAN's `--parameters` splits on `:`, so `17:00` only works through the config file) | `1700`, `Wednesday` (`none` to disable) |
| `single-anchor-symbol`, `-market`, `-security-type` | host instrument | `XAUUSD`, `oanda`, `Cfd` (`Forex` accepted) |
| `single-anchor-start-date`, `-end-date`, `-cash` | host run settings (`cash` only satisfies LEAN's setup; the strategy sizes in lots) | `2014-05-02`, `2014-05-14` (the shipped sample), 100000 |

## 4. Choices the specification leaves open

Each of these is explicit in code and covered by a test; none changes the
specified rules.

- **Hard-target prices.** T_up and T_down are midpoints like the anchor they
  derive from; the projected Bid/Ask at the target are T -/+ half the spread
  (observed on the sizing tick, or the configured `projected-spread`). BUY legs
  are projected to close at that Bid less slippage, SELL legs at that Ask plus
  slippage; the candidate leg enters at the current Ask plus slippage (BUY) or
  Bid less slippage (SELL); the round-trip commission is charged per lot on
  every leg, existing and new; accrued swap is included, future swap is not
  projected.
- **"Smallest valid Q".** With PL_1lot(T) > 0: Q_BE = -PL_existing / PL_1lot
  when PL_existing < 0, otherwise 0; the placed lot is
  ceil(max(Q_BE, minimum) / step) * step, then PL_after(T, Q) is recomputed
  directly and the lot stepped up while it is negative; above the maximum
  volume the sizing is infeasible. With PL_1lot(T) <= 0 the ratio is not valid
  and more volume cannot help, so the only candidate is the minimum volume: it
  is placed when PL_after(T, minimum) >= 0 (the basket already projects at or
  inside the ceiling), otherwise the sizing is infeasible.
- **Hard-BE verification after the fill.** The sizing uses the execution model
  and the research executor fills with exactly that model, so the projected and
  the actual entry price are the same number. The engine still recomputes the
  projected executable basket P/L at the fixed target with the actual fill
  after every tail leg; a negative value (only possible with an executor that
  departs from the model) is counted and raised as `HardBreakevenViolated`,
  and the results record the count. The fixture run reports 0.
- **Infeasible hard-BE.** No order is placed, hard-BE mode stays active, an
  `EntryRejected` event with the full sizing record is raised (the algorithm
  logs it with `Error`), the situation is re-evaluated on every later trigger
  quote and reported again when trade number, side, reason, outcome or the
  required lot after normalization change; the count of attempts is kept.
  Nothing is ever converted into a smaller lot.
- **Arithmetic lots** (trades 1..Nnormal) are normalized upward to the volume
  step (never below the requested B * n), raised to the minimum volume, and
  refused explicitly above the maximum.
- **Commission buffer** is the flat amount of section 9, optionally plus an
  amount per lot of gross open volume.
- **Net exposure**: every leg is a whole number of volume steps (the ledger
  refuses anything else), so N is exact and "net-flat" is exactly zero, in
  which case E is the smallest open lot.
- **Both boundaries on one quote** (an empty basket, spread of two steps or
  more): the specification defines no priority between the two entry rules, so
  no side is chosen, nothing is opened, and the quote is reported once as an
  `AmbiguousBoundaries` rejection. After the first leg the required side is
  fixed and the question does not arise.
- **Anchoring quote**: it can satisfy an entry rule only when the step is
  inside the spread, and then it satisfies both, so it never opens a leg.
- **Swap** accrues per leg at each rollover instant (`swap-rollover-time` in the
  quote clock) that ends a Monday-Friday trading day; the rollover ending the
  `triple-swap-day` charges three times; a leg opened at or after the instant
  is charged from the next one. LEAN's Oanda XAUUSD quotes are stamped in New
  York time, hence the 17:00 default. The rollover pass is per leg (audit) but
  runs at most once a day; every per-quote valuation is constant-time.
- **Executor contract**: all-or-nothing and immediate (an entry fills its whole
  volume at one price or fails; a close closes every leg or fails). A failed
  entry is an explicit rejection and the grid waits; a failed close ends that
  quote's processing (no entry on a quote whose exit fired) and the exit is
  re-evaluated on the next quote. The research executor never fails.
  Broker-style partial or deferred execution is out of scope (section 5).
- **Realized results**: a closed basket records the decision quantities at the
  closing quote (raw profit, exit profit, threshold) and the realized executable
  result: BUY legs closed at Bid - slippage, SELL legs at Ask + slippage, plus
  accrued swap, less the round-trip commission on the gross volume.
- **LEAN specifics.** Every valid quote tick of a slice reaches the engine in
  order; nothing is collapsed to the last tick. Non-quote ticks (trades) are
  unused and counted; quote ticks with non-positive or crossed prices are
  counted and skipped. LEAN delivers only ticks inside the market-hours
  sessions of its database (for Oanda XAUUSD: not the New York 16:58-18:03
  break or the weekend). Invalid or out-of-order quotes reaching the engine are
  ignored with an `InvalidQuote` event.

## 5. Deferred on purpose

- **Historical XAUUSD data for research**: no ingestion or conversion, no new
  data file, no synthetic data. The shipped 2014 sample is an engine fixture
  used for software-use evidence only (section 7); a research history needs
  its own provenance, licensing and integrity record and goes through the same
  `cfd/oanda/tick/xauusd` layout (`Data\cfd\readme.md`).
- **Broker-style execution** (LEAN orders, partial fills, pending fills, a
  netted host portfolio): a separate qualification with its own invariants
  (a partial tail fill must not be able to break the hard-BE requirement; a
  started close must run to completion). Not part of the research engine.
- Replay, optimization, UI, charting, live trading, broker connectivity.
- A full performance report (equity curve, drawdown, per-basket statistics)
  from the strategy's own results; the results file below is the input for it.
- A `decimal` versus `double` benchmark of the per-quote path; the arithmetic
  stays exact `decimal` until a measured need says otherwise.

## 6. Results the strategy writes

LEAN's `<Algorithm>.json` / `-summary.json` report an empty portfolio (0 orders,
unchanged equity) and must not be read as strategy performance. The strategy's
own results are:

- the algorithm log (`<run dir>\<Algorithm>-log.txt`): anchors, every leg with
  its sizing line, every close with decision and realized figures, rejections
  and violations as `Error` lines, and the end-of-data summary with the open
  basket marked to market (raw, exit and executable profit; never closed);
- `<run dir>\storage\single-anchor\results.json` (written through LEAN's object
  store at the end of the run): the parameters, the tick and quote counts, legs
  opened, rejections, baskets closed, hard-BE violations, the realized profit
  total, one record per closed basket (times, anchor, reason, lots, decision
  and realized figures, close prices, swap, commission) and the open basket's
  valuation and legs.

## 7. Validation record (2026-09-21, Windows, .NET SDK 10.0.401)

Software-use evidence only: nothing here is evidence of profitability, of the
sample's data quality or of a sensible parameter choice.

- `dotnet build ...MarketLab.SingleAnchor.csproj --configuration Release`: 0 errors; 0 compiler
  warnings from the two MarketLab projects (the referenced upstream projects print their own
  analyzer warnings, as recorded for the engine build).
- `dotnet test ...MarketLab.SingleAnchor.Tests.csproj --configuration Release`: 118 passed, 0 failed, 0 skipped.
- `MarketLab\scripts\run-backtest.ps1` with the assembly on the shipped sample,
  `-Parameters "single-anchor-step-percent:0.1,single-anchor-base-lot:0.01"`
  (default dates 2014-05-02..2014-05-14), twice: identical results, helper exit
  code 0, 0 failed data requests, 0 engine `ERROR::` lines; 1,688,736 quote
  ticks fed (every in-window tick of the sample inside LEAN's market hours; 0
  non-quote, 0 invalid), 30 legs, 7 baskets closed (5 by trailing, 2 by escape,
  the last one with 14 legs), 1 rejected entry (an `AmbiguousBoundaries` quote
  with a 2.6 spread on the 2014-05-02 08:30:01 anchor), 0 hard-BE violations,
  realized profit 3.275; at the end of data a 9-leg hard-BE basket (buy 0.10 /
  sell 0.11 / net -0.01 lots, raw profit -23.51) reported marked to market, not
  closed; `results.json` written; LEAN's own report: 0 orders, End Equity
  100,000. Wall time of the two runs 15 s and 27 s (LEAN's own figures 13.6 s
  and 25.1 s) for the same deterministic result; no throughput claim is made
  from two unrepeated timings.
- The same helper without the two required parameters: LEAN exit code 1 with
  the validation message; with dates outside the sample: exit code 3 (failed
  data requests), 0 quotes processed.
- `MarketLab\tests\Test-MarketLabBacktesting.ps1` (fast mode): unchanged
  helper, 150 passed, 0 failed.
