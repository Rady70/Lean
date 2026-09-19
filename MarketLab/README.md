# MarketLab LEAN: local backtesting on Windows

This directory is the MarketLab-owned layer of the `Rady70/Lean` fork. It adds a
bounded way to run the unchanged LEAN engine on this machine and nothing else:

```text
MarketLab LEAN
|
|-- local          the engine runs from this checkout's own build output
|-- historical     data is read from a local LEAN-format data folder
|-- backtesting    the only environment the MarketLab path can select
|-- research       results are files on disk for you to read
`-- no external execution
```

Nothing outside `MarketLab\` is modified. The upstream engine, Launcher and
default `Launcher\config.json` are exactly as at the qualified revision
(`f78c35d7`, see the Batch A record in `Rady70/Market_Lab`,
`docs/LEAN_BASELINE.md`).

| File | Purpose |
|---|---|
| `config\backtesting.json` | complete LEAN configuration for `--config`; backtesting only |
| `scripts\build.ps1` | runs the two Batch A build commands verbatim |
| `scripts\run-backtest.ps1` | pre-flight checks, direct Launcher invocation, post-run data check |
| `tests\Test-MarketLabBacktesting.ps1` | self-contained assertions for the above |
| `.gitignore` | ignores `output\` (generated runs) |

All scripts run on Windows PowerShell 5.1 and PowerShell 7 and use `exit`
codes you can read from `$LASTEXITCODE` when invoked with `-File`.

## 1. Prerequisites (established in Batch A)

- Windows, Git checkout of this fork.
- .NET SDK 10.x (`dotnet`). The scripts look for it on `PATH`, then
  `$env:DOTNET_ROOT`, then `%ProgramFiles%\dotnet\dotnet.exe`, and stop with an
  `ERROR:` if none exists.
- Network access to the NuGet feed for `dotnet restore` only.
- Not required: Visual Studio, Python (C# path), the LEAN CLI, Docker, a
  QuantConnect account. See section 11.

## 2. Build

```powershell
pwsh -File MarketLab\scripts\build.ps1            # or: powershell -File ...
```

The script echoes and runs, from the checkout root, exactly

```text
dotnet restore QuantConnect.Lean.sln
dotnet build QuantConnect.Lean.sln --configuration Release --no-restore
```

- Configuration: `Release` (Batch A baseline; `-Configuration Debug` is accepted).
- Output: `Launcher\bin\Release\` (no `net10.0` subfolder; upstream sets
  `AppendTargetFrameworkToOutputPath=false`).
- Success: exit code 0, MSBuild's `Build succeeded.` with `0 Error(s)`, and the
  final line `Build succeeded in N s. Launcher: ...\QuantConnect.Lean.Launcher.dll`.
  Thousands of warnings are normal for this solution (Batch A counted 7,795 on a
  full compile); they are upstream's and are not errors.
- `-NoRestore` skips the restore; `-ShutdownBuildServer` runs
  `dotnet build-server shutdown` afterwards (otherwise the SDK leaves MSBuild and
  Roslyn server processes running, which is harmless).

## 3. Configuration

`MarketLab\config\backtesting.json` is a complete LEAN configuration file
selected with `--config`. LEAN loads exactly one file
([`Configuration/Config.cs`](../Configuration/Config.cs)) and layers
`environments.<environment>` over the top-level keys; it never overlays a second
file, so this one carries every key LEAN needs. It differs from upstream's
`Launcher/config.json` only by omission and by explicit values:

- `environment` is `backtesting` and `environments` defines **only**
  `backtesting` (`live-mode: false` at both levels, the upstream backtesting
  handler set: `BacktestingSetupHandler`, `FileSystemDataFeed`,
  `BacktestingRealTimeHandler`, `BacktestingResultHandler`,
  `BacktestingTransactionHandler`, `SubscriptionDataReaderHistoryProvider`).
- `close-automatically: true` (no keypress wait), `show-missing-data-logs: true`.
- No broker keys, no live-data URL, no environment other than backtesting.
  `job-user-id "0"`, `api-access-token ""`, `job-organization-id ""` are the
  empty upstream defaults; nothing is filled in.
- `algorithm-*`, `data-folder`, `results-destination-folder` are placeholders;
  the helper always overrides them on the command line with absolute paths.

The helper's pre-flight checks the file the way LEAN will read it
(top level, then the `environments.<environment>` overlay) and refuses to
launch (exit 2) unless all of the following hold:

- `environment` is exactly the JSON string `backtesting`;
- `live-mode` is the JSON boolean `false` at the top level and inside every
  environment (a string `"false"` or an array `[false]` is rejected);
- `environments` is a JSON object whose only member is `backtesting`, and that
  member is an object that does **not** contain an `environment` or
  `environments` key of its own. LEAN resolves nested environments
  ([`Configuration/Config.cs`](../Configuration/Config.cs), `GetToken`), which
  would layer settings the checks above cannot see, so nesting is refused;
- the live-only keys `live-mode-brokerage` and `data-queue-handler` do not
  exist at the top level or in the environment;
- every handler key that is present, at the top level or in the environment,
  names the qualified backtesting type: `setup-handler`
  `BacktestingSetupHandler`, `result-handler` `BacktestingResultHandler`,
  `data-feed-handler` `FileSystemDataFeed`, `real-time-handler`
  `BacktestingRealTimeHandler`, `transaction-handler`
  `BacktestingTransactionHandler`, every `history-provider` entry
  `SubscriptionDataReaderHistoryProvider`, and `data-provider`
  `DefaultDataProvider`. A value matches when it is the simple type name or a
  namespace-qualified name ending in `.<that name>` (LEAN's Composer resolves
  either, [`Common/Extensions.cs`](../Common/Extensions.cs) `MatchesTypeName`).
  `ApiDataProvider` ([`Engine/DataFeeds/ApiDataProvider.cs`](../Engine/DataFeeds/ApiDataProvider.cs))
  is rejected by this rule: it downloads data through the QuantConnect API with
  an organization id and token (Batch A record, section 2.5).

This is the handler set qualified for Batch B. Extending it (another data
provider, a different history provider) is a later-batch decision that
changes the helper, not an operator setting.

The fork's default `Launcher\config.json` is left untouched. It still contains
upstream's inert `live-*` environments (`live-paper`, `live-interactive`, ...);
they are never selected by the MarketLab path, which does not read that file.

Upstream reference: [`Launcher/config.json`](../Launcher/config.json) and the
comments at its top describe the key set and the layering.

## 4. Historical data

Default data root: `<LeanRoot>\Data` (override with `-DataFolder`). LEAN reads
flat zip/CSV files in its own layout, documented in-repo in
[`Data/readme.md`](../Data/readme.md) and the per-asset readmes. The data
folder must also contain the auxiliary databases LEAN loads at startup,
`market-hours\market-hours-database.json` and
`symbol-properties\symbol-properties-database.csv`; the helper checks for both.

What ships in the checkout is an **engine fixture, not research data**: a few
tickers, and SPY minute data for six trading days in October 2013 plus one day
in 2023. `Data\equity\usa\readme.md` reads, in full, "DATA PROVIDED BY ALGOSEEK
/ ALL RIGHTS RESERVED / support@algoseek.com": its redistribution terms are not
established, so use it in place and do not copy it into other repositories.
Adjustment conventions and suitability for any research question are not
established by anything in this batch (see `Rady70/Market_Lab`,
`docs/DATA_INTEGRITY.md`).

Upstream's `.gitignore` already ignores new files under `Data/` (`*Data/*`);
the tracked sample files stay tracked. Data you add locally is therefore
outside Git by default.

## 5. Run a local backtest

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1              # defaults = Batch A representative run
pwsh -File MarketLab\scripts\run-backtest.ps1 -DryRun      # validate and print the command, launch nothing
Get-Help MarketLab\scripts\run-backtest.ps1 -Full          # every parameter
```

The helper, in order:

1. resolves `dotnet` and every path to an absolute form (trailing `\` stripped;
   a path that cannot be resolved is an `ERROR:`, exit 2);
2. pre-flight: launcher DLL present, config present and parsable and
   backtesting-only (section 3), algorithm file present, data folder present
   with both auxiliary databases, output root usable. Every problem is one
   `ERROR:` line naming the path and the fix; exit code 2, nothing launched;
3. creates `<OutputRoot>\<yyyyMMdd-HHmmss UTC>-<AlgorithmTypeName>\` and prints
   LEAN root, configuration, config file, algorithm, data folder, run
   directory, log file and the exact command line;
4. with the run directory as working directory, runs exactly

   ```powershell
   & 'C:\Program Files\dotnet\dotnet.exe' <LeanRoot>\Launcher\bin\Release\QuantConnect.Lean.Launcher.dll
       --config <abs config> --environment backtesting
       --data-folder <abs data> --results-destination-folder <abs run dir>
       --algorithm-type-name <name> --algorithm-language CSharp
       --algorithm-location <abs dll> --close-automatically true
   ```

   The printed line is exactly this call, rendered so it can be pasted into a
   PowerShell prompt (arguments with spaces or PowerShell-special characters are
   single-quoted). All options are declared in
   [`Configuration/LeanArgumentParser.cs`](../Configuration/LeanArgumentParser.cs);
   there is no `live-mode` option, that key comes from the validated file only;
5. reads the engine's own `data-monitor-report-*.json` from the run directory
   and fails with exit code 3 if any data request failed (section 10);
6. prints `run-backtest: exit code N; run directory: ...; log: ...`.

Nothing is copied, downloaded or installed. The script does not call `lean`,
`docker`, `pip`, any QuantConnect endpoint or any broker.

Invocation notes:

- Invoke from PowerShell with `-File` as shown. From `cmd.exe`, do not end a
  quoted path with a backslash (`"E:\data\"` reaches PowerShell as an illegal
  string under the Windows argv rules); write `"E:\data"` instead.
- `ERROR:` and `WARNING:` lines go to stderr, everything else to stdout. When
  the script is called from *inside* another PowerShell session with
  `2>&1`, PowerShell wraps LEAN's stderr lines as error records; the script
  relaxes `$ErrorActionPreference` around the launcher call so LEAN's own
  `ERROR::` output cannot abort the run under Windows PowerShell 5.1. The
  helper's own `ERROR:`/`WARNING:` lines are written straight to the process's
  stderr and its progress lines to the host, so an in-session `2>&1 | Out-File`
  captures neither; to capture everything, redirect at the OS level from an
  outer shell: `pwsh -File ...\run-backtest.ps1 > out.txt 2> err.txt`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | backtest completed; every local data request succeeded |
| 1 | LEAN: algorithm did not reach `Completed` ([`Launcher/Program.cs`](../Launcher/Program.cs)); also PowerShell's own code when it rejects a parameter value (for example an empty `-AlgorithmTypeName`) before the script runs |
| 2 | pre-flight validation failed; nothing was launched |
| 3 | LEAN exited 0 but its data monitor counted failed data requests (warning only with `-AllowMissingData`) |
| other | LEAN's own exit code, propagated unchanged |

## 6. Results

Everything a run produces is inside its run directory,
`MarketLab\output\<yyyyMMdd-HHmmss>-<AlgorithmTypeName>\` by default
(`-OutputRoot` to change the root; a `-N` suffix is added if the name exists):

| File | Content |
|---|---|
| `<Algorithm>.json` | full result packet (charts, statistics, orders, runtime stats) |
| `<Algorithm>-summary.json` | statistics summary |
| `<Algorithm>-order-events.json` | simulated order events (internal to `BacktestingBrokerage`) |
| `<Algorithm>-log.txt` | the algorithm's own `Debug`/`Log` output |
| `<Algorithm>\alpha-results.json` | framework insight results (framework algorithms) |
| `data-monitor-report-*.json`, `succeeded-data-requests-*.txt`, `failed-data-requests-*.txt` | the engine's data-request accounting |
| `storage\` | `LocalObjectStore` root (`object-store-root: ./storage`, relative to the working directory) |
| `log.txt` | engine log (section 7) |

One key drives all of this: `results-destination-folder`
([`Common/Globals.cs`](../Common/Globals.cs),
[`Engine/Initializer.cs`](../Engine/Initializer.cs)). Nothing is written to
`Launcher\bin\Release` by a MarketLab run.

## 7. Logs

- Engine log: `<run dir>\log.txt`. LEAN opens it in append mode
  ([`Logging/FileLogHandler.cs`](../Logging/FileLogHandler.cs)); because every run
  gets a fresh directory, each `log.txt` holds exactly one run. Its
  `JOB HANDLERS:` block lists the handler set actually used, which is the
  quickest way to confirm the backtesting boundary for a given run.
- Algorithm log: `<run dir>\<Algorithm>-log.txt`.
- Console: the helper streams LEAN's stdout/stderr live; LEAN's `Log.Error`
  lines (for example `File not found` with `show-missing-data-logs`) go to
  stderr, as do the helper's own `ERROR:`/`WARNING:` lines.

## 8. What is tracked, local, or generated

| Kind | Location | Git |
|---|---|---|
| Tracked source and configuration | everything under `MarketLab\` except `output\`; upstream source; tracked sample files under `Data\` | tracked |
| Local mutable data | files you add under `Data\` (or any `-DataFolder`); NuGet package cache | ignored (`*Data/*` upstream) / outside the repo |
| Build output | `*\bin\`, `*\obj\`, `Launcher\bin\Release\` | ignored (upstream `.gitignore`) |
| Generated runs | `MarketLab\output\` (results, logs, `storage\`, data-monitor files) | ignored (`MarketLab\.gitignore`) |
| Temporary test scratch | `%TEMP%\marketlab-tests-<guid>\` (fixtures and the `-IncludeSmoke` run of `tests\Test-MarketLabBacktesting.ps1`); removed by the test when it ends | outside the repo |
| Safe to delete | `MarketLab\output\*`, `*\bin`, `*\obj`, any leftover `%TEMP%\marketlab-tests-*` | rebuild / rerun to recreate |

No secrets or machine-local settings are needed anywhere in this workflow, so
none exists to protect.

## 9. Changing the algorithm

Only supported LEAN inputs are used (`--algorithm-type-name`,
`--algorithm-language`, `--algorithm-location`):

- Another C# algorithm from the shipped assembly:
  `-AlgorithmTypeName BasicTemplateAlgorithm` (any class in
  `Launcher\bin\Release\QuantConnect.Algorithm.CSharp.dll`; sources in
  `Algorithm.CSharp\`).
- Your own C# assembly: `-AlgorithmLocation <path\to\YourAlgorithms.dll>` with
  the matching `-AlgorithmTypeName`.
- Algorithm parameters: the `parameters` object in the config file (read
  through `QCAlgorithm.GetParameter`); copy `config\backtesting.json` and pass
  `-Config <copy>` to keep the tracked file unchanged.
- `-AlgorithmLanguage Python -AlgorithmLocation <file.py>` is passed through
  but **not qualified**: Batch A did not set up the pinned Python 3.11 runtime,
  and this batch does not either (section 13).

## 10. When required data is missing

LEAN does not fail on missing local data files: the subscription simply
receives nothing and the run ends with exit code 0
([`Engine/DataFeeds/SubscriptionDataSourceReader.cs`](../Engine/DataFeeds/SubscriptionDataSourceReader.cs)).
The MarketLab path makes this visible in three places:

1. `show-missing-data-logs: true` makes LEAN print
   `SubscriptionDataSourceReader.InvalidSource(): File not found: <path>` for
   each missing file (console and `log.txt`).
2. The engine's `failed-data-requests-*.txt` in the run directory lists every
   missing file; `data-monitor-report-*.json` carries the counts.
3. The helper reads that report's `failed-data-requests-count` (which already
   includes universe-file failures,
   [`Common/Data/DataMonitor.cs`](../Common/Data/DataMonitor.cs)) and exits
   **3** with an `ERROR:` block naming the count and the list file. `-AllowMissingData` turns this into a
   `WARNING:` and keeps LEAN's own exit code, for runs where the gap is
   intentional.

A data folder that is missing the auxiliary databases, or that does not exist,
is rejected in pre-flight (exit 2) before anything runs.

## 11. No QuantConnect account, login, API token, organization, Cloud, LEAN CLI, pip, Docker

The MarketLab path is `dotnet <launcher dll>` on local files, and nothing else:

- No QuantConnect account or login: the config's `job-user-id`,
  `api-access-token` and `job-organization-id` are the empty upstream
  defaults. `api-handler` stays `QuantConnect.Api.Api` as upstream ships it;
  for a local backtest it makes no request (`SetAlgorithmStatus` is a no-op,
  [`Api/Api.cs`](../Api/Api.cs)), and the Batch A and Batch B logs show no
  remote endpoint.
- No environment variable can smuggle a credential in: LEAN's configuration
  layer reads only the JSON file and the command line (there is no
  `GetEnvironmentVariable` anywhere under `Configuration/`), and the helper
  reads only `PATH`, `DOTNET_ROOT` and `ProgramFiles`, to find `dotnet`
  (it sets `DOTNET_CLI_TELEMETRY_OPTOUT` and `DOTNET_NOLOGO`).
- No LEAN CLI, no `pip install lean`, no Docker: the helper never invokes
  `lean`, `pip` or `docker`; neither executable is present on the qualifying
  machine. Upstream's readme recommends the CLI; this fork does not use it.
- No QuantConnect Cloud and no paid tier: no `api-url`, `live-data-url` or
  cloud handler is configured or selected.
- No Fincept or MarketLab Terminal dependency: this directory depends only on
  the checkout and the .NET SDK.

## 12. No broker connection

The only environment the MarketLab config defines and the helper accepts is
`backtesting`, whose handlers are the file-system data feed and the
backtesting setup/transaction/result handlers. Orders are simulated inside
`BacktestingBrokerage`. Pre-flight (section 3) rejects, before anything is
launched, a config that contains `live-mode-brokerage` or
`data-queue-handler`, that sets any handler key to a type other than the
qualified backtesting set (so `BrokerageSetupHandler`, `LiveTradingDataFeed`,
`LiveTradingResultHandler`, `LiveTradingRealTimeHandler`, `ApiDataProvider`
and any brokerage-specific handler are refused even with `live-mode: false`),
that sets `live-mode` to anything but `false`, or that nests another
environment. Upstream's brokerage code is still present in the repository,
unchanged and unused; nothing claims it was removed.

## 13. Known limitations

- Python algorithms are not qualified (Batch A observation 7); the language
  switch is a pass-through only.
- Shipped sample data is a small engine fixture under an AlgoSeek
  all-rights-reserved notice; it is not research data and must not be
  redistributed. Any real study needs its own data folder.
- The helper checks a run's data requests only through LEAN's own data
  monitor; it does not inspect the data files themselves.
- The build helper wraps upstream's command-line build only; the Visual Studio
  IDE route in upstream's readme is not covered.
- Outbound network traffic is not instrumented; the absence of remote calls is
  read from the configuration, the handler set and the logs.
- Failure handling beyond the pre-flight checks and the missing-data check
  (for example corrupt data files, algorithm exceptions, disk-full) is Batch C
  scope.
- One representative backtest (`BasicTemplateFrameworkAlgorithm`, the Batch A
  algorithm) exercises this path; other algorithms and resolutions are not
  qualified here.
