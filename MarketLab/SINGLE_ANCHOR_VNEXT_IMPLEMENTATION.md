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
| `src\SingleAnchor\SingleAnchorEngine.cs` | the per-quote state machine (sections 14-16), host-independent; verifies every tail fill; faults on a strategy invariant or a data-quality failure; raises typed events; keeps the closed-basket records with anchor, leg and rejection traces |
| `src\SingleAnchor\Execution.cs` | the all-or-nothing executor contract, the `ResearchExecutor`, the run-ending conditions, the hard-BE guarantee metadata, event and trace records |
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
and everything else has the specified default (section 3):

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
| `single-anchor-escape-enabled`, `-escape-profit-units`, `-escape-minimum-open-positions` | section 11 | true, 0.05, 2 |
| `single-anchor-fixed-tp-units` | U_TP (section 12) | 0 (disabled) |
| `single-anchor-trailing-enabled`, `-trailing-activation-units`, `-trailing-drop-units` | section 13 | true, 0.50, 0.25 |
| `single-anchor-commission-buffer` | CommissionBuffer (section 9): Profit = RawProfit - CommissionBuffer | 0 (disabled) |
| `single-anchor-point-value-per-lot` | V (section 10) | 100 for the ticker `XAUUSD` only (100 oz per lot, USD account); required for any other ticker, the host carries no other instrument's economics |
| `single-anchor-volume-step`, `-minimum-volume`, `-maximum-volume` | V_step and broker limits (section 8) | 0.01, 0.01, 100 |
| `single-anchor-commission-per-lot` | round-trip commission per lot: in the executable projection (section 7) and in every realized result | 0 |
| `single-anchor-slippage` | adverse slippage per execution, price units: in the projection and in every fill (section 7) | 0 |
| `single-anchor-projected-spread` | the configured spread assumed at the hard target (section 7, "configured ... spread"); the hard-BE requirement is verified under it only (section 4) | none, must be supplied; 0 is allowed (a sensitivity case: nothing in the arithmetic needs a positive spread) |
| `single-anchor-buy-swap-per-lot-per-day`, `-sell-swap-per-lot-per-day` | swap/financing (sections 7, 9); non-zero values are not qualified against the hard ceiling (section 4) | 0, 0 (no accrual) |
| `single-anchor-swap-rollover-time`, `-triple-swap-day` | rollover clock for swap; the time as `HHmm`/`HHmmss` (LEAN's `--parameters` splits on `:`, so `17:00` only works through the config file) | `1700`, `Wednesday` (`none` to disable) |
| `single-anchor-symbol`, `-market`, `-security-type` | host instrument; the host is XAUUSD-focused, another ticker is accepted only with its own explicit point value | `XAUUSD`, `oanda`, `Cfd` (`Forex` accepted) |
| `single-anchor-start-date`, `-end-date`, `-cash` | host run settings (`cash` only satisfies LEAN's setup; the strategy sizes in lots) | `2014-05-02`, `2014-05-14` (the shipped sample), 100000 |

## 4. Choices the specification leaves open

Each of these is explicit in code and covered by a test. Two of them are
**unresolved owner decisions**: the implementation had to do something, what it
does is stated here and in every results file (`openOwnerDecisions`), and it is
not the strategy until the owner decides. The specification itself is not
changed to fit the implementation.

- **UNRESOLVED OWNER DECISION 1: what T_up / T_down means as a price.** The
  specification defines T_up = A * (1 + C/100) and T_down = A * (1 - C/100) as
  the "maximum permitted ... basket breakeven price" and requires the tail
  calculation to use executable basket economics "including configured bid/ask
  execution side, spread, commission, slippage, swap/financing"; it does not
  say which price T is, nor which spread value applies at T. The
  implementation reads T as a midpoint and splits a configured target spread
  (`projected-spread`, an input; never the spread of the sizing quote)
  symmetrically around it: projected Bid = T - spread/2, projected Ask = T +
  spread/2. BUY legs are projected to close at that Bid less slippage, SELL
  legs at that Ask plus slippage; the candidate leg enters at the current Ask
  plus slippage (BUY) or Bid less slippage (SELL); the round-trip commission is
  charged per lot on every leg, existing and new; accrued swap is included,
  future swap is not projected. This reading (midpoint, configured spread split
  around it) is an implementation choice awaiting the owner's decision, not a
  rule of the specification.
- **What the hard-BE requirement covers, precisely.** `PL_after(T, Q) >= 0` is
  verified once, immediately after each tail entry, with the actual fill, under
  the configured target spread, the configured slippage and commission and the
  swap accrued up to that entry. It is never re-verified afterwards. It does not
  cover a spread wider than the configured one when the market reaches the
  target, financing accrued after the entry, or any other change of the
  execution model between the entry and the target; in those cases the basket
  can be below breakeven at the target although no rule was broken, and the
  specification defines no response. The results carry this as
  `hardBreakevenGuarantee` (scope, assumptions, what is not covered, and
  `Qualified`): a run is qualified only when nothing in its configuration can
  move the projected result after the entry, which today means zero swap; a run
  with non-zero swap is written as not qualified, with the reason, so it never
  looks like a zero-swap run. A conservatively calibrated target spread is the
  research-side answer to the spread caveat; no corrective rule is added for
  either caveat.
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
  after every tail leg. A negative value (only possible with an executor that
  departs from the model) is not a trading event: the engine records the fault
  first, then raises the diagnostic `HardBreakevenViolated` (the leg stays in
  the ledger for the post-mortem), then throws the `StrategyInvariantException`
  (`HardBreakevenViolatedByFill`) that stops the run, because continuing would
  be breakeven drift after hard-BE activation.
- **Infeasible hard-BE and other rejected entries are traced.** Every basket
  keeps one row per distinct rejected-entry situation (trade number, side,
  reason, hard-BE outcome and normalized required lot): the first attempt's
  quote (sequence, time, Bid, Ask), the requested or required lot, the
  normalized lot, and for a hard-BE rejection the target, the target spread,
  the projected Bid/Ask, PL_existing(T), PL_1lot(T) and the projected PL_after.
  Later attempts of the same situation are counted on that row with the last
  attempt's quote, not stored per tick (a requirement that stays infeasible for
  hours would otherwise produce hundreds of thousands of rows); a materially
  changed requirement is a new row. The rows are part of the closed-basket
  records and of the open-basket snapshot.
- **Infeasible hard-BE.** No order is placed, hard-BE mode stays active, an
  `EntryRejected` event with the full sizing record is raised (the algorithm
  logs it with `Error`), the situation is re-evaluated on every later trigger
  quote and reported again when trade number, side, reason, outcome or the
  required lot after normalization change; the count of attempts is kept.
  Nothing is ever converted into a smaller lot.
- **Arithmetic lots** (trades 1..Nnormal) are normalized upward to the volume
  step (never below the requested B * n), raised to the minimum volume, and
  refused explicitly above the maximum.
- **Commission buffer** is exactly the flat amount of section 9.
- **Net exposure**: every leg is a whole number of volume steps (the ledger
  refuses anything else), so N is exact and "net-flat" is exactly zero, in
  which case E is the smallest open lot.
- **UNRESOLVED OWNER DECISION 2: a first-entry quote that satisfies both
  boundaries** (an empty basket, Ask >= Upper and Bid <= Lower, a spread of at
  least two grid steps). The specification defines no rule for this case and
  the owner has not decided its treatment. Nothing is added: no BUY priority,
  no SELL priority, no "skip this quote", no double entry. Because a
  deterministic implementation must do something, the engine currently stops
  the run (`StrategyInvariantException`, `BothBoundariesSatisfied`, naming the
  quote, the spread and the levels; LEAN exit code 1). **That stop is interim
  behaviour, not an approved rule and not part of the strategy**; the owner
  decides how such a quote is to be treated. After the first leg the required
  side is fixed and the question does not arise. On the shipped sample the
  widest spread is 2.65, so a 0.1 % step (about 1.28 on a 1,280 anchor) meets
  the condition on 2014-05-02 08:30:01 and stops; the validation run in
  section 7 uses 0.2 %, which does not meet it.
- **Anchoring quote**: it can satisfy an entry rule only when the step is
  inside the spread, and then it satisfies both (decision 2 above); it never
  opens a leg.
- **Swap** accrues per leg at each rollover instant (`swap-rollover-time` in the
  quote clock) that ends a Monday-Friday trading day; the rollover ending the
  `triple-swap-day` charges three times; a leg opened at or after the instant
  is charged from the next one. LEAN's Oanda XAUUSD quotes are stamped in New
  York time, hence the 17:00 default. The rollover pass is per leg (audit) but
  runs at most once a day; every per-quote valuation is constant-time.
  **Limitation, stated precisely:** the hard-BE requirement is verified
  immediately after each tail entry only. Financing accrued at later rollovers
  enters the basket's projected P/L at the target and can make it negative
  again, and nothing re-verifies or corrects that (the specification defines no
  response). Non-zero swap is therefore not qualified against the hard ceiling
  for the time between entries; the default is zero and the algorithm logs a
  notice at start when swap is configured. Defining a continuous guarantee is a
  specification decision, not taken here (the same holds for a spread wider
  than the configured one at the target, see the guarantee item above).
- **Executor contract**: all-or-nothing and immediate (an entry fills its whole
  volume at one price or fails; a close closes every leg or fails). A failed
  entry is an explicit rejection and the grid waits; a failed close ends that
  quote's processing (no entry on a quote whose exit fired) and the exit is
  re-evaluated on the next quote. The research executor never fails.
  Broker-style partial or deferred execution is out of scope (section 5).
- **Executable prices must be positive.** The hard-BE projection is invalid
  (`InvalidTargetPrices`, an explicit rejection) when the projected BUY close
  (target Bid less slippage), the projected SELL close (target Ask plus
  slippage) or the candidate entry is not positive; a close whose executable
  price is not positive fails explicitly and is retried; the mark-to-market
  reports no executable value in that case. The step percent is bounded below
  100 so the lower level is always positive.
- **Realized results**: a closed basket records the decision quantities at the
  closing quote (raw profit, exit profit, threshold) and the realized executable
  result: BUY legs closed at Bid - slippage, SELL legs at Ask + slippage, plus
  accrued swap, less the round-trip commission on the gross volume.
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
  such quote; on a fault it is the faulting quote, which the failure record
  also carries. The feed keeps no second count. The end-of-data (or fault-time)
  mark to market uses `LastProcessedQuote`.
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
- Replay, optimization, UI, charting, live trading, broker connectivity.
- A full performance report (equity curve, drawdown, per-basket statistics)
  and the Python/MT5 parity comparison from the strategy's own results; the
  results file below, with its per-leg trace, is the input for both.
- A continuous hard-BE guarantee under non-zero financing or a target spread
  wider than the configured one (a specification decision; section 4).
- Per-row UTC timestamps in the traces (the rows are in the named exchange
  time zone; the conversion is a host concern for the parity task).
- The two owner decisions of section 4 (the meaning of T_up / T_down as a
  price; the treatment of a first-entry quote satisfying both boundaries).
  Neither is resolved by this implementation.
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
  store at the end of the run, or at the moment a strategy invariant or a
  data-quality condition fails): `completed` and, on a stop, `failure` (kind
  `StrategyInvariant` or `DataQuality`, the condition, the quote, the message);
  `hardBreakevenGuarantee` (`Qualified`, scope, assumptions, what is not
  covered, the reasons when not qualified); `openOwnerDecisions` (the two
  unresolved decisions of section 4 with the interim behaviour); the symbol,
  market and `quoteTimeZone`; the parameters; quote ticks processed and
  non-quote ticks unused; `lastProcessedQuote`; legs opened; rejections;
  baskets closed; the realized profit total; one record per closed basket
  (sequence number, `AnchorEvent`, created and closed times, the closing
  quote's sequence number, Bid and Ask, anchor, reason, lots, decision and
  realized figures, close prices, swap, commission) with its `LegTrace` and
  `RejectionTrace`; and `openBasket`, the complete state of the current basket
  with its `AnchorEvent`, geometry, targets, legs, last side, next trade
  number, lots, swap, hard-BE and trailing state, its valuation when it has
  legs, and its own `LegTrace` and `RejectionTrace` (a zero-leg anchored basket
  is represented with its anchor event). The `AnchorEvent` of every basket is
  the exact source quote (sequence number, time, Bid, Ask) and the derived
  anchor, step, upper, lower and both hard-BE targets. A `LegTrace` row carries
  basket number, trade number, the triggering quote's sequence number, time,
  decision Bid and Ask, side, lots, fill price, sizing regime, accrued swap and,
  for a tail leg, the hard-BE target, the target spread and projected Bid/Ask
  used, PL_existing(T), PL_1lot(T), the required lot and the projected P/L
  after the leg. A `RejectionTrace` row is described in section 4. Quote
  sequence numbers make same-timestamp ticks distinguishable; per-row times are
  in `quoteTimeZone`.

