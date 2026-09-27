# SingleAnchor frozen baseline contract

Status: **frozen**  -  the immutable reference configuration for the first
untouched continuous full-history SingleAnchor strategy baseline.

```text
baseline configuration freeze:            complete
first untouched full-history baseline:    NOT RUN
parameter optimization:                   NOT STARTED
```

- Canonical machine-readable configuration:
  [`config/baseline-contract.json`](config/baseline-contract.json)
- Baseline contract identity (SHA-256):
  `bcef6c6b22c7bf7dbd660b5aa4f2ba5274950332ad601b155a9474b691fb05f4`
- Canonicalization: the identity is the SHA-256 of the contract file's UTF-8
  text content with CRLF normalized to LF, lower-case hex. It is deliberately
  not stored in the contract file itself; it is recorded in
  [`config/baseline-decision-audit.json`](config/baseline-decision-audit.json)
  (`frozenBaselineContractSha256`), rendered by
  [`scripts/Get-SingleAnchorBaselineInvocation.ps1`](scripts/Get-SingleAnchorBaselineInvocation.ps1)
  and verified by
  [`tests/SingleAnchor/BaselineContractTests.cs`](tests/SingleAnchor/BaselineContractTests.cs)
  and
  [`tests/SingleAnchor/BaselineDecisionAuditTests.cs`](tests/SingleAnchor/BaselineDecisionAuditTests.cs).
- Decision record: [`BASELINE_CONFIGURATION_FREEZE_AUDIT.md`](BASELINE_CONFIGURATION_FREEZE_AUDIT.md)
  (the PR #14 decision audit, updated: all eight former class-D blockers are
  resolved).
- Qualified data evidence:
  [`tools/historical-data/fixtures/continuous-history-evidence.json`](tools/historical-data/fixtures/continuous-history-evidence.json).

The contract describes the configuration itself, not historical performance.
A later optimization, sensitivity or research configuration may differ from
these values, but it must be a separately identified configuration and must
never modify this file or be presented as the frozen baseline.

## 1. Data and run identity

| Value | Frozen value |
|---|---|
| symbol | `XAUUSD` |
| market | `dukascopy` |
| security type | `Cfd` |
| resolution | `Tick` |
| fill forward | `false` |
| data time zone | `UTC` |
| exchange time zone | `UTC` |
| continuous data folder | `E:\MarketLab\data\lean\xauusd-dukascopy` |
| start date | `2019-01-01` |
| end date | `2026-06-30` |
| session map | `marketlab-sessions/xauusd-sessions.json` |
| session-map SHA-256 | `33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949` |
| market-hours DB SHA-256 | `325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e` |
| symbol-properties DB SHA-256 | `7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed` |
| continuous semantic digest | `sha256:231cf63850cd033ea8167ab7d0017bdfbd7744f40412c1a899c2b9d98942886a` |
| continuous population | 90 months, 2,332 partitions, 413,750,130 quotes |
| first delivered quote | `2019-01-01T23:00:07.151Z` |
| last delivered quote | `2026-06-30T23:59:59.678Z` |
| source file-set SHA-256 | `8ce98dd27c2df3166a0dc3ec30c6be4756887f323934a6a0ca1c348592c6f1fd` |
| ordered month digest chain | `9d29c36bcd5ada21cdbf6f8e8a7ea3601efd5bab65e2acf7b4c3ee0f8b41f769` |

The run must not fall back to the Oanda market default, the 2014 fixture
dates, unrestricted/no-session-map behaviour or any monthly qualification data
folder. The session map is part of the frozen baseline: the first and last five
minutes of every complete session are quote-only under the approved PR 7 rule.

## 2. Run host and build identity

| Value | Frozen value |
|---|---|
| build configuration | `Release` |
| algorithm type name | `SingleAnchorVNextAlgorithm` |
| algorithm language | `CSharp` |
| algorithm assembly | `MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll` |
| LEAN config | `MarketLab/config/backtesting.json` (LF-normalized SHA-256 `877dadf1ff325ed836970cd36090a2b1ba48f3d687d4ad68ef11ba56e7b1a99f`) |
| helper | `MarketLab\scripts\run-backtest.ps1` |
| failed-data handling | `-AllowMissingData` present, with mandatory classification (section 5) |
| engine-error handling | `-AllowEngineErrors` absent (`AllowEngineErrors = false`) |

