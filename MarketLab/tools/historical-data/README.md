# Historical dataset qualification and native-LEAN replay (PR 1)

This directory is the MarketLab-owned offline tooling that takes a historical
bid/ask CSV source and establishes whether it can be represented and replayed
through LEAN's native XAUUSD/Oanda CFD tick path without silently changing the
strategy input stream:

```text
historical CSV
      |
      v
strict qualification          MarketLab/tools/historical-data (Python, offline)
      |
      v
native LEAN quote-tick files  <research data folder>/cfd/oanda/tick/xauusd
      |
      v
actual LEAN data path         unchanged LEAN engine + MarketLab replay probe
      |
      v
quotes delivered to MarketLab  replay-result.json
      |
      v
qualification record          explicit PASS/FAIL
```

The authoritative plan is
[`../../SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md`](../../SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md)
(PR 1). The behavioural authority remains
[`../../SINGLE_ANCHOR_VNEXT_STRATEGY.md`](../../SINGLE_ANCHOR_VNEXT_STRATEGY.md);
the current C# implementation is authoritative for the quote contract.

Nothing outside `MarketLab\` changes. The upstream LEAN engine, projects,
solution, Launcher and data readers are untouched: the converter adapts the
source to LEAN's supported native input, never the other way around. Python is
offline preparation only and never runs in the per-tick strategy path. The
normal SingleAnchor backtest path is unchanged: the probe is a separate
assembly selected only when it is named explicitly, and the strategy assembly
is not modified.

## 1. The authoritative contract

A valid quote is exactly the `MarketLab.SingleAnchor.Quote` contract
(`src\SingleAnchor\Quote.cs`):

```text
Bid > 0
Ask > 0
Ask >= Bid
```

A zero spread is valid (`Ask == Bid`). The retired archive validator that
rejects zero spread is deliberately not used. Prices are exact decimal values:
the source may spell them with an exact exponent (`1.9e3`), which is parsed
exactly and written back in canonical fixed-point form, so the native file
LEAN reads never contains an exponent.

A valid source is additionally:

```text
timestamp is valid
timestamps are non-decreasing
equal timestamps are allowed
source order is preserved
```

Qualification is strict: `source -> validate -> PASS or FAIL -> convert only
after PASS`. It never silently discards invalid rows, sorts, deduplicates,
interpolates, fills, repairs values or timestamps, reorders equal timestamps or
normalizes duplicate timestamps. One rejected row fails the dataset
qualification. The manifest still records accepted/rejected counts, rejection
reasons and up to ten rejection samples as evidence, and no native output is
published on failure.

## 2. Prerequisites

- Windows with the .NET 10 SDK; the LEAN Launcher built
  (`MarketLab\scripts\build.ps1`) and the replay probe built:

  ```powershell
  dotnet build MarketLab\tools\historical-data\probe\MarketLab.HistoricalDataProbe.csproj --configuration Release
  ```

- Python 3.11 or newer for the offline tool. The standard library `zoneinfo`
  needs the IANA timezone database; on Windows install the `tzdata` package
  (`python -m pip install tzdata`) if `zoneinfo.ZoneInfo("America/New_York")`
  fails. No other package is required (no pandas, no PyArrow).
- A runtime LEAN **research data folder outside Git**. It must contain
  `market-hours\market-hours-database.json` and
  `symbol-properties\symbol-properties-database.csv` (the same requirement as
  `MarketLab\scripts\run-backtest.ps1`). The qualifier refuses any output
  folder inside the LEAN Git worktree, because replacing a generation removes
  native partitions. The driver links the remaining auxiliary runtime data
  automatically (section 6).

## 3. Quick start

The driver runs the whole path and returns the record's verdict:

```powershell
powershell -File MarketLab\tools\historical-data\scripts\Invoke-ReplayQualification.ps1 `
    -SourceCsv E:\research-data\xauusd-history.csv `
    -DataFolder E:\research-data\lean `
    -TimestampColumn timestamp -BidColumn bid -AskColumn ask -SourceTimezone UTC
```

