# SingleAnchor vNext: C# implementation notes

The behavioural specification is
[SINGLE_ANCHOR_VNEXT_STRATEGY.md](SINGLE_ANCHOR_VNEXT_STRATEGY.md); this note only
says where the implementation lives, how it is built and tested, which
implementation choices it makes, and what is deferred. Nothing outside
`MarketLab\` is modified; the upstream engine, solution and projects are
unchanged.

The two strategy-definition questions that the specification previously left
open are resolved in the specification and implemented here:

- a still-empty basket does not start on a quote that satisfies both first-entry
  boundaries; the quote is skipped and the run continues (section 3 of the
  specification);
- `T_up` / `T_down` are the hard basket-BE **boundaries**: `Bid = T_up` is the
  maximum permitted upper BE Bid level and `Ask = T_down` the minimum permitted
  lower BE Ask level. They are ceilings used for sizing, not necessarily the
  actual zero-loss BE (which normally lies inside them after volume rounding)
  and not an exit rule: the configured target spread only reconstructs the
  opposite quote side of the sizing valuation (section 6).

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
                            commission from the same parameters
```

No LEAN order is placed and LEAN's portfolio is never read: LEAN nets one
symbol into one holding, which cannot represent the strategy's gross hedged
basket, so LEAN's orders, equity, drawdown, fees and margin stay empty and are
**not** the strategy's results. The strategy writes its own results (section 6).

| Path | Role |
|---|---|
| `src\SingleAnchor\MarketLab.SingleAnchor.csproj` | class library, `net10.0`, references the unchanged upstream `Algorithm` and `Common` projects; not part of `QuantConnect.Lean.sln` |
| `src\SingleAnchor\SingleAnchorParameters.cs` | every input (specification section 17 plus execution-cost, commission-buffer, volume-step and money-value settings) with validation |
| `src\SingleAnchor\Basket.cs`, `BasketLeg.cs` | the basket ledger: fixed anchor, levels and hard-BE targets, ordered legs (audit), the constant-time aggregates (BUY/SELL lots, entry notionals, smallest lot) and the compact skipped-first-entry trace |
| `src\SingleAnchor\BasketEconomics.cs` | constant-time valuations from the aggregates: raw profit (BUY at Bid, SELL at Ask), commission buffer, step money, executable profit at given close prices, projected P/L at a hard target, and the `TargetPrices` projections (upper: Bid = T_up, Ask = T_up + W; lower: Ask = T_down, Bid = T_down - W) |
| `src\SingleAnchor\HardBreakevenSizer.cs`, `VolumeMath.cs` | tail sizing: Q_BE, upward normalization, the broker-normalized requirement, verification, explicit infeasibility outcomes |
| `src\SingleAnchor\SingleAnchorEngine.cs` | the per-quote state machine (sections 14-16), host-independent; skips ambiguous first-entry quotes; verifies every tail fill before publishing it; faults on a strategy invariant or a data-quality failure; raises typed events; keeps the closed-basket records with anchor, leg, rejection and skipped-entry traces |
| `src\SingleAnchor\Execution.cs` | the all-or-nothing executor contract, the `ResearchExecutor`, the run-ending conditions, the hard-BE verification metadata, the rejection parity digest, event and trace records |
| `src\SingleAnchor\QuoteTickFeed.cs` | hands every LEAN quote tick of a slice to the engine in order; counts unused (non-quote) ticks; lets the engine's failures propagate |
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

