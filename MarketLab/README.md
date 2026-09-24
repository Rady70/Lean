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
| `tests\Test-TradingAvailabilityEndToEnd.ps1` | end-to-end check of the SingleAnchor session map through the real LEAN helper on a native tick fixture |
| `SINGLE_ANCHOR_VNEXT_STRATEGY.md` | the SingleAnchor vNext strategy specification (authoritative behaviour) |
| `SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md` | where its C# implementation lives, how it is built, tested and run, what is deferred |
| `SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md` | approved roadmap for historical-data qualification, C# research analytics, account survival and the first baseline research run |
| `src\SingleAnchor\` | the strategy assembly (`MarketLab.SingleAnchor.csproj`: engine, LEAN algorithm) |
| `tests\SingleAnchor\` | its NUnit behaviour tests on synthetic quotes |
| `tools\historical-data\` | offline source qualification, exact-decimal native LEAN tick conversion and the actual LEAN replay probe (PR 1); see its [README](tools/historical-data/README.md) and [provenance](tools/historical-data/PROVENANCE.md) |
| `.gitignore` | ignores `output\` (generated runs) |

All scripts run on Windows PowerShell 5.1 and PowerShell 7 and use `exit`
codes you can read from `$LASTEXITCODE` when invoked with `-File`.

## 1. Prerequisites (established in Batch A)

- Windows, Git, and a checkout of this fork (`git clone
  https://github.com/Rady70/Lean.git`, about 850 MB including `.git`; the
  clone is the first of the setup-time network steps below).
- .NET SDK 10.x (`dotnet`). The scripts look for it on `PATH`, then
  `$env:DOTNET_ROOT`, then `%ProgramFiles%\dotnet\dotnet.exe`, and stop with an
  `ERROR:` if none exists.
