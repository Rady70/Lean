# SingleAnchor Phase E authoritative replay export - result record

Status: **implemented, corrected after two independent reviews, and ready for
re-review** - the Phase E authoritative replay export was implemented in
`Rady70/Lean`, corrected for the first review's findings (hard-BE activation
snapshot, authoritative parity, fail-closed persistence/candles), produced
again by one execution of the frozen corrected-full-history model, and then
corrected for the second review's findings (candle source re-derivation,
comprehensive verifier parity/ordering/failure coverage, exact-string and
evidence fixes). It is qualified by the repository's corrected-full-history
classifier (`EXPECTED`) and the strengthened Phase E package verifier. Phase E
is additive: it does not rewrite the Phase D characterization, the Phase A/B/C
records or any frozen value.

**Finalization (2026-10-03):** the signed-net revision was approved and merged
from the exact approved head `1813c2efa4c11f0494754df96d9936bac083fe79` through
[Rady70/Lean#24](https://github.com/Rady70/Lean/pull/24) as merge commit
`72e1d3b5edc90c6bb93c9fe571f4e23120666338`, which is the resulting `master`.
The finalized signed-net package is
`d145a49b548fe9356f1355d33df3329f87ce667cd15b367369219b8f27a9ccb4` with
evidence manifest
`f98263618bde5d2cd24542e028d322d0bab35074c430ce6b0bdb4c7a4b22f685`; the
20261002 evidence directory remains unchanged. Phase E is finalized; the later
replay/visualization phases (G–I) have not started.

```text
Phase E implementation revision:  a2941581c02462a190f4d4289f371aed409cb1e3 (clean at run time)
build receipt:                    MarketLab/output/baseline-build.json (SHA-256 f1344cd814892126b2f661522c2c4a1f7e361e94cd7b5639dc05d202fcb4987d)
baseline contract:                MarketLab/config/baseline-contract.json (unchanged; SHA-256 0882b7aba759de88fa8480878ef8f6fc5b90448de0fc5dd7e083b8c5f84d361a)
corrected contract:               MarketLab/config/corrected-full-history-contract.json (unchanged; SHA-256 d97b3c9b375ed2e53a2af784618a90e4db5e5ab9c627ffc9f0638a8c245cd44f)
model revision:                   marketlab-single-anchor-broker-liquidation-v1
Stop Out model:                   BrokerLiquidation
run window:                       2019-01-01 .. 2026-06-30 (the frozen window)
execution:                        2026-10-01T22:18:31Z .. 2026-10-02T00:02:39Z (6,248 s); LEAN exit 0, helper exit 0, engine ERROR:: audit performed with 0 engine errors
classification:                   EXPECTED (invalidCount 0)
Phase D binding:                  the run's storage/single-anchor/results.json is byte-identical to the Phase D artifact (SHA-256 bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad)
package contract:                 marketlab-single-anchor-replay-package-v1
package sha256:                   5dcd8bfaffe76c9d2c8eec002073f62fe18b5d0d40b0602dbad0e59f6846097a
events / event snapshots / periodic samples: 1,454 / 1,452 / 98,866
verifier:                         PASS, 32,805 checks (31,255 authoritative payload-parity comparisons), Phase D binding enforced
candle cache contract:            marketlab-xauusd-m1-candle-cache-v1
candle cache content_sha256:      ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d
candle cache manifest_sha256:     75f1d2415e6d7012022c70c527370258d42dcbd9ac2c992af7540126650b23a1
candle source derivation:         the four month-aligned ranges were regenerated with the corrected generator; 90/90 monthly records equal the final cache bytes
candle cache verification:        verify-candles PASS (2,332/2,332 partitions, qualification-record binding), verify-candle-composition PASS (4 re-derived parts, 10/10 checks)
```

## 1. Implementation and provenance

The Phase E implementation adds, without changing any strategy or account
semantics:

- `MarketLab/src/SingleAnchor/ReplayPackage.cs` - the package contract,
  metadata records, canonical UTC/decimal formatting and hashing, plus the
  fail-closed publisher (payloads before manifest; a failed payload suppresses
  the manifest);
- `MarketLab/src/SingleAnchor/ReplayRecorder.cs` - the recorder that observes
  the engine's existing events and the research account's existing observations
  and writes `events.jsonl`, per-year `telemetry-YYYY.jsonl` and
  `manifest.json` under `single-anchor/replay/`;
- the host wiring in `SingleAnchorVNextAlgorithm.cs` (the recorder replaces the
  account as the engine's observer only after the account itself has observed
  the same event; the account remains the engine's risk guard; the package is
  attempted only after `results.json` persisted) and four read-only accessors
  on the research account;
- an observational `HardBreakevenActivated` engine event raised at the existing
  hard-BE mode transition, before the first tail attempt is sized or placed, so
  the activation telemetry snapshot is the exact pre-attempt state;
- `MarketLab/scripts/Test-SingleAnchorReplayPackage.ps1` - the strengthened
  package verifier (authoritative parity, periodic rule, Phase D binding) and
  `MarketLab/tests/Test-SingleAnchorReplayPackageVerifier.ps1` - the verifier
  mutation tests;
- `MarketLab/REPLAY_PACKAGE.md` - the package contract.

The package is emitted by the same run that persists the authoritative
`results.json`; it is additive object-store output and does not replace or
modify that result. The recorder is fault-guarded: a recorder defect refuses the
package build instead of aborting the strategy run.

### 1.1 First independent-review corrections

- **Hard-BE activation snapshot.** Previously the recorder reconstructed the
  activation inside the entry event, so the activation snapshot already
  contained the post-fill leg. The engine now publishes
  `HardBreakevenActivated` at the real transition (before sizing/placement) and
  the recorder snapshots it there. All **11/11** activation snapshots in this
  package are pre-attempt (the following entry adds exactly one position), with
  focused C# tests for the filled and rejected tail paths.
- **Authoritative event parity in the verifier.** The verifier now compares the
  replay stream against the authoritative `results.json` structures: every
  anchor (`AnchorEvent`), surviving entry (`LegTrace`), forced liquidation
  (`StopOutEpisodes[].Liquidations`, including before/after account state and
  same-quote ordering), Stop Out episode, rejection/summary
  (`RejectionTrace`), hard-BE activation (first tail leg/attempt) and the
  run-end provenance/counters/account/margin state. It also enforces the real
  `telemetryIntervalSeconds` periodic rule. The new mutation test proves 11/11
  deliberate corruptions (changed trade number, fill price, forced-liquidation
  ordinal/price, Stop Out time, same-quote reorder, manifest identity, file
  hash, deleted event, deleted snapshot, over-frequent periodic sample) are
  rejected.
- **Fail-closed package persistence.** The package is only attempted after
  `results.json` persisted; all payloads are saved before the manifest; a failed
  payload suppresses the manifest, so an incomplete package cannot be
  advertised.
- **Fail-closed candle provenance.** Candle generation now requires the
  qualified composition and a PASS qualification record bound to the actual
  composition hash, exact partition-set equality, per-partition `zip_sha256`
  and streaming member name/size/row-count/member-SHA verification. The derived
  cache is certified by `verify-candles` and `verify-candle-composition`.

### 1.2 Second independent-review corrections

- **Candle source derivation (the second review's blocker).** The four
  month-aligned ranges (`2019-01-01..2020-11-30`, `2020-12-01..2022-10-31`,
  `2022-11-01..2024-09-30`, `2024-10-01..2026-06-30`) were regenerated with the
  corrected fail-closed generator under the reviewed revision. All **90/90**
  regenerated monthly records (`sha256`, `bytes`, `rows`, `first_candle_utc`,
  `last_candle_utc`) equal the existing final cache; the final CSV bytes were
  **not changed**; the final manifest was rebuilt as the documented
  byte-for-byte merge of the four corrected part manifests, which bind the PASS
  qualification record (`e9c72d1a...`). The regenerated part manifests are
  committed **byte-identically** (fixing the earlier line-ending hash
  inconsistency). `verify-candles` now requires the qualification-record
  binding (fail-closed) and passed 9/9 checks with 2,332/2,332 partition zip
  hashes; `verify-candle-composition` passed 10/10 checks against the
  re-derived parts.
- **Verifier coverage completed.** `Test-SingleAnchorReplayPackage.ps1` now:
  binds every significant event's telemetry snapshot to the event's exact time
  and quote sequence and compares all overlapping account values to that
  snapshot (Stop Out, Margin Call, forced liquidation); compares
  `trailing_activated` thresholds against a derivation from the parity-verified
  anchor step, surviving inventory and parameters (207/207 on this run);
  compares `margin_call_entered/left` payloads and states; proves the hard-BE
  activation snapshot is the pre-attempt inventory derived from the
  parity-verified entry/liquidation events (11/11); selects the activation's
  authoritative attempt as the earliest hard-BE attempt across `LegTrace`,
  `LiquidationTrace` and tail `RejectionTrace` rows (fixing the
  rejected-then-later-filled case); asserts the causal same-timestamp lifecycle
  order (hard-BE activation before its enabling attempt, Margin Call
  alternation and active state at Stop Out, each Stop Out before its episode's
  first forced liquidation and after the previous episode's last, trailing
  activation before the close, `basket_liquidated` after the last forced close,
  ascending same-quote ordinals); completes the `run_ended` failure identity
  (kind/condition/message/faulting quote) and computes the expected run-end
  time with the documented `max(lastProcessedQuote, failureQuote)` rule (with
  forward-time and out-of-order failed-run positive fixtures); compares
  `manifest.algorithmTimeZone`, `startUtc`, `endUtc`, the `outcome` block,
  `counters.engineRealizedProfit` and the documented payload-file order; and
  enforces exact-string serialization for hard-BE targets, rejection decimals
  and the remaining manifest decimals. The record is now byte-reproducible
  (run-directory name only, sorted event-type counts).
- **Verifier proof expanded.** The verifier record on the exact run became
  **PASS, 25,727 checks including 24,191 authoritative payload-parity
  comparisons** (record SHA-256
  `753eeda149d661a10726cc465867e0d6feaf2fd9b279577a4b0c26f9f97b9b4e`);
  `tests\Test-SingleAnchorReplayPackageVerifier.ps1` rejects **22/22**
  mutations (including activation-snapshot replacement, activation ordering,
  the later-fill time, trailing threshold, Margin Call value/order and
  string-to-number decimal cases) and verifies **2/2** positive failed-run
  fixtures.
- **Evidence fixes.** The committed telemetry sample now contains all 11
  hard-BE activation snapshots and the snapshot of the immediately following
  attempt (pre-attempt 4 positions, post-entry 5); the committed part manifests
  are byte-identical to the verified files. The previous evidence manifest and
  its hash references are superseded.

### 1.3 Third independent-review corrections (this revision)

- **Snapshot-binding control-flow fix (the third review's main defect).** The
  inventory loop previously `continue`d for `entry_executed` and
  `forced_liquidation`, so those 555 + 65 snapshots skipped the snapshot checks
  and the forced-liquidation post-close comparison was unreachable. The loop now
  updates the derived inventory first and then validates every significant
  event: snapshot time equals the event time, the applicable quote is the event
  quote (`triggerQuoteSequence` for forced liquidation, `0` at run start,
  `quoteTicksProcessed` at run end), snapshot account values equal the event
  `after*` values for forced liquidation, and the derived inventory matches the
  snapshot (post-entry for entries, post-close for forced liquidation).
- **Missing/duplicate/unknown event detection.** The verifier now enforces the
  published event-type whitelist, exactly one `run_started` and one
  `run_ended`, the one-to-one `trailing_activated` lifecycle (at most one per
  basket; every authoritative Trailing close has exactly one activation), the
  `first_entry_skipped` population bound to `SkippedFirstEntryTrace`, the
  rejection-recap order against the authoritative `RejectionTrace` order, and
  the terminal mapping of `hard_breakeven_violated` to the documented
  `StrategyInvariant`/`HardBreakevenViolatedByFill` failure.
- **Exact-string coverage completed.** Missing decimals were added
  (`forced_liquidation.normalizedRequiredLot`/`commission`,
  `basket_liquidated` close fields, `first_entry_skipped`,
  `basket_close_failed`, `hard_breakeven_violated`, nullable
  `run_ended.failureBid/failureAsk`), and every numeric manifest parameter and
  margin parameter must now be a JSON string.
- **Margin Call authority.** `margin_call_entered` must satisfy the configured
  Margin Call condition (`level <= MarginCallLevelPercent`),
  `margin_call_left` must be outside it (or flat/null), and the account
  identities `equity = balance + floatingProfit`,
  `freeMargin = equity - usedMargin` and the exact
  `MarginLevelPercent = equity / usedMargin * 100` ratio are checked on margin
  events, Stop Out, forced liquidation and the run-end snapshot (numeric-scale
  tolerance `1e-20`; the frozen run contains last-digit artifacts of order
  `1e-25`).
- **Verifier proof expanded again.** The verifier record on the exact run
  became **PASS, 30,467 checks including 28,917 authoritative payload-parity
  comparisons** (record SHA-256
  `795710515caf47c8b617c26ccdb90f90cb04cfbfd8ff23fd47c79d6c37b50465`);
  `tests\Test-SingleAnchorReplayPackageVerifier.ps1` rejected **36/36**
  mutations (adding entry/forced snapshot binding, duplicate/unknown/spurious
  events, swapped rejection recaps, impossible Margin Call state and the new
  exact-string cases) and verified **2/2** positive failed-run fixtures. The
  evidence manifest at that point was `d57b2d79...`.

### 1.4 Fourth independent-review corrections (this revision)

- **Margin Call arithmetic completed.** The Margin Call block now also checks
  `equity = balance + floatingProfit` from the snapshot (not only
  free-margin/level), so corrupting balance in the event and snapshot together
  is rejected.
- **Reason-specific Stop Out validation.** `MarginLevel` requires a defined
  level at or below `StopOutLevelPercent`, open positions and an active Margin
  Call; `NegativeEquity` requires `equity < 0` with open positions and no
  defined-level/Margin Call requirement, mirroring `EvaluateSurvival` exactly.
- **Contract-consistent synthetic fixture.** The base fixture has strictly
  sequential baskets (one active basket at a time), monotonically non-decreasing
  live and telemetry quote sequences, a legal 20% MarginLevel Stop Out with an
  active Margin Call, coherent account identities, alternating entry sides with
  boundary-triggering quotes, an ambiguous skipped-first-entry quote, the
  producer's `forced_liquidation -> margin_call_left -> basket_liquidated`
  ordering, and a skipped-first-entry trace with `Attempts = 3` beside the
  single emission (`attempts = 1`) event. Its ledger, parity and account
  identities follow the producer's contracts; its quote path is constructed for
  the exercised rules, so it is not a full strategy replay.
- **Lifecycle and sequence contracts.** The verifier now enforces the
  one-active-basket lifecycle (an anchor closes the previous basket; only the
  last basket may remain open), live and telemetry quote-sequence
  monotonicity/range against `quoteTicksProcessed`, and run-start `time`
  equality with `manifest.startUtc`.
- **Remaining identity coverage.** `manifest.securityType` (frozen `Cfd`),
  `researchAccountEnabled`/`marginEnabled`, `delivered` presence symmetry,
  per-file `year` identities and per-row shard years, `entry_executed`
  `sizingOutcome` by regime, rejection `sizingOutcome`/`maximumVolume`,
  `eventCounts` whitelist/positive counts, and the bidirectional
  `hard_breakeven_violated` ⇔ `StrategyInvariant`/`HardBreakevenViolatedByFill`
  mapping (exactly one event, bound to the failure quote) are enforced.
- **Verifier proof completed.** The verifier record on the exact run is now
  **PASS, 32,805 checks including 31,255 authoritative payload-parity
  comparisons** (record SHA-256
  `273350ca61342f8b8541bf5c29e9d79431a881daad399d4d05fdfccd663063f6`);
  `tests\Test-SingleAnchorReplayPackageVerifier.ps1` rejects **54/54**
  mutations and verifies **4/4** positive fixtures (forward-time fault,
  out-of-order fault, negative-equity Stop Out, terminal hard-BE violation).
  The evidence manifest at that revision was `e4985b48...`.

### 1.5 Fifth-round fixture and documentation cleanup (this revision)

- **Terminal hard-BE violation semantics.** The positive fixture now matches the
  engine: the tail order fills and enters the basket ledger, then the engine
  throws before `EntriesOpened`/`EntryOpened` and before any strategy
  continuation. The fixture has exactly one `hard_breakeven_violated` event
  bound to the failure quote, the faulting leg in the final open basket state
  with **no** normal `entry_executed` event, no later close, and a consistent
  post-fill account state. The verifier exempts exactly that leg from the entry
  population/ordering checks and still enforces cardinality, failure mapping
  and quote binding; missing and duplicate violation events are rejected.
- **Fixture description accuracy.** The synthetic package is no longer described
  as a possible engine run. It is a contract-consistent synthetic verifier
  fixture: its ledger, parity and account identities follow the producer's
  contracts, while its quote path is constructed for the exercised rules (it is
  not a full strategy replay or proof that every producer execution is
  accepted). The base fixture also now uses strict side alternation with
  boundary-triggering quotes, a genuinely ambiguous skipped-first-entry quote,
  and the producer's `forced_liquidation -> margin_call_left ->
  basket_liquidated` ordering.
- **Credible NegativeEquity fixture.** Its states now use the frozen
  uncovered-volume used-margin model, and its balance transitions correspond
  exactly to the recorded forced-liquidation realized results.
- No verifier behavior changed for the real package at that revision: the verification
  record and evidence manifest hashes were unchanged
  (`273350ca...` and the then-current `e4985b48...`; section 1.6 records the later
  counter refresh).

### 1.6 Sixth-round terminal-violation fixture and enforcement cleanup (this revision)

- **Verifier terminal enforcement.** For a `HardBreakevenViolatedByFill` failure the verifier
  now requires the diagnostic key to be exactly one leg of the final `openBasket.LegTrace`
  (not merely somewhere in a LegTrace), with no normal `entry_executed` for it, binds the
  diagnostic `tradeNumber`/`side`/`placedLot`/`fillPrice`/`time`/`quoteSequence` to that leg,
  and rejects any live event after the diagnostic other than run-end recaps and `run_ended`.
- **Producer-level C# test.**
  `ReplayRecorderTests.ATerminalHardBreakevenViolationIsRecordedWithoutAnEntryEvent` drives
  the real engine/recorder path with an off-model fill: the faulting leg stays in the
  terminal basket ledger with no entry event, the single diagnostic binds to it, and no
  continuation is recorded (C# tests now **315/315**, 18 Phase E tests).
- **NegativeEquity fixture.** The initial trigger is now a genuinely net-flat inventory
  (zero used margin, undefined margin level) so it really exercises the `NegativeEquity`
  branch; later re-evaluations may legitimately become `MarginLevel`.
- **Base fixture trace corrections.** The retained basket-3 rejection is one rejected attempt
  at its own quote (the later fill is not a second rejected attempt), and the fully closed
  Stop Out episode is sealed `AllPositionsLiquidated`.
- **Post-fill diagnostic snapshot.** The terminal diagnostic's telemetry snapshot is now the
  exact post-fill account state (captured from the removed trade-5 entry snapshot before it
  is removed), matching the engine order ledger-add -> account observation -> hard-BE
  verification -> diagnostic; the C# producer test asserts the snapshot equals the account's
  post-fill balance/equity/floating/used-margin/positions/lots.
- **NegativeEquity sequence.** The initial trigger is `NegativeEquity`; after the first forced
  close the survivor is unmatched (defined negative margin level), so the second forced close
  is `MarginLevel`, with one `stop_out_triggered` event. The basket close economics follow the
  forced closes (`RealizedProfit`/`LiquidatedRealizedProfit` = -250).
- **Mutations.** Two focused terminal-semantics mutations were added (restoring a normal
  entry for the faulting leg; appending a live continuation after the diagnostic); the suite
  is **54/54** mutations with **4/4** positive fixtures. The real package, verifier record
  (`273350ca...`) and the package/Phase D identities are unchanged; the evidence manifest is
  now `825239f7...`.

### 1.7 Phase F-driven signed-net extension (2026-10-03, this revision)

The independent Phase F review kept the signed-net requirement (the strategy's
simultaneous opposing legs make direction fundamental) and required the value
to be exported authoritatively in Phase E through the smallest export-only
change. The original finalized record above is preserved unchanged; this
section records the later revision.

- **Contract decision.** `netLots` is an additive signed-net telemetry
  extension of `marketlab-single-anchor-replay-package-v1`, not a silent
  redefinition of it. The original finalized v1 package (without `netLots`)
  remains valid: the extension-aware verifier passes it with **136,027 checks
  including 134,477 payload-parity comparisons**, and that compatibility record
  is committed as
  `MarketLab/evidence/20261003-phase-e-signed-net-export/original-v1-verification.json`
  (the historical v1 record remains in the untouched
  `MarketLab/evidence/20261002-phase-e-replay-export/`). A package that carries
  the extension must carry it on every event and periodic row; the verifier
  then requires the field, checks `absoluteNetLots = |netLots|` on every row,
  and checks the sign against its independently derived basket inventory for
  **every event snapshot where inventory is defined** (all event types except
  the terminal hard-BE diagnostic, which by design carries a leg with no normal
  entry event) and for every periodic sample. `REPLAY_PACKAGE.md` section 9
  documents the extension.
- **Producer.** `ResearchAccount` exposes `CurrentNetLots` from the same
  observation that computes `_absoluteNetLots`, and `ReplayRecorder` writes it
  as an exact decimal string. No strategy, margin, liquidation, sizing or trade
  behavior changed.
- **Re-run and binding.** The frozen corrected-full-history command was
  re-executed at clean revision
  `f1bdc8fbc949bc3470deaaf8d16d013df7a1c473` (launched 2026-10-03T14:31:24Z,
  LEAN elapsed 5,201 s, LEAN exit 0, helper exit 0, zero engine `ERROR::`
  lines), classified `EXPECTED` (`invalidCount` 0, 407/407 failed requests
  reconciled). `results.json` is byte-identical to the Phase D artifact
  `bc3958b2...`; `events.jsonl` is byte-identical to the previous export
  (`2eb4d846...`) because only telemetry serialization changed.
- **New package identity.**
  `d145a49b548fe9356f1355d33df3329f87ce667cd15b367369219b8f27a9ccb4`;
  the verifier record on the exact run is **PASS, 238,428 checks including
  236,878 authoritative payload-parity comparisons**,
  `resultsBoundToPhaseD: true`, `telemetrySignedNet: true`,
  `telemetryEventSnapshotInventoryParity: true` (record SHA-256
  `75440db3158cf10a38c956054d624da3ccdf5f07644384261a24facbdc1eaa60`).
  The periodic derivation accepts the derived state before or after same-quote
  events, because a periodic sample can be written on either side of a
  same-quote event snapshot; a sign flip that matches neither state is
  rejected.
- **Verifier proof.** `tests\Test-SingleAnchorReplayPackageVerifier.ps1` now
  rejects **59/59** mutations (adding periodic and Margin Call `netLots` sign
  flips that the derived event/periodic direction parity catches) with **4/4**
  positive fixtures; the C# tests are **315/315**.
- **New evidence.** The signed-net run has its own directory,
  `MarketLab/evidence/20261003-phase-e-signed-net-export/` (manifest SHA-256
  `f98263618bde5d2cd24542e028d322d0bab35074c430ce6b0bdb4c7a4b22f685`),
  with the new receipts, classification, verifier record, package manifest, a
  regenerated 49-row telemetry sample carrying `netLots`, and byte-identical
  copies of the unchanged candle evidence. The finalized 20261002 evidence
  directory and the candle cache were not modified.

## 2. Phase D preservation and binding

Phase D is not rerun as a characterization and not rewritten. The corrected
Phase E export run executes the frozen corrected-full-history command with the
Phase E implementation revision, and its persisted `results.json` is
**byte-identical** to the Phase D artifact:

- Phase D artifact SHA-256: `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`;
- Phase E run artifact SHA-256: `bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`;
- byte comparison: **identical**.

The package manifest's delivered-stream identity reproduces the Phase D values
exactly (`413,750,130` quotes, semantic digest
`sha256:231cf63850cd033ea8167ab7d0017bdfbd7744f40412c1a899c2b9d98942886a`,
first `2019-01-01T23:00:07.151Z`, last `2026-06-30T23:59:59.678Z`). The Phase A
evidence, Phase B implementation record, Phase C bounded qualification and
Phase D result/evidence are unchanged; `config/baseline-contract.json` and
`config/corrected-full-history-contract.json` are unchanged.

## 3. Package contents and completeness

Authoritative event stream (1,454 events, `events.jsonl` SHA-256
`2eb4d8464d2ef4e7c95e6862a3253a9afbd952222f3c5e5ce9818cd96e67cc42`):

| Event | Count | Cross-check |
|---|---|---|
| `run_started` / `run_ended` | 1 / 1 | run identity and final counters |
| `basket_anchored` | 280 | 278 closed + 1 liquidated + 1 open (`openBasket`) |
| `entry_executed` | 555 | 490 surviving `LegTrace` + 65 `LiquidationTrace` identities |
| `strategy_exit` | 278 | `basketsClosed` (207 Trailing, 71 Escape) |
| `basket_liquidated` | 1 | `basketsLiquidated` (basket #279) |
| `stop_out_triggered` | 5 | `researchMargin.StopOutEpisodes` |
| `forced_liquidation` | 65 | `forcedLiquidations`, each with exact before/after account state |
| `hard_breakeven_activated` | 11 | baskets with hard-BE mode active; all pre-attempt snapshots |
| `trailing_activated` | 207 | the 207 trailing closes |
| `margin_call_entered` / `margin_call_left` | 23 / 23 | 23 episodes, final state inactive |
| `entry_rejected` | 2 | `distinctRejectedEntries` (all `InsufficientMargin`) |
| `entry_rejection_summary` | 2 | run-end recaps of the 346,942,369 compressed attempts |

Account telemetry (98,866 periodic samples plus 1,452 event snapshots, shards
`telemetry-2019/2020/2021/2026.jsonl`) exposes the exact balance, equity,
floating and realized P/L, used/free margin, margin level, Margin Call state,
open positions, gross lots and absolute net lots at every significant event and
at most every 300 simulated seconds while positions are open. No quote row is
exported.

The verifier returned **PASS** on the exact run - 32,805 checks including 31,255
authoritative parity comparisons - with the Phase D binding enforced
(`-ExpectedResultsSha256 bc3958b2...`); its record is
`MarketLab/evidence/20261002-phase-e-replay-export/replay-package-verification.json`
(SHA-256 `8abc269861c4a3bbeaa65d44c571016475c33b5f4bccddb04f5558da89dc586c`;
the record is byte-reproducible across verifier runs).

## 4. Determinism and local validation

- Bounded determinism: two identical bounded executions of the corrected model
  over `2019-01-01..2019-02-15` (including hard-BE activations) produced
  byte-identical `results.json` (`07ab303d...`), `events.jsonl`,
  telemetry and manifest (package
  `344db104429c648645282a719d23f765328dfc41b18e1173ad2eb11300e9326d`);
  both runs passed the strengthened verifier (523 checks).
- Behavior invariance of the corrections: the bounded March 2020 window
  (`results 81ba0304...`, 6,124 verifier checks) and the low-cash rejection
  window (`results 697bd85e...`, 206 checks) are byte-identical to the results
  produced before the corrections, and the full corrected run reproduced the
  Phase D result exactly.
- Focused tests: **315/315** C# tests (18 new Phase E tests including the
  pre-attempt hard-BE activation snapshots on the filled and rejected paths and
  the fail-closed publisher).
- PowerShell: launch/build guards 40/40, baseline invocation 12/12,
  failed-data classifier 97/97, trading availability 12/12, corrected-full-
  history classifier tests 160/160, production delivery end-to-end 40 checks,
  and the package-verifier suite (**54/54** mutations rejected plus four positive
  failed-run fixtures verified).
- Python historical data: **300/300** tests, including the fail-closed candle
  preflight, `verify-candles` and `verify-candle-composition`.
- The corrected export run classified `EXPECTED` (exit 0, `invalidCount` 0)
  with the complete qualified stream and all 407 failed data requests
  reconciled exactly as in Phase D.

## 5. Candle cache (derived visualization data)

`python -m marketlab_historical_data candles` generated the full M1 cache from
the qualified tree into `E:\MarketLab\data\lean\xauusd-m1-candles`:

- 90 monthly CSVs (2019-01 .. 2026-06), 2,332 partitions and 413,750,130 source
  rows read, 2,655,664 candle rows, 172,160,895 bytes;
- `content_sha256`
  `ab1b0c7f4321afc7ba31e149e31631a6c61deba40a88091ba951d5d886165d9d`; the
  final cache manifest (SHA-256
  `75f1d2415e6d7012022c70c527370258d42dcbd9ac2c992af7540126650b23a1`) and
  every per-file hash are committed;
- derivation: mid-of-best-bid/ask in exact decimal, UTC minutes, non-empty
  minutes only, absent minutes never filled; positive uncrossed quotes, the
  qualified composition, a PASS qualification record bound to the composition
  hash and a UTC `data_time_zone` are preconditions, and every selected
  partition's zip and member hashes/row count are verified while reading;
- because the local command runner terminates a single command at about one
  hour, the cache was produced in four contiguous **month-aligned** ranges and
  merged byte-for-byte with the documented recipe; month independence holds
  only for month-aligned bounds (a mid-month bound is a partial-month file).
  The four part manifests are committed under
  `MarketLab/evidence/20261002-phase-e-replay-export/candle-parts/`, and
  `verify-candle-composition` proves the final cache is their exact contiguous
  union (10/10 checks);
- **source derivation proven (second review).** The same four ranges were
  regenerated with the corrected fail-closed generator under the reviewed
  revision; all **90/90** regenerated monthly records equal the existing final
  cache byte-for-byte (the CSV bytes were not changed), and the final manifest
  was rebuilt as the documented merge of the four corrected part manifests,
  which bind the PASS qualification record (`e9c72d1a...`). The committed part
  manifests are byte-identical to the verified files;
- `verify-candles` certifies the source identity and the cache (now requiring
  the qualification-record binding): 2,332/2,332 partition zip hashes verified,
  9/9 checks. The records are `candle-cache-verification.json` and
  `candle-composition-verification.json`.

## 6. Evidence

Committed compact evidence under
`MarketLab/evidence/20261002-phase-e-replay-export/` (manifest SHA-256
`825239f7af217879049f6032eda09db83a2093706fee12acaf78b1ef447a564c`) with a
SHA-256 manifest:

- the run's `baseline-build.json`, `corrected-history-preflight.json`,
  `marketlab-run-invocation.json`, `marketlab-run-outcome.json` and
  `corrected-full-history-classification.json` byte-identical copies;
- the package verifier record (`replay-package-verification.json`, SHA-256
  `273350ca61342f8b8541bf5c29e9d79431a881daad399d4d05fdfccd663063f6`) and the
  package manifest (`replay-manifest.json`);
- the complete authoritative event stream (`replay-events.jsonl`) and a bounded
  account-telemetry sample (`replay-telemetry-sample.jsonl`) that includes all
  11 hard-BE activation snapshots and the snapshot of the immediately following
  attempt;
- the rebuilt candle cache manifest, `candle-cache-verification.json`,
  `candle-composition-verification.json` and the four byte-identical
  re-derived part manifests (A `d0489504...`, B `8f38b981...`, C `f329daa1...`,
  D `20fdabec...`).

The full telemetry shards (45.2 MB), the engine/algorithm logs, the LEAN result
packets, the run console capture and the candle cache itself remain local run
artifacts identified by SHA-256 in the evidence manifest; the run's
`results.json` is not duplicated because it is byte-identical to the Phase D
artifact committed in the Phase D evidence directory.

## 7. Limitations

- The package requires the research account (`single-anchor-research-account`,
  default true); the frozen Phase E command has it enabled.
- Periodic account telemetry is sampled at most every 300 simulated seconds;
  every significant event has its exact snapshot.
- Individual rejected-entry attempts are not exported (one live event per
  distinct episode plus a run-end recap).
- A recorder fault refuses the package build, and a failed payload suppresses
  the manifest, so the evidence gate cannot certify an incomplete export; the
  strategy run itself is never aborted by the recorder.
- The merge of the four candle parts was performed by the documented recipe and
  is verified by `verify-candle-composition`; the merge itself is not a shipped
  command (the re-derived part caches and their 90 matching monthly records are
  the derivation evidence).
- Trailing-activation exact parity is limited by what Phase D retains: the
  verifier enforces the one-to-one lifecycle relation, the derived
  `activationThreshold`, the snapshot time/quote binding and
  `profit >= threshold`, but the activation's exact historical identity -
  `time`, `quoteSequence`, `bid`, `ask` and `profit` - is not independently
  re-derived from a retained authoritative trace because the frozen
  `results.json` has no dedicated activation record. Reconstructing the
  strategy economics inside the gate is deliberately avoided.
- Margin Call transitions have the same limit: Phase D retains the episode
  count, the final state and the Stop Out episodes, but not every enter/leave
  quote identity. The verifier provides state/lifecycle qualification
  (alternation, count, threshold and arithmetic relations, event-to-snapshot
  equality, active state for MarginLevel Stop Outs), not exact
  Phase-D-retained payload parity for those transitions.
- `basket_close_failed` has no independent Phase D trace; it is constrained
  structurally (published type, snapshot binding, exact strings, active-basket
  membership) but its occurrence cannot be proven from retained results. The
  frozen run contains none.
- The free-margin and margin-level identities are compared with a numeric-scale
  tolerance of `1e-20`; the frozen run contains last-digit decimal scale
  artifacts of order `1e-25`, far below any meaningful corruption.
- The long run used a temporary AC power-plan change (standby and display
  disabled). Both original values were captured and restored exactly
  (`STANDBYIDLE` `0x00001c20`, `VIDEOIDLE` `0x00000258`).

## 8. What did not change / not started

- No strategy parameter, account/margin value, execution economic, liquidation
  rule, trade-numbering semantic or data identity changed.
- The 413,750,130-row historical-data qualification was not rerun; no parameter
  optimization or sensitivity sweep occurred; no hosted CI was dispatched.
- The LuxAlgo adaptation (Phases F-H) and the Fincept integration (Phase I)
  have not started.
