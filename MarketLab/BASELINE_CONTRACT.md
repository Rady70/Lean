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
  `59261cc7a6fed1210cac04a0293c18eab88e4b839c4340dbd9f5ee594747eaa4`
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
| run evidence | `-RunEvidence` present: the helper writes `marketlab-run-invocation.json` before LEAN launches and `marketlab-run-outcome.json` after it |
| contract binding | `-BaselineContract` + `-BaselineRegister` present: the helper verifies the contract hash equals the register pin before launch and records both in the pre-run evidence |
| repository identity | Git HEAD and clean/dirty state recorded in the pre-run evidence; a dirty tree is refused by the classifier |
| runtime identity | the qualified Release runtime binary set is hashed before the run and re-hashed after it; a changed binary is refused |
| register pin | the decision register's `frozenBaselineContractSha256` must equal this file's computed hash; the reporter and the classifier both refuse a mismatch |

Effective behaviour that is not a LEAN `[Parameter]` is frozen as well and
drift-checked against the live implementation:

| Fixed behaviour | Frozen value |
|---|---|
| data resolution | `Resolution.Tick` on the host subscription |
| fill forward | `false` on the host subscription |
| quote-only session buffer | first and last 5 minutes of every complete session |
| session junction zone | `America/New_York`, window `17:00:00 <= t < 18:00:00` (start inclusive, end exclusive) |
| benchmark | `SetBenchmark` on the traded symbol itself (the absent hour file is the enumerated auxiliary failed request) |
| session-map semantics | with the frozen session map the session buffers are quote-only; the final dataset-end session has an opening buffer only |

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

pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Release -Config MarketLab/config/backtesting.json -AlgorithmTypeName SingleAnchorVNextAlgorithm -AlgorithmLanguage CSharp -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll -DataFolder E:\MarketLab\data\lean\xauusd-dukascopy -Parameters "single-anchor-symbol:XAUUSD,single-anchor-market:dukascopy,single-anchor-security-type:Cfd,single-anchor-start-date:2019-01-01,single-anchor-end-date:2026-06-30,single-anchor-cash:20000,single-anchor-session-map:marketlab-sessions/xauusd-sessions.json,single-anchor-step-percent:0.25,single-anchor-base-lot:0.10,single-anchor-normal-trade-count:4,single-anchor-hard-be-ceiling-percent:4.478,single-anchor-escape-enabled:true,single-anchor-escape-profit-units:0.05,single-anchor-escape-minimum-open-positions:2,single-anchor-fixed-tp-units:0,single-anchor-trailing-enabled:true,single-anchor-trailing-activation-units:0.50,single-anchor-trailing-drop-units:0.25,single-anchor-commission-buffer:0,single-anchor-point-value-per-lot:100,single-anchor-volume-step:0.01,single-anchor-minimum-volume:0.01,single-anchor-maximum-volume:50,single-anchor-commission-per-lot:0,single-anchor-slippage:0,single-anchor-projected-spread:0.50,single-anchor-buy-swap-per-lot-per-day:0,single-anchor-sell-swap-per-lot-per-day:0,single-anchor-research-account:true,single-anchor-margin-enabled:true" -AllowMissingData -RunEvidence -BaselineContract MarketLab\config\baseline-contract.json -BaselineRegister MarketLab\config\baseline-decision-audit.json
```

`-AllowEngineErrors` is deliberately absent. `-RunEvidence` plus
`-BaselineContract`/`-BaselineRegister` make the helper write
`marketlab-run-invocation.json` inside the run directory **before** LEAN is
launched: the resolved inputs (paths, parameter pairs, allow flags and launcher
argv, plus the config and algorithm hashes), this contract's path and SHA-256,
the register pin (verified equal before launch), the Git HEAD and dirty state,
and the qualified runtime binary hashes. After the run the helper writes
`marketlab-run-outcome.json` (LEAN exit code, final helper exit code, whether
the engine-error check ran and its count, the data-monitor result and whether
the runtime binaries changed). The invocation is evidence, not a
reconstruction. The helper can print the same resolved invocation with
`-DryRun` (configuration-only validation; it launches nothing).

Before launching, report the contract identity and re-render the invocation
from the canonical contract:

```powershell
pwsh -File MarketLab\scripts\Get-SingleAnchorBaselineInvocation.ps1
```

The reporter refuses (exit 2) to render the invocation when the contract
file's computed SHA-256 does not equal the decision register's
`frozenBaselineContractSha256`, so an accidentally edited local contract
cannot be advertised as the frozen baseline.

## 5. Failed-data-request classification

`-AllowMissingData` is the approved procedure flag but is **not** blanket
permission to ignore missing data. After the run, every failed data request is
classified against the frozen contract and the qualified continuous tree:

```powershell
pwsh -File MarketLab\scripts\Test-SingleAnchorBaselineFailedData.ps1 -RunDirectory <the run directory printed by run-backtest.ps1>
```

Before classifying, the classifier proves the chain around the run:

1. the contract file's computed hash equals the decision register's
   `frozenBaselineContractSha256` (a non-pinned contract is refused);
2. the pre-run `marketlab-run-invocation.json` binds the run to that contract:
   its recorded contract path and SHA-256 and register pin must equal the
   canonical contract and pin, and its resolved build configuration, config
   file and hash, algorithm location and hash, data folder, exact parameter
   pairs and allow flags equal the contract's;
3. the pre-run evidence records a clean working tree (Git HEAD present,
   `repositoryDirty: false`) and the exact qualified Release runtime binary
   set, whose files still hash to the recorded values;
4. the post-run `marketlab-run-outcome.json` is bound to the pre-run file by
   its SHA-256 and must show the approved outcome: a normally completed run
   has LEAN exit 0, helper exit 0 and a performed engine-error check with zero
   engine `ERROR::` lines; an `AccountStopOut` run has exactly LEAN exit 1,
   helper exit 1 and no engine-error check (the run-ending line is the
   algorithm's own failure message); the recorded failed-request count equals
   the data monitor and the runtime binaries did not change during the run;
5. the machine-local continuous tree still matches its composition manifest:
   every one of the 2,332 partition zips is SHA-256 verified against the
   manifest's recorded `zip_sha256`, the partition name set must match exactly,
   the per-day semantic map must describe the same days, the market-hours
   database, symbol-properties database and session map are hash-verified
   against the contract, and the manifest file itself is anchored to the
   replay qualification record (`continuous-qualification-record.json`:
   `overall_qualification = PASS` and `continuous.composition_sha256` equal to
   the actual manifest hash);
6. the engine's single `data-monitor-report-*.json` failed-request count equals
   the total number of failed-request lines, so every failed request is
   accounted for (occurrences are counted; distinct paths carry the
   classification);
7. the run itself is the frozen baseline run (symbol/market/period/account/
   margin/session map/all parameters) and ended normally or through
   `AccountStopOut`  -  the intended modeled terminal survival outcome. Any other
   run-ending condition (strategy invariant, hard-BE verification, data-quality
   or session-map failure, account-survival failure, runtime error) is refused
   as a controlled failure and can never receive failed-data qualification
   EXPECTED.

The classifier preserves the strong distinction between:

```text
expected source-absent request        accepted: an always-open calendar day the qualified tree does not contain
known non-strategy/auxiliary request  accepted: only the enumerated benchmark hour file, recorded explicitly
absence after a stop-out horizon      accepted and recorded: a source-absent day after the actually processed horizon of an
                                      AccountStopOut run; the day was never requested because the run ended
