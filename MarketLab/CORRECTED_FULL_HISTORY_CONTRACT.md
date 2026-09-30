# SingleAnchor corrected untouched full-history contract (Phase D)

Status: **prepared for review, not executed**  -  the authoritative run and
evidence path for the corrected untouched full-history SingleAnchor
characterization (Phase D) under the finalized Phase B broker-forced-liquidation
model. This support change adds the descriptor, the classifier and the helper
mode; the full-history characterization itself has **not** been executed.
Executing it requires independent review of this support change and a separate
explicit authorization.

```text
Phase A historical pre-liquidation baseline:      preserved; unchanged
Phase B broker-forced liquidation:                implemented; merged through PR #18
Phase C focused March 2020 qualification:         reviewed; unchanged
Phase D corrected full-history characterization:  prepared; NOT RUN
parameter optimization:                           NOT STARTED
```

- Machine-readable descriptor:
  [`config/corrected-full-history-contract.json`](config/corrected-full-history-contract.json)
- Frozen baseline contract it pins and never replaces:
  [`config/baseline-contract.json`](config/baseline-contract.json), LF-normalized
  SHA-256 `0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a`,
  human-auditable rendering in [BASELINE_CONTRACT.md](BASELINE_CONTRACT.md)
- Preflight and post-run classification:
  [`scripts/Test-SingleAnchorCorrectedFullHistory.ps1`](scripts/Test-SingleAnchorCorrectedFullHistory.ps1)
- Phase A historical record (unchanged):
  [BASELINE_RUN_RESULT.md](BASELINE_RUN_RESULT.md)
- Phase B/C record (unchanged): section 14 of
  [SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md](SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md)

## 1. Chronology

- **Phase A  -  historical pre-liquidation result.** The first untouched
  full-history baseline was executed on 2026-09-28 under the frozen baseline
  contract and the approved pre-broker-liquidation account-survival model. It
  reached the frozen 20% Stop Out at `2020-03-23T12:06:26.292Z` and stopped
  there without simulating liquidation. Its contract, documentation and
  evidence are preserved and must never be rewritten. See
  [BASELINE_RUN_RESULT.md](BASELINE_RUN_RESULT.md) and section 13 of the
  implementation note.
