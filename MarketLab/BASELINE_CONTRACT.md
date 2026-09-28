# SingleAnchor frozen baseline contract

Status: **frozen**  -  the immutable reference configuration for the first
untouched continuous full-history SingleAnchor strategy baseline.

```text
baseline configuration freeze:            complete and merged through PR #15
first untouched full-history baseline:    NOT RUN
parameter optimization:                   NOT STARTED
```

The pre-baseline audit correction updates the operational contract and its
identity below. All 30 PR #15 parameter values and the qualified data identity
are preserved. The corrected source/procedure must be reviewed and merged
before building an authoritative receipt and authorizing the future run.

- Canonical machine-readable configuration:
  [`config/baseline-contract.json`](config/baseline-contract.json)
- Baseline contract identity (SHA-256):
  `0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a`
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
| algorithm time zone | `UTC` (explicit production host setting) |
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
| pre-run verification | the classifier's `-Preflight` stage must pass before the run: contract/register pin, clean Git checkout and the complete qualified-tree identity |
| run evidence | `-RunEvidence` present: the helper writes `marketlab-run-invocation.json` before LEAN launches and `marketlab-run-outcome.json` after it |
| contract binding | `-BaselineContract` + `-BaselineRegister` present: the helper verifies the contract hash equals the register pin before launch and records both in the pre-run evidence |
| terminal exception | `-ExpectedTerminalException MarketLab.SingleAnchor.AccountStopOutException`: the always-run engine-log audit counts only these lines separately as the modeled terminal outcome |
| repository identity | Git HEAD and clean/dirty state captured before launch; a dirty tree stops the helper before LEAN starts and is refused by the classifier |
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

The corrected procedure requires the reviewed and merged correction commit.
Set `$ReviewedCommit` to that explicitly approved full 40-character SHA; do
not populate it automatically from the current HEAD. The first full-history
baseline remains unrun and requires separate authorization.

Run these preparation commands in order, from the repository root:

```powershell
$ReviewedCommit = '<explicitly reviewed and approved full commit SHA>'
pwsh -File MarketLab\scripts\Build-SingleAnchorBaseline.ps1 -ReviewedCommit $ReviewedCommit
if ($LASTEXITCODE -ne 0) { throw 'Baseline build failed' }
pwsh -File MarketLab\scripts\Get-SingleAnchorBaselineInvocation.ps1 -ReviewedCommit $ReviewedCommit
if ($LASTEXITCODE -ne 0) { throw 'Baseline contract verification failed' }
pwsh -File MarketLab\scripts\Test-SingleAnchorBaselineFailedData.ps1 -Preflight -ReviewedCommit $ReviewedCommit -BuildReceipt MarketLab\output\baseline-build.json -OutputPath MarketLab\output\baseline-preflight.json
if ($LASTEXITCODE -ne 0) { throw 'Baseline preflight failed' }
```

The build wrapper requires a clean checkout at that SHA, invalidates any old
receipt before rebuilding, and checks both non-incremental Release builds.
Its receipt binds the source commit/tree and contract to the complete launcher,
strategy, .NET framework and host dependency file set, including Queues and
NodaTime. The runtime is selected once and launched with `--fx-version` and
`--roll-forward Disable`. Failed or interrupted builds cannot reuse an old
receipt. These are local provenance checks, not a hermetic or signed build.

