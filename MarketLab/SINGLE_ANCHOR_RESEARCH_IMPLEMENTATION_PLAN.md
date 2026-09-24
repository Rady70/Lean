# SingleAnchor vNext: historical research implementation plan

Status: approved implementation plan for the next research-qualification phase.

Implementation note (finalization record, not a plan change): PR 1
(historical dataset qualification and exact native-LEAN replay) is implemented
and merged, and PR 7 implements the source-derived trading availability for the
historical replay (source-derived sessions, the five-minute quote-only buffers
at session ends, and delivered-versus-eligible accounting; see
SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md section 8) and is merged with this note.
PR 7 changes no strategy formula and no PR 1 qualification semantics. The PR 1
replay-identity gate (section 3.6) is now resolved: the real Dukascopy/JForex
source replays under a MarketLab-derived always-open `XAUUSD/dukascopy/Cfd`
runtime identity, so LEAN's session filter removes no legitimate source quote.
The known 2023-03 case now delivers every accepted row: 4,465,226 accepted =
converted = delivered = probe-processed, source and delivered semantic digests
equal, zero session drops (the Oanda fixture identity previously clipped 6,798
rows). The full historical dataset completed the 90-month qualification sweep
(2019-01..2026-06) on 2026-09-24: 90/90 months PASS, accepted = converted =
delivered = probe-processed = 413,750,130 rows, 0 rejected rows, 0 session
drops, every per-partition count/digest and per-month ordered digest equal. The
tooling qualifies one source file per run; the per-month records and the
aggregate summary stay outside Git, and the result is recorded in
`tools/historical-data/README.md`. PR 2 is the next implementation phase.

This document is the authoritative implementation roadmap after the current
SingleAnchor vNext C# strategy implementation. It does not change strategy
behaviour. The behavioural authority remains
SINGLE_ANCHOR_VNEXT_STRATEGY.md and the implemented behaviour is described in
SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md.

The purpose of this plan is to make the existing C# strategy suitable for
credible historical qualification using the user's clean CSV tick history,
while preserving the current architecture:

~~~text
historical source
      |
      v
MarketLab-owned data qualification/conversion
      |
      v
LEAN -- data/time host only, unchanged
      |
      v
QuoteTickFeed
      |
      v
SingleAnchorEngine -- authoritative strategy state
      |
      +--> ResearchExecutor
      +--> research account / analytics
      +--> margin-survival model
      |
      v
MarketLab-owned research results
~~~

## 1. Non-negotiable boundaries

1. Nothing outside MarketLab/ is modified for this work. Upstream LEAN source,
   projects, solution files, Launcher behaviour and portfolio implementation
   remain unchanged.
2. The backtest hot path remains C#. Python is not called from
   SingleAnchorEngine, QuoteTickFeed, ResearchExecutor, account tracking,
   analytics, or margin calculations.
3. LEAN remains the historical data/time host. The strategy does not place LEAN
   orders and does not use LEAN portfolio holdings as strategy truth.
4. Basket and BasketLeg remain the authoritative position ledger. No imported
   account or analytics component may create a second position registry.
5. The current C# SingleAnchor vNext implementation remains the only
   authoritative implementation of the current strategy. The retired Python
   SingleAnchor strategy is not migrated.
6. The trade-5+ hard-BE rule remains hard. This plan does not introduce a soft
   ceiling, BE drift, or a later regime in which BE is allowed to drift.
7. NormalTradeCount remains 4 and HardBreakevenCeilingPercent remains 4.478 as
   the current research starting value unless a later approved research step
   changes them. 4.478 is not documented as optimal or universal.
8. Historical data are local research assets and remain outside Git.
9. Validation is Windows/local. Do not add hosted CI, automatic sanitizer runs,
   automatic PR lint/architecture/scope workflows, or other hosted pre-merge
   automation.
10. Avoid framework-building for its own sake. Implement only the capability
    needed by the SingleAnchor qualification path.

## 2. Retired repositories: approved sources

The retired repositories are source material, not runtime dependencies.

Use these pinned repository states when migrating behaviour:

- Rady70/quant_research_app
  commit 36a977fae0942cf49f856a3c9c3aa7aaba7f2dbb
  Primary source for mature market-data timestamp, CSV, quality and related
  utilities.
