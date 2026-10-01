# MarketLab SingleAnchor authoritative replay package (Phase E)

Status: **implemented; the authoritative package is produced by the finalized run
and qualified by the package verifier. Phase E is ready for independent review;
later replay/visualization phases (F–I) have not started.**

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

## 7. Verification

`MarketLab/scripts/Test-SingleAnchorReplayPackage.ps1` is the Phase E evidence
gate. It re-hashes every payload file against the manifest, recomputes the
package fingerprint, verifies the manifest against the run's `results.json`
(identity and every counter), verifies event ids/order/counts against the
authoritative counters, verifies exact-decimal strings in events and telemetry,
verifies event-snapshot coverage and the periodic bound, and (with
`-ExpectedResultsSha256`) enforces the Phase D binding. It writes
`replay-package-verification.json` and exits 0 only on PASS.

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
