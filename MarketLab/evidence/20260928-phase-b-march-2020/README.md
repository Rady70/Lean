# Phase B broker-liquidation March 2020 local qualification evidence

This directory preserves the source-bound evidence of the Phase B model's
bounded local qualification over the former March 2020 failure region.

- `manifest.json` — source revision, exact invocation, hashes, key results and
  the superseded-run list.
- `marketlab-run-invocation-run1.json` / `marketlab-run-invocation-run2.json` —
  the helper's machine-generated pre-run evidence for each run: repository HEAD
  (`d92580d74feafe7d42da0307fa979f493e1d085d`), clean-tree check,
  algorithm/launcher/config SHA-256 and the exact launcher arguments.
- `marketlab-run-outcome-run1.json` / `marketlab-run-outcome-run2.json` — the
  post-run outcome: exit codes, zero engine errors and the results SHA-256,
  which equals the SHA-256 of the committed canonical `results.json`.
- `results.json` — the complete canonical run result (run 1; run 2 is
  byte-identical). It contains every closed basket record with its
  `LiquidationTrace` and surviving `LegTrace`.
- `qualification-summary.json` — the two runs' totals, the trigger comparison
  against the preserved Phase A record, the determinism flags and every ordered
  `StopOutEpisodeRecord`.
- `run-parameters.txt` — the exact 30-value `single-anchor-*` parameter string.

## Method and source binding

Two independent runs of the real LEAN Release host on the qualified Dukascopy
XAUUSD data folder over `2019-01-01 .. 2020-04-30` — the frozen start date and
the former failure region plus five weeks of continuation — with the frozen
strategy parameter values (only `single-anchor-end-date` bounded), the frozen
session map and `single-anchor-margin-enabled=true`, launched with
`run-backtest.ps1 -RunEvidence` and without `-BaselineContract`/
`-BaselineRegister` (the frozen contract asserts the full
2019-01-01..2026-06-30 window). The full 2019-2026 baseline and the
413,750,130-row data qualification were not run.

The runs were launched from the clean committed source revision
`d92580d74feafe7d42da0307fa979f493e1d085d` (`repositoryDirty: false` in both
invocation files). Each qualification run records that clean source revision
together with the exact algorithm binary (DLL SHA-256), launcher,
configuration, runtime identities, invocation and result hash. This is strong
provenance evidence; without a source-bound build receipt for this bounded run
it is not a cryptographic proof that the DLL was compiled from that HEAD. The
evidence commit that contains this directory is a child of that revision and
changes only evidence/docs.

## Result

The two runs produced **byte-identical** `results.json`
(SHA-256 `b28336fc791df1d3d16b69a3e04dd16c657869091cb3eab5ffc38265735bdcef`,
1,202,916 bytes each): the complete persisted strategy result is deterministic
across the two executions. Other generated run artifacts (logs, timestamps,
elapsed times) naturally differ between executions.

- The pre-trigger path reproduces the preserved Phase A record exactly: basket
  #276, trigger quote sequence 51,304,749 at `2020-03-23T12:06:26.292Z`, the
  same bid/ask, balance 25,519.92800, floating -25,320.42700, equity 199.50100,
  used margin 1,157.8848069189189189189189189, margin level
  17.229779578062128554190460520%, 36 open positions.
- The corrected lifetime-economics model force-closes 30 positions over four
  episodes on basket #276 (20, 8, 1, 1), realizing -25,051.42100. The survivors
  are never evaluated at their own survivor-only profit: the Escape threshold
  applies to the lifetime economics, so the basket stays open until the
  survivors have recovered the forced loss. It closes normally by Escape on
  `2020-04-13T18:24:10.475Z` at 1721.098 / 1721.212 with 6 survivors and a
  lifetime realized result of **+30.65700** against the 22.1803125 threshold.
- Through 2020-04-30: 55,873,930 quotes, 539 legs, 278 strategy closes, 0
  baskets fully liquidated, 30 forced closes over 4 episodes, realized
  +5,572.00500, final balance 25,572.00500, final equity 23,526.86200, open
  basket #279 with 19 positions.
- Least-profitable-first held over all 30 real forced closes: independent
  reconstruction confirmed each selected leg was the actual least-profitable
  open position at that step. The March qualification encountered **no
  equal-profit tie**; the deterministic tie rule (higher immutable trade number
  first) is established by the focused unit test
  (`LiquidationTests.EqualProfitTiesCloseTheHigherImmutableTradeNumberFirst`),
  not by the historical run.

## Reconstructing the least-profitable-first selection

`results.json` contains enough to independently verify each forced close:

1. Take the `closedBaskets` record whose `Sequence == 276` (the array position
   is not the sequence number). Its `LegTrace` lists the 6 surviving legs and
   its `LiquidationTrace` lists the 30 removed legs, each with its immutable
   side, lots, entry price and realized P/L.
2. An episode's trigger quote (bid/ask) is carried on every one of its
   liquidation records; the open inventory at each step is the initial 36 legs
   minus the already removed ones.
3. Compute each open leg's executable P/L at the trigger quote (BUY at Bid,
   SELL at Ask, zero slippage/commission in the frozen configuration) and check
   that the leg actually removed is the minimum. If two open legs ever have
   equal executable P/L, the rule is the higher trade number first; the
   historical run contained no such tie, so this branch is covered by the
   focused unit test.

This qualification is execution evidence only: it does not establish
profitability, does not determine the final 2019-2026 strategy outcome and does
not replace the later corrected full-history characterization (Phase D).

## Superseded evidence

`E:\MarketLab\phaseb-march2020\` (pre-correction survivor-only economics) and
`E:\MarketLab\phaseb-march2020-correction\` (corrected economics but no
`-RunEvidence` source binding) are **superseded** and are not qualification
evidence for this model. Their earlier reported basket #276 Escape
(`-25,028.97300` lifetime while the survivors were only `+22.44800`)
demonstrated the survivor-only defect that the lifetime correction fixes.
