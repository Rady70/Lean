# SingleAnchor vNext: C# implementation notes

The behavioural specification is
[SINGLE_ANCHOR_VNEXT_STRATEGY.md](SINGLE_ANCHOR_VNEXT_STRATEGY.md); this note only
says where the implementation lives, how it is built and tested, which
implementation choices it makes, and what is deferred. Nothing outside
`MarketLab\` is modified; the upstream engine, solution and projects are
unchanged.

The approved next-phase historical research roadmap is
[SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md](SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md). It is deliberately separate from this record of already-implemented behaviour.

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
| `src\SingleAnchor\HistoricalSessions.cs` | the source-derived session junction rule, the session map contract (load/save/derive) and its provenance; section 8 |
| `src\SingleAnchor\HistoricalTradingAvailability.cs` | the five-minute quote-only buffer rule and the per-quote classifier (section 8) |
| `src\SingleAnchor\QuoteTickFeed.cs` | hands every LEAN quote tick of a slice to the engine in order; counts unused (non-quote) ticks; lets the engine's failures propagate |
| `tools\session-map\` | the `MarketLab.SessionMapTool` generator that derives a session map from the immutable Dukascopy/JForex XAUUSD CSV history and counts the quote-only rows (section 8) |
| `src\SingleAnchor\SingleAnchorVNextAlgorithm.cs`, `ParameterParsing.cs` | the `QCAlgorithm` host: XAUUSD CFD quote ticks, LEAN parameters, event logging, end-of-data mark to market, results file |
| `tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj` | NUnit tests on deterministic synthetic quotes (same NUnit / test SDK versions as upstream's `Tests` project) |
| `tests\Test-TradingAvailabilityEndToEnd.ps1` | end-to-end check through the real LEAN helper: a synthetic native tick fixture where a quote-only buffer quote is suppressed with the session map and trades without it (section 8.6) |

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
  A fallback start outside the range the sizer can produce, where a further volume
  step cannot even increase the lot, fails explicitly instead of being reported as
  a verified sizing.
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
  episodes).** Every basket keeps one row per rejected-entry episode. The episode
  key consists of trade number, side, rejection reason and hard-BE outcome; raw
  Bid/Ask values and the broker-normalized required volume are not part of the
  key.
  The first attempt's quote (sequence,
  time, Bid, Ask) and full sizing figures are kept, the last attempt's quote and
  the attempt count are updated, and every attempt of the episode is
  folded into that row, never stored per tick. Matching scans the basket's rows
  (newest first), so an episode that reappears after another episode appends to
  its existing row. For a given trade/side, only the finite reason/outcome
  combinations can create rows; a quote may change the outcome and therefore
  select another episode, but once that episode exists, later recurrence appends
  to it rather than creating another row, so a hovering price cannot grow the row
  count with the tick count. Across trades, the rejection trace can grow with the
  number of distinct filled trade numbers reached by the basket, but repeated
  ticks for an already-known trade/reason/outcome episode append to the existing
  row instead of creating a row per tick.
  Two quote-dependent quantities deliberately
  stay out of the key: the broker-normalized requirement (it moves with every
  quote, so 0.06, 0.07, 0.06 stays one row) and the economic figures. The
  hard-BE outcome itself is quote-dependent (PL_1lot crosses zero at
  `Ask = T_up - commission/V`), so a hovering price can alternate
  `NonPositiveMarginalProfit` and `ExceedsMaximumVolume`; that is bounded to one
  row per outcome (two rows total for that pair), not one row per tick. The row
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
  matches the attempt to its episode before building anything
  human-readable; the detailed message is only formatted for a new row (and
  raised to the host once). The sizing and rejection records are value types and
  the digest writer serializes fields directly into the accumulator, so a
  repeated rejected attempt allocates nothing: `HardBreakevenSizing`,
  `EntryRejection` and `EntryOrder` are value types and the message is not
  formatted (section 7: 0 bytes per attempt over one-million-tick probes for a
  stable hard-BE outcome, for an outcome alternating between two episodes, and
  for repeats where the executor fails; the earlier class-based revision measured
  808 and 352 bytes per hard-BE attempt, and a probe of the class-based
  `EntryOrder` measured 304 bytes per failed-execution attempt).
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

- **Historical XAUUSD data for research**: no dataset was ingested in this
  repository and no new or synthetic data is committed. The shipped 2014
  sample remains an engine fixture used for software-use evidence only
  (section 7). The MarketLab-owned offline qualification and conversion path
  now exists and **PR 1 is implemented, merged and locally validated**
  (`MarketLab\tools\historical-data\README.md`): it strictly qualifies a
  historical bid/ask CSV against this strategy's quote contract, writes native
  `cfd\oanda\tick\xauusd` partitions into a research data folder outside Git,
  and verifies the delivered stream through the unchanged LEAN engine; a
  research history still needs its own provenance, licensing and integrity
  record, and only a qualification PASS may precede a strategy run. The user's
  real dataset has not been qualified yet; PR 2 remains the next implementation
  phase after that data-path exercise.
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
  139 passed, 0 failed, 0 skipped.
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
- Independent allocation and boundedness probe (temporary console project
  outside the repository, 1,000,000 trigger ticks each): a persisting hard-BE
  rejection allocates 0 bytes per attempt and stays one row; an outcome
  alternating between `ExceedsMaximumVolume` and `NonPositiveMarginalProfit`
  (ask alternating 2089.48 / 2089.50 around `T_up - commission/V`) allocates
  0 bytes per attempt and stays two rows, 500,000 attempts each, with one digest
  per outcome; repeats where the executor fails allocate 0 bytes per attempt and
  stay two rows. Ordinary no-action ticks allocate 0 bytes and cost ~60 ns.
  (The same probe measured 808 bytes per attempt for the earlier class-based
  revision that formatted a message on every attempt, and 352 bytes after the
  message was made lazy but before the sizing and rejection records became value
  types.)
- Determinism: two identical runs of the shipped configuration produce
  byte-identical `results.json` (SHA-256
  `5A3F4D39A1E1E815AB5D3155836EDD9F8DB7ACE67E4D21AD1C5DFFFB90AA3502`).

## 8. Historical trading availability: source-derived sessions and five-minute quote-only buffers

The historical Dukascopy/JForex replay separates two properties of a quote that were previously
the same thing:

- **delivered**: LEAN read the quote from the native tick partition and handed it to the strategy
  (`QuoteTickFeed` -> `SingleAnchorEngine.OnQuote`). This gate changes nothing about delivery; it
  neither adds nor removes a delivered quote. Whether every legitimate source quote is delivered
  is a separate data-path property, and on the current research data folder it is **not** yet true
  (section 8.7); no claim in this document should be read as source-to-strategy completeness until
  that blocker is resolved and PR-1 passes.
- **strategy-eligible**: the quote may drive the strategy (anchor, entries, exits, trailing,
  rejections, ledger, events). The first and last five minutes of every source-derived session are
  quote-only: the strategy observes them and accounts for them, but acts on nothing until the next
  eligible quote, evaluated from its own fresh Bid/Ask. Nothing crossed during a buffer is queued.

The five-minute width is an explicit research assumption (fixed, not configurable); the source
carries no broker session definition, so it is not a claim about historical broker times. The
availability restriction never removes a quote from the data path and never changes the PR-1
contract (section 8.5).

### 8.1 Source-derived sessions

A session is a maximal run of observed quotes bounded by session junctions. A gap between
consecutive quote runs is a junction when it fully contains the New York local settlement interval
`17:00:00 <= t < 18:00:00` (`America/New_York`), strict on the last-tick side and inclusive on the
next-tick side. The rule is implemented once, in `src\SingleAnchor\HistoricalSessions.cs`
(`SessionJunctionRule`), and follows the named zone: every daylight-saving transition, holiday
closure, shortened day, delayed reopening and month file boundary is captured by the observed
source itself. No separate holiday calendar, DST calendar or fixed UTC session time exists in the
path.

For each session `T0` is the exact timestamp of the first observed quote and `T1` the exact
timestamp of the last one (millisecond precision, no rounding). Two dataset boundaries are
explicit: the first session starts at the first observed quote of the dataset, and the final
session's natural end is unobservable, so the map records no end for it and no close is
fabricated. A null end means "no closing buffer", **not** "unbounded": the source coverage end
(the dataset's last observed quote) still bounds the final session, and a quote after it is
refused (section 8.2). The first session's start is the dataset's first observed quote; it is the
observed start, not a claim about the true market open.

The rule time zone and the quote clock are separate concepts. The junction rule is evaluated in
New York (`America/New_York`, recorded as `junctionTimeZone`), while a replay may deliver quotes
in any clock LEAN resolves for the subscription; the UTC session boundaries are converted once, at
load, into whatever quote clock the run uses (`ToAvailability`), and no equality between the two
zones is required.

The map is a contract file (`marketlab-single-anchor-session-map-v1`) of ordered UTC sessions plus
source provenance: file count, row count, the aggregate SHA-256 over the per-file hashes and the
first and last observed quote. That is the semantic source identity; the machine directory of the
source is deliberately not part of the map, so identical data at another path produces the same
bytes. `HistoricalSessionMap.Derive` builds the map from ordered segments (rejecting unordered or
overlapping ones); `Load`/`Save` implement the file contract. `Load` is strict because the map is
a research-critical input: the contract, the v1 junction-rule text, the junction time zone,
ordered sessions whose adjacent pairs are actually separated by the settlement-window junction
(so an edited map cannot split a run at an arbitrary intraday gap and invent buffers), and a
complete, coherent source provenance block (positive counts, a 64-hex aggregate, first quote
equal to the first session's start, and, when the final session has an observed end, a coverage
end equal to it) are all required. The loader validates structure, not derivation: a coherent
hand edit cannot be cryptographically ruled out, so the map's SHA-256 and its source lineage are
recorded with every run's results.

### 8.2 The five-minute rule

`HistoricalTradingAvailability` classifies each quote in the quote clock:

| Interval | Classification |
|---|---|
| `T0 <= t < T0 + 5min` | quote-only (opening buffer) |
| `T0 + 5min <= t <= T1 - 5min` | tradable |
| `T1 - 5min < t <= T1` | quote-only (closing buffer) |

Exact millisecond boundaries: `t = T0` and `t = T0 + 4m59.999s` are quote-only, `t = T0 + 5m` is
tradable, `t = T1 - 5m` is tradable, `t = T1 - 4m59.999s` and `t = T1` are quote-only. A quote
after the source coverage end, before the first session, or in a gap a malformed map does not
describe is a deliberate run failure (`SessionMapException`, structured results), not a silent
classification.

### 8.3 The engine gate

The gate sits inside `SingleAnchorEngine.OnQuote`, after the data-quality validation and before the
delivery accounting, and before any strategy work. For a quote-only quote the engine:

- classifies it, then counts and records it as before (`QuotesProcessed++`, `LastProcessedQuote`
  update);
- increments `QuoteOnlyQuotes` and returns, so it does **not** create or reset an anchor, open or
  reject an entry, size a leg, close or fail to close a basket, activate or advance trailing,
  advance the sequence, touch rejection bookkeeping, raise a strategy event, or change realized
  P/L; the skipped-first-entry trace is untouched too;
- the end-of-data mark to market still uses the last delivered quote.

A quote outside the map's coverage faults the engine (`SessionMapException`, condition
`QuoteOutsideMapCoverage`) before it is counted or assigned, exactly like a data-quality fault;
the host writes structured results with `failure.kind = "SessionMap"` instead of stopping without
evidence.

`StrategyEligibleQuotes == QuotesProcessed - QuoteOnlyQuotes` counts quotes permitted to evaluate
strategy logic (most cause no trade), not executed actions. The results file reports
`quoteTicksProcessed` (delivered), `quoteOnlyQuotes`, `strategyEligibleQuotes` and a `sessionMap`
provenance block: the configured parameter value (not the resolved absolute path), the map's
SHA-256, symbol, junction time zone, session count, first session start, final-end observability,
and the source's file count, row count, aggregate SHA-256, first quote and coverage end. A reduced
eligible count can never be read as missing historical quotes. Without the
`single-anchor-session-map` parameter the engine has no availability: `QuoteOnlyQuotes` is 0 and
every delivered quote is eligible, exactly the previous behaviour.

### 8.4 The generator

`MarketLab\tools\session-map\` (`MarketLab.SessionMapTool`) derives the map from the immutable
monthly CSV history with the same rule and classifier types the strategy uses, in two streaming
passes (segments + provenance; then per-row availability counting). Build and run:

```powershell
dotnet build MarketLab\tools\session-map\MarketLab.SessionMapTool.csproj --configuration Release
MarketLab\tools\session-map\bin\Release\MarketLab.SessionMapTool.exe `
    --source D:\quant_research_workspace\common\market_data\raw\XAUUSD_raw_history `
    --out D:\quant_research_workspace\work\lean\single-anchor-sessions\xauusd-sessions.json `
    --stats D:\quant_research_workspace\work\lean\single-anchor-sessions\xauusd-sessions-stats.json
```

