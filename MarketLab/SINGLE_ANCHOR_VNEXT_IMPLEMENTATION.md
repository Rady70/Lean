# SingleAnchor vNext: C# implementation notes

The behavioural specification is
[SINGLE_ANCHOR_VNEXT_STRATEGY.md](SINGLE_ANCHOR_VNEXT_STRATEGY.md); this note only
says where the implementation lives, how it is built and tested, which choices
the specification leaves open and how they were fixed, and what is deferred.
Nothing outside `MarketLab\` is modified; the upstream engine, solution and
projects are unchanged.

## 1. Where it lives

| Path | Role |
|---|---|
| `src\SingleAnchor\MarketLab.SingleAnchor.csproj` | class library, `net10.0`, references the unchanged upstream `Algorithm` and `Common` projects; not part of `QuantConnect.Lean.sln` |
| `src\SingleAnchor\SingleAnchorParameters.cs` | every input (specification section 17 plus execution-cost, commission-buffer, volume-step and money-value settings) with validation |
| `src\SingleAnchor\Basket.cs`, `BasketLeg.cs` | the basket ledger: fixed anchor, levels and hard-BE targets, ordered legs with side, lots, entry price and sequence, BUY/SELL/gross/net lots, trailing state |
| `src\SingleAnchor\BasketEconomics.cs` | basket profit at a quote (BUY at Bid, SELL at Ask, plus accrued swap), commission buffer, step money, projected executable P/L at a hard target |
| `src\SingleAnchor\HardBreakevenSizer.cs`, `VolumeMath.cs` | tail sizing: Q_BE, upward normalization, verification, explicit infeasibility outcomes |
| `src\SingleAnchor\SingleAnchorEngine.cs` | the per-quote state machine (sections 14-16), host-independent; raises typed events |
| `src\SingleAnchor\Execution.cs` | the executor interface the engine drives, execution results, exit reasons, event records |
| `src\SingleAnchor\LeanBasketExecutor.cs` | LEAN execution: lots to units, market orders, fills taken from the returned ticket or from later order events, one flattening order per basket close |
| `src\SingleAnchor\SingleAnchorVNextAlgorithm.cs`, `ParameterParsing.cs` | the `QCAlgorithm` host: XAUUSD CFD quote ticks, LEAN parameters, event logging, end-of-data mark to market |
| `tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj` | NUnit tests on deterministic synthetic quotes (same NUnit / test SDK versions as upstream's `Tests` project) |

The engine never reads host holdings: LEAN nets one symbol into one holding,
while the strategy needs BUY lots, SELL lots, gross, signed net, every entry
price and the sequence, so the engine keeps its own ledger and the LEAN layer
only executes and reports fills.

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
above exercises the whole path (section 6). With any other data folder set
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
| `single-anchor-commission-per-lot` | round-trip commission in the executable projection (section 7) | 0 |
| `single-anchor-slippage` | adverse slippage per execution, price units (section 7) | 0 |
| `single-anchor-use-observed-spread`, `-projected-spread` | spread at the hard target (section 7) | true (spread of the sizing tick), 0 |
| `single-anchor-buy-swap-per-lot-per-day`, `-sell-swap-per-lot-per-day` | swap/financing (sections 7, 9) | 0, 0 (no accrual) |
| `single-anchor-swap-rollover-time`, `-triple-swap-day` | rollover clock for swap; the time as `HHmm`/`HHmmss` (LEAN's `--parameters` splits on `:`, so `17:00` only works through the config file) | `1700`, `Wednesday` (`none` to disable) |
| `single-anchor-symbol`, `-market`, `-security-type` | host instrument | `XAUUSD`, `oanda`, `Cfd` (`Forex` accepted) |
| `single-anchor-start-date`, `-end-date`, `-cash`, `-leverage`, `-units-per-lot` | host run settings | `2014-05-02`, `2014-05-14` (the shipped sample), 100000, 50, 100 |

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
- **Infeasible hard-BE.** No order is placed, hard-BE mode stays active, an
  `EntryRejected` event with the full sizing record is raised (the algorithm
  logs it with `Error`), the situation is re-evaluated on every later trigger
  quote and reported again only when trade number, side or reason change; the
  count of attempts is kept. Nothing is ever converted into a smaller lot.
- **Arithmetic lots** (trades 1..Nnormal) are rounded to the nearest volume
  step (midpoint away from zero), raised to the minimum volume, and refused
  explicitly above the maximum.
- **Commission buffer** is the flat amount of section 9, optionally plus an
  amount per lot of gross open volume.
- **"Meaningfully non-zero" net exposure**: every leg is a whole number of
  steps, so |N| below half a step counts as flat and E is the smallest open lot.
- **Both boundaries on one quote** (spread wider than the grid): the BUY
  condition is checked first, as written in section 3.
- **First quote after anchoring** can trigger an entry only when the step is
  inside the spread; nothing forbids it and the test records the behaviour.
- **Swap** accrues per leg at each rollover instant (`swap-rollover-time` in the
  quote clock) that ends a Monday-Friday trading day; the rollover ending the
  `triple-swap-day` charges three times; a leg opened at or after the instant
  is charged from the next one. LEAN's Oanda XAUUSD quotes are stamped in New
  York time, hence the 17:00 default.
- **Host execution edge cases** (not in the specification): a close whose
  order fails or is still pending ends that quote's processing (no entry on a
  quote whose exit fired) and the exit is re-evaluated on the next quote; while
  an order is pending the engine only observes (reported once); an unusable
  fill (non-positive price or volume) is a failed entry; invalid or out-of-order
  quotes are ignored with an `InvalidQuote` event.
- **LEAN specifics.** At this revision a backtest market order is filled inside
  the `MarketOrder` call (the backtesting transaction handler drains its queue
  on the algorithm thread and scans the brokerage; the Submitted and Filled
  events reach `OnOrderEvent` during the call), so the returned ticket is
  already filled and the executor records the ticket's average price and
  quantity. A ticket that comes back open (LEAN converts an order to
  market-on-open when it considers the exchange closed; a partial fill under a
  non-default fill model) is pending until its later order events; partial
  fills, including any already on the ticket, are accumulated into one
  volume-weighted fill, and an entry cancelled after a partial fill records the
  filled part (this carry-over relies on the single-threaded backtest sequence;
  live trading is out of scope). The last valid quote tick of each slice is the decision quote
  (LEAN fills against it; earlier same-timestamp ticks and invalid ticks are
  counted separately in the end-of-data line). LEAN delivers only ticks inside
  the market-hours sessions of its database (for Oanda XAUUSD: not the New York
  16:58-18:03 break or the weekend). A basket close is one order flattening
  LEAN's net holding (none when net-flat). LEAN's account simulation stays on
  LEAN's default models (netting, the market's default fee model, no swap): the
  strategy's decisions use its own ledger and explicit cost inputs, so LEAN's
  equity and the strategy's basket profit differ by the netting effect
  (hedged accounting pays the spread on both sides of an overlapping BUY/SELL
  pair) and by any cost LEAN does not model.

## 5. Deferred on purpose

- **Historical XAUUSD data for research**: no ingestion or conversion, no new
  data file, no synthetic data. The shipped 2014 sample is an engine fixture
  used for software-use evidence only (section 6); a research history needs
  its own provenance, licensing and integrity record and goes through the same
  `cfd/oanda/tick/xauusd` layout (`Data\cfd\readme.md`).
- Replay, optimization, UI, charting, live trading, broker connectivity.
- LEAN fee/slippage/swap models matching the strategy's cost inputs (the
  standard `SetFeeModel`/`SetSlippageModel` APIs remain available to a later
  task if the account-level simulation must reproduce them).

## 6. Validation record (2026-09-21, Windows, .NET SDK 10.0.401)

Software-use evidence only: nothing here is evidence of profitability, of the
sample's data quality or of a sensible parameter choice.

- `dotnet build ...MarketLab.SingleAnchor.csproj --configuration Release`: 0 errors; 0 compiler
  warnings from the two MarketLab projects (the referenced upstream projects print their own
  analyzer warnings, as recorded for the engine build).
- `dotnet test ...MarketLab.SingleAnchor.Tests.csproj --configuration Release`: 126 passed, 0 failed, 0 skipped.
- `MarketLab\scripts\run-backtest.ps1` with the assembly on the shipped sample,
  `-Parameters "single-anchor-step-percent:0.1,single-anchor-base-lot:0.01"`
  (default dates 2014-05-02..2014-05-14): helper exit code 0, 0 failed data
  requests, 0 engine `ERROR::` lines, 34 s; 1,688,736 quote slices (equal to the
  in-window ticks of the sample inside LEAN's market hours; 0 superseded, 0
  invalid), 22 legs, 6 baskets closed (5 by trailing, 1 by escape), 0 rejected
  entries, 28 LEAN orders; at the end of data a 15-leg hard-BE basket (buy 0.25
  / sell 0.23 / net 0.02 lots, raw profit -24.144) was reported marked to
  market with LEAN still holding 2 units, not closed; LEAN End Equity 99,987.40
  (netting view, no fees). The logged hard-BE lines recompute by hand, for
  example trade 5: PL_existing(T) = -143.71685, PL_1lot(T) = 5453.5425, Q_BE =
  0.02635 -> lot 0.03, PL_after = 19.889.
- The same helper without the two required parameters: LEAN exit code 1 with
  the validation message; with dates outside the sample: exit code 3 (failed
  data requests), 0 quotes processed.
- `MarketLab\tests\Test-MarketLabBacktesting.ps1` (fast mode): unchanged
  helper, 150 passed, 0 failed.