## 7. Validation record (2026-09-21, Windows, .NET SDK 10.0.401)

Software-use evidence only: nothing here is evidence of profitability, of the
sample's data quality or of a sensible parameter choice. The target spread
`0.5` below is an example value above the sample's usual spread (median 0.28,
99th percentile 1.6, widest 2.65), not a calibration. The parameter sets do not
meet the unresolved both-boundaries condition (decision 2).

- `dotnet build MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj --configuration Release`:
  0 errors; 0 compiler warnings from the two MarketLab projects (the referenced
  upstream projects print their own analyzer warnings, as recorded for the
  engine build).
- `dotnet test MarketLab\tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj --configuration Release`:
  138 passed, 0 failed, 0 skipped.
- `pwsh -File MarketLab\scripts\run-backtest.ps1 -AlgorithmTypeName SingleAnchorVNextAlgorithm
  -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll
  -Parameters "single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5"`
  (default dates 2014-05-02..2014-05-14): helper exit code 0, 0 failed data
  requests, 0 engine `ERROR::` lines; 1,688,736 quote ticks processed (every
  in-window tick of the sample inside LEAN's market hours; 0 non-quote), 21
  legs, 11 baskets closed (9 by trailing, 2 by escape), 0 rejected entries,
  realized profit 17.752; at the end of data a 7-leg hard-BE basket (#12, buy
  0.08 / sell 0.09 / net -0.01 lots, raw profit -43.167) reported marked to
  market, not closed; `results.json` (34 KB) written with `completed: true`,
  `hardBreakevenGuarantee.Qualified: true`, both open owner decisions, an
  `AnchorEvent` per basket whose anchor equals the midpoint of its source quote
  (checked for all 11), the open-basket snapshot with its anchor event and leg
  trace (the last tail row recomputes by hand: target 1250.1948, projected
  Bid/Ask 1249.9448 / 1250.4448 at spread 0.5, required lot 0.0183 -> 0.02);
  LEAN's own report: 0 orders, End Equity 100,000. Wall time 25 s (LEAN's own
  figure 23.4 s); no throughput claim is made from one timing.