- Rady70/quant_research_platform
  commit a5b64625a549da6d136f3491f7219fbddffdd35d
  Semantic reference for account and analytics behaviour.
- Rady70/single_anchor_research
  commit 0f2aca3cc87f2b368a8ccfbe8814e94b1d78763a
  Reference for SingleAnchor research schemas, basket/path metrics,
  reproducibility conventions and execution-accounting tests.

For every migrated source file or behaviour, record:

- source repository;
- source commit SHA;
- source path;
- MarketLab destination path;
- adaptations made.

Do not copy all three projects wholesale. Prefer the latest generalized
market-data implementation from quant_research_app, use
quant_research_platform as a semantic reference for account/analytics, and use
single_anchor_research only for SingleAnchor-specific reporting and research
contracts that remain useful.

## 3. Implementation sequence

Implement this plan as three bounded pull requests. Each pull request must be
independently reviewable and must not change upstream LEAN code.

### PR 1 -- historical dataset qualification and exact native-LEAN replay

Goal: prove that the historical CSV accepted by the qualification path is
represented and delivered to the C# strategy exactly under the declared native
LEAN constraints.

#### 3.1 Scope

Add MarketLab-owned offline tooling under a path such as:

~~~text
MarketLab/tools/historical-data/
~~~

Migrate only the retired Python capabilities actually required for the CSV
qualification/conversion path, expected to include:

- timestamp parsing and source-timezone normalization;
- CSV/header/delimiter utilities;
- deterministic data-quality profiling;
- rejected-row diagnostics;
- transactional/atomic output publication where useful;
- focused tests for the migrated behaviour.

Do not automatically migrate the retired Parquet/monthly archive stack,
seekable archive reader, archive composition system, or PyArrow dependency.
Those components solve a broader problem and should only be brought over if a
concrete requirement later needs them.

Add a MarketLab-owned CSV-to-native-LEAN converter and a LEAN-delivery parity
probe.

Python is allowed here because this is an offline preparation step performed
before the backtest. Python must not participate in the per-tick runtime once
LEAN starts.

#### 3.2 Authoritative qualification contract

The authoritative SingleAnchor input contract for research is:

~~~text
Bid > 0
Ask > 0
Ask >= Bid
timestamp is valid
timestamps are non-decreasing
equal timestamps are allowed
source order is preserved
~~~

This deliberately permits zero spread because the current C# Quote contract
permits Ask == Bid.

Do not blindly reuse the stricter retired archive validator that rejects zero
spread. The retired code contains two legacy policies: canonical archive
validation rejects Ask == Bid while the data-quality workflow accepts it. This
project resolves that difference in favour of the current C# strategy input
contract.

The authoritative qualification path is strict:

~~~text
source
  -> validate
  -> PASS or FAIL
  -> convert only after PASS
~~~

It must not:

- silently discard invalid rows;
- sort;
- deduplicate;
- interpolate;
- fill;
- repair timestamps;
- normalize away duplicate timestamps;
- alter source order.

Cleaning/profile tooling may remain available to diagnose another raw source,
but the dataset used for an authoritative research run must fail qualification
if rows are rejected.

#### 3.3 Exact price preservation

Prices used by the converter must be based on exact decimal text, not a
binary64 float round trip.

The retired data-quality workflow already retains accepted bid/ask source text
for clean CSV output. The new converter should consume the preserved decimal
text directly using an exact decimal representation and write values that LEAN
parses into the same decimal numbers.

The semantic parity tuple is conceptually:

~~~text
source ordinal
canonical timestamp
exact decimal Bid
exact decimal Ask
~~~

Float-based statistics remain acceptable for diagnostic profile values such as
mean/median spread, but float is not the authority for converted strategy
prices.

#### 3.4 Timestamp precision gate

Native LEAN quote-tick files encode time as milliseconds since midnight. The
source qualification therefore reports before conversion:

- count of source rows with sub-millisecond precision;
- count of distinct-source timestamps that collide into one LEAN millisecond;
- maximum rows mapping to one LEAN millisecond.

If every accepted source timestamp is exactly representable at millisecond
precision, native-LEAN exact timestamp parity can proceed.

