# Phase B broker-liquidation March 2020 local qualification evidence

This directory preserves the compact evidence of the corrected Phase B model's
bounded local qualification over the former March 2020 failure region. The full
run directories (55.9M-quote logs, LEAN result packets and object storage) stay
outside Git under `E:\MarketLab\phaseb-march2020-correction\`; their
`results.json` identity is recorded in `manifest.json`.

- `manifest.json` — run identities, exact invocation, window, results hashes.
- `qualification-summary.json` — the two runs' totals, the trigger comparison
  against the preserved Phase A record, the determinism flags and every ordered
  `StopOutEpisodeRecord` (including each forced close's immutable leg identity,
  side, lots, entry price/time, liquidation time, triggering quote, close
  price, commission, realized P/L, ordinal and account state before/after).
- `run-parameters.txt` — the exact 30-value `single-anchor-*` parameter string.

## Method

Two independent runs of the real LEAN Release host on the qualified Dukascopy
XAUUSD data folder over `2019-01-01 .. 2020-04-30` — the frozen start date and
the former failure region plus five weeks of continuation — with the frozen
strategy parameter values (only `single-anchor-end-date` bounded), the frozen
session map and `single-anchor-margin-enabled=true`. The runs deliberately do
not use the frozen-baseline `-RunEvidence` contract binding, because that
contract asserts the full 2019-01-01..2026-06-30 window. The full 2019-2026
baseline and the 413,750,130-row data qualification were not run.

## Result

The two runs produced **byte-identical** `results.json`
(SHA-256 `b28336fc791df1d3d16b69a3e04dd16c657869091cb3eab5ffc38265735bdcef`,
1,202,916 bytes each), so the whole run — not only the liquidation sequence —
is deterministic.

- The pre-trigger path reproduces the preserved Phase A record exactly: basket
  #276, trigger quote sequence 51,304,749 at `2020-03-23T12:06:26.292Z`, the
  same bid/ask, balance 25,519.92800, floating -25,320.42700, equity 199.50100,
  used margin 1,157.8848069189189189189189189, margin level
  17.229779578062128554190460520%, 36 open positions.
- The corrected lifetime-economics model then force-closes 30 positions over
  four episodes on basket #276 (20, 8, 1, 1), realizing -25,051.42100. The
  survivors are never evaluated at their own survivor-only profit: the basket's
  Escape threshold is applied to the lifetime economics, so the basket stays
  open until the survivors have recovered the forced loss. It closes normally by
  Escape on `2020-04-13T18:24:10.475Z` at 1721.098 / 1721.212 with 6 survivors
  and a lifetime realized result of **+30.65700** (forced -25,051.42100 plus
  +25,082.07800 from the survivors).
- Through 2020-04-30: 55,873,930 quotes, 539 legs, 278 strategy closes, 0
  baskets fully liquidated, 30 forced closes over 4 episodes, realized
  +5,572.00500, final balance 25,572.00500, final equity 23,526.86200, open
  basket #279 with 19 positions.
- Least-profitable-first held over all 30 real forced closes and the
  equal-profit tie rule was never violated in either run.

This qualification is execution evidence only: it does not establish
profitability, does not determine the final 2019-2026 strategy outcome and does
not replace the later corrected full-history characterization (Phase D).

## Superseded evidence

The earlier Phase B qualification runs under `E:\MarketLab\phaseb-march2020\`
were produced before the lifetime-economics correction and are **not**
qualification evidence for this model. In particular, the earlier reported
basket #276 outcome (Escape with a lifetime result of -25,028.97300 while the
survivors were only +22.44800) demonstrated the defect: the survivors' own
profit was being compared with the escape threshold while the forced loss was
ignored. The corrected model gives the outcome above.
