# SingleAnchor baseline configuration freeze: decision audit

Audit date: 2026-09-27 (Windows, .NET SDK 10.0.401 environment as in the
previous records). Audit base revision:
`bdf3c29a4e1b20be4110a6c9e75ecff9e00856f3` (the PR #13 finalization commit).

Finalization record: the audit is complete and merged through GitHub PR #14
(reviewed head `8811d20e3d6c701842c5086beee0f141b7886dfe`, merge commit
`261912d6cbda495c90ea68f578d3952fe3bba699`).

Project state after this audit:

```text
continuous historical-data qualification: complete
continuous native-history composition/replay qualification: complete (PR #13)
baseline configuration decision audit: complete and merged through PR #14
baseline configuration frozen: no (blocked on the eight decisions below)
first untouched full-history strategy baseline: not run
parameter optimization: not started
```

This document records the baseline-decision audit required before the first
authoritative continuous full-history SingleAnchor run. It classifies every
baseline-relevant value into the project's four audit classes, binds the
approved portion to the already-qualified data identity, and exposes every
value that still needs an explicit decision. The machine-readable register
inventories 65 baseline fields (49 class A, 8 class B, 8 class D) plus 21
fixture/example values (class C).

It is **not** the frozen baseline contract. No complete, runnable baseline
configuration exists yet: seven baseline-critical values and one run-procedure
policy have no approved authoritative value (section 10), so the machine-readable
decision register at
[`config/baseline-decision-audit.json`](config/baseline-decision-audit.json)
carries `baselineConfigurationFrozen: false` and must never be consumed as a run
configuration. The executable Windows-local check that keeps this audit, the
implementation and the qualified data identity aligned is
[`tests/SingleAnchor/BaselineDecisionAuditTests.cs`](tests/SingleAnchor/BaselineDecisionAuditTests.cs).

Nothing in this phase ran a strategy backtest, changed strategy, execution,
account or margin semantics, changed the qualified data, recomposed the
continuous tree, reran the 413,750,130-row qualification, or touched upstream
LEAN, `.github` or hosted CI. Section 15 lists the non-actions explicitly.

## 1. Scope and method

The audit compares the current implementation and the current project
documents against the freeze requirement of
[SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md](SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md)
section 6 and the completeness floor of the freeze phase. It treats as
authoritative, in this order:

1. the approved behavioural strategy specification
   ([SINGLE_ANCHOR_VNEXT_STRATEGY.md](SINGLE_ANCHOR_VNEXT_STRATEGY.md));
2. the approved implementation roadmap and its frozen contracts
   ([SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md](SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md)
   sections 1, 3.16-3.21, 5 and 6);
3. the implemented contracts and their records
   ([SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md](SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md),
   `src\SingleAnchor\`, `tests\SingleAnchor\`, [README.md](README.md),
   [tools/historical-data/README.md](tools/historical-data/README.md),
   [tools/session-map/README.md](tools/session-map/README.md));
4. the tracked PR #13 evidence
   (`tools\historical-data\fixtures\continuous-history-evidence.json`).

During this audit the local continuous tree was re-identified without rerunning
the qualification: the three tracked auxiliary identities were hashed in place
and the partition count was re-counted, and all four values match the tracked
evidence (session map
`33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949`,
market-hours
`325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e`,
symbol-properties
`7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed`,
2,332 `YYYYMMDD_quote.zip` partitions). The 413,750,130-row qualification was
**not** rerun.

## 2. Classification rules

Each baseline-relevant value is classified as:

```text
A  explicitly approved/frozen by the authoritative project contract
B  explicitly defined strategy default that is valid for the authoritative baseline
C  fixture/test/example value only
D  configurable value (or run policy) for which no authoritative baseline value
   has yet been approved
```

A value is class B only when an authoritative project source explicitly defines
its default and the baseline's use of that default is consistent with the
approved roadmap. Merely appearing in code, in a fixture,
in a test or in a recorded run does not make a value authoritative. Class C
values are inventoried in section 9. A class D value has no selected value in
this audit: selecting one would be a policy decision, not an audit result.

## 3. Approved data and run identity (class A)

| Value | Recorded value | Run parameter | Source |
|---|---|---|---|
| symbol | `XAUUSD` | `single-anchor-symbol` | plan sections 4-6; README section 9 |
| market | `dukascopy` | `single-anchor-market` | plan sections 4-6; tools README sections 9-10 |
| security type | `Cfd` | `single-anchor-security-type` | plan sections 4-6 |
| data folder | `E:\MarketLab\data\lean\xauusd-dukascopy` | `-DataFolder` | tools README section 10; tracked evidence |
| start date | `2019-01-01` | `single-anchor-start-date` | plan sections 5-6; evidence `lean_run_window` |
| end date | `2026-06-30` | `single-anchor-end-date` | plan sections 5-6; evidence `lean_run_window` |
| resolution | `Tick` (`fillForward: false`) | host implementation | `SingleAnchorVNextAlgorithm.AddCfd`; README section 9 |
| data/exchange time zone | `UTC` / `UTC` | derived identity | tools README sections 4, 9-10; evidence identity |
| session map | `marketlab-sessions/xauusd-sessions.json`, SHA-256 `33fa8fa3...34949` | `single-anchor-session-map` | plan sections 5-6; evidence |
| market-hours DB | SHA-256 `325a7abc...2518e` | carried by the data folder | tools README section 9; evidence |
| symbol-properties DB | SHA-256 `7d52262f...7d5ed` | carried by the data folder | tools README section 9; evidence |
| continuous semantic digest | `sha256:231cf638...42886a` | carried by the data folder | tools README section 10; evidence |
| continuous population | 90 months, 2,332 partitions, 413,750,130 quotes, first `2019-01-01T23:00:07.151Z`, last `2026-06-30T23:59:59.678Z` | carried by the data folder | tools README sections 9-10; evidence |
| source file-set / month-digest chain | `8ce98dd2...f1fd` / `9d29c36b...f769` | carried by the source identity | tools README section 9; evidence |
| LEAN environment | `MarketLab/config/backtesting.json`, SHA-256 `877dadf1...b1a99f` (LF-normalized tracked content), backtesting-only handler set | `-Config` | README section 3; helper pre-flight |
| build configuration | `Release` | `-Configuration` | README sections 2, 9 |
| algorithm | `SingleAnchorVNextAlgorithm`, C# | `-AlgorithmTypeName/-AlgorithmLanguage` | README section 9 |
| algorithm location | `MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll` (the helper's default is the unrelated upstream `QuantConnect.Algorithm.CSharp.dll`) | `-AlgorithmLocation` | README section 9; implementation note section 2 |
| engine-error policy | `false`: `-AllowEngineErrors` must be absent; a run with engine `ERROR::` lines fails (exit 4) | `-AllowEngineErrors` | README sections 5, 10 |
| trading-availability buffers | first and last five minutes of every complete session quote-only | fixed implementation constant (not configurable) | strategy spec section 1.1; plan section 5; implementation note section 8.2 |

The data tree is the bound input: the run must point `-DataFolder` at the
continuous folder and pass the three identity parameters explicitly, because the
in-code `Market.Oanda` default and the 2014 fixture dates are not a research
configuration (implementation note section 8.7). The run must also name
`-AlgorithmLocation` and `-Configuration` explicitly: the helper otherwise
defaults to the unrelated upstream `QuantConnect.Algorithm.CSharp.dll` and
would still build `Release`, so neither may be inferred. The tracked
`backtesting.json` is bound by its content hash as well as its path. The
five-minute buffer width and the New York settlement-window junction rule are
fixed implementation constants, not operator settings, and are therefore
accounted for here rather than configured.

## 4. Strategy geometry and sizing

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| `StepPercent` | **D** | unresolved | strategy spec section 2; plan section 6; no approved value |
| `BaseLot` | **D** | unresolved | strategy spec section 4; plan section 6 (risk policy required) |
| `NormalTradeCount` | A | `4` | plan sections 1.7 and 6 |
| `HardBreakevenCeilingPercent` | A | `4.478` | plan sections 1.7 and 6 (approved starting value, not an optimum) |
| `MinimumVolume` | A | `0.01` | plan sections 3.16 and 6 |
| `VolumeStep` | A | `0.01` | plan sections 3.16 and 6 |
| `MaximumVolume` | A | `50` | plan sections 3.16 and 6; the engine global default is `100` and must not be relied on |

## 5. Exit behavior

All exit settings are the explicitly specified strategy defaults (class B) and
are approved only in the sense that the baseline adopts the specification's
default configuration. The freeze must pass each of them explicitly rather than
let the runtime default them.

| Value | Class | Baseline value | Source |
|---|---|---|---|
| `EscapeEnabled` | B | `true` | strategy spec sections 11, 17 |
| `EscapeProfitUnits` | B | `0.05` | strategy spec sections 11, 17 |
| `EscapeMinimumOpenPositions` | B | `2` | strategy spec sections 11, 17 |
| `FixedTakeProfitUnits` | B | `0` (disabled) | strategy spec sections 12, 17 |
| `TrailingEnabled` | B | `true` | strategy spec section 13 |
| `TrailingActivationUnits` | B | `0.50` | strategy spec sections 13, 17 |
| `TrailingDropUnits` | B | `0.25` | strategy spec sections 13, 17 |

## 6. Execution economics

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| `ProjectedSpread` | **D** | unresolved | strategy spec sections 6-7; plan section 6; must be supplied even when zero |
| `CommissionPerLot` | A | `0` | plan sections 3.16 and 6 (approved XM-style baseline) |
| `CommissionBuffer` | **D** | unresolved | strategy spec section 9 defines it as optional without a value; only the implementation default `0` is recorded (see section 10) |
| `Slippage` | **D** | unresolved | plan section 6 freeze item with no approved value; only the implementation default `0` is recorded |
| `PointValuePerLot` | A | `100` | plan sections 3.16 and 6; host supplies `100` for `XAUUSD`; margin mode enforces it |
| `BuySwapPerLotPerDay` | A | `0` | plan sections 3.16 and 6 (Islamic baseline); non-zero is rejected |
| `SellSwapPerLotPerDay` | A | `0` | plan sections 3.16 and 6 (Islamic baseline); non-zero is rejected |

## 7. Research account

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| research account enabled | B | `true` | implementation note sections 3 and 9.6 (default `true`); the plan's baseline report (section 7) requires the account metrics and margin mode requires the account |
| account currency | A | `USD` | plan section 3.16 (USD-denominated research account; no historical EURUSD conversion) |
| `InitialBalance` (`single-anchor-cash`) | **D** | unresolved | plan sections 3.16, 6 and 10.5 defer the value to this freeze |

The research account is a read-only derived observer
(`Balance = InitialBalance + RealizedProfit`, executable floating P/L, equity,
extrema); it changes no strategy decision. `InitialBalance` is unresolved, so
the account's absolute values and any survival conclusion remain undecided.

## 8. Target-account margin contract

The PR 3 model and all of its values are approved (class A). Whether the
authoritative baseline **enables** the model is a separate, unresolved decision
(class D): the model is frozen, its activation for the baseline is not.

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| margin enabled | **D** | unresolved | plan section 6 freeze item; PR 3 default is `false` |
| `ContractSize` | A | `100` oz/lot | plan sections 3.16 and 6; `MarginParameters` default |
| selected `Leverage` | A | fixed `1:500` | plan sections 3.16 and 6; no dynamic tiers |
| initial margin rate | A | `1.0` | plan section 3.16; applied as the unit factor of the uncovered-volume formula |
| maintenance margin rate | A | `1.0` | plan section 3.16; the survival path uses the same used-margin amount |
| matched-hedge margin rule | A | matched BUY/SELL volume: zero margin | plan section 3.16; `MarginModel.UsedMargin` |
| uncovered-volume margin rule | A | `uncovered lots * contract size * weighted-average open price / leverage`, projected post-fill | plan section 3.16; `MarginModel.ProjectedUsedMargin` |
| Margin Call threshold | A | `50%` (new entries blocked, exits allowed) | plan sections 3.16 and 6 |
| Stop Out threshold | A | `20%` (terminal, no liquidation simulated) | plan sections 3.16 and 6 |
| negative-equity handling | A | open positions with negative equity are terminal stop-out, including the zero-used-margin matched-hedge case | plan sections 3.16, 3.20; `StopOutReason.NegativeEquity` |

## 9. Fixture and example values (class C)

This representative list covers the fixture, test and example values that are
most likely to be mistaken for decisions. Every value of this kind is class C
and **not** a baseline value, and none may be promoted merely to complete the
freeze. The machine-readable register keeps the same list under `fixtureValues`.

| Value | Where it appears | Why it is not a baseline value |
|---|---|---|
| `StepPercent = 0.2` | implementation note section 7 example run; session-map README example | documented example, not a calibration; plan section 6 says the example step percent is not automatically approved |
| `StepPercent = 0.1` | wide-first-entry/rejection scenarios | deliberate test scenario |
| `StepPercent = 1.0` | unit-test harness reference | test fixture |
| `BaseLot = 0.01` | strategy spec section 4 example; implementation note section 7; tests | specification example / smallest broker volume; no approved risk policy |
| `BaseLot = 0.015`, `20` | sizing and margin unit tests | test inputs |
| `ProjectedSpread = 0.5` | implementation note section 7 example; session-map README example | example above the sample's usual spread; explicitly not a calibration |
| `ProjectedSpread = 0.2` | unit-test harness reference | test fixture |
| `HardBreakevenCeilingPercent = 0.1` | rejection-heavy scenario | deliberate rejection test; the approved starting value is 4.478 |
| `cash = 100000` | host default; representative fixture runs | in-code default, deferred by the plan |
| `cash = 1000000`, `12`, `7`, `5` | margin parity/stress runs | diagnostic amounts chosen to be non-binding or to force Margin Call/stop-out |
| `cash = 1000` | research-account/margin unit tests | test input |
| `MaximumVolume = 100` | engine global default and unit-test harness | the approved broker profile is `50`; the 100 default must be overridden explicitly |
| `marginEnabled = true` | margin validation/stress runs | diagnostic runs that exercise survival; they do not decide the baseline toggle |
| default dates `2014-05-02..2014-05-14`, default market `oanda` | shipped Oanda fixture runs | engine-fixture identity; not the qualified Dukascopy baseline |
| `-AllowMissingData` in the probe route | PR 1 qualification driver | belongs to the qualification run, not to the strategy baseline |

## 10. Unresolved baseline values (class D)

Every entry below is required for the baseline and has no approved value. The
freeze cannot be declared complete while any of them remains undecided. The
decision record carries the five audit fields (parameter, why required, current
code default, fixture/example values, why those are not authoritative, decision
required) in
[`config/baseline-decision-audit.json`](config/baseline-decision-audit.json).

### 10.1 `StepPercent` (`single-anchor-step-percent`)

- **Why required:** sets the fixed grid distance `S = A * P / 100`, which fixes
  every entry level of every basket; changes entries, sizing, exits and every
  downstream result.
- **Current code default:** none; unset (0) is rejected by parameter validation.
- **Fixture/example values:** `0.2` (implementation-note example), `0.1` (test
  scenario), `1.0` (unit-test harness).
- **Why not authoritative:** the implementation note presents 0.2 as an
  example, not a calibration; plan section 6 says the example step percent is
  not automatically an approved research setting.
- **Decision required:** approve the baseline step percentage (and, if step
  sensitivity is intended, which values are separate sensitivity runs).

### 10.2 `BaseLot` (`single-anchor-base-lot`)

- **Why required:** builds trades 1-4 and scales the hard-BE tail; it is the
  position-scale and risk parameter of the whole run.
- **Current code default:** none; unset (0) is rejected.
- **Fixture/example values:** `0.01` (spec/implementation examples and tests),
  `0.015` (tests), `20` (tests).
- **Why not authoritative:** all are examples or test inputs; plan section 6
  requires an explicit risk policy before geometry sweeps.
- **Decision required:** approve the baseline base lot under an explicit risk
  policy, or approve BaseLot as a separately studied risk dimension with an
  explicit baseline value.

### 10.3 `ProjectedSpread` (`single-anchor-projected-spread`)

- **Why required:** reconstructs the opposite quote side of the projected
  simultaneous basket close in the hard-BE sizing valuation; changes required
  tail lots and rejection behaviour; must be supplied even when zero.
- **Current code default:** none; the nullable value is required by validation.
- **Fixture/example values:** `0.5` (example run), `0.2` (unit-test harness).
- **Why not authoritative:** 0.5 is explicitly not a calibration and the plan
  says the fixture's projected spread is not automatically approved.
- **Decision required:** approve the single baseline target spread (and, if
  spread sensitivity is intended, the separate sensitivity schedule).

### 10.4 `Slippage` (`single-anchor-slippage`)

- **Why required:** moves every fill against the basket and enters the hard-BE
  projection, realized P/L, floating P/L, equity and the margin/survival path.
- **Current code default:** `0`.
- **Fixture/example values:** `0` (all recorded runs), `0.05` (fill-model unit
  test).
- **Why not authoritative:** the default is an implementation default, the
  0.05 is a test input, and the plan lists Slippage as a freeze item and calls
  execution assumptions sensitivity scenarios rather than silently chosen
  values.
- **Decision required:** approve the baseline slippage (zero must be an
  explicit decision too), and whether slippage sensitivity runs are separate.

### 10.5 `CommissionBuffer` (`single-anchor-commission-buffer`)

- **Why required:** deducted from raw basket profit before every escape,
  fixed-TP and trailing exit decision; changes close timing and realized P/L.
- **Current code default:** `0` (disabled); recorded as the implementation
  default.
- **Fixture/example values:** `0` (all recorded runs and the unit-test
  harness).
- **Why not authoritative:** the strategy spec defines the buffer as optional
  without a default, the plan's freeze list does not adopt one, and the only
  recorded value is the implementation default used by fixtures. If the project
  decides that "0 (disabled)" is the approved strategy default, this entry can
  be reclassified B with no other change.
- **Decision required:** approve the baseline commission buffer (`0`/disabled
  or an explicit amount).

### 10.6 `InitialBalance` (`single-anchor-cash`)

- **Why required:** seeds `Balance` and `Equity` and therefore the account
  path, drawdown, margin level, entry financing and survival; with margin
  enabled it is a first-order parameter.
- **Current code default:** `100000`.
- **Fixture/example values:** `100000` (default/representative run), `1000000`
  (parity run), `7`, `12`, `5` (stress runs), `1000` (unit tests).
- **Why not authoritative:** plan sections 3.16/10.5 explicitly defer the value
  to this freeze; the recorded amounts are defaults, examples and deliberate
  stress amounts.
- **Decision required:** approve the baseline initial balance in the USD
  research account.

### 10.7 `marginEnabled` (`single-anchor-margin-enabled`)

- **Why required:** decides whether the baseline measures account survival;
  when enabled the Margin Call block, InsufficientMargin rejections and
  stop-out can change the actual entries, closes and realized P/L and can
  terminally stop the run; when disabled no survival claim may be made.
- **Current code default:** `false` (pre-PR-3 strategy path exactly).
- **Fixture/example values:** `false` (default/parity runs), `true` (margin
  validation/stress runs).
- **Why not authoritative:** the approved PR 3 contract freezes the model but
  the plan leaves the baseline toggle as an explicit freeze item; fixture runs
  are diagnostics.
- **Decision required:** approve whether the first authoritative baseline runs
  with the frozen margin/survival model enabled or disabled.

### 10.8 `helperFailedDataRequestPolicy` (`-AllowMissingData` present/absent)

- **Why required:** under the always-open `XAUUSD/dukascopy/Cfd` identity LEAN
  requests a partition for every calendar day; the qualified continuous record
  counts 406 source-absent calendar days plus 1 unrelated missing benchmark file
  (`cfd/dukascopy/hour/xauusd.zip`) as failed data requests. Without
  `-AllowMissingData` the helper maps those to exit code 3, so the authoritative
  procedure must define how those already-classified, expected failures are
  handled. It must not hide a failed request for a partition that carries rows,
  and it must not weaken the missing-data guard.
- **Current code default:** helper fails (exit code 3) on any failed data
  request; `-AllowMissingData` downgrades it to a warning. The PR 1
  qualification driver used the flag together with a record that classifies
  every failed request.
- **Fixture/example values:** `-AllowMissingData` in the tools README
  qualification route; exit code 3 otherwise.
- **Why not authoritative:** the flag belongs to the qualification run; no
  project document states the strategy baseline's policy, and the helper
  default would make the authoritative run end as a failed helper exit instead
  of a documented expected outcome.
- **Decision required:** approve the baseline policy — run with
  `-AllowMissingData` and record a classification of every failed request, or
  run without it and define the expected exit-code-3 interpretation.
  `-AllowEngineErrors` must not be used either way.

## 11. Additional effective inputs and host settings discovered

Beyond the requested checklist, these effective inputs were found and are
accounted for:

- `single-anchor-research-account` — read-only derived account, class B
  (enabled); it changes no strategy decision, but the plan's baseline report
  uses its metrics.
- Host instrument mechanics — tick resolution, `fillForward: false`,
  `SetBenchmark` on the traded symbol (so no unrelated benchmark data is
  required), quoted times in the subscription exchange time zone.
- Fixed implementation constants that cannot be configured and are therefore
  part of the frozen behaviour: the five-minute quote-only session buffers, the
  New York settlement-window (`17:00:00 <= t < 18:00:00 America/New_York`)
  junction rule, the quote data-quality contract, and the deterministic
  `ResearchExecutor` fill model.
- Qualified LEAN run mechanics from `MarketLab/config/backtesting.json` and
  `run-backtest.ps1`: backtesting-only environment and handler set, local
  file-system data, no broker/API/live path, `close-automatically`, the
  mandatory `market-hours` and `symbol-properties` auxiliary files, and
  `object-store-root: ./storage` relative to the run directory. The helper
  pre-flight enforces the backtesting boundary; a material change there is a
  configuration drift that the helper rejects. All nine baseline-relevant
  helper inputs (`-Configuration`, `-Config`, `-AlgorithmTypeName`,
  `-AlgorithmLanguage`, `-AlgorithmLocation`, `-DataFolder`, `-Parameters`,
  `-AllowMissingData`, `-AllowEngineErrors`) are classified in the register;
  the mechanical helper options (`-LeanRoot`, `-PythonDll`, `-OutputRoot`,
  `-DryRun`) cannot change the strategy configuration, and the engine/binary
  identity is covered by the run-evidence requirements above.
- Run-evidence requirements for the eventual authoritative run: the run must be
  launched from the reviewed and merged freeze commit and must record the
  repository commit, the runtime binary hashes (the PR 1 route already records
  these for the probe), the full parameter block (already written into
  `storage\single-anchor\results.json`), and the session-map/data provenance
  block. These are evidence requirements, not values to freeze.
- Helper post-run policy: engine `ERROR::` lines fail the run (exit 4) and
  `-AllowEngineErrors` must not be used for the authoritative baseline
  (class A field `allowEngineErrors = false`). The failed-data-request policy
  is the unresolved entry 10.8.

## 12. Completeness mapping

Every requested completeness category is covered by an entry:

```text
data/run identity            section 3 (symbol, market, security type, data folder,
                             period, session map, market hours, symbol properties,
                             continuous digest, resolution, environment, build
                             configuration, algorithm, algorithm location, run policies)
strategy geometry/sizing     section 4 (StepPercent D, BaseLot D, NormalTradeCount,
                             HardBreakevenCeilingPercent, MinimumVolume, VolumeStep,
                             MaximumVolume)
exit behavior                section 5 (escape, fixed TP, trailing)
execution economics          section 6 (ProjectedSpread D, CommissionPerLot,
                             CommissionBuffer D, Slippage D, PointValuePerLot, swaps)
research account             section 7 (enabled B, currency USD, InitialBalance D)
margin/survival              section 8 (model A; enablement D)
helper run inputs            section 11 (all nine baseline-relevant run-backtest.ps1
                             inputs classified; mechanical options enumerated)
additional inputs            section 11
```

## 13. Drift detection and validation

The freeze is blocked, so this phase implements only the bounded supporting
work: the register plus its check. The Windows-local NUnit tests in
[`tests/SingleAnchor/BaselineDecisionAuditTests.cs`](tests/SingleAnchor/BaselineDecisionAuditTests.cs)
verify that:

- the register declares the right contract, is explicitly **not** frozen, and
  cannot claim `baselineConfigurationFrozen: true` while unresolved entries
  exist;
- every required baseline field is inventoried exactly once, with a valid
  class, and every class A/B entry has a value and a source;
- every class D entry has no value and the full decision record, and the
  unresolved set is exactly the eight known blockers (so closing a blocker or
  adding one is always a deliberate edit);
- the recorded data identity (folder, period, session map, market-hours,
  symbol-properties, continuous digest/population/boundaries, source-set and
  month-digest aggregates) is exactly the tracked PR #13 continuous-history
  evidence, that the evidence itself is a PASS with zero missing partitions and
  zero coverage gaps, and that exactly one complete derived native
  representation is recorded;
- the tracked `backtesting.json` still hashes to the recorded LF-normalized
  SHA-256, the helper run identity is pinned (`Release`, the exact
  `MarketLab.SingleAnchor.dll` location, `allowEngineErrors = false`), and the
  helper's own parameter list is exactly the classified baseline inputs plus the
  enumerated mechanical options (a new helper parameter fails the check);
- the failed-request counts that justify the unresolved helper policy
  (406 source-absent-day failed requests, 1 unrelated benchmark request, 0
  out-of-window requests) are bound to the tracked evidence;
- the host `SingleAnchorVNextAlgorithm` `[Parameter]` members (LEAN's own
  field/property discovery) are exactly the inventoried `single-anchor-*`
  parameters, each pinned host default still matches,
  and every class A/B value either equals its host default or is one of the
  documented overrides (qualified market/period/session map/volume maximum and
  the host-supplied point value);
- the approved class A/B strategy and margin values match the live
  implementation defaults and the frozen host contract (including the
  deliberate distinction that the engine's global `MaximumVolume` default is
  `100` while the approved broker profile requires the explicit `50`);
- fixture/example values are inventoried with their location and the reason
  they are not baseline values.

The check deliberately does **not**: judge whether a cited source truly
authorizes a value (that remains human review), re-verify the 2.7 GB machine-local
data tree, rerun the qualification, execute any strategy run, or substitute for
the eventual frozen run configuration.

## 14. What completion requires

The complete freeze can be established only after the project explicitly
approves all eight decisions in section 10 (in particular `StepPercent`,
`BaseLot`, `ProjectedSpread`, `Slippage`, `CommissionBuffer`, `InitialBalance`
and `marginEnabled`, plus the helper failed-data-request policy). At that point
the project should create one canonical, explicit, immutable baseline
configuration (a complete parameter record plus the exact frozen run command,
with no runtime defaults and no fixture values) and extend the validation to
resolve every value from it and detect drift. Until then:

```text
baseline configuration frozen: no
```

and the first untouched continuous full-history baseline must not be run.

## 15. Explicit non-actions in this phase

```text
first authoritative full-history strategy baseline run:  no
parameter optimization / sweep:                          no
historical-result-driven value selection:                no
strategy formula / hard-BE / escape / fixed-TP /
  trailing / execution semantics change:                 no
research-account or margin/account model change:         no
qualified data change:                                   no
continuous history recomposition:                        no
413,750,130-row qualification rerun:                     no
upstream LEAN change:                                    no
.github or hosted CI change:                             no
historical/native data committed to Git:                 no
```