If any accepted source timestamp contains meaningful sub-millisecond precision,
do not silently round, truncate, or reject the historical source as bad.
Instead the native-LEAN exact replay qualification fails with an explicit
reason such as:

~~~text
NativeLeanTimestampParity = FAIL
Reason = SourcePrecisionExceedsLeanTickFormat
~~~

That failure stops the authoritative native-LEAN conversion/run until a
separate decision is made about how to handle the higher-precision source.

#### 3.5 LEAN timezone and partition semantics

Do not assume UTC milliseconds or use ExchangeTimeZone as the file encoding
timezone.

Resolve the actual LEAN subscription configuration and record both:

- DataTimeZone;
- ExchangeTimeZone.

The conversion path is:

~~~text
source timestamp
  -> canonical UTC
  -> LEAN DataTimeZone
  -> DataTimeZone-local YYYYMMDD file partition
  -> milliseconds since DataTimeZone-local midnight
~~~

LEAN then performs its normal conversion from DataTimeZone to ExchangeTimeZone
when reading the native file.

The converter must derive/verify these values from the actual LEAN runtime data
configuration rather than hardcoding a timezone.

The qualification record must also identify the actual runtime market-hours
database used locally, including its SHA-256, and record the resolved
XAUUSD/Oanda data timezone, exchange timezone and market-hours/session rules.

#### 3.6 Session-filter gate

Physical rows in native LEAN files and quote ticks delivered to the algorithm
are different assertions. LEAN can apply subscription/session filtering.

Record:

- clean accepted source rows;
- converted native-LEAN rows;
- LEAN session-eligible rows if deterministically observable;
- LEAN-delivered quote rows;
- session-excluded rows/differences.

For exact strategy replay qualification, require that no accepted source quote
is silently removed by LEAN session semantics unless an explicit later decision
declares LEAN session filtering to be part of the intended source semantics.

At minimum:

~~~text
LEAN delivered rows == accepted source rows
~~~

must hold for a normal exact-replay PASS.

If it does not hold, stop and investigate the differences before historical
strategy research.

Resolution note (implementation record): the gate is satisfied for the real
source by the source-appropriate `XAUUSD/dukascopy/Cfd` replay identity with a
MarketLab-derived always-open, holiday-free runtime identity prepared from the
engine fixtures and recorded with source/derived SHA-256 provenance. The source
stream then defines the sessions; LEAN requests every calendar day, and days
with no accepted source rows are recorded as `source_absent_days` evidence
rather than failures. Session-bounded identities (the Oanda engine fixture)
keep the original `SourceCoverageGap` failure path, which the end-to-end test
still exercises. See `tools/historical-data/README.md` sections 5-6.

#### 3.7 Provenance and manifest

Produce a deterministic semantic qualification manifest containing at least:

- source file path/identity suitable for a local record;
- source file SHA-256;
- source file size;
- converter Git SHA;
- LEAN Git SHA;
- actual runtime market-hours database SHA-256;
- source timestamp representation;
- source timezone contract;
- resolved DataTimeZone;
- resolved ExchangeTimeZone;
- raw row count;
- accepted row count;
- rejected row count;
- out-of-order count;
- duplicate timestamp count;
- sub-millisecond row count;
- same-LEAN-millisecond collision count;
- maximum rows per LEAN millisecond;
- first and last canonical UTC timestamps;
- spread min/max/mean/median diagnostics;
- per-day accepted and converted row counts;
- hash of the uncompressed LEAN CSV members;
- ordered semantic digest of accepted source tuples;
- ordered semantic digest of LEAN-delivered tuples after interpreting delivered tick.Time in the resolved ExchangeTimeZone and normalizing it back to canonical UTC;
- LEAN-delivered row count;
- session-filter difference count.

A deterministic ZIP byte hash may also be recorded if trivial to produce, but
ZIP-container byte identity is not a qualification blocker. Semantic content
and delivered-stream identity are the authority.

#### 3.8 Actual LEAN replay probe

The acceptance test must exercise the real LEAN path rather than only unit-test
the converter.