## 3. Frozen strategy, execution and account values

Every `single-anchor-*` host parameter is passed explicitly. Values whose
authority is an approved baseline decision (rather than a specification
default or fixture) are marked in the machine-readable contract's `authority`
field. In particular, `ProjectedSpread = 0.50`, `Slippage = 0` and
`CommissionBuffer = 0` are authorized by the approved baseline decision, not
by any fixture/default that happened to use the same number.

| Parameter | Value | Authority kind |
|---|---|---|
| `single-anchor-symbol` | `XAUUSD` | qualified identity |
| `single-anchor-market` | `dukascopy` | qualified identity |
| `single-anchor-security-type` | `Cfd` | qualified identity |
| `single-anchor-start-date` | `2019-01-01` | qualified period |
| `single-anchor-end-date` | `2026-06-30` | qualified period |
| `single-anchor-cash` | `20000` | approved baseline decision |
| `single-anchor-session-map` | `marketlab-sessions/xauusd-sessions.json` | qualified identity |
| `single-anchor-step-percent` | `0.25` | approved baseline decision |
| `single-anchor-base-lot` | `0.10` | approved baseline decision |
| `single-anchor-normal-trade-count` | `4` | approved contract |
| `single-anchor-hard-be-ceiling-percent` | `4.478` | approved starting value |
| `single-anchor-escape-enabled` | `true` | specified default |
| `single-anchor-escape-profit-units` | `0.05` | specified default |
| `single-anchor-escape-minimum-open-positions` | `2` | specified default |
| `single-anchor-fixed-tp-units` | `0` | specified default |
| `single-anchor-trailing-enabled` | `true` | specified default |
| `single-anchor-trailing-activation-units` | `0.50` | specified default |
| `single-anchor-trailing-drop-units` | `0.25` | specified default |
| `single-anchor-commission-buffer` | `0` | approved baseline decision |
| `single-anchor-point-value-per-lot` | `100` | approved contract |
| `single-anchor-volume-step` | `0.01` | approved broker profile |
| `single-anchor-minimum-volume` | `0.01` | approved broker profile |
| `single-anchor-maximum-volume` | `50` | approved broker profile |
| `single-anchor-commission-per-lot` | `0` | approved contract |
| `single-anchor-slippage` | `0` | approved baseline decision |
| `single-anchor-projected-spread` | `0.50` | approved baseline decision |
| `single-anchor-buy-swap-per-lot-per-day` | `0` | approved Islamic baseline |
| `single-anchor-sell-swap-per-lot-per-day` | `0` | approved Islamic baseline |
| `single-anchor-research-account` | `true` | approved research account |
| `single-anchor-margin-enabled` | `true` | approved baseline decision |

