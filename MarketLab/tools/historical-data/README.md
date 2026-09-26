# Historical dataset qualification and native-LEAN replay (PR 1)

Status: **PR 1 is implemented and complete** (`Rady70/Lean` PR #6), and the
replay identity for the real Dukascopy/JForex source is **resolved**: the
source qualifies under the `XAUUSD/dukascopy/Cfd` identity with a
MarketLab-derived always-open, holiday-free runtime identity (section 6), so
LEAN's session filter removes no legitimate source quote. The
qualification/conversion tooling is offline Python only; the normal per-tick
SingleAnchor runtime remains C#, LEAN is unchanged, and every custom file stays
under `MarketLab/`.

This directory is the MarketLab-owned offline tooling that takes a historical
bid/ask CSV source and establishes whether it can be represented and replayed
through LEAN's native CFD quote-tick path without silently changing the
strategy input stream:

```text
historical CSV
      |
      v
strict qualification          MarketLab/tools/historical-data (Python, offline)
      |
      v
native LEAN quote-tick files  <research data folder>/cfd/<market>/tick/xauusd
      |
      v
actual LEAN data path         unchanged LEAN engine
      |
      v
QuoteTickFeed                 MarketLab replay probe (strategy feed path)
      |
      v
qualification record          explicit PASS/FAIL
```

For the Dukascopy/JForex source the market is `dukascopy` and the runtime
identity is prepared (always open, no holidays); for the committed fixture
tests the market is the engine's `oanda` fixture identity. The path is derived
from the identity, never assumed.

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
- A runtime LEAN **research data folder outside Git**. The qualifier and the
  LEAN helper read `market-hours\market-hours-database.json` and
  `symbol-properties\symbol-properties-database.csv` from it (the same
  requirement as `MarketLab\scripts\run-backtest.ps1`). For the
  `dukascopy` identity the driver does not link the engine fixtures here;
  instead it derives these two databases into the folder with
  `prepare-identity` (section 6), recording their provenance. The qualifier
  refuses any output folder inside the LEAN Git worktree, because replacing a
  generation removes native partitions. The driver links the remaining
  auxiliary runtime data automatically (section 6).

## 3. Quick start

The driver runs the whole path and returns the record's verdict. The real
Dukascopy/JForex source is qualified with `-Market dukascopy` (the
source-appropriate identity with no session filtering); omitting the option
keeps the committed-fixture `oanda` identity:

```powershell
powershell -File MarketLab\tools\historical-data\scripts\Invoke-ReplayQualification.ps1 `
    -SourceCsv E:\research-data\xauusd-history.csv `
    -DataFolder E:\research-data\lean `
    -Market dukascopy `
    -TimestampColumn timestamp -BidColumn bid -AskColumn ask
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

### The four underlying steps

```powershell
$env:PYTHONPATH = "MarketLab\tools\historical-data\python"

# 1. derive the always-open runtime identity for the Dukascopy identity
python -m marketlab_historical_data prepare-identity `
    --data-folder E:\research-data\lean `
    --source-data-folder <LeanRoot>\Data `
    --symbol XAUUSD --market dukascopy --security-type Cfd

# 2. strict qualification + conversion (never converts a failing source)
python -m marketlab_historical_data qualify `
    --source E:\research-data\xauusd-history.csv `
    --data-folder E:\research-data\lean `
    --timestamp-column timestamp --bid-column bid --ask-column ask `
    --symbol XAUUSD --market dukascopy --security-type Cfd

# 3. actual LEAN replay probe (helper; change the paths as needed)
powershell -File MarketLab\scripts\run-backtest.ps1 `
    -AlgorithmTypeName SingleAnchorReplayProbeAlgorithm `
    -AlgorithmLocation MarketLab\tools\historical-data\probe\bin\Release\MarketLab.HistoricalDataProbe.dll `
    -DataFolder E:\research-data\lean -AllowMissingData `
    -Parameters "probe-symbol:XAUUSD,probe-market:dukascopy,probe-security-type:Cfd"

# 4. final record combining the manifest and the probe result
python -m marketlab_historical_data verify `
    --manifest E:\research-data\lean\marketlab-qualification\qualification-manifest.json `
    --data-folder E:\research-data\lean `
    --probe-result <run dir>\storage\single-anchor-replay-probe\replay-result.json `
    --failed-data-requests <run dir>\failed-data-requests-*.txt `
    --runtime-binaries <run dir>\runtime-binaries.json `
    --helper-exit-code 0
```

The `probe-market` parameter is mandatory for a non-default identity: the probe
refuses an expectation whose identity does not match its configured one. Step 1
is the authoritative way to obtain the derived databases; a data folder whose
always-open identity was hand-assembled without the recorded provenance cannot
produce a PASS (`RuntimeIdentityProvenanceMissing`, section 5).

### Aggregating a per-file sweep

The CLI qualifies one source file per run, so a full-history qualification is a
sequence of per-file PR-1 runs. The per-month records are aggregated and
re-validated with the tracked command:

```powershell
python -m marketlab_historical_data summarize-history `
    --months-root E:\research-data\history-months `
    --expected-first-month 2019_01 `
    --expected-last-month 2026_06
```

Each direct child of `--months-root` is one month directory (`YYYY_MM`) holding
`data\marketlab-qualification\qualification-record.json`. The command requires:
the explicit expected first/last month, so a contiguous subset (for example a
single year) cannot claim the qualified window; one contiguous, ordered,
gap-free month sequence; each record a structurally valid `PASS` with helper
exit 0, accepted = converted = LEAN-delivered = probe-processed, zero rejected
rows and session differences, equal per-partition counts/digests and equal
source/delivered digests; no missing partition, no coverage gap and no
stale/hash-mismatched partition; each record's source file name matching its
month and its first/last timestamps falling inside that month; and a singleton
identity across every run (symbol, market, security type, native path, time
zones, market-hours database SHA-256, symbol-properties SHA-256, converter
source aggregate, clean checkout and runtime binary set). A record missing any
field the aggregator consumes is reported as an error instead of a traceback.
It writes `full-history-summary.json` with totals and two documented aggregate
hashes:

- `source_file_set_sha256` = SHA-256 of the newline-joined
  `<source file name>:<source sha256>` lines in month order;
- `ordered_month_digest_chain_sha256` = SHA-256 of the newline-joined
  per-month ordered source semantic digests in month order.

The default output is `<months-root>\full-history-summary.json`; the command
overwrites only that aggregate, and refuses a user-supplied `--output` that
resolves inside any month directory of the months root or inside a source
directory recorded by the month records, so a mistaken path cannot overwrite a
qualification record or a raw source file.

Both are aggregates over the decomposition. Per-month ordinals restart per file
and the tooling does not ingest multiple source files into one run, so there is
**no single-stream PR-1 ordinal digest**; the per-month PR-1 digests and the
chain are the evidence. The command exits 0 only when every check passes, 1 for
a non-conforming record set (the summary still lists the errors), and 2 for a
missing or invalid months root.

`-AllowMissingData` is required for step 2 because LEAN probes the trading days
adjacent to the qualified window for continuity; the final record classifies
every failed request, so a missing native partition that carries accepted rows
still fails the record. In step 3, an explicitly supplied `--probe-result` or
`--failed-data-requests` path that is missing or malformed is a configuration
error (exit 2); omit the option to record missing evidence as a qualification
failure instead.

**An authoritative PASS requires the helper exit code and the runtime-binary
evidence.** `--helper-exit-code 0` states that the LEAN helper completed
cleanly; a nonzero value is accepted only when the probe deliberately reported
a replay mismatch (the record is then a FAIL). Omitting the option yields
`HelperExitCodeMissing` and therefore `overall_qualification: FAIL`. The
`runtime-binaries.json` written by the driver contains SHA-256 for the probe,
Launcher, Engine, AlgorithmFactory, Algorithm and Common assemblies (plus
Configuration and Logging when present); a manual `verify` without
`--runtime-binaries` fails with `RuntimeBinariesMissing`. Use
`Invoke-ReplayQualification.ps1` as the authoritative route.

## 4. What the converter writes, and where

All generated research data stays **outside Git**.

| Output | Meaning |
|---|---|
| `<data folder>\cfd\<market>\tick\xauusd\YYYYMMDD_quote.zip` | native LEAN quote-tick partition; one entry `YYYYMMDD_xauusd_tick_quote.csv`, lines `time,bid,ask` |
| `<data folder>\marketlab-qualification\qualification-manifest.json` | machine-readable source/conversion/provenance record |
| `<data folder>\marketlab-qualification\replay-expectation.json` | what the probe must observe (counts, digests, window, partitions) |
| `<data folder>\marketlab-qualification\qualification-record.json` | final record: manifest + probe result + runtime-binary hashes + helper exit code + every comparison + explicit overall PASS/FAIL (written by `verify`) |
| `<data folder>\marketlab-qualification\runtime-identity.json` | provenance of a `prepare-identity` derivation: source databases and SHA-256s, derived databases and SHA-256s, the inserted always-open entry and the rule (absent for the engine-fixture `oanda` identity) |
| `<run dir>\storage\single-anchor-replay-probe\replay-result.json` | the probe's delivered stream summary and comparison |

### Native file semantics (derived from the current LEAN implementation)

- The partition date and the time value are in the subscription's
  **`DataTimeZone`**, not the exchange timezone and not necessarily UTC. The
  conversion is: source timestamp -> canonical UTC -> `DataTimeZone` local ->
  `YYYYMMDD` partition -> milliseconds since that local midnight. LEAN's reader
  converts `DataTimeZone -> ExchangeTimeZone` itself (`Common/Data/Market/Tick.cs`).
- The resolved values for the actual subscription are recorded in the manifest
  and again at runtime by the probe (`DataTimeZone`, `ExchangeTimeZone`, the
  runtime market-hours database path and its SHA-256). The source identity is
  `dukascopy` with `DataTimeZone = ExchangeTimeZone = UTC`; the fixture
  identity is `oanda` with `DataTimeZone = UTC`, `ExchangeTimeZone =
  America/New_York`.
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
the LEAN helper completed cleanly (exit code 0 for a PASS; a nonzero code is only
  accepted for a deliberate probe-reported replay mismatch, which can only be a FAIL)
the manifest is internally coherent (counts, per-day, per-partition and native totals agree)
the source SHA-256 is verified unchanged across qualification and conversion
the probe's engine processed every delivered quote (QuoteTickFeed invariant)
the probe is self-consistent and its first/last and per-partition evidence matches the manifest
source semantic digest == delivered semantic digest
the probe's embedded expectation matches this manifest (digest, source hash, identity, zones)
every per-partition count and semantic digest agrees
runtime DataTimeZone/ExchangeTimeZone and market-hours database SHA agree with the manifest
an always-open identity carries its recorded `prepare-identity` provenance (source and derived database SHA-256s)
the complete runtime binary set is recorded and agrees with the probe's observed assemblies
every native partition file exists, matches its recorded hash, no stale partition
no failed data request for a partition that carries accepted rows
for a session-bounded identity, no failed data request for a market day inside the qualified window
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
| `SourceCoverageGap` | a market day inside the qualified window has no source rows (session-bounded identities; for an always-open identity such days are recorded as `source_absent_days` evidence instead, because the source itself defines its calendar) |
| `StaleNativePartition` | the tick directory holds a partition the current manifest does not describe |
| `NativeReplayProbeResultMissing` / `NativeReplayProbeDidNotComplete` | the probe did not run or the engine faulted |
| `EngineDidNotProcessEveryAcceptedQuote` | the engine processed fewer quotes than the source accepted |
| `EngineDidNotProcessEveryDeliveredQuote` | `QuoteTickFeed` delivered fewer quotes to the engine than the probe captured |
| `ProbeSelfInconsistent` | a probe claiming PASS with failure reasons or false comparison flags |
| `ProbeExpectationDoesNotMatchManifest` | the probe compared against an expectation that is not this manifest's |
| `RuntimeBinariesMissing` / `RuntimeBinariesMismatchWithProbe` | the runtime binary evidence is absent, or contradicts the probe's observed assemblies |
| `RuntimeIdentityProvenanceMissing` | the manifest resolved an always-open identity but carries no `prepare-identity` provenance; a hand-assembled identity cannot qualify |
| `RuntimeIdentityProvenanceMismatch` | the recorded provenance hashes do not match the databases the manifest resolved |
| `HelperExitCodeMissing` | the LEAN helper exit code was not supplied (a PASS record requires 0) |
| `HelperExitNotClean` | the helper exited nonzero and the probe did not deliberately report a replay mismatch |
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
resolved exchange sessions (for the Oanda XAUUSD fixture entry: the New York
16:58-18:03 break, weekends and holidays) in `SubscriptionFilterEnumerator`.
The manifest records the offline session preview as a diagnostic only; the
probe measures the real delivery. For an exact-replay PASS the delivered count
must equal the accepted count. The Dukascopy/JForex source is replayed under
the derived always-open identity, which has no closed interval at all, so no
accepted quote can be filtered; the committed `oanda` fixture case proves the
filter detection still fails a session-clipped replay. Under an always-open
identity LEAN still requests a file for every calendar day; failed requests for
days the source has no rows for are recorded as `source_absent_days` in the
record (evidence, not a failure), while a failed request for any day that does
carry accepted rows remains `NativePartitionMissing`.

## 6. Auxiliary runtime data and the junction warning

`Invoke-ReplayQualification.ps1` links, from `-AuxiliaryDataSource`
(default `<LeanRoot>\Data`), any missing `alternative` and `equity` path into
the research data folder as a directory **junction**. For the `oanda` fixture
identity it also links `market-hours`, `symbol-properties` and
`cfd\oanda\hour`. For the `dukascopy` identity it instead runs
`prepare-identity`, which reads the engine fixture databases from
`-AuxiliaryDataSource` and writes the derived always-open runtime databases
into the data folder (real files, never through a junction; writing through a
junction is refused). The Dukascopy identity does **not** link or require the
Oanda hour fixture or the Oanda calendar, and the end-to-end test exercises a
Dukascopy run whose auxiliary source has no `cfd` directory at all. Use
`-NoAuxiliaryLinks` to skip the links and accept the helper's missing-data
warnings, which the final record reports (`prepare-identity` still runs for
`dukascopy`, because it only reads from `-AuxiliaryDataSource`).

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
# Python offline tool (230 tests)
cd MarketLab\tools\historical-data\python
python -m unittest discover -s tests -t . -v

# C# probe canonical values/digest/comparison/boundaries (32 tests)
dotnet test MarketLab\tools\historical-data\probe-tests\MarketLab.HistoricalDataProbe.Tests.csproj --configuration Release

# end-to-end Windows test: CSV -> native files -> actual LEAN replay -> record
powershell -File MarketLab\tools\historical-data\scripts\Test-HistoricalDataQualification.ps1
```

The end-to-end test uses the committed fixtures in `fixtures\` (not the user's
dataset): an exact-replay PASS, the same session-gap source under the derived
always-open Dukascopy identity with a Dukascopy auxiliary source that has no
Oanda `cfd` fixture at all (PASS, every quote delivered) and under the Oanda
fixture identity (FAIL, one quote filtered), a sub-millisecond source that must
fail before conversion, a crossed quote that must fail without cleaning, an
unsupported identity and an in-worktree data folder that must be refused. It
creates scratch data folders outside the repository and removes the junctions
as links during cleanup.

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
- The committed fixture tests exercise the XAUUSD/Oanda CFD tick subscription;
  the real Dukascopy source is qualified under XAUUSD/dukascopy/Cfd. The tool is
  parameterised by symbol/market/security type, but no other subscription has
  been qualified, and the driver accepts exactly those two identities.
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
- The subscription identity is the driver-enforced XAUUSD/oanda/Cfd (engine
  fixture) and XAUUSD/dukascopy/Cfd (Dukascopy source) scope; any other
  identity is refused rather than loosely supported.
- Provenance: `lean_checkout_git_sha` and `converter_source` (per-file and
  aggregate hashes) identify the source that produced the manifest, even from a
  dirty checkout. The runtime identity is recorded twice: the driver hashes the
  probe and LEAN assemblies it launches (`runtime_binaries` in the record), and
  the probe adds an in-process `runtime.assemblies` list as supplemental
  evidence (byte-loaded assemblies may not expose a file `Location`).
- The full historical dataset completed a **90-month decomposed exact-replay
  sweep** (2019-01..2026-06, 90 source files, 22.35 GiB) on 2026-09-24: **90/90
  months PASS, 0 failures**, with accepted = converted = LEAN-delivered =
  probe-processed = **413,750,130** rows, 0 rejected rows, 0 session drops,
  every per-partition count and semantic digest equal and every per-month
  source/delivered digest equal. This is the sequence of per-file runs the CLI
  supports, re-validated by the tracked `summarize-history` command, which also
  checks the ordered 90-file set, adjacent month boundaries, totals, singleton
  identity, clean checkout and runtime binary set. The source file-set SHA-256 is
  `8ce98dd27c2df3166a0dc3ec30c6be4756887f323934a6a0ca1c348592c6f1fd`; the
  aggregate chain over the 90 ordered per-month digests (an aggregate, not a
  single-run PR-1 digest) is
  `9d29c36bcd5ada21cdbf6f8e8a7ea3601efd5bab65e2acf7b4c3ee0f8b41f769`. All
  months resolved the identical derived identity (market-hours SHA-256
  `325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e`,
  symbol-properties SHA-256 `7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed`,
  converter source aggregate `1642c5c2ab7cd0422290859ad685138fedfb2c7ece9ea0d98f46d40bd40957bf`
  as recorded by those runs — later review-fix commits added the tracked
  aggregator and tightened the identity preparation without changing the
  qualification behavior, so the records remain the authority for the sweep's
  tooling identity — from clean HEAD
  `ab7754af8c7175fe7f9837cf17541956a094927b`; runtime
  binary set SHA-256 `eceb4d7526ff78098c0f29e88e1cc0fff0b9ff1a32d64e943e0237e90ce11f5b`).
  First delivered timestamp `2019-01-01T23:00:07.151Z`, last
  `2026-06-30T23:59:59.678Z`. The always-open identity recorded 376
  source-absent days (weekends and source holidays LEAN requested with no
  accepted rows) as evidence; no coverage gap and no missing accepted
  partition. Exactly one unrelated failed request per month
  (`cfd/dukascopy/hour/xauusd.zip`, the benchmark hour file). The sweep ran in
  6.83 h of driver wall time; the per-month records, the runner log and
  `full-history-summary.json` (regenerated and validated by the tracked
  command) stay outside Git under
  `D:\quant_research_workspace\work\lean\pr1-xauusd-full-history-dukascopy\`.
  A distilled evidence fixture with no market data — one row per month carrying
  the source file name/hash/size, canonical first/last timestamps, every
  compared row count (raw/accepted/rejected/converted/delivered/processed), the
  session difference, the source/delivered digests, failed-request counts and
  the distilled identity hashes — is tracked at
  `fixtures\full-history-sweep-evidence.json`; tests recompute the totals, the
  singleton identity and both aggregate hashes, and re-check the
  sequence/boundary properties, so the full-history claim is verifiable from
  the repository without the external records or the raw source.

  The sweep is a decomposed per-file acceptance: PR 1 writes one native data
  folder per run and does not compose multiple source files into one data tree.
  After PR 2 and PR 3, and before the baseline configuration freeze, the
  already-qualified daily partitions must be materialized into one continuous
  research data folder under the same derived identity, preserving each
  partition's hash and the qualification identity, and the replay probe must
  re-prove the composed delivery against the concatenated per-month evidence.
  Running 90 independent monthly strategy runs is not the full-history
  baseline. That composition step is deliberately not implemented in PR 1.
  **PR 2** (C# research account view and bounded analytics) is implemented and
  merged (SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md section 9), and **PR 3**
  (target-account margin survival) is implemented on its review branch (section
  10 of the same note). The next roadmap step after PR 3 is composition of the
  already-qualified partitions into one continuous research data folder, the
  baseline configuration freeze and the first full-history baseline. PR 3 uses
  the approved USD-denominated XM-style research account, so it does **not**
  require an EURUSD conversion dataset or any additional FX-conversion
  qualification; the qualified XAUUSD history remains the market-data input for
  this roadmap phase.