The probe must compare the qualified source stream against the quote stream
actually delivered through LEAN/QuoteTickFeed. For semantic comparison, treat
the delivered tick.Time in its resolved ExchangeTimeZone context and normalize
it back to canonical UTC before hashing/comparing it with the qualified source
timestamp. Prices use canonical exact-decimal text/value semantics. The probe
must establish:

~~~text
accepted count     == delivered count
Bid                == expected exact decimal Bid
Ask                == expected exact decimal Ask
timestamp          == expected timestamp within native LEAN precision contract
ordering           == expected source ordering
same-ms ordering   == expected ordering
first/last quote   == expected
semantic digest    == expected
~~~

Any mismatch is a qualification failure.

#### 3.9 PR 1 acceptance criteria

PR 1 is complete when:

1. only MarketLab-owned files change;
2. the migrated tooling records pinned provenance;
3. zero-spread semantics match the C# strategy;
4. strict qualification performs no silent cleaning/sorting/deduplication;
5. decimal prices are preserved exactly;
6. timestamp precision is measured before conversion;
7. DataTimeZone/ExchangeTimeZone and runtime market-hours identity are recorded;
8. actual LEAN delivery is compared with accepted source rows;
9. an exact-replay PASS is impossible when rows/prices/order/session delivery
   differ;
10. tests pass on Windows/local;
11. no hosted CI or upstream LEAN modification is introduced.

PR 1 is implemented and merged (see the implementation note at the top); PR 2 is the next implementation phase.

### PR 2 -- C# research account view and bounded analytics

Goal: add the useful retired account/analytics capabilities to the C# runtime
without creating a second trading ledger or materially degrading backtest
throughput.

#### 3.10 Architecture

Basket/BasketLeg remain position truth.

The research account component is a derived view/accumulator, not another
position store. Its core values are derived from the existing strategy engine
and BasketEconomics.

Conceptually:

~~~text
SingleAnchorEngine
      |
      +--> Basket / BasketLeg              position truth
      |
      +--> BasketEconomics                 executable valuation
      |
      +--> ResearchAccount / Analytics     derived state + extrema only
~~~

Do not copy quant_research_platform/account.py literally because that retired
object owns positions. Reuse its semantics where helpful, not its ownership
model.

Avoid a second independently accumulated realized-P/L authority. The current
engine's realized result remains authoritative.

#### 3.11 Account P/L definitions

Define account values precisely:

~~~text
Balance =
    InitialBalance + SingleAnchorEngine.RealizedProfit

FloatingPL =
    current executable basket mark-to-market
    using configured execution economics

Equity =
    Balance + FloatingPL
~~~

For account equity/drawdown/survival, FloatingPL means executable economic P/L,
including modeled close-side slippage and CommissionPerLot as represented by
the existing C# execution/economics model.

CommissionBuffer is an exit-decision threshold adjustment only. It is not an
account loss and must not be subtracted from account equity.

#### 3.12 Required run-level analytics

Track in constant time where possible:

- initial balance;
- current/final balance;
- current/final equity;
- realized P/L;
- executable floating P/L;
- peak balance;
- maximum balance drawdown;
- peak equity;
- maximum equity drawdown;
- current/maximum open positions;
- current/maximum gross lots;
- current/maximum absolute net lots;
- maximum executable floating loss;
- maximum executable floating profit.

Normal research mode should retain aggregates and basket records, not one
object per tick.

#### 3.13 Required per-basket research record

Retain at least:

- basket id;
- anchor time;
- first-entry time;
- close/end time;
- duration from first entry;
- first side;
- entry count;
- deepest trade number;
- maximum open positions;
- maximum gross lots;
- maximum absolute net lots;
- maximum individual placed lot;
- maximum executable floating profit;
- maximum executable floating loss;
- close reason;
- realized executable P/L;
- whether hard-BE mode activated;
- first hard-BE trade number;
- largest exact required tail lot;
- largest normalized required tail lot;
- largest placed tail lot;
- hard-BE rejected attempts;
- hard-BE rejection episodes;
- rejection counts by reason/outcome.

Preserve the existing distinction between:

~~~text
ExactRequiredLot
NormalizedRequiredLot
PlacedLot
~~~

Do not collapse repeated attempts and compact rejection episodes into one
ambiguous metric.

#### 3.14 Observation timing

