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
| `src\SingleAnchor\LeanBasketExecutor.cs` | LEAN execution: lots to units, market orders, pending fills resolved from order events, one flattening order per basket close |
| `src\SingleAnchor\SingleAnchorVNextAlgorithm.cs` | the `QCAlgorithm` host: XAUUSD CFD quote ticks, LEAN parameters, event logging, end-of-data mark to market |
| `tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj` | NUnit tests on deterministic synthetic quotes (same NUnit / test SDK versions as upstream's `Tests` project) |

The engine never reads host holdings: LEAN nets one symbol into one holding,
while the strategy needs BUY lots, SELL lots, gross, signed net, every entry
price and the sequence, so the engine keeps its own ledger and the LEAN layer
only executes and reports fills.

## 2. Build and test

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
    -Parameters "single-anchor-step-percent:1.0,single-anchor-base-lot:0.01,single-anchor-start-date:2024-01-02,single-anchor-end-date:2024-01-05"
```

No XAUUSD data ships with the fork (section 5), so today this run loads and
initializes the algorithm, requests `Data\cfd\oanda\tick\xauusd\<date>_quote.zip`
files that do not exist, processes no quote and ends with the helper's exit
code 3 (failed data requests; 0 with `-AllowMissingData`). Missing required
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
| `single-anchor-commission-buffer-per-lot` | CommissionBuffer (section 9), per lot of gross open volume | 0 (disabled) |
| `single-anchor-point-value-per-lot` | V (section 10) | 100 (XAUUSD: 100 oz per lot, USD account) |
| `single-anchor-volume-step`, `-minimum-volume`, `-maximum-volume` | V_step and broker limits (section 8) | 0.01, 0.01, 100 |
| `single-anchor-commission-per-lot` | round-trip commission in the executable projection (section 7) | 0 |
| `single-anchor-slippage` | adverse slippage per execution, price units (section 7) | 0 |
| `single-anchor-use-observed-spread`, `-projected-spread` | spread at the hard target (section 7) | true (spread of the sizing tick), 0 |
| `single-anchor-buy-swap-per-lot-per-day`, `-sell-swap-per-lot-per-day` | swap/financing (sections 7, 9) | 0, 0 (no accrual) |
| `single-anchor-swap-rollover-time`, `-triple-swap-day` | rollover clock for swap | `17:00:00`, `Wednesday` (`none` to disable) |
| `single-anchor-symbol`, `-market`, `-security-type` | host instrument | `XAUUSD`, `oanda`, `Cfd` (`Forex` accepted) |
| `single-anchor-start-date`, `-end-date`, `-cash`, `-leverage`, `-units-per-lot` | host run settings | `2024-01-02`, `2024-01-05` (placeholders: set to the data coverage), 100000, 50, 100 |

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
  projected. PL_1lot(T) <= 0 is an infeasible sizing.
- **"Smallest valid Q".** Q_BE = -PL_existing / PL_1lot when PL_existing < 0,
  otherwise 0; the placed lot is ceil(max(Q_BE, minimum) / step) * step, then
  PL_after(T, Q) is recomputed directly and the lot stepped up while it is
  negative. Above the maximum volume the sizing is infeasible.
- **Infeasible hard-BE.** No order is placed, hard-BE mode stays active, an
  `EntryRejected` event with the full sizing record is raised (the algorithm
  logs it with `Error`), the situation is re-evaluated on every later trigger
  quote and reported again only when trade number, side or reason change; the
  count of attempts is kept. Nothing is ever converted into a smaller lot.
- **Arithmetic lots** (trades 1..Nnormal) are rounded to the nearest volume
  step (midpoint away from zero), raised to the minimum volume, and refused
  explicitly above the maximum.
- **Commission buffer** is per lot of gross open volume.
- **"Meaningfully non-zero" net exposure**: every leg is a whole number of
  steps, so |N| below half a step counts as flat and E is the smallest open lot.
- **Both boundaries on one quote** (spread wider than the grid): the BUY
  condition is checked first, as written in section 3.
- **First quote after anchoring** can trigger an entry only when the step is
  inside the spread; nothing forbids it and the test records the behaviour.
- **Swap** accrues per leg at each rollover instant (`swap-rollover-time` in the
  quote clock) that ends a Monday-Friday trading day; the rollover ending the
  `triple-swap-day` charges three times; a leg opened exactly at the instant is
  charged from the next one. LEAN's Oanda XAUUSD quotes are stamped in New York
  time, hence the 17:00 default.
- **Host execution edge cases** (not in the specification): a close whose
  order fails or is still pending ends that quote's processing (no entry on a
  quote whose exit fired) and the exit is re-evaluated on the next quote; while
  an order is pending the engine only observes (reported once); an unusable
  fill (non-positive price or volume) is a failed entry; invalid or out-of-order
  quotes are ignored with an `InvalidQuote` event.
- **LEAN specifics.** Backtest market orders fill after `OnData`, so every order
  is pending until its order event; partial fills are accumulated into one
  volume-weighted fill. The last valid quote tick of each slice is the decision
  quote (LEAN fills against it). A basket close is one order flattening LEAN's
  net holding (none when net-flat). LEAN's account simulation stays on LEAN's
  default models (netting, the market's default fee model, no swap): the
  strategy's decisions use its own ledger and explicit cost inputs, so LEAN's
  equity and the strategy's basket profit differ by the netting effect
  (hedged accounting pays the spread on both sides of an overlapping BUY/SELL
  pair) and by any cost LEAN does not model. An order submitted while LEAN
  considers the exchange closed is converted by LEAN to market-on-open and
  stays pending until it fills.

## 5. Deferred on purpose

- **Historical XAUUSD data**: no ingestion or conversion, no sample file, no
  synthetic data. The algorithm subscribes to `cfd/oanda/tick/xauusd` quote
  files in LEAN's own format (`Data\cfd\readme.md`); providing them is a
  separate task with its own provenance, licensing and integrity record.
- Replay, optimization, UI, charting, live trading, broker connectivity.
- LEAN fee/slippage/swap models matching the strategy's cost inputs (the
  standard `SetFeeModel`/`SetSlippageModel` APIs remain available to a later
  task if the account-level simulation must reproduce them).

## 6. Validation record (2026-09-21, Windows, .NET SDK 10.0.401)

- `dotnet build ...MarketLab.SingleAnchor.csproj --configuration Release`: 0 errors.
- `dotnet test ...MarketLab.SingleAnchor.Tests.csproj --configuration Release`: all tests passed (count in the pull request).
- `MarketLab\scripts\run-backtest.ps1` with the assembly, `-AllowMissingData` and the two required parameters: the loader reported `Loaded SingleAnchorVNextAlgorithm`, the parameter summary was logged, five missing `xauusd` tick files were reported by the data monitor, the algorithm completed with 0 quotes; without the required parameters LEAN exit code 1 with the validation message.
- `MarketLab\tests\Test-MarketLabBacktesting.ps1` (fast mode): unchanged helper, all assertions passed.