Run under LEAN through the qualified helper. Four inputs have no value in the
specification: the step percent, the base lot, the target spread of the hard-BE
projection and the point value per lot. The host supplies the point value for
`XAUUSD` only (100), so for the shipped sample the other three must be given
and everything else has the specified default:

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1 `
    -AlgorithmTypeName SingleAnchorVNextAlgorithm `
    -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll `
    -Parameters "single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5"
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
| `single-anchor-step-percent` | P (section 2); 0 < P < 100 so the lower level stays positive | none, required |
| `single-anchor-base-lot` | B (section 4) | none, required |
| `single-anchor-normal-trade-count` | Nnormal (section 5) | 4 |
| `single-anchor-hard-be-ceiling-percent` | C (section 6) | 4.478 (research starting value, not an optimum) |
| `single-anchor-escape-enabled`, `-escape-profit-units`, `-escape-minimum-open-positions` | section 11 | true, 0.05, 2 (the minimum must be >= 2; higher values stay available for research) |
| `single-anchor-fixed-tp-units` | U_TP (section 12) | 0 (disabled) |
| `single-anchor-trailing-enabled`, `-trailing-activation-units`, `-trailing-drop-units` | section 13 | true, 0.50, 0.25 |
| `single-anchor-commission-buffer` | CommissionBuffer (section 9): Profit = RawProfit - CommissionBuffer | 0 (disabled) |
| `single-anchor-point-value-per-lot` | V (section 10) | 100 for the ticker `XAUUSD` only (100 oz per lot, USD account); required for any other ticker, the host carries no other instrument's economics |
| `single-anchor-volume-step`, `-minimum-volume`, `-maximum-volume` | V_step and broker limits (section 8) | 0.01, 0.01, 100 |
| `single-anchor-commission-per-lot` | round-trip commission per lot: in the executable projection (section 7) and in every realized result | 0 |
| `single-anchor-slippage` | adverse slippage per execution, price units: in the projection and in every fill (section 7) | 0 |
| `single-anchor-projected-spread` | W: the spread assumed at the hard boundary to reconstruct the opposite quote side of the projected simultaneous basket valuation (section 6); it never shifts the boundary itself | none, must be supplied; 0 is allowed |
| `single-anchor-buy-swap-per-lot-per-day`, `-sell-swap-per-lot-per-day` | financing (sections 7, 9, 17); must both be 0 in a strategy-qualified run | 0, 0 |
| `single-anchor-symbol`, `-market`, `-security-type` | host instrument; the host is XAUUSD-focused, another ticker is accepted only with its own explicit point value | `XAUUSD`, `oanda`, `Cfd` (`Forex` accepted) |
| `single-anchor-start-date`, `-end-date`, `-cash` | host run settings (`cash` only satisfies LEAN's setup; the strategy sizes in lots) | `2014-05-02`, `2014-05-14` (the shipped sample), 100000 |

## 4. Implementation choices and constraints

- **Ambiguous first-entry quote (resolved, specification section 3).** While the
  basket is empty, a quote satisfying both `Ask >= Upper` and `Bid <= Lower`
  starts nothing: no
  priority, no skip-as-trade, no double entry. A quote satisfying both boundaries
  necessarily has a spread of at least two grid steps, but spread width alone
  does not determine whether both boundaries are satisfied (a quote entirely
  above both levels can be two steps wide and satisfy only the BUY rule), so the
  engine evaluates the two inequalities directly. The quote is skipped, the basket
  stays empty, the anchor stays fixed and the run continues. The engine counts
  every skip (`skippedFirstEntryQuotes`) and keeps one compact trace per basket
  (first and last skipped quote, attempts, and a parity digest over every
  skipped quote) in the results. One event is raised
  when a basket first skips; later skips are counted on the trace, not logged
  per tick. After the first leg only the opposite side of the previous trade is
  evaluated, even on a quote that also satisfies the other boundary.
- **Hard-BE boundaries (resolved, specification section 6).** Basket BE is the
  level at which every open position closes at the same instant with total
  executable P/L zero. `T_up` is the maximum permitted upper BE Bid level and
  `T_down` the minimum permitted lower BE Ask level. They are hard boundaries,
  not necessarily the actual zero-loss BE: after upward volume normalization the
  actual BE normally lies inside the boundary, and that satisfies the rule
  `PL(T_up) >= 0` / `PL(T_down) >= 0`. The sizing valuation prices the
  simultaneous close at the boundary: upper recovery `Bid = T_up`,
  `Ask = T_up + W`; lower recovery `Ask = T_down`, `Bid = T_down - W`. `W` is
  the configured target spread, used only for the opposite side; the boundary is
  never shifted by it, nor by slippage or commission. The boundary is not an
  exit: the basket is closed only by escape, fixed TP or trailing (section 14),
  never automatically at its BE boundary.
- **`Smallest valid Q`.** With PL_1lot(T) > 0: Q_BE = -PL_existing / PL_1lot
  when PL_existing < 0, otherwise 0; the broker-normalized requirement is
  `ceil(max(Q_BE, minimum) / step) * step`, verified by direct recomputation of
  PL_after(T, Q) and stepped upward while negative; above the maximum volume the
  sizing is infeasible. With PL_1lot(T) <= 0 the ratio is not valid and more
  volume cannot help, so the only candidate is the minimum volume: it is placed
  when PL_after(T, minimum) >= 0 (the basket already projects at or inside the
  ceiling), otherwise the sizing is infeasible. This is a consequence of the
  primary rule (smallest valid Q with PL_after >= 0), not a separate strategy
  decision.
- **Infeasibility keeps the required lot.** `HardBreakevenSizing.NormalizedRequiredLot`
  is the **smallest broker-valid lot whose direct recomputation verifies**
  `PL_after >= 0`, retained even when it exceeds the maximum volume; if decimal
  rounding makes the ceil estimate one or more steps short, the verification
  fallback moves the reported requirement with the verified lot (the placed lot
  and the reported requirement are always the same number on a feasible sizing).
  `NormalizedLot` is 0 when nothing can be placed.
  The rejection trace carries both, so no infeasible case hides the needed lot.
  `ExactRequired` (and the leg/rejection traces' `ExactRequiredLot`) is null
  whenever `PL_1lot(T) <= 0`, because then there is no finite exact Q_BE; a
  minimum-volume leg placed while the basket already projects inside the
  boundary carries `ExactRequiredLot = null`, not zero.
- **Hard-BE verification after the fill, before publication.** The sizing uses
  the execution model and the research executor fills with exactly that model,
  so the projected and the actual entry price are the same number. The engine
  still recomputes the projected executable basket P/L at the fixed boundary
  with the actual fill after every tail leg. Only after that check does it raise
  the normal `EntryOpened` event. A negative value (only possible with an
  executor that departs from the model) is not a trading event: the engine
  records the fault first (and sets the run's
  `HardBEVerifiedUnderConfiguredExecutionModel` state to false), then raises the
  diagnostic `HardBreakevenViolated` (the leg stays
  in the ledger for the post-mortem, no `EntryOpened` is raised for it), then
  throws the `StrategyInvariantException` (`HardBreakevenViolatedByFill`) that
  stops the run, because continuing would be breakeven drift after hard-BE
  activation.
- **Financing is rejected (specification sections 7, 9, 17).** A non-zero
  `buy-swap-per-lot-per-day` or `sell-swap-per-lot-per-day` fails parameter
  validation: financing accrued after a tail entry moves the projected P/L at
  the hard boundary and the engine spends no quote re-verifying it, so such a run
  could violate the hard ceiling. The engine therefore has no financing accrual
  and no swap fields; zero is the only accepted configuration until continuous
  financing behaviour is specified.
- **Infeasible hard-BE and other rejected entries are traced (bounded
  episodes).** Every basket keeps one row per rejected-entry episode: trade
  number, side, reason and hard-BE outcome. The first attempt's quote (sequence,
  time, Bid, Ask) and full sizing figures are kept, the last attempt's quote and
  the attempt count are updated, and later attempts of the same episode are
  folded into that row, never stored per tick. The broker-normalized requirement
  is deliberately not part of the episode identity: it moves with every quote, so
  a requirement oscillating between adjacent volume steps (for example 0.06,
  0.07, 0.06, ...) stays one bounded row instead of one row per tick. The row
  carries the first attempt's normalized requirement for context, the min/max
  normalized requirement over the episode, and a
  deterministic FNV-1a 64-bit parity digest over the canonical tuple of every
  attempt (quote sequence, Bid, Ask, trade number, side, reason, outcome,
  candidate entry, PL_existing, PL_1lot, exact required lot, broker-normalized
  required lot, raw requested lot, PL_after; fields newline-terminated, enums by
  exact name, decimals in canonical numeric form: invariant culture, no
  exponent, insignificant trailing zeros removed, zero as `0`) plus min/max
  values of the exact required lot, PL_existing, PL_1lot and PL_after. The
  canonical decimal form means numerically equal values such as `1.2`, `1.20`
  and `1.200` hash identically, so the checksum compares strategy values rather
  than .NET decimal scales. A Python implementation can replay the same attempts
  and compare the digest to detect a divergence; a 64-bit checksum is a compact
  high-confidence mismatch detector, not a mathematical proof.
- **Skipped first-entry attempts carry the same kind of digest.** The
  `SkippedFirstEntryTrace` row folds every skipped quote into an FNV-1a 64-bit
  digest over quote sequence, Bid and Ask (canonical decimals as above) next to
  the first/last quote and the count, so a one-tick decision mismatch between two
  engines is detectable even when first quote, last quote and count agree.
- **Lot concepts are separate in the traces.** Arithmetic legs and rejections
  carry `RawRequestedLot` (B * n) and `NormalizedRequiredLots`; hard-BE legs and
  rejections carry `ExactRequiredLot` (Q_BE when the ratio applies) and
  `NormalizedRequiredLots`; a placed lot appears only as `PlacedLot` on a leg,
  and is null on a rejection. Exact required lots that exceed the maximum volume
  are still reported (for example Q_BE 0.054725... normalizes to 0.06 and stays
  0.06 even when the maximum is 0.05).
- **Repeated rejections do not allocate on the hot path (measured).** The engine
  decides whether an attempt is a new situation before building anything
  human-readable; the detailed message is only formatted for a new row (and
  raised to the host once). The sizing and rejection records are value types and
  the digest writer serializes fields directly into the accumulator, so a
  repeated rejected attempt allocates nothing (section 7: 0 bytes per attempt
  over a one-million-tick probe; the earlier class-based revision measured 808
  and 352 bytes per attempt).
- **Arithmetic lots** (trades 1..Nnormal) are normalized upward to the volume
  step (never below the requested B * n), raised to the minimum volume, and
  refused explicitly above the maximum.
- **Commission buffer** is exactly the flat amount of section 9.
- **Net exposure**: every leg is a whole number of volume steps (the ledger
  refuses anything else), so N is exact and "net-flat" is exactly zero, in which
  case E is the smallest open lot.
- **Anchoring quote**: it can satisfy an entry rule only when the step is inside
  the spread, and then it satisfies both; it is skipped like any ambiguous empty
  basket quote (above) and never opens a leg.
- **Executor contract**: all-or-nothing and immediate (an entry fills its whole
  volume at one price or fails; a close closes every leg or fails). A failed
  entry is an explicit rejection and the grid waits; a failed close ends that
  quote's processing (no entry on a quote whose exit fired) and the exit is
  re-evaluated on the next quote. The research executor never fails.
  Broker-style partial or deferred execution is out of scope (section 5).
- **Executable prices must be positive.** The hard-BE projection is invalid
  (`InvalidTargetPrices`, an explicit rejection) when the projected BUY close
  (Bid less slippage), the projected SELL close (Ask plus slippage) or the
  candidate entry is not positive; a close whose executable price is not
  positive fails explicitly and is retried; the mark-to-market reports no
  executable value in that case. The step percent is bounded below 100 so the
  lower level is always positive.
- **Realized results**: a closed basket records the decision quantities at the
  closing quote (raw profit, exit profit, threshold) and the realized executable
  result: BUY legs closed at Bid - slippage, SELL legs at Ask + slippage, less
  the round-trip commission on the gross volume.
- **Data quality is enforced by the engine itself.** Every quote tick of a
  slice reaches the engine in order; nothing is collapsed to the last tick.
  Non-quote ticks (trades) are unused and counted. A quote with a non-positive
  or crossed bid/ask, or one stamped earlier than a quote the engine already
  processed, faults the engine (`DataQualityException`, at the lowest layer, so
  no host can continue a supposedly valid deterministic replay after a market
  quote was lost): a path-dependent tick replay that skipped it would no longer
  be faithful, the run stops, and its result is written as not completed. Equal
  timestamps are in order. A faulted engine refuses every later quote.
- **Quote accounting has one meaning.** `QuotesProcessed` counts the quotes
  whose processing began (valid and in order), the count after a quote is that
  quote's sequence number in the traces, and `LastProcessedQuote` is the last
  such quote. A quote refused for data quality is neither counted nor assigned:
  `LastProcessedQuote` stays the last valid processed quote while `Fault.Quote`
  is the refused quote. A strategy invariant happens on a quote that was
  processed, so there `LastProcessedQuote` is the faulting quote. The end-of-data
  (or fault-time) mark to market uses `LastProcessedQuote`.
- **LEAN specifics.** LEAN delivers only ticks inside the market-hours sessions
  of its database (for Oanda XAUUSD: not the New York 16:58-18:03 break or the
  weekend); tick times are in the exchange time zone, which the results file
  names (`quoteTimeZone`). A strategy invariant or data-quality failure is
  logged, the results file is written with the failure recorded, and the
  exception is rethrown so LEAN ends the run as a runtime error (exit code 1;
  `OnEndOfAlgorithm` does not run in that case).

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
- **Financing / swap** until continuous financing behaviour is specified: the
  single-anchor engine currently rejects non-zero swap configurations instead
  of allowing the hard ceiling to drift after a tail entry.
- Replay, optimization, UI, charting, live trading, broker connectivity.
- A full performance report (equity curve, drawdown, per-basket statistics)
  and the Python/MT5 parity comparison from the strategy's own results; the
  results file below, with its per-leg trace, rejection parity digest and
  skipped-entry trace, is the input for both.
- A continuous hard-BE guarantee under a target spread wider than the
  configured one (a specification decision; section 4).
- Per-row UTC timestamps in the traces (the rows are in the named exchange
  time zone; the conversion is a host concern for the parity task).
- A `decimal` versus `double` benchmark of the per-quote path; the arithmetic
  stays exact `decimal` until a measured need says otherwise.

## 6. Results the strategy writes

LEAN's `<Algorithm>.json` / `-summary.json` report an empty portfolio (0 orders,
unchanged equity) and must not be read as strategy performance. The strategy's
own results are:

- the algorithm log (`<run dir>\<Algorithm>-log.txt`): anchors, the first
  skipped first-entry quote of each basket, every leg with its sizing line,
  every close with decision and realized figures, rejections and violations as
  `Error` lines, and the end-of-data summary with the open basket marked to
  market (raw, exit and executable profit; never closed);
- `<run dir>\storage\single-anchor\results.json` (written through LEAN's object
  store at the end of the run, or at the moment a strategy invariant or a
  data-quality condition fails): `completed` and, on a stop, `failure` (kind
  `StrategyInvariant` or `DataQuality`, the condition, the quote, the message);
  `hardBreakevenVerification` (`StrategyDefinitionResolved`,
  `HardBEVerifiedUnderConfiguredExecutionModel`, scope, assumptions, what is
  not covered); the symbol, market and `quoteTimeZone`; the parameters; quote
  ticks processed and non-quote ticks unused; `lastProcessedQuote`; legs
  opened; skipped first-entry quotes; distinct rejected entries and attempts;
  baskets closed; the realized profit total; one record per closed basket
  (sequence number, `AnchorEvent`, created and closed times, the closing
  quote's sequence number, Bid and Ask, anchor, reason, lots, decision and
  realized figures, close prices, commission) with its `LegTrace`,
  `RejectionTrace` and `SkippedFirstEntryTrace`; and `openBasket`, the complete
  state of the current basket with its `AnchorEvent`, geometry, targets, legs,
  last side, next trade number, lots, hard-BE and trailing state, its valuation
  when it has legs, and its own `LegTrace`, `RejectionTrace` and
  `SkippedFirstEntryTrace` (a zero-leg anchored basket is represented with its
  anchor event). The `AnchorEvent` of every basket is the exact source quote
  (sequence number, time, Bid and Ask) and the derived anchor, step, upper,
  lower and both hard-BE boundaries. A `LegTrace` row carries basket number, trade
  number, the triggering quote's sequence number, time, decision Bid and Ask,
  side, `PlacedLot`, fill price, sizing regime, `RawRequestedLot`,
  `ExactRequiredLot`, `NormalizedRequiredLot` and, for a tail leg, the hard-BE
  boundary, the target spread, the projected Bid/Ask used, PL_existing(T),
  PL_1lot(T) and the projected P/L after the leg. A `RejectionTrace` row
  carries the lot distinction, the first attempt's full sizing figures, the
  attempt count and last quote, the parity digest and the min/max aggregates.
  A `SkippedFirstEntryTrace` row carries the first and last skipped quote, the
  attempt count and a parity digest over every skipped quote. Quote sequence
  numbers make same-timestamp ticks
  distinguishable; per-row times are in `quoteTimeZone`.

## 7. Validation record (2026-09-21, Windows, .NET SDK 10.0.401)

Software-use evidence only: nothing here is evidence of profitability, of the
sample's data quality or of a sensible parameter choice. The target spread
`0.5` below is an example value above the sample's usual spread (median 0.28,
99th percentile 1.6, widest 2.65), not a calibration.

- `dotnet build MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj --configuration Release`:
  0 errors; 0 compiler warnings from the two MarketLab projects (the referenced
  upstream projects print their own analyzer warnings, as recorded for the
  engine build).
- `dotnet test MarketLab\tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj --configuration Release`:
  132 passed, 0 failed, 0 skipped.
- `MarketLab\tests\Test-MarketLabBacktesting.ps1` (fast mode): 150 passed,
  0 failed.
- `pwsh -File MarketLab\scripts\run-backtest.ps1 -AlgorithmTypeName SingleAnchorVNextAlgorithm
  -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll
  -Parameters "single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5"`
  (default dates 2014-05-02..2014-05-14): helper exit code 0, 0 failed data
  requests, 0 engine `ERROR::` lines; 1,688,736 quote ticks processed (every
  in-window tick of the sample inside LEAN's market hours; 0 non-quote), 21
  legs, 11 baskets closed (9 by trailing, 2 by escape), 0 rejected entries,
  0 skipped first-entry quotes, realized profit 17.752; at the end of data a
  7-leg hard-BE basket (#12, buy 0.08 / sell 0.09 / net -0.01 lots, raw profit
  -43.167) reported marked to market, not closed; `results.json` (31,542 bytes)
  written with `completed: true`, both `hardBreakevenVerification` flags true,
  no owner-decision block, an `AnchorEvent` per basket whose anchor equals the
  midpoint of its source quote, and leg 5 (SELL, lower recovery) and leg 6
  (BUY, upper recovery) recomputed by hand under the new semantics:
  - leg 5 SELL: T_down = 1250.19480166, Bid = T_down - 0.5 = 1249.69480166,
    Ask = T_down = 1250.19480166, PL_existing = -146.56139668, PL_1lot =
    5597.21983400, Q_BE = 0.026184677... -> normalized requirement 0.03,
    PL_after = 21.35519834;
  - leg 6 BUY: T_up = 1367.41119834, Bid = T_up = 1367.41119834, Ask =
    T_up + 0.5 = 1367.91119834, PL_existing = -96.36119834, PL_1lot =
    5590.01983400, Q_BE = 0.017238078... -> normalized requirement 0.02,
    PL_after = 15.43919834;
  LEAN's own report: 0 orders, End Equity 100,000.
- Rejection-heavy configuration, same command plus
  `,single-anchor-hard-be-ceiling-percent:0.1` (the tail boundary sits between
  the entry level and the anchor, so the required side cannot reach breakeven):
  helper exit code 0; 18 legs, 11 baskets closed, realized profit 17.752;
  1 distinct rejected-entry situation over 985,370 attempts folded into 1 row
  with `reason=HardBreakevenInfeasible`, `outcome=NonPositiveMarginalProfit`,
  a 16-character parity digest, its algorithm string and min/max aggregates;
  `results.json` 31,387 bytes (no per-tick rows; the same episode also carries the min/max broker-normalized requirement).
- Wide-first-entry configuration, same command with
  `single-anchor-step-percent:0.1` (the previously run-ending case): helper exit
  code 0; the quote 1275.507 / 1278.152 (spread 2.645) on 2014-05-02 08:30:01 is
  skipped, counted once (`skippedFirstEntryQuotes: 1`) and folded into one
  compact `SkippedFirstEntryTrace` (attempts 1, parity digest
  `5902baf022001a2c`); the run completes with 21 legs,
  6 baskets closed, realized profit 3.080 and an open 14-leg basket;
  `results.json` 26,745 bytes.
- Independent allocation probe (temporary console project outside the
  repository, 1,000,000 trigger ticks with a persisting hard-BE rejection):
  0 bytes allocated per rejected attempt and ~1.17 microseconds per tick, one
  rejection row; ordinary no-action ticks allocate 0 bytes and cost ~60 ns.
  (The same probe measured 808 bytes per attempt for the earlier class-based
  revision that formatted a message on every attempt, and 352 bytes after the
  message was made lazy but before the sizing and rejection records became value
  types.)
- Determinism: two identical runs of the shipped configuration produce
  byte-identical `results.json` (SHA-256
  `5A3F4D39A1E1E815AB5D3155836EDD9F8DB7ACE67E4D21AD1C5DFFFB90AA3502`).
