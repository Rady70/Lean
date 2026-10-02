# MarketLab SingleAnchor authoritative replay package (Phase E)

Status: **implemented and corrected after independent review; the authoritative
package was produced by the corrected Phase E export run and qualified by the
strengthened package verifier (PASS, 32,805 checks including 31,255
authoritative payload-parity comparisons, bound to the byte-identical Phase D
result).
Phase E is ready for re-review; later replay/visualization phases (F–I) have not
started.**

Corrected Phase E export run: `Rady70/Lean` revision
`a2941581c02462a190f4d4289f371aed409cb1e3`, classified `EXPECTED`; package
SHA-256 `5dcd8bfaffe76c9d2c8eec002073f62fe18b5d0d40b0602dbad0e59f6846097a`
(1,454 events, 1,452 event snapshots, 98,866 periodic samples). Full record:
[PHASE_E_REPLAY_EXPORT_RESULT.md](PHASE_E_REPLAY_EXPORT_RESULT.md).

This document is the contract of the deterministic replay package the
SingleAnchor host emits next to its strategy result. It exists so a later
replay/visualization consumer can show exactly what the finalized LEAN run did
without re-deriving, netting, renumbering or recomputing anything.

The governing boundary is unchanged:

> **LEAN determines what happened. LuxAlgo shows what happened. Fincept launches
> and navigates the result.**

## 1. Authority and scope

- The authoritative strategy, account, margin and broker-liquidation semantics
  remain the persisted `single-anchor/results.json` written by
  `SingleAnchorVNextAlgorithm` (the Phase D record). The replay package is
  additive output of the same run and does not replace it.
- The recorder observes the engine's existing events and the research account's
  existing observations. It owns no strategy state, makes no decision and never
  mutates the engine or the account. Wiring it cannot change a decision, a fill,
  an account value, an event order or the persisted results.
- Candles are **derived visualization data** from the already-qualified
  Dukascopy quote history (section 6). They are never an authority over the
  native partitions or over the authoritative events.
- No Phase E output changes the frozen strategy parameters, account/margin
  values, Stop Out model, execution economics, qualified data identity or the
  Phase A–D evidence.

## 2. Package location and files