Analytics must define when extrema are observed so entry/exit ticks are not
lost.

At minimum, basket extrema must observe:

1. the current incoming quote valuation before an exit can remove the basket;
2. the post-entry valuation after a newly opened leg is added and its immediate
   execution costs affect executable P/L.

This instrumentation must not alter the strategy's existing decision priority
or create a replacement basket on a closing tick.

#### 3.15 Performance constraints

The normal per-quote path should remain O(1) using existing basket aggregates.
Do not loop all legs every tick when an aggregate calculation already exists.

Do not:

- create detailed report objects every tick;
- format strings every tick;
- write CSV/JSON every tick;
- call Python;
- create an independent per-position accounting ledger.

Use bounded run/basket retention. A diagnostic/audit mode may retain more data
for short fixtures if required, but high-volume research mode stays compact.

Benchmark before and after PR 2 using the same representative C# tick fixture
and same parameters:

- Release build;
- one warm-up run;
- 3-5 measured runs;
- median wall-clock duration;
- median ticks/second;
- managed allocations attributable to analytics.

Acceptance also requires strategy-path parity with analytics enabled vs
disabled:

- same anchors;
- same entries;
- same lots;
- same rejections;
- same closes;
- same realized strategy P/L;
- same end-of-data basket state.

Set any numerical throughput-regression threshold after measuring baseline
variance rather than inventing one in advance. A material unexplained slowdown
is a defect to fix, not an expected cost to accept.

### PR 3 -- target-account margin survival

Goal: answer whether the configured account could finance and survive the
strategy path. This is a MarketLab research layer, not LEAN portfolio/margin.

#### 3.16 Prerequisite: freeze broker/account rules first

Do not implement a generic broker simulator before the target rules are known.

Before PR 3 implementation, document the target account/broker rules:

- account currency;
- XAUUSD contract size;
- leverage;
- margin formula;
- price used for margin;
- hedged-position margin rule:
  full both sides, largest leg, reduced hedge margin, unmatched exposure, or
  another explicit rule;
- margin-call threshold;
- stop-out threshold;
- account-currency conversion rule if needed;
- broker min/max/step lot rules that materially differ from current settings;
- intended insufficient-free-margin behaviour.

For XAUUSD in a USD account this can remain focused and simple.

#### 3.17 One account authority

PR 3 extends the same research account state introduced by PR 2. Do not add
another Balance/Equity owner.

Conceptually:

~~~text
ResearchAccount
    Balance
    FloatingPL
    Equity
        |
        v
MarginModel
    UsedMargin
    FreeMargin
    MarginLevel
~~~

#### 3.18 Entry feasibility

The strategy first computes the actual candidate lot under existing sizing
rules, including hard-BE sizing. Margin is then evaluated against the projected
post-fill basket/account:

~~~text
strategy lot decision
      |
      v
candidate actual lot + candidate execution price
      |
      v
projected post-fill BUY/SELL inventory
      |
      v
margin feasibility under configured hedge rule
      |
      +--> feasible -> ResearchExecutor
      |
      '--> insufficient margin -> explicit rejection
~~~

Do not calculate incremental margin as candidate lot times a simple leverage
formula independently of the existing hedged inventory unless that is exactly
the frozen broker rule.

#### 3.19 Failure semantics

Keep these conditions distinct:

HardBreakevenInfeasible:
the strategy cannot produce a broker-valid lot satisfying the hard-BE rule.

InsufficientMargin:
the strategy produced a valid candidate order but the configured research
account cannot finance it.

On InsufficientMargin:

- no leg is added;
- trade number does not advance;
- required side remains unchanged;
- hard-BE mode remains active if already activated;
- later eligible quotes may retry;
- the event is recorded separately from hard-BE infeasibility and generic
  execution failure.

#### 3.20 Margin-call and stop-out

On every incoming quote, before allowing strategy actions that could rescue the
account, use the explicitly frozen survival order unless the actual broker rule
requires something else:

~~~text
1. revalue executable account equity
2. calculate current used margin / free margin / margin level
3. evaluate stop-out
4. if alive, allow normal strategy exit/entry processing
~~~

Margin call can initially be diagnostic.