The source is read-only and the output is deterministic (same source, same map and stats). Only a
legitimate quote may define a session boundary: pass 1 parses the timestamp and the Bid/Ask
columns and requires the engine's own contract (positive Bid and Ask, `Ask >= Bid`), so a
timestamp-valid but price-invalid row cannot move a five-minute boundary. The map's symbol is the
source's own symbol read from the file names, never a hardcoded instrument label, so a directory
of another instrument's files can never produce a map that claims to be XAUUSD. The stats file
keeps the overall and complete-session populations separate with their own percentages, because
the final, dataset-end session contributes opening-buffer rows but no closing buffer.

The map is placed outside Git (or copied under a research data folder) and named in the run with
`single-anchor-session-map`; the value cannot contain `:` on the helper's `-Parameters` route, so
the relative-to-data-folder form is the practical one (see
[tools/session-map/README.md](tools/session-map/README.md)).

### 8.5 PR-1 impact

None. `SingleAnchorReplayProbeAlgorithm` and the qualification tooling are untouched and know
nothing about sessions; the probe builds its engine without an availability, so
`engine_quotes_processed == accepted` and the semantic digests keep their exact meaning. The
five-minute restriction is an execution-time property of the strategy run, not a source
qualification rule; no source row is excluded, filtered, redescribed or converted differently.