Written to the run's object store under `single-anchor/replay/` (on disk:
`<run>\storage\single-anchor\replay\`):

| File | Content |
|---|---|
| `events.jsonl` | one JSON object per line, in exact engine occurrence order, each with a strictly increasing `id` injected as the final property |
| `telemetry-YYYY.jsonl` | account telemetry shards, one UTC calendar year per file, ascending year order, one JSON object per line (`kind` = `event` or `periodic`) |
| `manifest.json` | the run identity, sampling interval, per-file `name`/`sha256`/`bytes`/`lines`, event-type counts, telemetry counts, outcome and the package fingerprint |

Every decimal is a JSON **string** in invariant-culture canonical text exactly
as the strategy computed it; every timestamp is
`yyyy-MM-ddTHH:mm:ss.fffZ` UTC. No wall-clock value, machine path or random
value is written.

`packageSha256` is the SHA-256 over the concatenated payload rows
`name\nsha256\nbytes\n` (UTF-8, LF) in the manifest's file order: `events.jsonl`
first, then the telemetry shards by ascending year. The manifest is excluded
because it cannot contain its own hash. `manifest.json` is LF-normalized so the
package bytes do not depend on the platform.

## 3. Event stream

Every event line carries `type`, `time` (except the run-end recaps), and `id`.
The stream covers the plan's event list:

| `type` | Meaning | Key exact values |
|---|---|---|
| `run_started` | run identity | model revision, stop-out model, symbol/market, window, quote time zone |
| `basket_anchored` | a basket was anchored | basket, quote sequence/time/bid/ask, anchor, step, upper, lower, hard-BE lower/upper targets |
| `hard_breakeven_activated` | the basket entered hard-BE mode | basket, trade number, quote identity, both hard-BE boundaries |
| `entry_executed` | a leg was filled | immutable trade number, side, placed lot, fill price, regime, raw/exact/normalized requirement, hard-BE sizing when applicable, decision quote |
| `entry_rejected` | a new rejected-entry episode | trade number, side, reason, candidate requirement, margin assessment, message, quote identity |
| `entry_rejection_summary` | run-end recap of one compressed rejection episode | attempts, first/last quote identity, parity hash/algorithm, min/max requirement and projected free margin, message |
| `first_entry_skipped` | ambiguous first-entry quote skipped | basket, quote identity, spread, attempts |
| `trailing_activated` | trailing activated | basket, profit, activation threshold, quote identity |
| `strategy_exit` | a strategy close (Trailing/Escape/FixedTakeProfit) | reason, closing quote, legs/lots, raw/exit/threshold, close prices, commission, realized result |
| `basket_liquidated` | every position was broker-liquidated | same shape, reason `BrokerLiquidation` |
| `stop_out_triggered` | the Stop Out condition started an episode | reason, trigger quote, balance/floating/equity/used/free/margin level/open positions |
| `forced_liquidation` | one deterministic broker-forced close | immutable leg identity, ordinal, executable close price/time, trigger quote identity, realized P/L, and the exact account state `before*`/`after*` |
| `basket_close_failed` | the executor refused a close; the basket stays open | reason, quote, message |
| `hard_breakeven_violated` | the post-fill verification failed (run stops) | leg, target, projected P/L after fill, message |
| `margin_call_entered` / `margin_call_left` | Margin Call state transitions | quote identity, balance/equity/margin state, open positions |
| `run_ended` | final run outcome and counters | completed/failure kind/condition/message, faulting quote identity when a run was refused, delivery identity, every final engine counter and the final account snapshot |

`entry_rejection_summary` events are deliberately snapshot-less recaps: they are
appended at run end but carry historical `firstTime`/`lastTime` identity, so they
are outside the live event clock. The live `entry_rejected` event of the episode
does carry an exact account snapshot.

## 4. Account telemetry

Every significant event gets exactly one `kind=event` snapshot (`eventId`
references the event). A `kind=periodic` sample is added at most once per
`telemetryIntervalSeconds` of simulated time while positions are open, and never
while flat. Both expose the exact research-account values:

`balance`, `equity`, `floatingProfit`, `floatingObservable`, `realizedProfit`,
`usedMargin`, `freeMargin`, `marginLevelPercent`, `marginCallActive`,
`openPositions`, `grossLots`, `absoluteNetLots`, plus the quote time/sequence.

The authoritative `results.json` remains the run-level account record; the
package is the event-ordered, bounded presentation of the same account.

## 5. Determinism and provenance

- The package is deterministic: the same inputs produce byte-identical events,
  telemetry and manifest (the manifest body is LF-normalized; file order and
  JSON property order are fixed).
- The manifest carries the run identity (model revision, stop-out model, symbol,
  market, window, parameter block and margin parameters as exact strings,
  session-map identity) and the delivered-stream identity (quote count,
  semantic digest, first/last canonical UTC), all copied from the same run's
  authoritative values.
- Binding to the finalized Phase D characterization: the Phase E export run
  executes the same frozen corrected-full-history command and the run's
  `results.json` is required to be byte-identical to the Phase D artifact
  (`bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad`). A
  mismatch fails the evidence step; it is never resolved by changing parameters
  or by editing Phase D.

## 6. Candle cache (derived visualization data)

`python -m marketlab_historical_data candles --data-folder <qualified tree> --out <dir>`
derives monthly M1 candles from the qualified native partitions:
`mid = (bid + ask) / 2` in exact decimal text, UTC-minute buckets, OHLC from the
first/max/min/last mid in source order, `ticks` per minute, only non-empty
minutes (absent minutes are never filled), one UTF-8 CSV per UTC month and a
deterministic `manifest.json` with per-file hashes and the input identity. See
`tools/historical-data/README.md` section 10. The cache is never an authority
over the native source or over the authoritative LEAN events.

The committed cache was additionally proven to derive from the qualified source
under the corrected fail-closed generator: the same four month-aligned ranges
were regenerated under the reviewed revision, every one of the 90 regenerated
monthly CSV hashes (bytes, rows, first/last candle) equals the final cache
exactly, the final CSV bytes were not changed, and the final manifest was
rebuilt as the documented byte-for-byte merge of the four corrected part
manifests, which bind the PASS qualification record
(`inputs.qualification_record`). `verify-candles` requires that binding
(fail-closed) and `verify-candle-composition` proves the final cache is the
contiguous month-aligned union of those parts.

## 7. Verification

`MarketLab/scripts/Test-SingleAnchorReplayPackage.ps1` is the Phase E evidence
gate. It re-hashes every payload file against the manifest, recomputes the
package fingerprint, verifies the manifest against the run's `results.json`
(contract, identity, time zones, run bounds, parameters, margin parameters,
session map, delivered stream, outcome/failure, payload-file order and every
counter including `engineRealizedProfit`), and then compares the replay stream
itself against the authoritative `results.json` structures: every anchor
against `AnchorEvent`, every surviving entry against `LegTrace`, every forced
liquidation against `researchMargin.StopOutEpisodes[].Liquidations` (including
before/after account state and same-quote ordering), every Stop Out against its
episode, every rejection against `RejectionTrace`/summaries, every hard-BE
activation against the earliest authoritative hard-BE attempt across
`LegTrace`, `LiquidationTrace` and tail `RejectionTrace` rows, every trailing
activation threshold re-derived from the verified anchor step, surviving
inventory and parameters, every Margin Call transition against its snapshot
state, the configured Margin Call condition and the full
`equity = balance + floatingProfit` identity, every Stop Out against the
reason-specific `EvaluateSurvival` contract (`MarginLevel`: defined level at or
below `StopOutLevelPercent`, open positions, active Margin Call;
`NegativeEquity`: negative equity with open positions and no defined-level
requirement), and the run-end counters/snapshot/failure identity against the
final account, margin and `results.failure` state. It also proves every
significant event's snapshot is the account state at that event's exact time
and applicable quote (including the post-entry inventory for entries, the
post-close account for forced liquidation, `0` at run start and
`quoteTicksProcessed` at run end), compares all overlapping account values to
that snapshot, checks the account-arithmetic identities
(`equity = balance + floatingProfit`, `freeMargin = equity - usedMargin`, the
exact `MarginLevelPercent` ratio) to a numeric-scale tolerance, asserts the
causal same-timestamp lifecycle order (hard-BE activation before its enabling
attempt, Margin Call alternation and active state for MarginLevel Stop Outs,
each Stop Out before its episode's first forced liquidation and after the
previous episode's last one, `basket_liquidated` after the last forced close,
trailing activation before the close, ascending same-quote liquidation
ordinals), enforces the **one-active-basket lifecycle** (an anchor closes the
previous basket; only the last basket may remain open), live and telemetry
**quote-sequence monotonicity/range** against `quoteTicksProcessed`, run-start
`time` equality with `manifest.startUtc`, the published event-type whitelist
with exactly one `run_started`/`run_ended` and positive `eventCounts` keys
only, the one-to-one trailing-activation lifecycle, the
`first_entry_skipped`/`SkippedFirstEntryTrace` binding with emission semantics
(`attempts == 1`, authoritative first-quote spread, attempts sum equal to
`skippedFirstEntryQuotes`), the `entry_executed` `sizingOutcome` by regime,
rejection `sizingOutcome`/`maximumVolume`, the manifest
`securityType`/`researchAccountEnabled`/`marginEnabled`/`delivered`-presence
and per-file/per-row year identities, and the bidirectional
`hard_breakeven_violated` ⇔ `StrategyInvariant`/`HardBreakevenViolatedByFill`
mapping (exactly one event, bound to `results.failure.Quote`). It verifies
event ids/order/counts, exact-decimal strings in every event and telemetry
class (including the manifest parameter blocks), event-snapshot coverage, the
actual `telemetryIntervalSeconds` periodic rule while positions are open, and
(with `-ExpectedResultsSha256`) the Phase D binding. A failed run's run-end
time is checked against the documented
`max(lastProcessedQuote, failureQuote)` rule.

`tests\Test-SingleAnchorReplayPackageVerifier.ps1` drives 52 mutation cases over
a synthetic package that is itself a possible SingleAnchor run (strictly
sequential baskets, monotone quote sequences, a legal 20% MarginLevel Stop Out
with an active Margin Call, a valid skipped-first-entry trace, the hard-BE
reject-then-later-fill sequence, a trailing activation, two rejection
episodes): changed trade number, fill price, entry snapshot quote/inventory,
forced-liquidation ordinal/price/commission and snapshot time/trigger
quote/post-close account, Stop Out time and an impossible MarginLevel state,
same-quote reorder, backward event+snapshot quote sequences, run-start time,
manifest identity/outcome/parameter representation/securityType/delivered
presence/file year/eventCounts keys, file hashes, deleted events and snapshots,
over-frequent periodic sample, hard-BE activation snapshot replacement,
ordering and later-fill time, entry/rejection sizing outcomes and maximum
volume, trailing threshold/snapshot/duplicate changes, Margin Call value,
ordering, impossible state and joint balance corruption, skipped-entry
attempts/spread/counter changes, a duplicated trailing activation, an extra
`run_started`, a spurious `first_entry_skipped`, an unknown event type, swapped
rejection recaps, and exact strings replaced by JSON numbers in events,
forced-liquidation/close payloads and manifest parameters; each must be
rejected. It also verifies **four positive fixtures**: a forward-time fault
whose quote is later than the last accepted quote, an out-of-order fault whose
quote precedes it, a NegativeEquity Stop Out with no active Margin Call, and a
terminal hard-BE violation with its one diagnostic event; it rejects a tampered
failure identity, a run-end time that ignores the `max` rule, a numeric
`failureBid`, a missing violation event behind the failure and a duplicate
violation event. The verifier writes
`replay-package-verification.json` and exits 0 only on PASS. A mutation of the
committed event values that preserves all hashes and counts is caught by the
parity, derivation or ordering comparisons, not only by the repository's own
replay of the same code.

```powershell
pwsh -File MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1 `
    -RunDirectory <run> `
    -ExpectedResultsSha256 bc3958b2629e8930ef8de3890cac9c80006f26d7c8dffdf5ecf54d6a6aa9bdad