For the first survival implementation, stop-out should be terminal unless the
broker's exact liquidation algorithm is known and explicitly approved:

~~~text
margin level reaches stop-out
    -> record terminal stop-out
    -> mark research account/run failed for survival
    -> stop strategy research execution
~~~

Do not invent ticket-liquidation ordering, partial liquidation or broker
intervention merely to continue the simulation.

#### 3.21 Risk-disabled parity

Margin/risk must be configurable off.

With risk disabled, require exact strategy-path parity with the current merged
vNext engine:

- same anchors;
- same entries;
- same lots;
- same rejections;
- same closes;
- same realized strategy P/L;
- same final open-basket state.

The expanded results file may contain additional research fields, so byte
identity of the entire results JSON is not required.

## 4. After PR 3: freeze before historical research

After PR 1-3 pass review, freeze the backtester before parameter research. The
freeze includes the qualified data identity: the authoritative historical runs
use the `XAUUSD/dukascopy/Cfd` subscription prepared by
`MarketLab\tools\historical-data` (`single-anchor-symbol XAUUSD`,
`single-anchor-market dukascopy`, `single-anchor-security-type Cfd`). The
in-code defaults (`XAUUSD/oanda/Cfd`, the shipped 2014 fixture dates) are
software-use fixtures only; a real historical baseline that omits
`single-anchor-market dukascopy` is not a valid run under this plan (section 6
and section 7).

The resulting architecture is:

~~~text
historical CSV
      |
      v
strict offline qualification
      |
      v
native LEAN tick files + manifest
      |
      v
LEAN -- unchanged data/time host
      |
      v
QuoteTickFeed
      |
      v
SingleAnchorEngine vNext -- authoritative C# strategy
      |
      +--> ResearchExecutor
      +--> ResearchAccount/Analytics
      '--> MarginModel
      |
      v
MarketLab research results
~~~

## 5. Full historical data qualification

Before the first strategy baseline run, execute PR 1 qualification across the
full historical source.

The qualification report should make long gaps and coverage anomalies visible
by day/month and must preserve the local source identity/hash.

Only a PASS under the declared replay contract may proceed to the baseline
strategy run. The baseline strategy run reads that qualified data folder under
the same identity it was qualified with: `single-anchor-symbol XAUUSD`,
`single-anchor-market dukascopy`, `single-anchor-security-type Cfd`. Running
the baseline against the Oanda fixture default in a qualified Dukascopy data
folder would resolve a different subscription identity and is not a valid
baseline.

PR 1 qualifies one source file per run and writes one native data folder per
run, so the 90-month full-history qualification is a decomposed acceptance of
the data and not itself one continuous LEAN data tree. After PR 2 and PR 3 and
before the frozen baseline, compose the already-qualified daily partitions into
a single continuous research data folder under the same derived identity,
carrying over each partition's hash and the qualification identity, and re-run
the replay probe over the composed folder to prove its delivery equals the
concatenated per-month qualification evidence. Do not run 90 independent
monthly strategy runs and treat that as the full-history baseline; that
composition step is deliberately out of scope for PR 1.

The historical files themselves remain outside Git.

## 6. Freeze the complete baseline configuration

Do not run a supposedly authoritative baseline with only:

~~~text
NormalTradeCount = 4
HardBreakevenCeilingPercent = 4.478
~~~

Freeze one complete immutable baseline configuration including at least:

- data identity: `single-anchor-symbol = XAUUSD`, `single-anchor-market =
  dukascopy`, `single-anchor-security-type = Cfd`, with the qualified
  `XAUUSD/dukascopy/Cfd` data folder — the single composed continuous folder
  from section 5, not the 90 per-run qualification folders (the Oanda fixture
  default is not a research configuration);
- the qualified start/end dates and, when used, the source-derived
  `single-anchor-session-map`;
- StepPercent;
- BaseLot;
- NormalTradeCount = 4;
- HardBreakevenCeilingPercent = 4.478;
- escape settings;
- fixed TP settings;
- trailing settings;
- ProjectedSpread;
- CommissionPerLot;
- Slippage;
- PointValuePerLot;
- InitialBalance;
- MinimumVolume;
- VolumeStep;
- MaximumVolume;
- margin enabled/disabled;
- ContractSize;
- Leverage;
- hedged-margin rule;
- margin-call threshold;
- stop-out threshold.