unexpected missing qualified data     INVALID: a failed request for a partition carrying qualified rows
unrequested absence within horizon    INVALID: a source-absent day within the run's processed horizon that was not requested at all
failed-request accounting mismatch    INVALID: the data-monitor failed-request count and the failed-request lines disagree
contract/evidence mismatch            INVALID: the auxiliary count or the tracked continuous-history evidence disagrees
engine/runtime error                  INVALID for the baseline: the outcome record must show zero engine ERROR:: lines
                                      in a completed run (helper exit code 4); -AllowEngineErrors stays prohibited
```

An unexpected missing partition, an out-of-window or unknown failed request, a
source-absent day within the run's processed horizon that was not requested at
all, or a failed-request accounting mismatch invalidates the baseline run;
absence after an `AccountStopOut` run's horizon is recorded, not treated as
missing qualified data. The qualified continuous replay reference is 406
source-absent calendar-day requests, 1 unrelated auxiliary request, 0 missing
qualified partitions and 0 coverage gaps; the classifier does not assume the
strategy run reproduces that list  -  it derives expected absence from the
qualified data tree and checks the actual run.

## 6. Baseline identity and run evidence

The run directory persists three evidence files that bind it to this contract:
the pre-run `marketlab-run-invocation.json` written by
`run-backtest.ps1 -RunEvidence -BaselineContract ... -BaselineRegister ...`
(the actual resolved invocation, the contract identity verified against the
register pin before launch, the Git HEAD/dirty state and the qualified runtime
binary hashes), the post-run `marketlab-run-outcome.json` (the helper's own
verdict and the runtime re-hash), and the classifier's
`baseline-failed-data-classification.json` (the verified contract identity,
invocation, runtime, tree and manifest-to-qualification-record anchor). The
classifier only issues qualification EXPECTED when all of these agree and the
run ended in the approved shape. The run audit additionally records the full
effective parameter block from `storage\single-anchor\results.json` and the
session-map/data provenance block. Together these prove which frozen contract
launched the run, which qualified tree it read and how it ended. The operator's
shell history is outside the repository's control and remains part of the run
audit narrative; the persisted pre-run evidence makes the effective invocation
and identity independently checkable.

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