- Network access to the NuGet feed for `dotnet restore`. Which feed is
  machine state, not repository state: `dotnet restore` applies the
  user-level `%APPDATA%\NuGet\NuGet.Config` (or NuGet's built-in nuget.org
  default when none exists) and does **not** apply the repository's tracked
  `.nuget\NuGet.config` (an upstream artefact pointing at an empty
  `LocalPackages\`). A fresh package cache pulls about 650 MB (86 package
  versions) from `api.nuget.org`; NuGet also keeps an HTTP cache under
  `%LOCALAPPDATA%\NuGet\v3-cache` (about 130 MB).
- Disk: about 3.4 GB for a clean setup — the clone, both build
  configurations (`bin\`/`obj\` about 1.8 GB), the package cache and the
  HTTP cache — plus the run directories you keep (section 8).
- For Python algorithms only (section 9): a CPython 3.11 installation with the
  packages named in `Algorithm.Python\readme.md` (pandas, wrapt) and the
  **Debug** build (section 2). Obtaining CPython and installing those packages
  may need network access (python.org, PyPI), as may the build's NuGet
  restore; the backtest itself needs none (outbound traffic is not
  instrumented, section 13).
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

- Configuration: `Release` (Batch A baseline, the C# path). `-Configuration
  Debug` builds `Launcher\bin\Debug\` alongside it and is **required for Python
  algorithms** (section 9); both builds can coexist.
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
pwsh -File MarketLab\scripts\run-backtest.ps1 -DryRun      # validate and print the command; LEAN is not launched
Get-Help MarketLab\scripts\run-backtest.ps1 -Full          # every parameter
```

The helper, in order:

1. resolves `dotnet` and every path to an absolute form (trailing `\` stripped;
   a path that cannot be resolved is an `ERROR:`, exit 2);
2. pre-flight: launcher DLL present, config present and parsable and
   backtesting-only (section 3), algorithm file present, data folder present
   with both auxiliary databases, output root usable. Every problem is one
   `ERROR:` line naming the path and the fix; exit code 2, LEAN not launched;
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

   With `-Parameters` (section 9) the call ends with one more option,
   `--parameters key:value,key:value`. The printed line is exactly this call,
   rendered so it can be pasted into a PowerShell prompt (arguments with
   spaces or PowerShell-special characters are single-quoted). All options
   are declared in
   [`Configuration/LeanArgumentParser.cs`](../Configuration/LeanArgumentParser.cs);
   there is no `live-mode` option, that key comes from the validated file only;
5. reads the engine's own `data-monitor-report-*.json` from the run directory
   and fails with exit code 3 if any data request failed (section 10), then
   reads the run's `log.txt` and fails with exit code 4 if LEAN exited 0 but
   logged an engine `ERROR::` line (section 10);
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
| 0 | backtest completed; every local data request succeeded; no engine `ERROR::` line in `log.txt` |
| 1 | LEAN: algorithm did not reach `Completed` ([`Launcher/Program.cs`](../Launcher/Program.cs)); also PowerShell's own code when it rejects a parameter value (for example an empty `-AlgorithmTypeName`) before the script runs |
| 2 | pre-flight validation failed; LEAN was not launched (for Python, the pandas probe may have run) |
| 3 | LEAN exited 0 but its data monitor counted failed data requests (warning only with `-AllowMissingData`) |
| 4 | LEAN exited 0 but its engine log contains engine `ERROR::` lines, for example a corrupt or empty data file it skipped or a statistics failure (warning only with `-AllowEngineErrors`); the algorithm's own `Error()` output, rejected orders and missing-file lines already counted by exit code 3 are not engine errors |
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
| Local mutable data | files you add under `Data\` (or any `-DataFolder`); NuGet package cache (`%USERPROFILE%\.nuget\packages`, or `$env:NUGET_PACKAGES`) and NuGet's HTTP cache (`%LOCALAPPDATA%\NuGet\v3-cache`) | ignored (`*Data/*` upstream) / outside the repo |
| Build output | `*\bin\`, `*\obj\`, `Launcher\bin\Release\` | ignored (upstream `.gitignore`) |
| Generated runs | `MarketLab\output\` (results, logs, `storage\`, data-monitor files) | ignored (`MarketLab\.gitignore`) |
| Temporary test scratch | `%TEMP%\marketlab-tests-<guid>\` (fixtures and the `-IncludeSmoke` run of `tests\Test-MarketLabBacktesting.ps1`); removed by the test when it ends | outside the repo |
| Safe to delete | `MarketLab\output\*`, `*\bin`, `*\obj`, any leftover `%TEMP%\marketlab-tests-*` | rebuild / rerun to recreate |

No secrets or machine-local settings are needed anywhere in this workflow, so
none exists to protect.

## 9. Changing the algorithm

Only supported LEAN inputs are used (`--algorithm-type-name`,
`--algorithm-language`, `--algorithm-location`, `--parameters`):

- Another C# algorithm from the shipped assembly:
  `-AlgorithmTypeName BasicTemplateAlgorithm` (any class in
  `Launcher\bin\Release\QuantConnect.Algorithm.CSharp.dll`; sources in
  `Algorithm.CSharp\`).
- Your own C# assembly: `-AlgorithmLocation <path\to\YourAlgorithms.dll>` with
  the matching `-AlgorithmTypeName`.
- Algorithm parameters (`QCAlgorithm.GetParameter`, `self.get_parameter`,
  or a C# field with `[Parameter("name")]`): see the next subsection.
- Python algorithms: see the subsection after it.

### Algorithm parameters (qualified in Batch D)

LEAN hands an algorithm a flat string dictionary
(`AlgorithmNodePacket.Parameters`, built in
[`Queues/JobQueue.cs`](../Queues/JobQueue.cs) from the config key
`parameters` and applied by `BacktestingSetupHandler` through
`QCAlgorithm.SetParameters`). Two supported ways feed it:

- **Config file** (upstream's mechanism): the `parameters` object of the
  config file, `"parameters": { "ema-fast": 10, "ema-slow": 20 }`. The
  tracked `config\backtesting.json` carries an empty object; copy it, edit
  the copy and pass `-Config <copy>` so the tracked file stays unchanged.
- **`-Parameters`** (helper option): `-Parameters ema-fast:10,ema-slow:20`,
  rendered as LEAN's own command-line option `--parameters
  ema-fast:10,ema-slow:20`
  ([`Configuration/LeanArgumentParser.cs`](../Configuration/LeanArgumentParser.cs)).
  LEAN merges command-line values over the config file's object
  ([`Configuration/Config.cs`](../Configuration/Config.cs),
  `MergeCommandLineArgumentsWithConfiguration`): a key given here overrides
  the same key in the file, the file's other keys stay in effect. The dry
  run prints a `parameters:` line and the option in the command line.

Both routes deliver the same dictionary; the result packet's
`algorithmConfiguration.parameters` (in `<Algorithm>.json` and
`-summary.json`) is exactly what the algorithm received, which is the way to
confirm a value arrived. Values are strings: `[Parameter]` fields are
converted to the field type, `GetParameter(name, default)` parses to the
default's type and returns the default when parsing fails.

What the command line cannot carry intact, and what pre-flight therefore
refuses (exit 2, LEAN not launched): LEAN splits the option value on `,` and
each pair on `:` and keeps only the text after the first `:`
([`Configuration/ApplicationParser.cs`](../Configuration/ApplicationParser.cs)),
so a value containing `:` is refused (use the config route), as are an entry
without `:`, an empty key or value (LEAN logs an engine `ERROR::` for an
empty value and skips it, which the post-run check would report as exit
code 4; a whitespace-only value fails the `[Parameter]` conversion instead),
a key or value with leading or trailing whitespace (neither LEAN nor the
helper trims: `ema-fast:10, ema-slow:20` would hand the algorithm the key
`" ema-slow"`, which `[Parameter("ema-slow")]` and `GetParameter("ema-slow")`
never match, so the in-code default would be used with exit code 0 and no
message — observed in Batch D before the refusal was added), an entry
containing a double quote, a list that contains whitespace anywhere and
whose last entry ends with a backslash (Windows PowerShell 5.1 passes
neither to the launcher intact: `q:a"b` arrived as `q:ab`, `p:hello world\`
as `p:hello world"` and `ema-fast:10,p:hello world,z:dir\` delivered `z` as
`dir"`, each with exit code 0 — also observed in Batch D; PowerShell 7
delivers all of them correctly, but the helper behaves the same on both
shells, because the pairs travel as one quoted argument), and a repeated key (LEAN
silently keeps the last; keys are compared exactly, as LEAN compares them,
so `A` and `a` are two keys). Everything else is delivered as typed: values
with spaces, `=`, `;`, `|`, `&`, parentheses, braces, `$`, backticks,
non-ASCII text and a backslash not at the end were checked in Batch D. The
helper splits on `,` the same way LEAN does, so `-Parameters a:1,b:2` from a
`-File` command line and `-Parameters 'a:1','b:2'` from inside PowerShell
mean the same pairs; with `-File`, quote a list that contains a space
(`-Parameters "name:hello world,ema-fast:10"`), otherwise the shell splits it
into separate arguments and the second part binds to the next positional
parameter (`-LeanRoot`), which the helper then rejects with a confusing
message.

Behaviour observed in Batch D that the helper does not change:

- a key the algorithm never reads is accepted silently and still listed in
  `algorithmConfiguration.parameters`;
- a value a C# `[Parameter]` field cannot convert (`ema-fast:abc`) makes
  `SetParameters` log `Error applying parameter values: ...` as an
  algorithm-time-prefixed error (exit code stays 0) and **stops applying the
  remaining attributed fields**, which keep their in-code defaults
  ([`Common/Parameters/ParameterAttribute.cs`](../Common/Parameters/ParameterAttribute.cs));
  a Python `get_parameter(name, default)` with the same input returns the
  default for that key only, with no message at all;
- upstream's shipped `Launcher/config.json` (which the MarketLab path does
  not read) sets `ema-fast: 10, ema-slow: 20`, and upstream's regression
  expectations for `ParameterizedAlgorithm` were produced with those
  values, not with the algorithm's in-code defaults (100/200).

### Python algorithms (qualified in Batch C on the Debug build)

`-Parameters` applies to Python runs unchanged (the same `--parameters`
option; `self.get_parameter("ema-fast", 100)`).

LEAN runs Python algorithms through its embedded Python.NET runtime
(`QuantConnect.pythonnet`, [`AlgorithmFactory/Loader.cs`](../AlgorithmFactory/Loader.cs),
[`Common/Python/PythonInitializer.cs`](../Common/Python/PythonInitializer.cs)),
which loads the CPython DLL named by the `PYTHONNET_PYDLL` environment
variable, exactly as [`Algorithm.Python/readme.md`](../Algorithm.Python/readme.md)
describes for Windows. What that readme asks for, and what was used:

| Requirement (upstream) | Qualified on this machine |
|---|---|
| CPython 3.11 (readme: 3.11.11 from python.org; python.org ships no Windows installer past 3.11.9, and upstream's own container uses conda 3.11.11) | python.org CPython **3.11.9** x64, per-user install (`%LOCALAPPDATA%\Programs\Python\Python311`), not on `PATH` |
| `PYTHONNET_PYDLL` → that installation's `python311.dll` | passed by the helper (`-PythonDll`, or an inherited `PYTHONNET_PYDLL`) to the launcher process only |
| `pandas` (readme: 2.2.3), `wrapt` (readme: 1.16.0), installed into that interpreter | `pandas==2.2.3`, `wrapt==1.16.0`, plus `numpy==1.26.4` pinned to the version upstream's container tests against (`DockerfileLeanFoundation`); pandas's own dependencies as resolved by pip |
| build LEAN, then run with `algorithm-language: Python` | `build.ps1 -Configuration Debug`, then the helper with `-Configuration Debug` |

Install the Python packages once (this step may require PyPI access;
installing CPython and the build's NuGet restore may need network access
too):

```powershell
& "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe" -m pip install pandas==2.2.3 wrapt==1.16.0 numpy==1.26.4
pwsh -File MarketLab\scripts\build.ps1 -Configuration Debug
```

Run:

```powershell
pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Debug -AlgorithmLanguage Python `
    -AlgorithmTypeName BasicTemplateAlgorithm -AlgorithmLocation Algorithm.Python\BasicTemplateAlgorithm.py `
    -PythonDll "$env:LOCALAPPDATA\Programs\Python\Python311\python311.dll"
```

What the helper does for a Python run, in addition to section 5:

- pre-flight (exit 2, LEAN not launched) requires `-AlgorithmLocation`, an
  existing `-PythonDll` / `PYTHONNET_PYDLL`, and `-Configuration Debug`;
- pre-flight imports `pandas` through the `python.exe` next to the DLL, because
  LEAN's `PandasConverter` imports pandas for every Python algorithm and its
  only diagnostic when pandas is missing is
  `The type initializer for 'QuantConnect.Python.PandasConverter' threw an
  exception`; if there is no `python.exe` next to the DLL the check is skipped
  with a warning;
- for the launcher process only, it sets `PYTHONNET_PYDLL` to the DLL and
  `PYTHONPATH` to `Launcher\bin\Debug`, where the build copies
  `AlgorithmImports.py`. Upstream relies on that directory being the working
  directory for `from AlgorithmImports import *` to resolve; the MarketLab
  working directory is the run directory, so the path is supplied the way
  upstream's own `.vscode/launch_research.sh` and `DockerfileJupyter` supply
  it (upstream appends to `PYTHONPATH`; the helper replaces an inherited value
  and warns, so the import path is exactly the qualified one). Use the config
  key `python-additional-paths` for extra import paths. The pandas probe runs
  with the same two variables, and it also runs under `-DryRun`;
- the algorithm's own directory is put on the Python path by LEAN itself
  ([`Queues/JobQueue.cs`](../Queues/JobQueue.cs), `GetAlgorithmLocation`).

**Why Debug only.** With the Release build, LEAN completes the Python backtest
and writes every result file, then aborts while shutting down the Python
runtime: `PythonInitializer.Shutdown()` takes a `Py.GIL()` handle it never
disposes, the optimizing JIT lets it be garbage-collected during
`PythonEngine.Shutdown()`, and Python.NET's `GILState` finalizer throws
`GIL must always be released...` on the finalizer thread, which ends the
process with exit code -532462766 (0xE0434352) after "PythonInitializer.
Shutdown(): calling engine shutdown...". With the Debug build the JIT keeps
the local alive and the process exits 0. On this machine the abort
reproduced 3/3 on Release and never on Debug; it matches upstream issue
[QuantConnect/Lean#9708](https://github.com/QuantConnect/Lean/issues/9708)
(closed 2026-09-10 without a fix; the maintainers did not reproduce it in
their public CI), so what is established is a reproducible failure in the
upstream shutdown path on the qualified environment, not an upstream
acknowledgement. It is not corrected in this fork because the
MarketLab no-modification policy allows no engine source change without an
approved exception. Debug is upstream's own documented run configuration
(readme: `dotnet build`, `Launcher/bin/Debug`), so the helper refuses
`-AlgorithmLanguage Python` with `-Configuration Release` in pre-flight rather
than launching a run that cannot exit cleanly.

The qualified Python runtime is the one in the table above. Python.NET 2.0.66
also loaded this machine's python.org 3.14.5 with pandas 3.0.3 and produced
the same statistics once; that is an observation, not a qualified
configuration.

### The SingleAnchor vNext strategy (MarketLab-owned C#)

`src\SingleAnchor\` holds the strategy assembly and `tests\SingleAnchor\` its
tests; both are built with plain `dotnet build` / `dotnet test` on top of the
engine build and run through this helper with `-AlgorithmLocation
MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll
-AlgorithmTypeName SingleAnchorVNextAlgorithm` plus the `single-anchor-*`
parameters. LEAN is the data and time host only: the strategy engine keeps its
own hedged basket ledger and fills deterministically from the quotes, places no
LEAN order, and writes its own results (`storage\single-anchor\results.json`
in the run directory and the algorithm log); LEAN's statistics for such a run
show an empty portfolio and are not strategy results. The optional
`single-anchor-session-map` parameter names a source-derived session map and
makes the first and last five minutes of each complete historical session
quote-only (the final truncated session has an opening buffer only):
the engine observes every quote LEAN delivers, and the results report delivered,
quote-only and strategy-eligible counts separately (section 8 of the
implementation note, and `tools\session-map\`). Without it the run is
unrestricted. Whether LEAN itself delivers every source quote is a separate
data-path property (section 8.7): on the current research data folder it does
not yet, so no source-to-strategy completeness is claimed here.
[SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md](SINGLE_ANCHOR_VNEXT_IMPLEMENTATION.md)
has the commands, the parameter names, the deferred items and a validation
record. Its default dates lie inside upstream's shipped Oanda XAUUSD tick
sample (`Data\cfd\oanda\tick\xauusd`, May 2014, an engine fixture like the
SPY sample, not research data); any other data folder needs the dates set to
its coverage, or the run ends with exit code 3 (section 10).

A historical CSV source is qualified and converted offline before it reaches
that run: `MarketLab\tools\historical-data\` strictly validates the source
against the strategy's quote contract, writes native
`cfd\<market>\tick\xauusd` partitions into a research data folder outside Git,
and verifies the quotes the unchanged LEAN engine actually delivers with a
separate replay probe. See [its README](tools/historical-data/README.md).
**PR 1 of the [research implementation plan](SINGLE_ANCHOR_RESEARCH_IMPLEMENTATION_PLAN.md) is
complete**, and **PR 7** (source-derived session maps and the five-minute
quote-only trading availability described above) is merged. The replay identity
for the real Dukascopy/JForex source is resolved: the source is replayed under
the derived always-open `XAUUSD/dukascopy/Cfd` identity, so LEAN's session
filter removes no legitimate source quote. The known 2023-03 case now delivers
every accepted row (4,465,226 delivered, 4,465,226 probe-processed, source
digest reproduced exactly); under the Oanda fixture identity it previously
clipped 6,798 rows. The full 90-month sweep is the remaining qualification step;
**PR 2** (C# research account and bounded analytics) remains the next
implementation phase after the data path is exercised on the full history.

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

Two further shapes were observed in Batch D:

- **History requests** for files that do not exist behave the same way: the
  `History(...)` call returns an empty result (no exception) and each probed
  file is one failed data request, so the run exits 3 although the
  algorithm completed. The shipped `HistoryAlgorithm` shows this: its demo
  custom-data type builds minute-resolution paths that do not exist, and its
  deliberate history request for the user-defined universe symbols probes
  `qc-universe-userdefined-*` files (39 failed requests, all 28
  upstream-expected statistics still reproduced); `-AllowMissingData` gives
  exit 0 when that is understood.
- **A symbol whose map file starts after the backtest period** (for
  example `GOOG` in October 2013, `map_files\goog.csv` first date
  2014-03-27) is silently moved to that start date: no file is requested,
  no data request fails, the algorithm just never receives the symbol and
  the only signal is the pair of `Debug` lines at the end of the algorithm
  log (`The starting dates for the following symbols have been adjusted to
  match their map files first date`). A symbol whose map file covers the
  period but whose files are absent (`AAPL` minute data in October 2013)
  produces the missing-file lines and exit 3 as described above.

### Corrupt data and other errors LEAN carries on from (exit code 4)

LEAN exits 0 whenever the algorithm reaches `Completed`, even when the engine
logged errors on the way and kept going. Three shapes were observed in
Batch C:

- a **corrupt zip file** is skipped with
  `ZipDataCacheProvider.Fetch(): Corrupt zip file/entry: ...`
  ([`Engine/DataFeeds/ZipDataCacheProvider.cs`](../Engine/DataFeeds/ZipDataCacheProvider.cs)),
  fill-forward covers the gap, the data monitor still counts the request as
  succeeded (the file exists), and the risk statistics silently differ from
  the intact-data run;
- a **valid zip whose entry is empty** (or otherwise yields no data) is
  reported only as `SubscriptionDataSourceReader.InvalidSource(): File not
  found: ...` — the same line LEAN prints for a genuinely missing file — while
  the data monitor counts the request as succeeded because the file opened;
- **malformed rows inside a valid zip** poison the equity curve and
  `BaseResultsHandler.GenerateStatisticsResults()` fails with an
  `OverflowException`, leaving the statistics block empty.

Every clean qualified run has no `ERROR::` line in its `log.txt`, so after a
run that LEAN ended with exit code 0 the helper reads `log.txt` and exits **4**
with an `ERROR:` block quoting up to five engine `ERROR::` lines when any are
present. Two kinds of `ERROR::` line are **not** engine errors and are not
counted:

- lines whose message starts with the algorithm time
  (`2013-10-07 09:31:00 ...`): LEAN routes the algorithm's own `Error()` /
  `self.error()` output and handled simulation errors such as rejected orders
  (`Order Error: ... Insufficient buying power ...`) through `Log.Error` with
  that prefix ([`Messaging/Messaging.cs`](../Messaging/Messaging.cs),
  `HandledError`). They are the algorithm's messages, appear in its result
  packet, and a completed backtest that contains them is still a clean run;
- `InvalidSource(): File not found` lines whose path is in the run's
  `failed-data-requests-*.txt`: those files really are missing and the
  data-monitor check above already owns them (exit code 3, or a warning with
  `-AllowMissingData`). The same line for a file that is **not** in that list
  means the file exists but produced no data, and it is counted.

When a run has both a missing file and an engine error, exit code 3 is
returned and both `ERROR:` blocks are printed. `-AllowEngineErrors` turns the
engine-error block into a `WARNING:` and keeps LEAN's exit code. The check
reads the log only; it does not inspect data files, and it relies on the
message texts above, so an upstream change to them would add noise rather
than change an exit code.

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
  reads only `PATH`, `DOTNET_ROOT` and `ProgramFiles`, to find `dotnet`, plus
  `PYTHONNET_PYDLL` and `PYTHONPATH` for Python runs (it sets
  `DOTNET_CLI_TELEMETRY_OPTOUT` and `DOTNET_NOLOGO`, and, for the launcher
  process of a Python run only — and for the pandas probe, which is the one
  other process the helper starts — `PYTHONNET_PYDLL` and `PYTHONPATH`).
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

- Python algorithms are qualified on the **Debug** build only, with the
  runtime in section 9; on this machine the Release build reproducibly
  aborts at Python shutdown (matching closed upstream issue #9708) and is
  refused in pre-flight. `wrapt` is installed because the
  upstream readme lists it; no engine source references it, so its necessity
  was not verified. The pandas pre-flight probe needs a `python.exe` next to
  the DLL and is skipped (with a warning) otherwise.
- Shipped sample data is a small engine fixture under an AlgoSeek
  all-rights-reserved notice; it is not research data and must not be
  redistributed. Any real study needs its own data folder.
- The helper checks a run's data requests only through LEAN's own data
  monitor and its engine log; it does not inspect the data files themselves.
  A corrupt or empty data file is therefore detected only because LEAN logs
  it; a file with plausible but wrong numbers is not detected at all.
- Python runs leave `__pycache__` directories beside the algorithm file and
  in `Launcher\bin\<Configuration>` (CPython's own byte-code cache; ignored
  by upstream's `.gitignore`).
- The build helper wraps upstream's command-line build only; the Visual Studio
  IDE route in upstream's readme is not covered.
- Outbound network traffic is not instrumented; the absence of remote calls is
  read from the configuration, the handler set and the logs.
- The representative backtests are `BasicTemplateAlgorithm` (C# and Python)
  and the Batch A `BasicTemplateFrameworkAlgorithm`, on SPY minute data for
  one week. Batch D added shipped upstream algorithms, each in C# and Python
  where a twin exists and checked against upstream's own expected
  statistics, for history requests (`HistoryAlgorithm`), indicators
  (`IndicatorSuiteAlgorithm`, SPY/GOOG/IBM daily 2013-2014), scheduled
  events (`ScheduledEventsAlgorithm`,
  `ScheduledEventsOrderRegressionAlgorithm`), parameters
  (`ParameterizedAlgorithm`), several securities
  (`AddRemoveSecurityRegressionAlgorithm`, SPY/AIG/BAC minute) and custom
  data read from the local object store
  (`CustomDataObjectStoreRegressionAlgorithm`); the record is in
  `Rady70/Market_Lab`, `docs/LEAN_FINAL_QUALIFICATION.md`. Optimization
  (`Optimizer.Launcher`) and the Jupyter research route (`Research\`) are
  present in the checkout and were not exercised: the console optimizer
  starts launcher processes that read `config.json` from the launcher
  directory rather than the validated MarketLab config, and the research
  route needs Jupyter with Python hosting .NET (`clr-loader`), a different
  runtime model from the one qualified here. Other algorithms, symbols,
  resolutions and asset classes are not qualified.
- Exit code 1 is also what LEAN returns after an upstream cosmetic error: when
  an algorithm fails to load, `BacktestingResultHandler.SendFinalResult()` logs
  a `NullReferenceException` from `ParameterCountAnalysis` after the real
  error; the real error is the first `ERROR::` line.
- `tests\Test-MarketLabBacktesting.ps1` run against a directory that is not a
  LEAN checkout ends with a terminating error (exit 1) instead of a tally; it
  still fails, which is what the negative check requires.