Frozen margin/survival contract (host-enforced PR #3 model, unchanged):

| Value | Frozen value |
|---|---|
| account currency | `USD` |
| `ContractSize` | 100 oz/lot |
| `Leverage` | fixed 1:500 |
| initial margin rate | 1.0 |
| maintenance margin rate | 1.0 |
| matched hedge margin | zero margin on matched Gold BUY/SELL volume |
| uncovered margin | uncovered lots * contract size * weighted-average open price / leverage (projected post-fill) |
| Margin Call | 50% (new entries blocked, exits allowed) |
| Stop Out | 20% (terminal, no liquidation simulated) |
| negative equity | open positions with negative equity are terminal stop-out, including the fully matched zero-used-margin edge |

`InitialBalance = 20,000 USD` on the existing derived research account; no
second account or position ledger is introduced and no EUR conversion exists.

## 4. Exact future baseline invocation

The full-history baseline is launched exactly once, after this contract is
reviewed and merged, from the merged freeze commit:

```powershell
pwsh -File MarketLab\scripts\build.ps1
dotnet build MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj --configuration Release

pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Release -Config MarketLab/config/backtesting.json -AlgorithmTypeName SingleAnchorVNextAlgorithm -AlgorithmLanguage CSharp -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll -DataFolder E:\MarketLab\data\lean\xauusd-dukascopy -Parameters "single-anchor-symbol:XAUUSD,single-anchor-market:dukascopy,single-anchor-security-type:Cfd,single-anchor-start-date:2019-01-01,single-anchor-end-date:2026-06-30,single-anchor-cash:20000,single-anchor-session-map:marketlab-sessions/xauusd-sessions.json,single-anchor-step-percent:0.25,single-anchor-base-lot:0.10,single-anchor-normal-trade-count:4,single-anchor-hard-be-ceiling-percent:4.478,single-anchor-escape-enabled:true,single-anchor-escape-profit-units:0.05,single-anchor-escape-minimum-open-positions:2,single-anchor-fixed-tp-units:0,single-anchor-trailing-enabled:true,single-anchor-trailing-activation-units:0.50,single-anchor-trailing-drop-units:0.25,single-anchor-commission-buffer:0,single-anchor-point-value-per-lot:100,single-anchor-volume-step:0.01,single-anchor-minimum-volume:0.01,single-anchor-maximum-volume:50,single-anchor-commission-per-lot:0,single-anchor-slippage:0,single-anchor-projected-spread:0.50,single-anchor-buy-swap-per-lot-per-day:0,single-anchor-sell-swap-per-lot-per-day:0,single-anchor-research-account:true,single-anchor-margin-enabled:true" -AllowMissingData
```

`-AllowEngineErrors` is deliberately absent. The helper can print the same
resolved invocation with `-DryRun` (configuration-only validation; it launches
nothing).

Before launching, report the contract identity and re-render the invocation
from the canonical contract:

```powershell
pwsh -File MarketLab\scripts\Get-SingleAnchorBaselineInvocation.ps1
```

## 5. Failed-data-request classification

`-AllowMissingData` is the approved procedure flag but is **not** blanket
permission to ignore missing data. After the run, every failed data request is
classified against the frozen contract and the qualified continuous tree:

```powershell
pwsh -File MarketLab\scripts\Test-SingleAnchorBaselineFailedData.ps1 -RunDirectory <the run directory printed by run-backtest.ps1>
```

The classifier preserves the strong distinction between:

```text
expected source-absent request        accepted: an always-open calendar day the qualified tree does not contain
known non-strategy/auxiliary request  accepted: only the enumerated benchmark hour file, recorded explicitly
absence after a terminated horizon    accepted and recorded: a source-absent day after the actually processed horizon of a run
                                      ended by an approved run-ending condition (for example terminal stop-out); the day was
                                      never requested because the run ended
unexpected missing qualified data     INVALID: a failed request for a partition carrying qualified rows
unrequested absence within horizon    INVALID: a source-absent day within the run's processed horizon that was not requested at all
engine/runtime error                  handled by the helper: exit code 4; -AllowEngineErrors stays prohibited
```

An unexpected missing partition, an out-of-window or unknown failed request, or
an expected-absent day within the run's actually processed horizon that was not
requested at all invalidates the baseline run; absence after an approved early
termination (terminal stop-out is an intended baseline outcome) is recorded, not
treated as missing qualified data. The qualified continuous replay reference is 406
source-absent calendar-day requests, 1 unrelated auxiliary request, 0 missing
qualified partitions and 0 coverage gaps; the classifier does not assume the
strategy run reproduces that list  -  it derives expected absence from the
qualified data tree and checks the actual run.

## 6. Baseline identity and run evidence

The contract identity above must be reported with the future baseline run,
together with the repository commit, the runtime binary hashes, the full
effective parameter block written by the strategy to
`storage\single-anchor\results.json`, the session-map/data provenance block and
the failed-data classification record. This proves exactly which frozen
contract generated the results.

## 7. Relationship to later optimization and sensitivity runs

- This contract is the immutable reference for the first untouched
  full-history baseline. It is a configuration identity, not a performance
  claim.
- Later parameter research (StepPercent, HardBreakevenCeilingPercent, BaseLot,
  execution assumptions, ...) must define separate, clearly identified
  configurations and record which values differ. Those runs must never modify
  this file, silently reuse it as their own configuration or be reported as the
  frozen baseline.
- The approved research hierarchy (survival/feasibility before profit, frozen
  selection criteria, explicit development/validation/holdout periods) applies
  after the baseline audit, not to this freeze.