### 8.6 Full-history validation (2026-09-23, Windows, .NET SDK 10.0.401)

`MarketLab.SessionMapTool` over the 90-file immutable Dukascopy/JForex XAUUSD source
(413,750,130 rows, `D:\quant_research_workspace\common\market_data\raw\XAUUSD_raw_history`,
first quote `2019-01-01T23:00:07.151Z`, last `2026-06-30T23:59:59.678Z`, wall time 103-125 s;
every row passed the generator's timestamp and Bid/Ask contract validation):

- **1,935 sessions, 1,934 junctions** — exactly the previously established segmentation; 1,934
  sessions have an observable end and the final session (dataset end) has none.
- **exact-timestamp buffer counts** for the complete sessions: 817,808 opening + 529,041 closing =
  **1,346,849 quote-only rows = 0.325522 %** of all source rows; the final session adds 802
  opening-buffer rows and has no closing buffer (**1,347,651 quote-only rows overall =
  0.325716 %**). The map is byte-identical across runs (SHA-256
  `33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949`).
- The investigation's published **1,339,139 (0.323659 %)** was reproduced exactly by re-running
  the investigation's own counter against the current `sessions.json` (same totals, by year and
  by class), so the evidence is internally consistent. Its scan recorded gap endpoints at whole
  minutes (`start = last covered minute + 59 s`, `end = next covered minute`), so its `T0`/`T1`
  are minute-quantized approximations; the agreed model requires the exact observed timestamps,
  which is why the implementation counts 7,710 more quote-only rows (+3,994 opening, +3,716
  closing). Under the quantized map 1,768 source rows even fall after a recorded end and before
  the next session start (outside every window); the exact map has no such rows. The difference
  is a boundary-precision artifact of the earlier scan, not a rule difference.
