# SingleAnchor baseline configuration freeze: decision audit

Audit date: 2026-09-27 (Windows, .NET SDK 10.0.401 environment as in the
previous records). Audit base revision:
`bdf3c29a4e1b20be4110a6c9e75ecff9e00856f3` (the PR #13 finalization commit).

Finalization records:

- PR #14 completed the audit and exposed the eight unresolved class-D
  decisions (reviewed head
  `8811d20e3d6c701842c5086beee0f141b7886dfe`, merge commit
  `261912d6cbda495c90ea68f578d3952fe3bba699`);
- the eight decisions were then explicitly approved (full-history baseline
  freeze decision, 2026-09-27) and the complete immutable baseline contract
  was frozen in
  [`config/baseline-contract.json`](config/baseline-contract.json), with its
  human-auditable rendering in [`BASELINE_CONTRACT.md`](BASELINE_CONTRACT.md).

Project state after the freeze:

```text
continuous historical-data qualification: complete
continuous native-history composition/replay qualification: complete (PR #13)
baseline configuration decision audit: complete and merged through PR #14
baseline configuration freeze: complete (all eight decisions resolved)
first untouched full-history strategy baseline: NOT RUN
parameter optimization: NOT STARTED
```

This document records the baseline-decision audit required before the first
authoritative continuous full-history SingleAnchor run. It classifies every
baseline-relevant value into the project's four audit classes, binds the
approved portion to the already-qualified data identity, and records how each
decision was approved. The machine-readable register inventories 65 baseline
fields (57 class A, 8 class B, 0 class D after the freeze) plus the
fixture/example values (class C).

The freeze is complete. The canonical, complete, runnable configuration is
[`config/baseline-contract.json`](config/baseline-contract.json) with contract
identity (LF-normalized SHA-256)
`d57e245ce370ad4a82954f805e7d9b077c1b691ed5bcebe7891e474f64f1196e`; the
human-auditable contract is [`BASELINE_CONTRACT.md`](BASELINE_CONTRACT.md).
The machine-readable decision register at
[`config/baseline-decision-audit.json`](config/baseline-decision-audit.json)
is the decision record, now `status: resolved` with
`baselineConfigurationFrozen: true` and `unresolvedDecisionCount: 0`; its
values must agree with the contract. The executable Windows-local checks that
keep the audit, the contract, the implementation and the qualified data
identity aligned are
[`tests/SingleAnchor/BaselineDecisionAuditTests.cs`](tests/SingleAnchor/BaselineDecisionAuditTests.cs)
and
[`tests/SingleAnchor/BaselineContractTests.cs`](tests/SingleAnchor/BaselineContractTests.cs).

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
in a test or in a recorded run does not make a value authoritative; a fixture
value that happens to equal an approved baseline value does not thereby become
the authority. Class C values are inventoried in section 9. Class D is empty in
the resolved register: at audit time a class D entry carried no selected value
because selecting one would have been a policy decision, not an audit result;
the eight former class-D decisions were then explicitly approved and are now
class A (section 10).

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
| `StepPercent` | A | `0.25` | approved baseline decision (2026-09-27); frozen in the contract. The example `0.2` and test values remain class C, not the authority. |
| `BaseLot` | A | `0.10` | approved baseline decision (2026-09-27) under an explicit risk scale; frozen in the contract. The example `0.01` and test values remain class C. |
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
| `ProjectedSpread` | A | `0.50` | approved baseline decision (2026-09-27): a fixed hard-BE projection assumption, not declared empirically optimal. The example `0.5` is numerically equal but is not the authority. |
| `CommissionPerLot` | A | `0` | plan sections 3.16 and 6 (approved XM-style baseline); kept distinct from `CommissionBuffer` |
| `CommissionBuffer` | A | `0` (disabled) | approved baseline decision (2026-09-27); the implementation default happens to be the same number but is not the authority |
| `Slippage` | A | `0` | approved baseline decision (2026-09-27) because no separately qualified slippage/latency model exists yet; the implementation default happens to be the same number but is not the authority |
| `PointValuePerLot` | A | `100` | plan sections 3.16 and 6; host supplies `100` for `XAUUSD`; margin mode enforces it |
| `BuySwapPerLotPerDay` | A | `0` | plan sections 3.16 and 6 (Islamic baseline); non-zero is rejected |
| `SellSwapPerLotPerDay` | A | `0` | plan sections 3.16 and 6 (Islamic baseline); non-zero is rejected |

## 7. Research account

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| research account enabled | B | `true` | implementation note sections 3 and 9.6 (default `true`); the plan's baseline report (section 7) requires the account metrics and margin mode requires the account |
| account currency | A | `USD` | plan section 3.16 (USD-denominated research account; no historical EURUSD conversion) |
| `InitialBalance` (`single-anchor-cash`) | A | `20000` USD | approved baseline decision (2026-09-27), frozen in the contract; the host default `100000` and the recorded stress amounts are not the authority |

The research account is a read-only derived observer
(`Balance = InitialBalance + RealizedProfit`, executable floating P/L, equity,
extrema); it changes no strategy decision. `InitialBalance = 20,000 USD` makes
the account's absolute values and the modeled survival question explicit; the
run is intended to reveal real modeled survival outcomes at that scale.

## 8. Target-account margin contract

The PR 3 model and all of its values are approved (class A), and the
authoritative baseline now explicitly enables the model: margin enabled = true
(approved baseline decision, 2026-09-27). The model is unchanged by this
freeze.

| Value | Class | Baseline value | Source / note |
|---|---|---|---|
| margin enabled | A | `true` | approved baseline decision (2026-09-27): the baseline uses the already-approved PR #3 target-account margin/survival model and is intended to reveal real modeled survival outcomes, including Margin Call, InsufficientMargin and terminal stop-out. Do not disable or soften it because the result looks unfavorable. |
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
and **not** a baseline value, and none was promoted merely to complete the
freeze. Three approved baseline values happen to be numerically equal to a
former fixture/default value: `ProjectedSpread = 0.50` (example `0.5`),
`marginEnabled = true` (diagnostic runs) and `-AllowMissingData` (qualification
driver). Their authority is the explicit baseline decision, not the fixture or
default that happened to use the same value; the machine-readable register
marks those entries with `promotedByExplicitDecision` and an `authorityNote`.
The machine-readable register keeps the same list under `fixtureValues`.

| Value | Where it appears | Why it is not a baseline value |
|---|---|---|
| `StepPercent = 0.2` | implementation note section 7 example run; session-map README example | documented example, not a calibration; plan section 6 says the example step percent is not automatically approved |
| `StepPercent = 0.1` | wide-first-entry/rejection scenarios | deliberate test scenario |
| `StepPercent = 1.0` | unit-test harness reference | test fixture |
| `BaseLot = 0.01` | strategy spec section 4 example; implementation note section 7; tests | specification example / smallest broker volume; no approved risk policy |
| `BaseLot = 0.015`, `20` | sizing and margin unit tests | test inputs |
| `ProjectedSpread = 0.5` | implementation note section 7 example; session-map README example | example above the sample's usual spread; explicitly not a calibration. The approved baseline value is numerically equal (`0.50`) but its authority is the explicit baseline decision, not this example. |
| `ProjectedSpread = 0.2` | unit-test harness reference | test fixture |
| `Slippage = 0` | implementation default; all recorded fixture runs | implementation default, not an approved execution assumption. The approved baseline value is `0` but its authority is the explicit baseline decision, not the default. |
| `CommissionBuffer = 0` | implementation default; all recorded fixture runs | implementation default; the strategy specification stated no value. The approved baseline value is `0` but its authority is the explicit baseline decision, not the default. |
| `HardBreakevenCeilingPercent = 0.1` | rejection-heavy scenario | deliberate rejection test; the approved starting value is 4.478 |
| `cash = 100000` | host default; representative fixture runs | in-code default, deferred by the plan |
| `cash = 1000000`, `12`, `7`, `5` | margin parity/stress runs | diagnostic amounts chosen to be non-binding or to force Margin Call/stop-out |
| `cash = 1000` | research-account/margin unit tests | test input |
| `MaximumVolume = 100` | engine global default and unit-test harness | the approved broker profile is `50`; the 100 default must be overridden explicitly |
| `marginEnabled = true` | margin validation/stress runs | diagnostic runs that exercise survival; they do not decide the baseline toggle. The approved baseline value is `true` but its authority is the explicit baseline decision, not these diagnostics. |
| default dates `2014-05-02..2014-05-14`, default market `oanda` | shipped Oanda fixture runs | engine-fixture identity; not the qualified Dukascopy baseline |
| `-AllowMissingData` in the probe route | PR 1 qualification driver | belonged to the qualification run, not to the strategy baseline. The approved baseline policy also enables the flag, but with a mandatory post-run classification of every failed request; its authority is the explicit baseline decision, not the qualification driver. |

## 10. Resolved baseline decisions (former class D)

The eight entries below were the class-D blockers exposed by PR #14. All eight
were explicitly approved by the full-history baseline freeze decision
(2026-09-27) and are frozen in
[`config/baseline-contract.json`](config/baseline-contract.json); the register
now records them as class A with `wasClassD: true`, the approved value and the
approved decision, while preserving the original audit context (why the value
is required, the then-current code default, the fixture/example values and why
those values were not authoritative at audit time). Where an approved value
happens to equal a former fixture or default, the register records explicitly
that the authority is the approved decision, not the look-alike value.

### 10.1 `StepPercent` (`single-anchor-step-percent`) = `0.25`

- **Why required:** sets the fixed grid distance `S = A * P / 100`, which fixes
  every entry level of every basket; changes entries, sizing, exits and every
  downstream result.
- **Audit-time code default:** none; unset (0) is rejected by validation.
- **Audit-time fixture/example values:** `0.2` (implementation-note example),
  `0.1` (test scenario), `1.0` (unit-test harness). They were examples or test
  inputs and were not promoted.
- **Approved decision:** `StepPercent = 0.25` for the frozen baseline. Step
  sensitivity, if any, belongs to later separately identified configurations.

### 10.2 `BaseLot` (`single-anchor-base-lot`) = `0.10`

- **Why required:** builds trades 1-4 and scales the hard-BE tail; it is the
  position-scale and risk parameter of the whole run.
- **Audit-time code default:** none; unset (0) is rejected.
- **Audit-time fixture/example values:** `0.01`, `0.015`, `20` (spec/tests).
  They were examples or test inputs and were not promoted.
- **Approved decision:** `BaseLot = 0.10` under the approved risk scale against
  the 20,000 USD research account. Later geometry research treats BaseLot as a
  separate, clearly identified study dimension.

### 10.3 `ProjectedSpread` (`single-anchor-projected-spread`) = `0.50`

- **Why required:** reconstructs the opposite quote side of the projected
  simultaneous basket close in the hard-BE sizing valuation; changes required
  tail lots and rejection behaviour; must be supplied even when zero.
- **Audit-time code default:** none; the nullable value is required by
  validation.
- **Audit-time fixture/example values:** `0.5` (example run), `0.2` (unit-test
  harness). Neither was authoritative at audit time.
- **Approved decision:** `ProjectedSpread = 0.50` as the fixed baseline
  hard-BE projection assumption, not declared empirically optimal or
  permanently correct. The value is numerically equal to the former example
  `0.5`, but its authority is the approved baseline decision, not the example.

### 10.4 `Slippage` (`single-anchor-slippage`) = `0`

- **Why required:** moves every fill against the basket and enters the hard-BE
  projection, realized P/L, floating P/L, equity and the margin/survival path.
- **Audit-time code default:** `0`.
- **Audit-time fixture/example values:** `0` (recorded runs), `0.05`
  (fill-model unit test). The `0` was only the implementation default.
- **Approved decision:** `Slippage = 0` for the frozen baseline because no
  separately qualified slippage/latency model exists yet. The value is
  numerically equal to the implementation default, but its authority is the
  approved baseline decision, not the default.

### 10.5 `CommissionBuffer` (`single-anchor-commission-buffer`) = `0` (disabled)

- **Why required:** deducted from raw basket profit before every escape,
  fixed-TP and trailing exit decision; changes close timing and realized P/L.
- **Audit-time code default:** `0` (disabled).
- **Audit-time fixture/example values:** `0` (recorded runs and the unit-test
  harness). The `0` was only the implementation default.
- **Approved decision:** `CommissionBuffer = 0` (disabled): the optional
  exit-decision buffer is not enabled. The value is numerically equal to the
  implementation default, but its authority is the approved baseline decision,
  not the default. It stays conceptually distinct from `CommissionPerLot`,
  which is also `0`.

### 10.6 `InitialBalance` (`single-anchor-cash`) = `20000` USD

- **Why required:** seeds `Balance` and `Equity` and therefore the account
  path, drawdown, margin level, entry financing and survival; with margin
  enabled it is a first-order parameter.
- **Audit-time code default:** `100000`.
- **Audit-time fixture/example values:** `100000`, `1000000`, `7`, `12`, `5`,
  `1000` (defaults, examples, stress amounts, test inputs). None was a
  deliberate research balance.
- **Approved decision:** `InitialBalance = 20,000 USD` in the existing USD
  research account, a deliberate scale intended to reveal real modeled survival
  outcomes.

### 10.7 `marginEnabled` (`single-anchor-margin-enabled`) = `true`

- **Why required:** decides whether the baseline measures account survival;
  when enabled the Margin Call block, InsufficientMargin rejections and
  stop-out can change the actual entries, closes and realized P/L and can
  terminally stop the run; when disabled no survival claim may be made.
- **Audit-time code default:** `false` (pre-PR-3 strategy path exactly).
- **Audit-time fixture/example values:** `false` (default/parity runs), `true`
  (margin validation/stress runs). The diagnostic `true` did not decide the
  toggle.
- **Approved decision:** `marginEnabled = true`: the baseline uses the
  already-approved PR #3 target-account margin/survival model and is intended
  to reveal real modeled survival outcomes, including Margin Call,
  InsufficientMargin and terminal stop-out. Do not disable or soften it because
  the result looks unfavorable. The value is numerically equal to a diagnostic
  run's toggle, but its authority is the approved baseline decision, not the
  diagnostic.

### 10.8 `helperFailedDataRequestPolicy` = `-AllowMissingData` enabled with mandatory classification

- **Why required:** under the always-open `XAUUSD/dukascopy/Cfd` identity LEAN
  requests a partition for every calendar day; the qualified continuous record
  counts 406 source-absent calendar days plus 1 unrelated missing benchmark file
  (`cfd/dukascopy/hour/xauusd.zip`) as failed data requests. Without
  `-AllowMissingData` the helper maps those to exit code 3, so the authoritative
  procedure must define how those already-classified, expected failures are
  handled. It must not hide a failed request for a partition that carries rows,
  and it must not weaken the missing-data guard.
- **Audit-time code default:** helper fails (exit code 3) on any failed data
  request; `-AllowMissingData` downgrades it to a warning.
- **Audit-time fixture/example values:** `-AllowMissingData` in the PR 1
  qualification driver and tools README route; it belonged to the qualification
  run.
- **Approved decision:** run with `-AllowMissingData` and `-RunEvidence`
  (plus `-BaselineContract`/`-BaselineRegister`) enabled and classify every
  failed request after the run with
  [`scripts/Test-SingleAnchorBaselineFailedData.ps1`](scripts/Test-SingleAnchorBaselineFailedData.ps1)
  against the register-pinned frozen contract, the run's persisted
  pre-run/outcome evidence and the qualified continuous tree: expected
  source-absent calendar days of the frozen window, the enumerated known
  auxiliary path, and source-absent days after the actually processed horizon
  of an `AccountStopOut` run (the intended modeled terminal survival outcome)
  may be accepted and recorded; an unexpected missing qualified partition, an
  out-of-window or unknown request, a source-absent day within the processed
  horizon that was not requested at all, a mismatch between the engine's
  data-monitor failed-request count and the failed-request lines, or a
  contract/evidence mismatch invalidates the baseline. Any other run-ending
  condition is not an approved baseline outcome and is refused as a controlled
  failure. The classifier also verifies the tree against its composition
  manifest (all 2,332 partition hashes, the partition name set and the
  auxiliary database hashes), anchors the manifest file to the replay
  qualification record, verifies the pre-run evidence's contract hash/register
  pin/Git HEAD/clean tree/runtime binary hashes, and requires the post-run
  outcome record to show a clean completed run (or the exact `AccountStopOut`
  terminal shape with only the declared terminal exception separated and zero
  unrelated engine `ERROR::` lines), so a run without matching evidence or
  with engine errors can never receive qualification EXPECTED. The classifier's
  `-Preflight` mode runs the same pre-run-knowable checks before LEAN starts,
  so an accidental data/checkout drift cannot consume the one-off run.
  `-AllowEngineErrors` remains prohibited. The flag is also used by the
  qualification driver, but its authority is the approved baseline decision,
  not that driver.

## 11. Additional effective inputs and host settings discovered

Beyond the requested checklist, these effective inputs were found and are
accounted for:

- `single-anchor-research-account`  -  read-only derived account, class B
  (enabled); it changes no strategy decision, but the plan's baseline report
  uses its metrics.
- Host instrument mechanics  -  tick resolution, `fillForward: false`,
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
  launched from the reviewed and merged freeze commit only after the
  classifier's `-Preflight` stage has passed, and must persist that preflight
  record alongside the run directory evidence: the pre-run invocation evidence
  written by
  `run-backtest.ps1 -RunEvidence -BaselineContract ... -BaselineRegister ... -ExpectedTerminalException ...`
  (resolved absolute inputs, exact parameter pairs, allow flags, launcher argv,
  the config/algorithm hashes, the contract SHA-256 and register pin verified
  equal, the Git HEAD and dirty state, and the qualified runtime binary
  hashes), the post-run outcome evidence (LEAN and helper exit codes, the
  always-run engine-error audit with the expected-terminal-exception lines
  separated, the data-monitor result and the runtime re-hash) and the
  post-run classification record that binds the run directory
  to the contract identity, the verified tree and its replay qualification
  record. The run audit additionally records the full parameter block (already
  written into `storage\single-anchor\results.json`) and the session-map/data
  provenance block. These are evidence requirements, not values to freeze.
- Helper post-run policy: engine `ERROR::` lines fail the run (exit 4) and
  `-AllowEngineErrors` must not be used for the authoritative baseline
  (class A field `allowEngineErrors = false`). The failed-data-request policy
  is resolved (entry 10.8): `-AllowMissingData` with the mandatory
  classification of every failed request by
  `scripts/Test-SingleAnchorBaselineFailedData.ps1`.

## 12. Completeness mapping

Every requested completeness category is covered by an entry:

```text
data/run identity            section 3 (symbol, market, security type, data folder,
                             period, session map, market hours, symbol properties,
                             continuous digest, resolution, environment, build
                             configuration, algorithm, algorithm location, run policies)
strategy geometry/sizing     section 4 (StepPercent, BaseLot, NormalTradeCount,
                             HardBreakevenCeilingPercent, MinimumVolume, VolumeStep,
                             MaximumVolume)
exit behavior                section 5 (escape, fixed TP, trailing)
execution economics          section 6 (ProjectedSpread, CommissionPerLot,
                             CommissionBuffer, Slippage, PointValuePerLot, swaps)
research account             section 7 (enabled B, currency USD, InitialBalance)
margin/survival              section 8 (model A; enablement A)
helper run inputs            section 11 (all nine baseline-relevant run-backtest.ps1
                             inputs classified; mechanical options enumerated)
additional inputs            section 11
```

## 13. Drift detection and validation

The freeze is complete and its bounded supporting work is:

- the canonical machine-readable contract
  [`config/baseline-contract.json`](config/baseline-contract.json);
- the human-auditable contract
  [`BASELINE_CONTRACT.md`](BASELINE_CONTRACT.md);
- the decision register
  [`config/baseline-decision-audit.json`](config/baseline-decision-audit.json),
  now resolved and bound to the contract;
- the exact-invocation/identity reporter
  [`scripts/Get-SingleAnchorBaselineInvocation.ps1`](scripts/Get-SingleAnchorBaselineInvocation.ps1);
- the failed-data-request classifier
  [`scripts/Test-SingleAnchorBaselineFailedData.ps1`](scripts/Test-SingleAnchorBaselineFailedData.ps1);
- the Windows-local NUnit checks
  [`tests/SingleAnchor/BaselineDecisionAuditTests.cs`](tests/SingleAnchor/BaselineDecisionAuditTests.cs)
  and
  [`tests/SingleAnchor/BaselineContractTests.cs`](tests/SingleAnchor/BaselineContractTests.cs).

The register check verifies that:

- the register declares the right contract, `status: resolved`,
  `baselineConfigurationFrozen: true`, zero unresolved decisions and the
  frozen contract path plus LF-normalized SHA-256, and the frozen flag is the
  exact complement of the unresolved count;
- every required baseline field is inventoried exactly once, with a valid
  class, and every class A/B entry has a value and a source; no class D entry
  remains;
- the eight former blockers are still identified (`wasClassD`), are class A,
  carry their approved value, the approved decision and the preserved
  fixture/example history, so re-opening a blocker or adding one is always a
  deliberate edit;
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
- the failed-request counts that bound the now-approved helper policy
  (406 source-absent-day failed requests, 1 unrelated benchmark request, 0
  out-of-window requests) are bound to the tracked evidence;
- the host `SingleAnchorVNextAlgorithm` `[Parameter]` members (LEAN's own
  field/property discovery) are exactly the inventoried `single-anchor-*`
  parameters, each pinned host default still matches, and every class A/B value
  either equals its host default or is a documented override (qualified
  market/period/session map/volume maximum, the host-supplied point value, and
  the approved step/base-lot/initial-balance/margin-enablement decisions);
- the approved class A/B strategy and margin values match the live
  implementation defaults and the frozen host contract (including the
  deliberate distinction that the engine's global `MaximumVolume` default is
  `100` while the approved broker profile requires the explicit `50`);
- fixture/example values are inventoried with their location and the reason
  they are not baseline values, and a fixture/default value that is
  numerically equal to the approved baseline value is explicitly marked as
  authorized by the baseline decision, not by the look-alike.

The contract check verifies that the freeze is actually runnable:

- the contract is complete: every host `[Parameter]` is present exactly once,
  with an explicit value and an authority, and no effective parameter is left
  unclassified; the live host defaults are pinned, so a host-default change
  cannot silently alter the run;
- every frozen value matches the approved baseline (step/base lot/balance/
  spread/slippage/buffer/margin and all specification defaults), the audit
  register agrees with the contract, and the contract identity (LF-normalized
  SHA-256) matches the register and the human contract;
- the exact run invocation renders deterministically from the contract (the
  `-Parameters` list contains every frozen parameter), is recorded in the
  human contract, and uses Release, `SingleAnchorVNextAlgorithm`,
  `MarketLab.SingleAnchor.dll`, `MarketLab/config/backtesting.json`, the
  continuous data folder, the qualified session map, the research account, the
  margin model, `-AllowMissingData`, `-RunEvidence` and no
  `-AllowEngineErrors`;
- the qualified data identity and the approved PR #3 margin contract are
  unchanged and still bound to the tracked continuous-history evidence and the
  live `MarginParameters` defaults;
- effective runtime behaviour that is not a `[Parameter]` is machine-bound and
  drift-checked: tick resolution, `fillForward:false`, the five-minute
  quote-only buffer (`HistoricalTradingAvailability.QuoteOnlyBuffer`), the New
  York `17:00:00 <= t < 18:00:00` junction rule
  (`SessionJunctionRule`/`HistoricalSessionMap.JunctionRuleText`) and the
  traded-symbol benchmark are asserted against the live implementation and the
  host source;
- the failed-data policy is not weakened: the classifier script exists, the
  contract records all six invalidating categories (the four unexpected
  request classes plus `failed-request-accounting-mismatch` and
  `contract-evidence-mismatch`), the `AccountStopOut`-only termination rule,
  the run-outcome contract (clean completed run or the exact terminal shape)
  and the qualified replay reference; neither the contract invocation nor the
  classifier enables `-AllowEngineErrors`.

The classifier's own edge-case suite
([`tests/Test-SingleAnchorBaselineFailedData.ps1`](tests/Test-SingleAnchorBaselineFailedData.ps1))
additionally proves the failure modes on synthetic fixtures: a modified
partition with an unchanged count, a present/absent-day swap, an invocation/
data-folder mismatch, a data-monitor vs failed-request count mismatch, an
auxiliary-count mismatch, a non-approved termination, an unpinned contract, an
unapproved data-folder override, a non-clean helper outcome (engine errors), a
missing post-run outcome, a pre-run contract-hash mismatch, a runtime binary
changed after the run, a manifest not anchored to the qualification record,
an `AccountStopOut` with a non-terminal outcome shape, an `AccountStopOut`
with an unrelated engine `ERROR::` line, and preflight tree drift or an
unpinned contract all fail as intended, while the preflight pass path is
proven without running anything. The
reporter suite
([`tests/Test-SingleAnchorBaselineInvocation.ps1`](tests/Test-SingleAnchorBaselineInvocation.ps1))
proves the register-pin refusal.

The C# checks deliberately do **not**: judge whether a cited source truly
authorizes a value (that remains human review), re-verify the 2.7 GB
machine-local data tree, recompute the 413,750,130-row semantic digest, rerun
the qualification, execute any strategy run, or produce a performance result.
The classifier's tree verification happens at future baseline-audit time (it
hashes the 2,332 partitions against the composition manifest then, without
replaying the 413,750,130 rows).

## 14. The freeze is complete; what remains

All eight decisions in section 10 are resolved and the complete immutable
contract exists:

```text
baseline configuration frozen: yes
baseline contract:             MarketLab/config/baseline-contract.json
baseline contract SHA-256:     d57e245ce370ad4a82954f805e7d9b077c1b691ed5bcebe7891e474f64f1196e
first untouched full-history strategy baseline: NOT RUN
parameter optimization:        NOT STARTED
```

The next roadmap step is the first untouched continuous full-history baseline:
run the exact invocation of section 4 of
[`BASELINE_CONTRACT.md`](BASELINE_CONTRACT.md) once, then classify its failed
data requests with
[`scripts/Test-SingleAnchorBaselineFailedData.ps1`](scripts/Test-SingleAnchorBaselineFailedData.ps1)
and audit the resulting survival, exposure, basket-resolution and P/L evidence
before beginning any optimization. A later optimization/sensitivity
configuration may intentionally vary parameters, but it must never modify the
frozen baseline contract or be reported as the baseline.

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
