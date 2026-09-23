# Session-map generator (MarketLab-owned)

`MarketLab.SessionMapTool` derives the source-session map the SingleAnchor historical replay uses
to apply the five-minute quote-only buffers. It reads the immutable Dukascopy/JForex **XAUUSD**
monthly CSV history, uses the strategy assembly's own session-junction rule and availability
classifier (`MarketLab.SingleAnchor`), and writes two research artifacts outside Git. The tool is
deliberately XAUUSD-specific: the junction rule was established from that history only, so any
other instrument or provider is refused rather than relabeled.

- the session map (`marketlab-single-anchor-session-map-v1`): every source session as its exact
  first and last observed quote timestamp in UTC, with source provenance (file count, row count,
  aggregate SHA-256, first and last quote) that the replay binds into its results;
- an optional stats file: the quote-only and tradable row counts per the runtime classifier, with
  the overall and complete-session populations and percentages kept separate.

## Build and run

```powershell
dotnet build MarketLab\tools\session-map\MarketLab.SessionMapTool.csproj --configuration Release

MarketLab\tools\session-map\bin\Release\MarketLab.SessionMapTool.exe `
    --source D:\quant_research_workspace\common\market_data\raw\XAUUSD_raw_history `
    --out D:\quant_research_workspace\work\lean\single-anchor-sessions\xauusd-sessions.json `
    --stats D:\quant_research_workspace\work\lean\single-anchor-sessions\xauusd-sessions-stats.json
```

Options: `--source <csv directory>` (required; Dukascopy/JForex XAUUSD monthly files named
`XAUUSD_<YYYY>_<MM>_DUKASCOPY_JFOREX_FULL.csv`, contiguous months, read-only), `--out <map.json>`
(required), `--stats <stats.json>` (optional), `--jobs <n>` (default `min(processor count, 8)`).

## What it does

1. Scans every monthly file in order (parallel per file) into junction-split segments, validating
   the header, the canonical `yyyy-MM-ddTHH:mm:ss.fffZ` timestamps, the exact five-column row
   shape (`timestamp,bid,ask,bidVolume,askVolume`, as PR-1's qualification requires), non-decreasing
   time and month contiguity, and the quote contract the engine/PR-1 path uses (Bid > 0, Ask > 0,
   `Ask >= Bid`); a timestamp-valid but price-invalid or wrongly shaped row fails the generation
   instead of moving a boundary. Each file is hashed (SHA-256).
2. Derives the sessions: adjacent segments belong to one session unless the gap fully contains the
   New York local settlement interval `17:00:00 <= t < 18:00:00`. The final session of the dataset
   gets no end (no close is fabricated); the source coverage end still bounds it at runtime
   (`ToAvailability`), and a quote after it is refused.
3. Classifies every source row again with the runtime availability classifier and counts the
   opening-buffer, tradable and closing-buffer rows per session.

Both passes complete before anything is published: the map and stats files are written only after
the classification pass succeeded, so a map on disk is a validated artifact, never a partial
result. `--out` and `--stats` must be different paths and must not point into the source directory
(the source file itself, any path under it, or the directory itself), so the tool can never
replace immutable source history; both checks run before the source is scanned. The loader
independently checks that adjacent sessions are separated by the declared
junction rule, that a completed session is at least ten minutes long (the two buffers may not
overlap), and that the source provenance is coherent (including `lastQuoteUtc` equal to the final
session's observed end when it has one).

The source is never modified. The map is deterministic: the same immutable source produces the same
map and stats byte for byte (`--jobs` only changes speed).

## Using the map in a run

`SingleAnchorVNextAlgorithm` takes `single-anchor-session-map`, absolute or relative to the run's
data folder. The helper's `-Parameters` cannot carry a value with `:`, so place the map under the
data folder and pass the relative path:

```powershell
powershell -File MarketLab\scripts\run-backtest.ps1 `
    -AlgorithmTypeName SingleAnchorVNextAlgorithm `
    -AlgorithmLocation MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll `
    -DataFolder <research data folder> -AllowMissingData `
    -Parameters "single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5,single-anchor-start-date:2019-01-01,single-anchor-end-date:2026-06-30,single-anchor-session-map:marketlab-sessions/xauusd-sessions.json"
```

An absolute path can be given through a config copy (`parameters` object) and `-Config`.
The loader requires the map's contract, v1 junction rule, ordered sessions and complete source
provenance, and accepts any quote clock (the UTC boundaries are converted to the subscription's
clock; the junction-rule zone is not required to equal it). The run log records the resolved map
path, its SHA-256, the junction-rule zone, the quote clock and the source identity;
`storage\single-anchor\results.json` carries `quoteTicksProcessed`, `quoteOnlyQuotes`,
`strategyEligibleQuotes` and the `sessionMap` provenance block (configured parameter value, map
hash, session count, final-end observability, source file/row counts, aggregate hash, first quote
and coverage end). Without the parameter the run is unrestricted, exactly as before this feature.

## Evidence

See section 8 of [SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md](../../SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md)
for the full-history validation and the explanation of how the exact-timestamp counts relate to the
earlier investigation's minute-quantized evidence.