Do not promote fixture-only values to research defaults. In particular, the
representative fixture's projected spread and its example step percent/base lot
are not automatically approved research settings.

BaseLot is a risk-scale parameter once account survival/margin is modeled. It
must either be frozen by an explicit risk policy before geometry sweeps or be
studied later as a separate risk dimension.

## 7. First full-history run: qualification baseline, not optimization

The first frozen full-history strategy run exists to characterize the current
strategy, not select parameters.

Report at least:

- total baskets;
- basket-depth histogram for every observed depth;
- grouped depth summaries such as 5+ and 10+ where useful;
- percentage of baskets closing after 1, 2, 3 and 4 trades;
- count/rate of baskets reaching trade 5+;
- longest basket duration;
- worst executable floating loss;
- best executable floating profit;
- maximum gross lots;
- maximum absolute net lots;
- maximum individual placed lot;
- hard-BE activation count/rate;
- first hard-BE trade distribution if useful;
- largest exact required tail lot;
- largest normalized required tail lot;
- largest placed tail lot;
- hard-BE rejected attempts;
- hard-BE rejection episodes;
- hard-BE rejection reasons/outcomes, including non-positive marginal profit,
  maximum-volume infeasibility and invalid target-price cases if observed;
- maximum equity drawdown;
- maximum balance drawdown;
- minimum margin level;
- insufficient-margin rejections;
- margin-call observations;
- terminal stop-out, if any;
- final unresolved basket state;
- realized P/L and end-of-run mark-to-market equity.

Do not claim account survival from drawdown/exposure metrics if PR 3 is disabled.

## 8. Parameter research only after baseline audit

Do not optimize StepPercent or HardBreakevenCeilingPercent against the complete
history and then present that same history as validation evidence.

Before the first parameter sweep:

1. define development, validation and untouched holdout periods, or an approved
   rolling/walk-forward equivalent;
2. freeze the selection criteria;
3. keep execution assumptions such as commission/slippage/spread as sensitivity
   scenarios rather than values chosen to maximize profit.

The research hierarchy should prioritize survival/feasibility before raw
profit, for example:

~~~text
1. no stop-out
2. feasible tail behaviour
3. acceptable maximum drawdown/exposure
4. acceptable basket-resolution characteristics
5. profit
~~~

This is a research ordering, not an already-approved numerical threshold set.
Any thresholds used for selection must be fixed before reviewing the candidate
results.

Initial geometry research may study:

- StepPercent;
- HardBreakevenCeilingPercent.

BaseLot must already be frozen by risk policy or treated explicitly as a
separate position-scale dimension.

## 9. Deferred unless evidence requires them

Do not add these in PR 1-3 unless a concrete test demonstrates they are
necessary:

- LEAN source modifications;
- Python calls inside the per-tick runtime;
- a second strategy implementation;
- a second position/account ledger;
- native LEAN order placement;
- generalized multi-asset portfolio margin;
- order-book depth or queue simulation;
- partial fills;
- asynchronous order states;
- variable network latency;
- speculative broker liquidation sequencing;
- a generic optimization framework;
- a new Parquet/archive framework already solved by retired projects;
- hosted CI.

Execution-delay sensitivity such as next-tick or deterministic fixed-delay
scenarios can be added after the baseline if the research question requires it.

## 10. Definition of completion for this roadmap phase

This phase is complete only when:

1. the user's historical CSV has a retained qualification PASS under the exact
   declared native-LEAN replay contract;
2. the current vNext strategy receives the qualified stream through actual
   LEAN with proven count/order/price/timestamp semantics;
3. the C# research account and bounded analytics produce audited run/basket
   metrics without changing the strategy path;
4. the configured target account's margin/survival rules are modeled without
   using LEAN portfolio holdings;
5. risk-disabled runs reproduce the current strategy path exactly;
6. performance remains suitable for multi-year tick research;
7. a complete baseline configuration is frozen;
8. one untouched full-history baseline run is completed and audited before
   parameter optimization begins.

Until those gates pass, historical output is engineering/qualification evidence,
not proof of strategy edge or an optimized parameter set.