- The same with `,single-anchor-maximum-volume:0.02,single-anchor-buy-swap-per-lot-per-day:-1.5`
  appended, to exercise the rejection trace and the guarantee metadata: exit
  code 0; 22 legs, 17 baskets closed, 3 distinct rejected-entry situations over
  685,505 attempts (every third arithmetic trade exceeds the 0.02 maximum and
  stays rejected while the price holds beyond the level); `results.json`
  (41 KB): `hardBreakevenGuarantee.Qualified: false` with the swap reason, 3
  rejection rows in total (2 in closed baskets, 1 on the open basket) whose
  `Attempts` sum to 685,505, each with its first and last quote (sequence,
  time, Bid, Ask), trade number, side, reason and lots.
- The same with `single-anchor-step-percent:0.1` (earlier revision, same code
  path): the run stops on 2014-05-02 08:30:01 with `BothBoundariesSatisfied`
  (quote 1275.507 / 1278.152, spread 2.645, step 1.277), LEAN runtime error,
  helper exit code 1, `results.json` with `completed: false`, the failure, the
  baskets closed before it and the anchored basket's state. This is the interim
  behaviour of decision 2, not an approved rule.
- `single-anchor-symbol:EURUSD,single-anchor-market:fxcm,single-anchor-security-type:Forex`
  without `single-anchor-point-value-per-lot`: LEAN exit code 1,
  "single-anchor-point-value-per-lot must be given for EURUSD ...".
- Without `single-anchor-projected-spread`, or without the other required
  inputs: LEAN exit code 1 with the validation message; with dates outside the
  sample: exit code 3 (failed data requests), 0 quotes processed.
- `MarketLab\tests\Test-MarketLabBacktesting.ps1` (fast mode): unchanged
  helper, 150 passed, 0 failed.