- DST: the 15 US transitions in the dataset are handled by the named zone with no fixed UTC
  adjustment (unit tests cover both a spring-forward and a fall-back weekend; the full map's
  session boundaries track the observed New York clock at every transition).
- Known large intraday gaps (2019-03-10, 2019-07-04, 2019-09-02, 2024-10-09, 2025-03-03,
  2025-11-28, 2025-12-01, and the other gaps catalogued in the earlier investigation) remain
  inside their sessions; none became a session junction.

End-to-end replay check on the converted 2023-03 research data folder (a short
2023-03-01..2023-03-05 window, `single-anchor-session-map:marketlab-sessions/xauusd-sessions.json`):
helper exit code 0, 437,741 delivered quote ticks, 351 classified quote-only, 437,390
strategy-eligible; the same window without the map delivered the identical 437,741 quotes with 0
quote-only and produced the same strategy outcome on this window (no trigger happened to fall in a
buffer). The log and `storage\single-anchor\results.json` carry the map provenance and the three
counts.

A second, behavioral end-to-end check runs through the real helper on a synthetic native tick
fixture and proves the host path (map loading, quote-clock conversion, feed wiring, engine gate)
as a unit: `powershell -File MarketLab\tests\Test-TradingAvailabilityEndToEnd.ps1` (12 checks,
exit 0). On its five-quote fixture the identical delivered count (5) yields one BUY without the
map and no position with it (4 quote-only, 1 eligible), and the results carry the configured map
value and the source row count. The strategy unit tests are 167 (see section 7 plus the new
availability, coverage-end, provenance, junction-consistency, grid/reversal-buffer and
out-of-coverage failure tests, and the generator symbol/quote-contract tests).

### 8.7 Quote delivery on the current research data folder (separate blocker, not fixed here)

The strategy-side availability removes no delivered quote, but it cannot restore quotes the LEAN
data path filtered out before the strategy. On the current research data folder the resolved
runtime session identity/hours clip legitimate source ticks at both session edges (in the earlier
real-data PR-1 exercise, 6,798 accepted rows in 2023-03 were never delivered because the resolved
Oanda XAUUSD entry ends the New York day at 16:58 and reopens at 18:03). Until that identity is
corrected, "every legitimate Dukascopy quote is in the strategy stream" is **not** true
end-to-end, and PR-1 on the full history would not pass.

Resolving it is deliberately out of scope for this feature and for this branch: the replay's
market/data identity and session definition must allow every legitimate source tick, and the
proper source-appropriate LEAN identity for the Dukascopy history is a separate decision to be
made and validated with the data owner. This section records the blocker; it prescribes no
broker-specific calendar and no maintained holiday list.