Only after preparation passes and a baseline run is authorized, use:

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Release -Config MarketLab/config/backtesting.json -AlgorithmTypeName SingleAnchorVNextAlgorithm -AlgorithmLanguage CSharp -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll -DataFolder E:\MarketLab\data\lean\xauusd-dukascopy -Parameters "single-anchor-symbol:XAUUSD,single-anchor-market:dukascopy,single-anchor-security-type:Cfd,single-anchor-start-date:2019-01-01,single-anchor-end-date:2026-06-30,single-anchor-cash:20000,single-anchor-session-map:marketlab-sessions/xauusd-sessions.json,single-anchor-step-percent:0.25,single-anchor-base-lot:0.10,single-anchor-normal-trade-count:4,single-anchor-hard-be-ceiling-percent:4.478,single-anchor-escape-enabled:true,single-anchor-escape-profit-units:0.05,single-anchor-escape-minimum-open-positions:2,single-anchor-fixed-tp-units:0,single-anchor-trailing-enabled:true,single-anchor-trailing-activation-units:0.50,single-anchor-trailing-drop-units:0.25,single-anchor-commission-buffer:0,single-anchor-point-value-per-lot:100,single-anchor-volume-step:0.01,single-anchor-minimum-volume:0.01,single-anchor-maximum-volume:50,single-anchor-commission-per-lot:0,single-anchor-slippage:0,single-anchor-projected-spread:0.50,single-anchor-buy-swap-per-lot-per-day:0,single-anchor-sell-swap-per-lot-per-day:0,single-anchor-research-account:true,single-anchor-margin-enabled:true" -AllowMissingData -RunEvidence -BaselineContract MarketLab\config\baseline-contract.json -BaselineRegister MarketLab\config\baseline-decision-audit.json -ReviewedCommit $ReviewedCommit -BuildReceipt MarketLab\output\baseline-build.json -ExpectedTerminalException MarketLab.SingleAnchor.AccountStopOutException
```

The helper compares its actual resolved parameters, configuration, algorithm,
data folder and allow flags with the contract **before LEAN starts**. It then
runs the authoritative preflight itself; a missing receipt, changed dependency,
wrong reviewed commit or data-tree failure prevents launch. `-DryRun` performs
these same checks but starts no LEAN process and writes no run directory.
The build and preflight receipts are copied into each run directory and bound
by hashes in `marketlab-run-invocation.json`. After execution the helper hashes
the dependencies again and binds the results file in `marketlab-run-outcome.json`.

## 5. Failed-data-request classification

`-AllowMissingData` is the approved procedure flag but is **not** blanket
permission to ignore missing data. After the run, every failed data request is
classified against the frozen contract and the qualified continuous tree:

```powershell
pwsh -File MarketLab\scripts\Test-SingleAnchorBaselineFailedData.ps1 -RunDirectory <the run directory printed by run-backtest.ps1>
```

The same script's `-Preflight` mode proves the pre-run half of this chain
(contract/register pin, reviewed-source build, exact runtime dependencies, qualified tree) before the baseline is
launched; only result-dependent checks remain here after the run.

Before classifying, the classifier proves the chain around the run:

1. the contract file's computed hash equals the decision register's
   `frozenBaselineContractSha256` (a non-pinned contract is refused);
2. the pre-run `marketlab-run-invocation.json` binds the run to that contract:
   its recorded contract path and SHA-256 and register pin must equal the
   canonical contract and pin, and its resolved build configuration, config
   file and hash, algorithm location and hash, data folder, exact parameter
   pairs and allow flags equal the contract's;
3. the pre-run evidence and successful build receipt name the explicit reviewed
   commit and clean source tree, the pinned .NET runtime, and the complete
   Release dependency file set, whose files still hash to the recorded values;
4. the post-run `marketlab-run-outcome.json` is bound to the pre-run file by
   its SHA-256 and must show the approved outcome; the engine-error audit runs
   for every run and separates only the declared terminal exception:
   a normally completed run has LEAN exit 0, helper exit 0, zero engine
   `ERROR::` lines and zero terminal-exception lines; an `AccountStopOut` run
   has exactly LEAN exit 1, helper exit 1, at least one expected
   `AccountStopOutException` line and zero unrelated engine `ERROR::` lines;
   the recorded failed-request count equals the data monitor and the runtime
   binaries did not change during the run;
5. the machine-local continuous tree still matches its composition manifest:
   every one of the 2,332 partition zips is SHA-256 verified against the
   manifest's recorded `zip_sha256`, the partition name set must match exactly,
   the per-day semantic map must describe the same days, the market-hours
   database, symbol-properties database and session map are hash-verified
   against the contract, and the manifest file itself is anchored to the
   replay qualification record (`continuous-qualification-record.json`:
   `overall_qualification = PASS` and `continuous.composition_sha256` equal to
   the actual manifest hash); the raw qualification-record SHA-256 must also
   equal the immutable tracked evidence field `replay.record_sha256`, so changing
   both local JSON files coherently cannot replace the qualified identity;
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
   EXPECTED. Completion must also be consistent with the failure record. The
   effective algorithm clock/window is UTC. A completed run must match every
   qualified partition and the full count/global digest and final UTC quote.
   A stop-out must match every preceding partition and the exact delivered
   prefix of its terminal partition, including its final Bid/Ask and terminal
   research-account state. Only that partial day is read for prefix verification;
   the history is not replayed.

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

Each authoritative run retains `baseline-build.json`, `baseline-preflight.json`,
`marketlab-run-invocation.json`, `marketlab-run-outcome.json`, the classification
record, and `storage/single-anchor/results.json`. The invocation hashes the
copied receipts; the outcome hashes the invocation and strategy results. The
classifier verifies this chain, the explicit reviewed commit and source tree,
all runtime dependencies, the tracked qualification anchor and the actual
processed quote population before issuing EXPECTED.

The strategy records `completed`, `algorithmTimeZone`, `startUtc`, `endUtc`,
`runtimeVersion`, `runtimeDirectory` and `delivered`. Delivery evidence uses the
same exact-decimal semantic format as qualification: global/per-partition
counts and SHA-256, first/last UTC timestamps, and the final quote. It includes
the processed terminal quote and excludes any later ticks in the same slice.
Evidence size grows with partition count, not quote count. Session boundary
logic remains based on America/New_York; only the algorithm run window is UTC.

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