```

## 8. Limitations

- The package requires the research account (`single-anchor-research-account`,
  default true); a run with the account disabled logs that no package is
  emitted. The authoritative Phase E run has it enabled.
- The periodic telemetry interval is fixed at 300 simulated seconds; the exact
  per-event snapshots carry every significant state.
- A recorder failure refuses the package build (no partial package) so the
  evidence gate cannot certify an incomplete export; the strategy run itself is
  never aborted by the recorder.
- Entry rejections are represented as one live event per distinct episode plus a
  run-end recap; individual attempts (hundreds of millions on the frozen run)
  are deliberately never exported.
- Exact trailing-activation parity is limited by what Phase D retains: the
  frozen `results.json` has no dedicated trailing-activation record, so the
  verifier enforces the one-to-one lifecycle relation, the parity-derived
  `activationThreshold`, the snapshot time/quote binding and `profit >=
  threshold`, but the activation's exact historical identity - `time`,
  `quoteSequence`, `bid`, `ask` and `profit` - is not independently re-derived
  from a retained authoritative trace. Reconstructing the strategy economics
  inside the gate is deliberately avoided.
- The Margin Call transitions have the same provenance limit: Phase D retains
  the episode count, the final `MarginCallActive` state and the Stop Out
  episodes, but not every enter/leave `time`/`quoteSequence`/`bid`/`ask`. The
  verifier therefore provides state/lifecycle qualification (alternation,
  count, threshold relation, event-to-snapshot equality, complete arithmetic
  identities, margin-call-active at MarginLevel Stop Outs) rather than exact
  Phase-D-retained payload parity for those transitions.
- `basket_close_failed` is a producer-observed diagnostic with no independent
  Phase D trace. The verifier constrains it structurally (published type,
  snapshot time/quote binding, exact-string decimals, membership of the active
  basket) but cannot prove its occurrence from retained results; the frozen run
  contains none. Deliberately no second exit/close implementation is added.
- The free-margin and margin-level identities are compared with a
  numeric-scale tolerance of `1e-20`; the frozen run contains last-digit
  decimal scale artifacts of order `1e-25`, far below any meaningful
  corruption.