Useful source options (all explicit settings override deterministic
header detection): `-TimestampColumn`, `-DateColumn`, `-TimeColumn`,
`-BidColumn`, `-AskColumn`, `-Delimiter` (`\t` means tab), `-TimestampFormat`
(strptime), `-SourceTimezone` (IANA name). The tool records the interpreted
timestamp contract in the manifest; it never guesses an economically meaningful
timezone. If timestamps are naive, `-SourceTimezone` is required; if they carry
an embedded UTC offset, it must not be given.

Re-running over an existing output set requires `-Force`. Qualification
generations are coherent: a first run publishes the partitions, manifest and
expectation; a forced replacement invalidates the previous
`qualification-record.json` in the same transaction; and a forced requalification
that fails clears the superseded expectation, record and native partitions
while publishing the new failure manifest. **Foreign partitions are never
touched:** `-Force` may replace or remove a `YYYYMMDD_quote.zip` only when the
previous MarketLab manifest lists it and its recorded SHA-256 matches. Any
native ZIP without a usable MarketLab manifest, or with a mismatched hash, is
refused with exit 2 (`ForeignNativePartitions`); use a clean/dedicated research
data folder. Without `-Force`, any existing generation is refused (exit 2)
rather than mixed. Output folders inside the LEAN Git worktree are refused,
because replacing a generation removes native partitions.

### The three underlying steps

```powershell
$env:PYTHONPATH = "MarketLab\tools\historical-data\python"

# 1. strict qualification + conversion (never converts a failing source)
python -m marketlab_historical_data qualify `
    --source E:\research-data\xauusd-history.csv `
    --data-folder E:\research-data\lean `
    --timestamp-column timestamp --bid-column bid --ask-column ask --source-timezone UTC

# 2. actual LEAN replay probe (helper; change the paths as needed)
powershell -File MarketLab\scripts\run-backtest.ps1 `
    -AlgorithmTypeName SingleAnchorReplayProbeAlgorithm `
    -AlgorithmLocation MarketLab\tools\historical-data\probe\bin\Release\MarketLab.HistoricalDataProbe.dll `
    -DataFolder E:\research-data\lean -AllowMissingData

# 3. final record combining the manifest and the probe result
python -m marketlab_historical_data verify `
    --manifest E:\research-data\lean\marketlab-qualification\qualification-manifest.json `
    --data-folder E:\research-data\lean `
    --probe-result <run dir>\storage\single-anchor-replay-probe\replay-result.json `
    --failed-data-requests <run dir>\failed-data-requests-*.txt `
    --runtime-binaries <run dir>\runtime-binaries.json