- **Phase B  -  broker-liquidation implementation.** Deterministic
  broker-forced liquidation replaced the terminal Stop Out behavior in the
  research account: reaching the 20% Stop Out condition starts forced
  liquidation at the executable market side of the triggering quote, the
  least-profitable open position first, and an operable account continues
  processing subsequent historical data. Implemented and independently
  reviewed through [Rady70/Lean PR #18](https://github.com/Rady70/Lean/pull/18)
  (merge commit `85af343c5fb5105adcdc2a2785600ff436a7f977`). See section 14 of
  the implementation note.
- **Phase C  -  focused March 2020 qualification.** The Phase B model was
  qualified locally over the bounded `2019-01-01 .. 2020-04-30` region with
  the frozen parameter values; two independent runs produced byte-identical
  results. The compact source-bound evidence is committed under
  `evidence/20260928-phase-b-march-2020/`. It is execution evidence only and
  does not determine the full-history outcome.
- **Phase D  -  corrected untouched full-history characterization.** The
  frozen Phase A strategy, account and data values, unchanged, over the full
  qualified `2019-01-01 .. 2026-06-30` window under the finalized Phase B
  model. This support change prepares the authoritative run and evidence path;
  the run has not been executed.

## 2. Readiness audit of the pre-existing tooling

An audit of the pre-existing tooling (before this support change) found that it
could not produce an authoritative Phase D evidence chain:

1. **The frozen baseline contract fixes the historical terminal
   AccountStopOut semantics.** `config/baseline-contract.json` declares
   `-ExpectedTerminalException MarketLab.SingleAnchor.AccountStopOutException`
   and the terminal 20% Stop Out rule with no liquidation simulated. That
   contract is the sole authority for the frozen values and must not be
   rewritten to describe the current model.
2. **The baseline run path and classifier hard-require the historical
   terminal shape.** `run-backtest.ps1 -RunEvidence -BaselineContract` uses
   `Assert-BaselineLaunch`, which refuses any invocation whose declared
   terminal exception is not `AccountStopOutException`, and
   `Test-SingleAnchorBaselineFailedData.ps1` classifies against the
   AccountStopOut whitelist with the historical verifier
   `Assert-BaselineDelivery`. Neither can certify a current-model run.
3. **The Phase B verifier existed but was not wired into an authoritative
   run path.** `Assert-BrokerLiquidationDelivery` in
   `scripts/SingleAnchorDelivery.ps1` verified a completed full stream and
   refused any terminal failure; no helper mode launched a run whose result
   it could certify.
4. **No Phase D descriptor existed.** Nothing pinned the current-model
   identity, the frozen-baseline reference, the exact run command or the
   outcome policy a Phase D classification may accept.

The support change closes that gap. Where each required evidence item is
established:

| Required evidence item | Where this support change establishes it |
|---|---|
| Clean source revision | `-ReviewedCommit`: the explicit full 40-character SHA is required by build, preflight, launch and classification; HEAD must equal it and the checkout must be clean |
| Built algorithm | `Build-SingleAnchorBaseline.ps1` receipt (`-BuildReceipt`, default `MarketLab\output\baseline-build.json`) produced from the reviewed source tree |
| Source-bound build | `Assert-BaselineBuild` re-verifies the receipt field by field: reviewed commit, source tree, frozen baseline contract hash, algorithm artifact and the complete Release dependency file set |
| Runtime identity | the receipt's runtime version is pinned on the launcher command line (`dotnet exec --fx-version <version> --roll-forward Disable`); the classifier reconciles the result's `runtimeVersion`/`runtimeDirectory` with the receipt and re-hashes the qualified runtime binary set after the run |
| Effective parameters | `Assert-CorrectedFullHistoryLaunch` compares the actual resolved inputs against the frozen baseline contract before launch; the classifier compares the persisted invocation evidence and the result's parameter block against the same contract |
| Descriptor source binding | in authoritative mode both `run-backtest.ps1` and the classifier require the canonical tracked `MarketLab\config\corrected-full-history-contract.json` from the clean reviewed checkout; an arbitrary descriptor path is refused, and synthetic fixtures may vary it only under the explicit non-authoritative override |
| Model identity | `model.revision = marketlab-single-anchor-broker-liquidation-v1` and `stopOutModel = BrokerLiquidation` in the descriptor; the classifier refuses a result that does not name both |
| Account/margin identity | the classifier checks the result's `researchMargin.Parameters` directly against the frozen baseline contract: contract size 100, leverage 500, Margin Call 50%, Stop Out 20% (the hedged-margin behavior stays source-bound) |
| Qualified data-tree identity | the corrected preflight hash-verifies the composition manifest, all 2,332 partition zips, the market-hours and symbol-properties databases and the session map, and anchors the manifest to the replay qualification record, without replaying history; the record is written to `corrected-history-preflight.json` |
| Session-map identity | the frozen baseline contract's SHA-256 `33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949`; checked in preflight and against the result's `sessionMap.Sha256` |
| Full date range | the frozen baseline contract's `2019-01-01 .. 2026-06-30`; the current-model verifier checks the effective UTC subscription window against it |
| Launch command | `runProcedure.exactRunCommand` reproduced in section 4; the helper records the actual launcher argv in `marketlab-run-invocation.json` and the classifier reconstructs the expected command and requires exact equality |
| Output destination | the run directory printed by `run-backtest.ps1`; `corrected-history-preflight.json` by the preflight's `-OutputPath`; `corrected-full-history-classification.json` in the run directory by default |
| Missing-data policy | `-AllowMissingData` is required; the classifier reconciles every failed request against the qualified tree, the data monitor and the tracked continuous-history evidence (expected source-absent calendar days, the enumerated auxiliary request, occurrence/line accounting equality) |
| Current-model delivery/result validation | `Assert-BrokerLiquidationDelivery` in `scripts/SingleAnchorDelivery.ps1`, called with `-AllowTerminalFailure`: a completed run must deliver the full qualified stream; a genuinely terminal run must deliver and evidence the exact qualified prefix |

Test coverage note: the synthetic classifier suite
`tests/Test-SingleAnchorCorrectedFullHistory.ps1` runs its run-path cases
with `-AllowNonAuthoritativeOverride` on synthetic fixtures, so the
authoritative-only checks (clean reviewed checkout, source-bound build receipt,
the run's copied corrected preflight binding, runtime pinning, build-artifact
equality and the exact reconstructed launcher command) are exercised by the
real run's mandatory preflight and post-run classification, not synthetically;
Cases U/U2 additionally exercise the authoritative data-folder-override and
`-ReviewedCommit` gates. The corrected launch guard and the helper's mode
mutual exclusion are covered by `tests/Test-SingleAnchorBaselineGuards.ps1`.
In a terminal-prefix classification the recorded global delivered semantic
digest is informational; the verified identity is the per-partition set and
the native terminal-day ZIP prefix
(`deliveryVerification.globalSemanticDigestVerified` is `false` there and
`true` for the completed full stream).

## 3. The corrected full-history contract

The descriptor is
[`config/corrected-full-history-contract.json`](config/corrected-full-history-contract.json):

| Field | Value |
|---|---|
| contract id | `marketlab-single-anchor-corrected-full-history-contract-v1` |
| status | `frozen`, `immutable` |
| frozen baseline contract | `MarketLab/config/baseline-contract.json`, LF-normalized SHA-256 `0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a` |
| baseline register | `MarketLab/config/baseline-decision-audit.json`; its `frozenBaselineContractSha256` must equal the actual baseline contract hash |
| model revision | `marketlab-single-anchor-broker-liquidation-v1` |
| stopOutModel | `BrokerLiquidation` |
| algorithm | `SingleAnchorVNextAlgorithm` (CSharp), `MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll` |
| data folder | the frozen baseline contract's qualified data folder `E:\MarketLab\data\lean\xauusd-dukascopy` |
| `AllowMissingData` / `AllowEngineErrors` | `true` / `false` |
| declared terminal exception | none: under the current model a Stop Out is not terminal |
| canonicalization | SHA-256 of the descriptor's UTF-8 text with CRLF normalized to LF, lower-case hex, computed and recorded at launch by `run-backtest.ps1 -RunEvidence` and re-verified by the classifier; the descriptor itself is bound to the reviewed source commit and clean tree |

Every effective strategy parameter, account/margin value, qualified data
identity, session map, run window and missing-data rule remains the immutable
frozen baseline contract's. The corrected descriptor does not restate them as a
second source of truth and never authorizes a parameter change. The 30 frozen
`single-anchor-*` values, the window and the margin contract are in
[BASELINE_CONTRACT.md](BASELINE_CONTRACT.md) sections 1-3 and
[`config/baseline-contract.json`](config/baseline-contract.json).

**Terminal-failure policy.** A terminal run may only be classified through one
of the current implementation's own run-ending kinds: `StrategyInvariant`,
`DataQuality`, `SessionMap`, `AccountSurvival`, `BrokerLiquidation`.
`AccountStopOut` is deliberately absent: it belongs to the historical
pre-liquidation model, the current model never raises it, and it can never
qualify a Phase D run.

## 4. Intended Phase D invocation (not executed)

The exact command is the descriptor's `runProcedure.exactRunCommand`. It is
reproduced here with `$ReviewedCommit` literal. The required order is:
independent review of the exact final PR head, manual dispatch of
`marketlab-final-validation.yml` on that exact reviewed candidate, confirmation
that the candidate and dispatched-base identities have not moved and the gate
is clean, merge (not by the support author), then local `master`
synchronization. `$ReviewedCommit` must be the resulting merged `master` SHA —
`Build-SingleAnchorBaseline.ps1`/`Assert-BaselineBuild` require a clean checkout
whose `HEAD` equals `$ReviewedCommit`, so the Phase D build and run use the
merged master tree (verified to be the reviewed and gated tree), not the
pre-merge PR-head SHA. Do not populate `$ReviewedCommit` automatically from the
current HEAD, and do not dispatch the gate before independent review. Only
after a separate authorization to run Phase D may this command be executed;
`run-backtest.ps1` repeats the corrected preflight immediately before launch.

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Release -Config MarketLab/config/backtesting.json -AlgorithmTypeName SingleAnchorVNextAlgorithm -AlgorithmLanguage CSharp -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll -DataFolder E:\MarketLab\data\lean\xauusd-dukascopy -Parameters "single-anchor-symbol:XAUUSD,single-anchor-market:dukascopy,single-anchor-security-type:Cfd,single-anchor-start-date:2019-01-01,single-anchor-end-date:2026-06-30,single-anchor-cash:20000,single-anchor-session-map:marketlab-sessions/xauusd-sessions.json,single-anchor-step-percent:0.25,single-anchor-base-lot:0.10,single-anchor-normal-trade-count:4,single-anchor-hard-be-ceiling-percent:4.478,single-anchor-escape-enabled:true,single-anchor-escape-profit-units:0.05,single-anchor-escape-minimum-open-positions:2,single-anchor-fixed-tp-units:0,single-anchor-trailing-enabled:true,single-anchor-trailing-activation-units:0.50,single-anchor-trailing-drop-units:0.25,single-anchor-commission-buffer:0,single-anchor-point-value-per-lot:100,single-anchor-volume-step:0.01,single-anchor-minimum-volume:0.01,single-anchor-maximum-volume:50,single-anchor-commission-per-lot:0,single-anchor-slippage:0,single-anchor-projected-spread:0.50,single-anchor-buy-swap-per-lot-per-day:0,single-anchor-sell-swap-per-lot-per-day:0,single-anchor-research-account:true,single-anchor-margin-enabled:true" -AllowMissingData -RunEvidence -CorrectedHistoryContract MarketLab\config\corrected-full-history-contract.json -ReviewedCommit $ReviewedCommit -BuildReceipt MarketLab\output\baseline-build.json
```

Do not pass `-AllowEngineErrors` and do not pass `-ExpectedTerminalException`.
The post-run audit is:

```powershell
pwsh -File MarketLab\scripts\Test-SingleAnchorCorrectedFullHistory.ps1 -Contract MarketLab\config\corrected-full-history-contract.json -RunDirectory <run directory printed by run-backtest.ps1> -ReviewedCommit $ReviewedCommit
```

The corrected preflight (`-Preflight -CheckOnly`) is the exact
non-result-dependent stage the helper invokes immediately before launching the
run; only result-dependent checks remain for the post-run classification. A
`-DryRun` performs the same checks without starting LEAN and writes no run
directory.

## 5. Classification policy

`scripts/Test-SingleAnchorCorrectedFullHistory.ps1` classifies the run with
exit code 0 (`EXPECTED`), exit code 1 (`INVALID`, unexpected failed-request
conditions) or exit code 2 (controlled configuration failure: bad or
mismatched descriptor, a run that is not the corrected full-history run, a
non-current-model result, a terminal condition outside the current model's
kinds, a delivery/evidence mismatch or a data tree that no longer matches its
composition manifest). Three outcomes are possible:

- **Completed full stream.** The run must deliver the qualified full stream
  (2,332 partitions, 413,750,130 quotes, the qualified first/last quotes and
  the global semantic digest) and pass the current-model full-stream
  verification; LEAN exit 0 / helper exit 0, the engine-error audit
  performed, zero engine `ERROR::` lines; the result must name
  `modelRevision` `marketlab-single-anchor-broker-liquidation-v1` and
  `stopOutModel` `BrokerLiquidation`; the failed-data requests must classify
  as the expected source-absent calendar days and the enumerated auxiliary
  request. Stop Out episodes and forced liquidations inside a completed run
  are normal research observations, not failures.
- **Exactly evidenced current-model terminal failure.** A run that ends
  through one of the current model's own run-ending conditions is preserved
  exactly: `completed = false` with the recorded failure. The kind and
  condition must be one exact, case-sensitive reviewed pair
  (`StrategyInvariant`/`HardBreakevenViolatedByFill`,
  `DataQuality`/`InvalidQuote`, `DataQuality`/`OutOfOrderQuote`,
  `SessionMap`/`QuoteOutsideMapCoverage`,
  `AccountSurvival`/`ExecutableMarkUnavailable`,
  `BrokerLiquidation`/`ForcedCloseFailed`). The faulting quote is bound to the
  verified execution: the final processed quote for accepted-then-faulted kinds
  (`StrategyInvariant`, `AccountSurvival`, `BrokerLiquidation`) and the next
  qualified source quote after the verified delivered prefix for pre-acceptance
  kinds (`DataQuality`, `SessionMap`); the complete failure quote is persisted
  in the classification record. Delivery must be the exact qualified prefix
  ending at the last processed quote, with the partial terminal day verified
  against the native ZIP prefix; LEAN exit 1 / helper exit 1; exactly one
  terminal engine `ERROR::` line (the `SetRuntimeError` line naming the recorded
  failure's exception type and message) and no unrelated engine `ERROR::` lines;
  no declared terminal exception. The failed-data requests are classified with
  the processed horizon as their bound: an actual failed request for a
  source-absent day after the terminal horizon is invalid.
- **Invalid / infrastructure cases.** Any other ending, a missing or
  mismatched evidence record, a terminal kind/condition pair outside the exact
  reviewed set, a faulting quote that does not match the engine's processed or
  pre-acceptance semantics, an engine `ERROR::` line beyond the single
  recorded-failure line, a failed request after the terminal horizon, a changed
  runtime binary, a dirty working tree at launch, or a delivered stream that is
  neither the full qualified population nor the exact qualified prefix cannot
  certify Phase D evidence.

**AccountStopOut is refused for Phase D.** It is the historical terminal
shape, belongs to the frozen Phase A model, and can never be a Phase D
outcome. A Stop Out/liquidation is an episode, never a terminal state: under
the current model the 20% Stop Out condition invokes broker liquidation and
processing continues whenever the account remains operable. A completion may
contain any number of Stop Out episodes, forced liquidations and fully
liquidated baskets; none of them makes the run terminal and none may be
withheld from the characterization.

## 6. Explicit non-goals

This support change and the Phase D run it prepares do **not**:

- change any strategy parameter or account/margin value (all 30 frozen
  `single-anchor-*` values remain the frozen baseline contract's);
- optimize, sweep, select or sensitivity-test parameters;
- re-run or re-qualify the 413,750,130-row qualification;
- change strategy behavior, execution economics or the Phase B
  broker-liquidation model;
- begin Phase E or any LuxAlgo work;
- change CI or any GitHub-hosted validation workflow.

## 7. Relationship to the Phase A record

The historical Phase A contract, its documentation and its evidence are
untouched by this support change. A Phase D result is a new, separately
identified current-model characterization: it may contain Stop Out episodes
and forced liquidations the Phase A record could not contain, and it reports
the post-liquidation continuation the Phase A record deliberately did not
simulate. A Phase D result must carry its own provenance chain (build receipt,
corrected preflight, invocation and outcome evidence, classification,
effective parameter block and source/session/delivery evidence) and must
never rewrite the Phase A record or be merged into it as a competing number
with the Phase A trigger state.