```

`-AllowMissingData` is required for step 2 because LEAN probes the trading days
adjacent to the qualified window for continuity; the final record classifies
every failed request, so a missing native partition that carries accepted rows
still fails the record. In step 3, an explicitly supplied `--probe-result` or
`--failed-data-requests` path that is missing or malformed is a configuration
error (exit 2); omit the option to record missing evidence as a qualification
failure instead.

**An authoritative PASS requires the runtime-binary evidence**, i.e. the
`runtime-binaries.json` the driver writes into the run directory. That file
contains SHA-256 for the probe, Launcher, Engine, AlgorithmFactory, Algorithm
and Common assemblies (plus Configuration and Logging when present). The
converter state hash is not part of it. A manual `verify` without
`--runtime-binaries` still produces a record, but with `RuntimeBinariesMissing`
and therefore `overall_qualification: FAIL`; use
`Invoke-ReplayQualification.ps1` as the authoritative route.

## 4. What the converter writes, and where

All generated research data stays **outside Git**.

| Output | Meaning |
|---|---|
| `<data folder>\cfd\oanda\tick\xauusd\YYYYMMDD_quote.zip` | native LEAN quote-tick partition; one entry `YYYYMMDD_xauusd_tick_quote.csv`, lines `time,bid,ask` |
| `<data folder>\marketlab-qualification\qualification-manifest.json` | machine-readable source/conversion/provenance record |
| `<data folder>\marketlab-qualification\replay-expectation.json` | what the probe must observe (counts, digests, window, partitions) |
| `<data folder>\marketlab-qualification\qualification-record.json` | final record: manifest + probe result + runtime-binary hashes + every comparison + explicit overall PASS/FAIL (written by `verify`) |
| `<run dir>\storage\single-anchor-replay-probe\replay-result.json` | the probe's delivered stream summary and comparison |

### Native file semantics (derived from the current LEAN implementation)

- The partition date and the time value are in the subscription's
  **`DataTimeZone`**, not the exchange timezone and not necessarily UTC. The
  conversion is: source timestamp -> canonical UTC -> `DataTimeZone` local ->
  `YYYYMMDD` partition -> milliseconds since that local midnight. LEAN's reader
  converts `DataTimeZone -> ExchangeTimeZone` itself (`Common/Data/Market/Tick.cs`).
- The resolved values for the actual subscription are recorded in the manifest
  and again at runtime by the probe (`DataTimeZone`, `ExchangeTimeZone`, the
  runtime market-hours database path and its SHA-256).
- Prices are written as canonical exact-decimal text; the converter parses
  source text with `decimal.Decimal` and never passes an authoritative price
  through binary floating point. Numerically equal source spellings (`1.2`,
  `1.20`) serialize identically.
- Timestamps must be exactly representable at millisecond precision. If any
  accepted row carries meaningful sub-millisecond precision, qualification
  fails with `NativeLeanTimestampParity = FAIL` and reason
  `SourcePrecisionExceedsLeanTickFormat`; nothing is truncated, rounded or
  silently dropped, and the source itself is not labelled invalid.

## 5. What PASS and FAIL mean

`qualify` gates, in order:

| Gate | PASS means |
|---|---|
| source qualification | every row satisfies the quote/timestamp/order contract; no rejected, out-of-order or mixed-representation row |
| native timestamp parity | no accepted row has sub-millisecond precision |
| price decimal parity | every accepted price round-trips through the native LEAN decimal reader (coefficient up to unsigned 64-bit max, scale at most 28) |
| conversion | native partitions, manifest and expectation were published atomically |

`verify` (the final authority) requires all of the following:

```text
accepted source rows == converted native rows == LEAN-delivered rows
the manifest is internally coherent (counts, per-day, per-partition and native totals agree)
the source SHA-256 is verified unchanged across qualification and conversion
the probe's engine processed every delivered quote (QuoteTickFeed invariant)
the probe is self-consistent and its first/last and per-partition evidence matches the manifest
source semantic digest == delivered semantic digest
the probe's embedded expectation matches this manifest (digest, source hash, identity, zones)
every per-partition count and semantic digest agrees
runtime DataTimeZone/ExchangeTimeZone and market-hours database SHA agree with the manifest
the complete runtime binary set is recorded and agrees with the probe's observed assemblies
every native partition file exists, matches its recorded hash, no stale partition
no failed data request for a partition that carries accepted rows
no failed data request inside the qualified window without source rows
```

The probe result is validated against the exact probe contract
(`marketlab-single-anchor-replay-probe-v1`); a wrong-schema or wrong-contract
manifest/probe file is a configuration error (exit 2), never a qualification
verdict.

Any failure produces `overall_qualification: FAIL` and a machine-readable
`failure_reasons` list. Common reasons:

| Reason | Meaning |
|---|---|
| `SourceRejectedRows` | at least one source row failed the contract; see `counts.rejected_row_reasons` |
| `SourcePrecisionExceedsLeanTickFormat` | meaningful sub-millisecond source precision; native millisecond parity is impossible |
| `SourcePriceExceedsLeanDecimalFormat` | a price does not round-trip through the native LEAN reader (`StreamReaderExtensions.GetDecimal`: unchecked 64-bit coefficient limbs, coefficient up to unsigned 64-bit max, scale ≤ 28) |
| `NativeLeanConversionFailed` | conversion/publish refused or failed; nothing was published |
| `AcceptedConvertedCountMismatch` | a conversion-PASS manifest says accepted ≠ converted |
| `ConvertedRowCountMismatch` / `NativePartitionCountMismatch` | the converted totals, partition row counts or per-day totals disagree |
| `PerDayAcceptedCountMismatch` / `PerPartitionAcceptedCountMismatch` | per-day or per-partition accepted totals disagree with the accepted count |
| `NativePartitionMissing` | LEAN could not read a partition that carries accepted rows |
| `SourceCoverageGap` | a market day inside the qualified window has no source rows |
| `StaleNativePartition` | the tick directory holds a partition the current manifest does not describe |
| `NativeReplayProbeResultMissing` / `NativeReplayProbeDidNotComplete` | the probe did not run or the engine faulted |
| `EngineDidNotProcessEveryAcceptedQuote` | the engine processed fewer quotes than the source accepted |
| `EngineDidNotProcessEveryDeliveredQuote` | `QuoteTickFeed` delivered fewer quotes to the engine than the probe captured |
| `ProbeSelfInconsistent` | a probe claiming PASS with failure reasons or false comparison flags |
| `ProbeExpectationDoesNotMatchManifest` | the probe compared against an expectation that is not this manifest's |
| `RuntimeBinariesMissing` / `RuntimeBinariesMismatchWithProbe` | the runtime binary evidence is absent, or contradicts the probe's observed assemblies |
| `ExpectedAndDeliveredCountsDiffer` | LEAN delivered fewer/more quotes than accepted (for example market-hours/session filtering) |
| `DeliveredSemanticDigestMismatches` | price/order/timestamp content differs after canonical UTC normalization |
| `ReplayRuntimeDataTimeZoneMismatch` / `ReplayRuntimeExchangeTimeZoneMismatch` | the probe's runtime timezones differ from the manifest's resolved values |
| `ReplayRuntimeMarketHoursDatabaseMismatch` | the probe's runtime market-hours database SHA-256 differs from the manifest's |
| `FirstDeliveredQuoteMismatches` / `LastDeliveredQuoteMismatches` | the delivered boundary quote disagrees with the manifest |
| `PerPartitionCountsDiffer` / `PerPartitionDigestsDiffer` | a delivered partition disagrees with the manifest's partition evidence |
| `NativePartitionFileMissing` / `NativePartitionHashMismatch` | converted output changed after conversion |

Configuration/infrastructure errors (exit 2, no qualification verdict) include
`DataFolderInsideRepository`, `ForeignNativePartitions` (`-Force` will not
remove native data the current MarketLab manifest does not own),
`NativePartitionSetChanged` (a partition changed between the ownership check
and publication), `OutputsExistWithoutForce`, `SymbolPropertiesDatabaseMissing`,
`MarketHoursDatabaseUnusable`, `SourceUnreadable` / `SourceLayoutUnusable`
(invalid encoding, delimiter or CSV parser failure),
`SourceChangedDuringQualification` (the source changed mid-run; nothing was
published), a report path that would replace one of its evidence inputs, and
wrong-schema/incomplete manifest, probe or runtime-binaries inputs.

**Session filtering must not silently pass.** LEAN drops ticks outside the
resolved exchange sessions (for Oanda XAUUSD: the New York 16:58-18:03 break,
weekends and holidays) in `SubscriptionFilterEnumerator`. The manifest records
the offline session preview as a diagnostic only; the probe measures the real
delivery. For an exact-replay PASS the delivered count must equal the accepted
count.

## 6. Auxiliary runtime data and the junction warning

`Invoke-ReplayQualification.ps1` links, from `-AuxiliaryDataSource`
(default `<LeanRoot>\Data`), any missing `market-hours`, `symbol-properties`,
`alternative`, `equity` and `cfd\oanda\hour` path into the research data folder
as a directory **junction**. These are the unchanged engine fixtures the
subscription setup reads; junctions keep them in place and copy nothing. Use
`-NoAuxiliaryLinks` to skip this and accept the helper's missing-data
warnings, which the final record reports.

> **Warning:** a directory junction is a link, not a copy. Deleting a research
> data folder that contains junctions with a recursive delete tool that follows
> reparse points can delete the linked engine fixtures. Delete junctions as
> links (Explorer does; the end-to-end test removes them as links), or remove
> the junction first.

## 7. The semantic digest contract

One accepted quote serializes as one UTF-8 line:

```text
{ordinal}|{yyyy-MM-ddTHH:mm:ss.fffZ}|{canonical bid}|{canonical ask}\n
```

`ordinal` is 1-based in stream order, timestamps are canonical UTC with exactly
millisecond precision, and prices are fixed-point invariant decimals without
exponent, without a leading `+` and without trailing fractional zeros (`-0` is
`0`). The digest is the SHA-256 of the concatenated lines, recorded as
`sha256:<lowercase hex>`. Python (`canonical.py`) and C# (`probe/SemanticStream.cs`)
implement the identical contract; the committed cross-language vector is
`sha256:92db8c553e1229145d107d52e8da0e40f645b3f929bbe41a864d2c0e4053d218`.

The delivered stream is derived by interpreting each delivered `Tick.Time` in
the resolved `ExchangeTimeZone`, normalizing it back to canonical UTC, and
hashing the same tuple. Ordering, equal timestamps and duplicates are part of
the digest: swapping two equal-timestamp rows changes it.

## 8. Tests

```powershell
# Python offline tool (160 tests)
cd MarketLab\tools\historical-data\python
python -m unittest discover -s tests -t . -v

# C# probe canonical values/digest/comparison/boundaries (32 tests)
dotnet test MarketLab\tools\historical-data\probe-tests\MarketLab.HistoricalDataProbe.Tests.csproj --configuration Release

# end-to-end Windows test: CSV -> native files -> actual LEAN replay -> record
powershell -File MarketLab\tools\historical-data\scripts\Test-HistoricalDataQualification.ps1
```

The end-to-end test uses the committed fixtures in `fixtures\` (not the user's
dataset): an exact-replay PASS, a session-filter discrepancy that must FAIL, a
sub-millisecond source that must fail before conversion, and a crossed quote
that must fail without cleaning. It creates scratch data folders outside the
repository and removes the junctions as links during cleanup.

## 9. Provenance of adapted retired code

See [`PROVENANCE.md`](PROVENANCE.md). The retired repositories are reference
material only; nothing here is a runtime dependency on them.

## 10. Known limitations

- The offline session preview is diagnostic. It is exact for the XAUUSD entry
  (no early closes or late opens) but simplified when an entry defines them;
  `preview_exact` says which. The actual replay is the authority.
- The converter requires a header row; explicit column options name columns
  that must exist in the header (normalized), and they do not make a headerless
  file usable.
- Only the XAUUSD/Oanda CFD tick subscription is exercised. The tool is
  parameterised by symbol/market/security type, but no other subscription has
  been qualified.
- The probe reuses the SingleAnchor engine's data-quality gate through the
  same `QuoteTickFeed`; it is a data-delivery qualification, not a strategy
  performance run (LEAN statistics for a probe run are empty by design).
- LEAN probes the trading days adjacent to the window for continuity and logs
  them as failed data requests when the source does not extend there; the
  record classifies those as `out_of_window_failed_data_requests` warnings.
- Source values are bounded by the native LEAN reader: the coefficient is
  accumulated in an unchecked 64-bit integer, so exact round-trips hold up to
  unsigned 64-bit max with at most 28 fractional digits. Extreme exponents are
  rejected with a controlled `SourcePriceExceedsLeanDecimalFormat` failure
  instead of an exception, and spread diagnostics are marked `complete: false`
  when such a row is present.
- The subscription identity is the driver-enforced XAUUSD/oanda/Cfd scope; a
  non-default identity is refused rather than loosely supported.
- Provenance: `lean_checkout_git_sha` and `converter_source` (per-file and
  aggregate hashes) identify the source that produced the manifest, even from a
  dirty checkout. The runtime identity is recorded twice: the driver hashes the
  probe and LEAN assemblies it launches (`runtime_binaries` in the record), and
  the probe adds an in-process `runtime.assemblies` list as supplemental
  evidence (byte-loaded assemblies may not expose a file `Location`).
