<#
.SYNOPSIS
Runs one local LEAN backtest through the MarketLab backtesting-only path.

.DESCRIPTION
Validates the local build output, the MarketLab configuration, the algorithm
and the local data folder, then invokes the LEAN Launcher DIRECTLY
(`dotnet QuantConnect.Lean.Launcher.dll ...`) with the backtesting environment
and absolute local paths, with the process working directory set to a fresh
per-run output directory under -OutputRoot. After the run it reads the engine's
own data-monitor report and fails if any local data request failed, and it
fails if the engine log of an exit-0 run contains ERROR:: lines (LEAN keeps
going after a corrupt data file or a statistics failure and still exits 0).

Pre-flight rejects (exit code 2, LEAN not launched) a config that is not
backtesting-only: `environment` must be exactly "backtesting"; `live-mode`
must be the JSON boolean false at the top level and inside every environment;
`environments` must be an object defining only `backtesting`, and that
environment must not nest an `environment`/`environments` of its own (LEAN
resolves nested environments, Configuration/Config.cs GetToken); the keys
`live-mode-brokerage` and `data-queue-handler` must not exist; and every
handler key that is present, at the top level or inside the environment, must
name the qualified backtesting type (setup-handler BacktestingSetupHandler,
result-handler BacktestingResultHandler, data-feed-handler FileSystemDataFeed,
real-time-handler BacktestingRealTimeHandler, transaction-handler
BacktestingTransactionHandler, history-provider entries
SubscriptionDataReaderHistoryProvider, data-provider DefaultDataProvider).

Python algorithms (-AlgorithmLanguage Python) use LEAN's embedded Python.NET
runtime, which loads the CPython DLL named by the PYTHONNET_PYDLL environment
variable (Algorithm.Python/readme.md). Pre-flight requires -PythonDll (or an
inherited PYTHONNET_PYDLL) naming an existing python3xx.dll, checks that pandas
imports in the interpreter next to it (LEAN's PandasConverter imports pandas for
every Python algorithm and reports only "type initializer ... threw an
exception" when it is missing), and refuses the Release configuration: with
Release binaries LEAN completes the backtest and writes every result, then
aborts while shutting down the Python runtime (reproducible on the qualified
Windows environment; in Common/Python/PythonInitializer.cs; matches upstream
issue QuantConnect/Lean#9708, closed without a fix; exit code
-532462766 / 0xE0434352). Python runs are qualified on the Debug build only
(-Configuration Debug). For the launcher process only, the script sets
PYTHONNET_PYDLL to the resolved DLL and PYTHONPATH to the launcher build
directory so that `from AlgorithmImports import *` resolves from the per-run
working directory (upstream puts the build directory on PYTHONPATH the same
way in .vscode/launch_research.sh and DockerfileJupyter; upstream appends,
this script replaces an inherited value and warns, so the import path is
exactly what was qualified). The pandas probe runs the interpreter next to
the DLL with the same two variables; it is the only process started besides
the launcher and it also runs under -DryRun.

The script never calls the LEAN CLI (`lean`), Docker, pip, QuantConnect Cloud or
any broker, needs no QuantConnect account, login, API token or organization,
and reads no credential from the environment: the only environment variables
it reads are PATH, DOTNET_ROOT and ProgramFiles (to find dotnet), and, for
Python runs, PYTHONNET_PYDLL and PYTHONPATH. LEAN's configuration layer itself
does not read environment variables (no GetEnvironmentVariable in
Configuration/).

Exit codes (observable via $LASTEXITCODE when invoked with `-File`):
  0  backtest completed, every local data request succeeded, no engine
     ERROR:: line in the run's log.txt
  1  LEAN reported that the algorithm did not complete (Launcher/Program.cs),
     or PowerShell rejected a parameter value before the script ran
  2  pre-flight validation failed; LEAN was not launched (a Python
     pre-flight may have run the pandas probe)
  3  LEAN exited 0 but its data-monitor report counts failed data requests
     (suppressed to a warning by -AllowMissingData)
  4  LEAN exited 0 but its engine log (log.txt) contains engine ERROR:: lines,
     e.g. a corrupt or empty data file that was skipped or a statistics
     failure (suppressed to a warning by -AllowEngineErrors). Not counted:
     the algorithm's own Error() output and handled simulation errors such
     as rejected orders (algorithm-time-prefixed lines), and missing-file
     lines for files listed in failed-data-requests-*.txt (exit code 3's)
  other  LEAN's own exit code, propagated unchanged

ERROR:/WARNING: lines are written to stderr, informational lines to stdout.

Requires: Windows PowerShell 5.1 or PowerShell 7+, and the .NET 10 SDK from
Batch A (`dotnet` on PATH, or $env:DOTNET_ROOT, or "$env:ProgramFiles\dotnet").

.PARAMETER LeanRoot
Root of the LEAN checkout. Default: two levels above this script.

.PARAMETER Configuration
Build configuration whose output to run: Release (default) or Debug.

.PARAMETER Config
LEAN configuration file passed as `--config`. Must define ONLY the backtesting
environment with live-mode false. Default: <LeanRoot>\MarketLab\config\backtesting.json.

.PARAMETER AlgorithmTypeName
Algorithm class name (`--algorithm-type-name`), not empty. Default: BasicTemplateFrameworkAlgorithm.

.PARAMETER AlgorithmLanguage
CSharp (default) or Python. Python requires -AlgorithmLocation, -PythonDll (or
PYTHONNET_PYDLL) and -Configuration Debug; see DESCRIPTION and
MarketLab\README.md section 9.

.PARAMETER AlgorithmLocation
Assembly (.dll) or Python file containing the algorithm (`--algorithm-location`).
Default: <LeanRoot>\Launcher\bin\<Configuration>\QuantConnect.Algorithm.CSharp.dll.
Required when -AlgorithmLanguage is Python.

.PARAMETER PythonDll
Python runs only: the CPython 3.11 runtime DLL (python311.dll) that Python.NET
loads, passed to the launcher process as PYTHONNET_PYDLL. Default: the
PYTHONNET_PYDLL environment variable. The interpreter next to it must have the
packages from Algorithm.Python/readme.md installed (pandas, wrapt).

.PARAMETER Parameters
Algorithm parameters, one `key:value` string each (for example
-Parameters ema-fast:10,ema-slow:20), passed to LEAN as its own
`--parameters key:value,key:value` option (Configuration/LeanArgumentParser.cs)
and read by the algorithm through QCAlgorithm.GetParameter / the [Parameter]
attribute. LEAN merges them over the config file's "parameters" object
(Configuration/Config.cs), so a key given here overrides the same key in the
file and the file's other keys stay in effect. LEAN's parser splits the option
value on ',' and each pair on ':' and keeps only the text after the first ':'
(Configuration/ApplicationParser.cs); the script splits the same way (one
string with commas or several strings both work), so ',' can never be part of
a key or value, and a value containing ':' is refused in pre-flight (exit 2),
as are an empty key or value, a key or value with leading or trailing
whitespace (neither LEAN nor this script trims, so " ema-slow" would never
match the algorithm's "ema-slow" and the default would be used silently), an
entry containing a double quote, a list that contains whitespace anywhere
and whose last entry ends with a backslash (Windows PowerShell 5.1 does not
pass either to the launcher intact, so both are refused on every shell) and
a repeated key, compared exactly as LEAN compares keys (LEAN logs an engine
ERROR:: for an empty value and silently keeps the last duplicate). Default: none.

.PARAMETER DataFolder
Historical data root (`--data-folder`). Must contain
market-hours\market-hours-database.json and
symbol-properties\symbol-properties-database.csv. Default: <LeanRoot>\Data.

.PARAMETER OutputRoot
Directory under which one <yyyyMMdd-HHmmss>-<AlgorithmTypeName> run directory
is created per run (UTC timestamp). Results, log.txt, storage\ and the
data-monitor files all land in that run directory. Default: <LeanRoot>\MarketLab\output.

.PARAMETER AllowMissingData
Downgrade failed data requests from exit code 3 to a warning.

.PARAMETER AllowEngineErrors
Downgrade engine ERROR:: lines in an exit-0 run from exit code 4 to a warning.

.PARAMETER RunEvidence
Write machine-readable run evidence into the run directory. Before LEAN is
launched, `marketlab-run-invocation.json` records the resolved absolute inputs
(build configuration, config file with its LF-normalized SHA-256, algorithm
location and SHA-256, data folder, the exact `--parameters` pairs, the allow
flags, the launcher and its SHA-256, the exact launcher argv array, the Git HEAD
and dirty state, and the hashes of the qualified runtime binary set). After the
run, `marketlab-run-outcome.json` records the LEAN exit code, the final helper
exit code, the engine-error check and count, the data-monitor result and
whether the runtime binaries changed during the run. The files are evidence of
what the run actually did, not a reconstruction; failing to write the pre-run
file stops the run before LEAN is launched (exit 2). Default: off (dry runs
never create it).

.PARAMETER BaselineContract
With -RunEvidence: path to the frozen baseline contract whose LF-normalized
SHA-256 is recorded in the pre-run evidence. Must be passed together with
-BaselineRegister, must exist, and must hash exactly to the register pin or the
run refuses to launch (exit 2).

.PARAMETER BaselineRegister
With -RunEvidence: path to the authoritative decision register that pins the
frozen contract hash. See -BaselineContract.

.PARAMETER ExpectedTerminalException
With -RunEvidence: the fully-qualified name of the one modeled terminal
strategy exception the run is allowed to end with (the AccountStopOut
exception for the frozen baseline). The post-run engine-log audit always runs
when the engine log exists; engine ERROR:: lines whose message contains this
name are counted separately as the expected terminal exception, so every other
engine ERROR:: line still counts as an unrelated engine error. The value is
recorded in the evidence so the classifier can check it.

.PARAMETER ReviewedCommit
With the baseline contract: explicitly reviewed full Git SHA. A clean checkout
at exactly this commit and a successful source-bound build receipt are required.

.PARAMETER BuildReceipt
Receipt from Build-SingleAnchorBaseline.ps1. Default: MarketLab\output\baseline-build.json.
The baseline helper verifies every dependency, compares the actual invocation
with the frozen contract and automatically repeats the qualified-tree preflight.

.PARAMETER DryRun
Validate everything, print the resolved paths and the exact command line, create
nothing and exit 0. (For Python, validation includes the pandas probe, which
runs the interpreter next to -PythonDll.)

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1
Runs the representative Batch A backtest (BasicTemplateFrameworkAlgorithm) on
the shipped sample data.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -AlgorithmTypeName BasicTemplateAlgorithm
Runs another algorithm compiled into QuantConnect.Algorithm.CSharp.dll.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -Configuration Debug -AlgorithmLanguage Python -AlgorithmTypeName BasicTemplateAlgorithm -AlgorithmLocation Algorithm.Python\BasicTemplateAlgorithm.py -PythonDll C:\Python311\python311.dll
Runs the Python representative algorithm against the Debug build.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -AlgorithmTypeName ParameterizedAlgorithm -Parameters ema-fast:10,ema-slow:20
Runs a parameterized algorithm with two parameter values passed through LEAN's
--parameters option (read by GetParameter / [Parameter("ema-fast")]).

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -DryRun
Shows what would be run without launching LEAN (a Python dry run still runs
the pandas probe).

.LINK
https://github.com/QuantConnect/Lean/blob/master/Launcher/config.json
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [string]$Config,
    [ValidateNotNullOrEmpty()]
    [string]$AlgorithmTypeName = 'BasicTemplateFrameworkAlgorithm',
    [ValidateSet('CSharp', 'Python')]
    [string]$AlgorithmLanguage = 'CSharp',
    [string]$AlgorithmLocation,
    [string]$PythonDll,
    [string[]]$Parameters,
    [string]$DataFolder,
    [string]$OutputRoot,
    [switch]$AllowMissingData,
    [switch]$AllowEngineErrors,
    [switch]$RunEvidence,
    [string]$BaselineContract,
    [string]$BaselineRegister,
    [string]$ExpectedTerminalException,
    [string]$ReviewedCommit,
    [string]$BuildReceipt,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SingleAnchorBaseline.ps1')
# The launcher's exit code is read from $LASTEXITCODE and propagated by this
# script; never let PowerShell 7.4+ turn a non-zero native exit into an exception.
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$script:ExitPreflight = 2
$script:ExitMissingData = 3
$script:ExitEngineErrors = 4
# "<python version> <pandas version>" from the Python pre-flight probe, when it ran.
$script:PythonProbe = $null

# The qualified backtesting handler set (Batch B). Values are LEAN type names;
# LEAN's Composer accepts the simple name, the namespace-qualified name or the
# assembly-qualified name (Common/Extensions.cs MatchesTypeName), so a
# configured value must equal the simple name or end with ".<simple name>".
# Extending this set is a later-batch decision, not an operator setting.
$script:QualifiedHandlers = @{
    'setup-handler'       = 'BacktestingSetupHandler'
    'result-handler'      = 'BacktestingResultHandler'
    'data-feed-handler'   = 'FileSystemDataFeed'
    'real-time-handler'   = 'BacktestingRealTimeHandler'
    'transaction-handler' = 'BacktestingTransactionHandler'
    'history-provider'    = 'SubscriptionDataReaderHistoryProvider'
    # DefaultDataProvider reads local files only. ApiDataProvider
    # (Engine/DataFeeds/ApiDataProvider.cs) downloads through the QuantConnect
    # API with an organization id and token (Batch A section 2.5) and is
    # therefore outside the accountless boundary.
    'data-provider'       = 'DefaultDataProvider'
}
# Keys that only exist for live trading; they must not appear anywhere.
$script:ForbiddenKeys = @('live-mode-brokerage', 'data-queue-handler')

# The qualified LEAN runtime binary set (the continuous-qualification route's
# engine assembly list, without its probe assembly): -RunEvidence hashes these
# before the run and again after it, so a mid-run binary change is visible.
$script:RuntimeBinaryFileNames = @(
    'QuantConnect.Lean.Launcher.dll',
    'QuantConnect.Lean.Engine.dll',
    'QuantConnect.Common.dll',
    'QuantConnect.Algorithm.dll',
    'QuantConnect.AlgorithmFactory.dll',
    'QuantConnect.Configuration.dll',
    'QuantConnect.Logging.dll'
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Write-Info([string]$Message) {
    Write-Host $Message
}

function Write-ErrorLine([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Write-WarningLine([string]$Message) {
    [Console]::Error.WriteLine("WARNING: $Message")
}

# Absolute, normalized path without a trailing directory separator. A path that
# ends in "\" immediately before a closing quote breaks Windows argv parsing and
# swallows the following arguments, so every path handed to the launcher goes
# through here. Does not require the path to exist. Throws on an illegal path.
function ConvertTo-AbsolutePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'empty path'
    }
    $base = (Get-Location).ProviderPath
    $combined = [System.IO.Path]::Combine($base, $Path)
    $full = [System.IO.Path]::GetFullPath($combined)
    $trimmed = $full.TrimEnd([char]'\', [char]'/')
    # Keep a bare drive root ("C:\") intact; "C:" alone would be drive-relative.
    if ($trimmed -match '^[A-Za-z]:$') {
        return $full
    }
    return $trimmed
}

# SHA-256 of a file as lower-case hex. -LfNormalized reads the file as UTF-8
# text and normalizes CRLF to LF first (the content-identity convention used by
# the MarketLab baseline contract); the default hashes the raw bytes.
function Get-Sha256Hex([string]$Path, [switch]$LfNormalized) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($LfNormalized) {
            $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
        }
        else {
            $stream = [System.IO.File]::OpenRead($Path)
            try {
                $hash = $sha.ComputeHash($stream)
            }
            finally {
                $stream.Dispose()
            }
        }
    }
    finally {
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Resolve-DotnetExecutable {
    $cmd = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) {
        return $cmd.Source
    }
    $candidates = @()
    if (-not [string]::IsNullOrEmpty($env:DOTNET_ROOT)) {
        $candidates += (Join-Path $env:DOTNET_ROOT 'dotnet.exe')
    }
    if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

# Strips // and /* */ comments outside of JSON strings. LEAN parses its config
# with Newtonsoft (comments allowed); ConvertFrom-Json on Windows PowerShell 5.1
# does not accept them.
function Remove-JsonComments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $i = 0
    $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq [char]'\' -and ($i + 1) -lt $n) {
                [void]$sb.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($c -eq [char]'"') {
                $inString = $false
            }
            $i++
            continue
        }
        if ($c -eq [char]'"') {
            $inString = $true
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq [char]'/' -and ($i + 1) -lt $n) {
            $next = $Text[$i + 1]
            if ($next -eq [char]'/') {
                while ($i -lt $n -and $Text[$i] -ne [char]"`n") { $i++ }
                continue
            }
            if ($next -eq [char]'*') {
                $end = $Text.IndexOf('*/', $i + 2)
                if ($end -lt 0) { $i = $n } else { $i = $end + 2 }
                continue
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

# Property lookup that works under Set-StrictMode on both PS 5.1 and 7 and
# returns $null for a missing property instead of throwing. The unary comma
# keeps a JSON array intact (PowerShell would otherwise unroll a one-element
# array into its element, letting "live-mode": [false] pass as a boolean).
function Get-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return , $prop.Value
}

function Test-JsonPropertyExists($Object, [string]$Name) {
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

# JSON kind of a value parsed by ConvertFrom-Json, for error messages.
function Get-JsonKind($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [array]) { return 'array' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [System.ValueType]) { return 'number' }
    return $Value.GetType().Name
}

function Format-JsonValue($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [array]) { return ('[' + (($Value | ForEach-Object { Format-JsonValue $_ }) -join ', ') + ']') }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return '{...}' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    return [string]$Value
}

# True when a configured LEAN type name resolves to the given simple type name:
# equal to it, or namespace-qualified ending in ".<simple>", optionally with an
# assembly-qualified ", Assembly, Version=..." suffix (Common/Extensions.cs MatchesTypeName).
function Test-LeanTypeName($Value, [string]$SimpleName) {
    if (-not ($Value -is [string])) { return $false }
    $name = $Value.Trim()
    $comma = $name.IndexOf(',')
    if ($comma -ge 0) { $name = $name.Substring(0, $comma).Trim() }
    return (($name -ceq $SimpleName) -or $name.EndsWith('.' + $SimpleName, [System.StringComparison]::Ordinal))
}

# Checks the handler keys of one config object (top level or one environment)
# against the qualified backtesting set. Adds problems to $Problems.
function Test-HandlerSet($Object, [string]$Scope, [string]$ConfigPath, $Problems) {
    foreach ($key in $script:ForbiddenKeys) {
        if (Test-JsonPropertyExists $Object $key) {
            $Problems.Add("Config `"$ConfigPath`": $Scope`"$key`" is present. This key only exists for live trading; remove it. The MarketLab path is backtesting-only.")
        }
    }
    foreach ($key in ($script:QualifiedHandlers.Keys | Sort-Object)) {
        if (-not (Test-JsonPropertyExists $Object $key)) { continue }
        $expected = $script:QualifiedHandlers[$key]
        $value = Get-JsonProperty $Object $key
        $values = @()
        if ($key -eq 'history-provider') {
            # LEAN accepts a string or an array of type names here.
            if ($value -is [array]) { $values = @($value) } else { $values = @($value) }
        }
        elseif ($value -is [string]) {
            $values = @($value)
        }
        else {
            $Problems.Add("Config `"$ConfigPath`": $Scope`"$key`" is a JSON $(Get-JsonKind $value) but must be the JSON string naming $expected.")
            continue
        }
        if ($values.Count -eq 0) {
            $Problems.Add("Config `"$ConfigPath`": $Scope`"$key`" is empty; it must name $expected.")
            continue
        }
        foreach ($entry in $values) {
            if (-not (Test-LeanTypeName $entry $expected)) {
                $Problems.Add("Config `"$ConfigPath`": $Scope`"$key`" is $(Format-JsonValue $entry) but the MarketLab path only runs the qualified backtesting handler $expected (a simple or namespace-qualified LEAN type name ending in $expected). Live, brokerage, API or other handlers are outside the boundary.")
            }
        }
    }
}

# PowerShell-pasteable rendering of the launch: `& 'exe' arg arg ...`, quoting
# any argument that contains whitespace or a character PowerShell would parse.
function Format-CommandLine([string]$Executable, [string[]]$Arguments) {
    $parts = @()
    foreach ($item in (@($Executable) + $Arguments)) {
        if ($item -match '[\s''"|<>&;(){}$`,]') {
            $parts += ("'" + ($item -replace "'", "''") + "'")
        }
        else {
            $parts += $item
        }
    }
    return ('& ' + ($parts -join ' '))
}

# ----------------------------------------------------------------------------
# Resolve inputs
# ----------------------------------------------------------------------------

$problems = New-Object System.Collections.Generic.List[string]

function Resolve-InputPath([string]$ParameterName, [string]$Value) {
    try {
        return ConvertTo-AbsolutePath $Value
    }
    catch {
        $problems.Add("-$ParameterName value `"$Value`" is not a usable path ($($_.Exception.Message)). Pass a plain absolute or relative path; from cmd.exe do not end a quoted path with a backslash.")
        return $null
    }
}

if ([string]::IsNullOrEmpty($LeanRoot)) {
    $LeanRoot = Join-Path $PSScriptRoot '..\..'
}
$leanRootPath = Resolve-InputPath 'LeanRoot' $LeanRoot

$configPath = $null
if ($null -ne $leanRootPath) {
    if ([string]::IsNullOrEmpty($Config)) {
        $Config = Join-Path $leanRootPath 'MarketLab\config\backtesting.json'
    }
    $configPath = Resolve-InputPath 'Config' $Config
}

$launcherDir = $null
$launcherDll = $null
$algorithmLocationPath = $null
$algorithmLocationSupplied = -not [string]::IsNullOrEmpty($AlgorithmLocation)
if ($null -ne $leanRootPath) {
    $launcherDir = Join-Path $leanRootPath ("Launcher\bin\" + $Configuration)
    $launcherDll = Join-Path $launcherDir 'QuantConnect.Lean.Launcher.dll'
    if (-not $algorithmLocationSupplied) {
        $AlgorithmLocation = Join-Path $launcherDir 'QuantConnect.Algorithm.CSharp.dll'
    }
    $algorithmLocationPath = Resolve-InputPath 'AlgorithmLocation' $AlgorithmLocation
}

# Python runs: the CPython DLL for Python.NET. Read from -PythonDll, else from
# the inherited PYTHONNET_PYDLL (the upstream-documented setting). Only used,
# validated and passed on when the language is Python.
$pythonDllPath = $null
$pythonDllSource = '-PythonDll'
$pythonDllGiven = $false
if ($AlgorithmLanguage -eq 'Python') {
    if ([string]::IsNullOrEmpty($PythonDll) -and -not [string]::IsNullOrEmpty($env:PYTHONNET_PYDLL)) {
        $PythonDll = $env:PYTHONNET_PYDLL
        $pythonDllSource = 'PYTHONNET_PYDLL'
    }
    if (-not [string]::IsNullOrEmpty($PythonDll)) {
        $pythonDllGiven = $true
        $pythonDllPath = Resolve-InputPath 'PythonDll' $PythonDll
    }
}

$dataFolderPath = $null
if ($null -ne $leanRootPath) {
    if ([string]::IsNullOrEmpty($DataFolder)) {
        $DataFolder = Join-Path $leanRootPath 'Data'
    }
    $dataFolderPath = Resolve-InputPath 'DataFolder' $DataFolder
}

$outputRootPath = $null
if ($null -ne $leanRootPath) {
    if ([string]::IsNullOrEmpty($OutputRoot)) {
        $OutputRoot = Join-Path $leanRootPath 'MarketLab\output'
    }
    $outputRootPath = Resolve-InputPath 'OutputRoot' $OutputRoot
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-ErrorLine $problem }
    Write-ErrorLine "Pre-flight validation failed with $($problems.Count) problem(s); LEAN was not launched. Exit code $script:ExitPreflight."
    exit $script:ExitPreflight
}

# ----------------------------------------------------------------------------
# Pre-flight validation (collect every problem, then exit 2)
# ----------------------------------------------------------------------------

$dotnet = Resolve-DotnetExecutable
if ($null -eq $dotnet) {
    $problems.Add("dotnet was not found on PATH, in `$env:DOTNET_ROOT, or at `"$env:ProgramFiles\dotnet\dotnet.exe`". Install the .NET 10 SDK (Batch A prerequisite) or add it to PATH.")
}

if (-not (Test-Path -LiteralPath $leanRootPath -PathType Container)) {
    $problems.Add("LEAN root `"$leanRootPath`" is not a directory. Pass -LeanRoot <path to the LEAN checkout>.")
}

if (-not (Test-Path -LiteralPath $launcherDll -PathType Leaf)) {
    $problems.Add("Launcher build output `"$launcherDll`" does not exist. Build first: MarketLab\scripts\build.ps1 -Configuration $Configuration (or pass -LeanRoot / -Configuration matching an existing build).")
}

if ($AlgorithmLanguage -eq 'Python' -and -not $algorithmLocationSupplied) {
    $problems.Add("-AlgorithmLanguage Python requires -AlgorithmLocation <algorithm .py file> (see MarketLab\README.md section 9).")
}
if (-not (Test-Path -LiteralPath $algorithmLocationPath -PathType Leaf)) {
    $problems.Add("Algorithm location `"$algorithmLocationPath`" does not exist. Build first, or pass -AlgorithmLocation <assembly or .py file>.")
}

# Python runtime pre-flight (Batch C). Everything here is checked before
# launch because LEAN's own diagnostics for these cases are late or opaque.
$pythonExe = $null
if ($AlgorithmLanguage -eq 'Python') {
    if ($Configuration -ne 'Debug') {
        $problems.Add("-AlgorithmLanguage Python requires -Configuration Debug. With the $Configuration build LEAN completes the backtest and writes every result, then aborts while shutting down the Python runtime (reproducible on the qualified environment; matches upstream QuantConnect/Lean issue #9708, closed without a fix: Common/Python/PythonInitializer.cs Shutdown() holds a Py.GIL() handle it never disposes, and the optimizing JIT lets Python.NET finalize it during PythonEngine.Shutdown; process exit code -532462766 / 0xE0434352). Python runs are qualified on the Debug build only: build with MarketLab\scripts\build.ps1 -Configuration Debug and pass -Configuration Debug.")
    }
    if (-not $pythonDllGiven) {
        $problems.Add("-AlgorithmLanguage Python requires -PythonDll <path to python311.dll> or the PYTHONNET_PYDLL environment variable (Algorithm.Python/readme.md). Python.NET cannot start without it (Runtime.PythonDLL was not set). See MarketLab\README.md section 9 for the qualified runtime.")
    }
    elseif ($null -eq $pythonDllPath) {
        # Unusable path: already reported by Resolve-InputPath.
    }
    elseif (-not (Test-Path -LiteralPath $pythonDllPath -PathType Leaf)) {
        $problems.Add("Python DLL `"$pythonDllPath`" (from $pythonDllSource) does not exist. Point -PythonDll / PYTHONNET_PYDLL at the python311.dll of a CPython 3.11 installation (see MarketLab\README.md section 9).")
    }
    else {
        # LEAN's PandasConverter imports pandas in its static constructor for
        # every Python algorithm (Common/Python/PandasConverter.cs) and the only
        # engine diagnostic when it is missing is "The type initializer for
        # 'QuantConnect.Python.PandasConverter' threw an exception". The
        # interpreter that owns the DLL sits next to it in every standard
        # Windows CPython layout; when it is there, import pandas through it,
        # with the same PYTHONNET_PYDLL/PYTHONPATH the launcher process gets so
        # that the probe sees the same module search path. This is the one
        # process the script starts besides the launcher; it runs `-c` code
        # only, cannot prompt, and makes no network call. -DryRun runs it too.
        $pythonExe = Join-Path ([System.IO.Path]::GetDirectoryName($pythonDllPath)) 'python.exe'
        if (Test-Path -LiteralPath $pythonExe -PathType Leaf) {
            $probeOutput = ''
            $probeExit = $null
            $previousErrorActionPreference = $ErrorActionPreference
            $probePreviousDll = $env:PYTHONNET_PYDLL
            $probePreviousPath = $env:PYTHONPATH
            try {
                $ErrorActionPreference = 'Continue'
                $env:PYTHONNET_PYDLL = $pythonDllPath
                $env:PYTHONPATH = $launcherDir
                $probeOutput = (& $pythonExe -c 'import sys, pandas; print(sys.version.split()[0], pandas.__version__)' 2>&1 | Out-String).Trim()
                $probeExit = $LASTEXITCODE
            }
            catch {
                $probeOutput = $_.Exception.Message
                $probeExit = -1
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
                $env:PYTHONNET_PYDLL = $probePreviousDll
                $env:PYTHONPATH = $probePreviousPath
            }
            if ($probeExit -ne 0) {
                $lastLine = ''
                if (-not [string]::IsNullOrWhiteSpace($probeOutput)) { $lastLine = ($probeOutput -split "`r?`n")[-1] }
                $problems.Add("Python runtime `"$pythonExe`" (next to $pythonDllSource `"$pythonDllPath`") cannot import pandas ($lastLine). LEAN needs pandas for every Python algorithm and would only report `"The type initializer for 'QuantConnect.Python.PandasConverter' threw an exception`". Install the packages from Algorithm.Python/readme.md into that interpreter (python.exe -m pip install pandas==2.2.3 wrapt==1.16.0) or point -PythonDll at an interpreter that has them.")
            }
            else {
                $script:PythonProbe = $probeOutput
            }
        }
        else {
            Write-WarningLine "No python.exe next to `"$pythonDllPath`"; the pandas pre-flight check was skipped. LEAN will fail at algorithm creation if pandas is not importable."
        }
    }
}

# Algorithm parameters (-Parameters), rendered as LEAN's own
# `--parameters key:value,key:value` (Configuration/LeanArgumentParser.cs).
# LEAN splits that single value on ',' and each pair on ':' and keeps only the
# text after the first ':' (Configuration/ApplicationParser.cs). The same
# splitting is done here first: a `-File` invocation delivers
# `-Parameters ema-fast:10,ema-slow:20` as one string, an in-session caller
# may pass an array, and both must mean the same pairs. A pair whose value
# contains ':' would be truncated by LEAN, an empty value makes
# ParameterAttribute.ApplyAttributes log an engine ERROR:: and skip the key
# (which the post-run check would turn into exit code 4), a whitespace-only
# value fails the [Parameter] conversion instead (the algorithm-time "Error
# applying parameter values" of the README), a repeated key is silently
# overwritten, and a '"' anywhere, or a list with whitespace anywhere whose
# last entry ends in '\', is not delivered intact to the launcher by Windows
# PowerShell 5.1 (it does not escape embedded quotes for native executables;
# observed: q:a"b arrived as q:ab and p:hello world\ as p:hello world"); all
# of these are refused. Keys are compared ordinally, as LEAN's dictionaries
# do (A and a are two keys).
$parameterPairs = @()
if ($null -ne $Parameters -and $Parameters.Count -gt 0) {
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($text in @($Parameters | ForEach-Object { ([string]$_).Split(',') })) {
        $colon = $text.IndexOf(':')
        $key = if ($colon -ge 0) { $text.Substring(0, $colon) } else { $text }
        $value = if ($colon -ge 0) { $text.Substring($colon + 1) } else { '' }
        if ($colon -lt 0 -or [string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($value)) {
            $problems.Add("-Parameters entry `"$text`" is not key:value with a non-empty key and value. LEAN reads --parameters as comma-separated key:value pairs (Configuration/ApplicationParser.cs); it logs an engine ERROR:: for an empty value and fails the [Parameter] conversion for a whitespace-only one; write for example -Parameters ema-fast:10,ema-slow:20.")
            continue
        }
        # Neither LEAN's parser nor this script trims: "ema-fast:10, ema-slow:20"
        # would hand the algorithm the key " ema-slow", which [Parameter("ema-slow")]
        # and GetParameter("ema-slow") never match, so the in-code default would be
        # used with exit code 0 and no message (observed in Batch D). Refuse it
        # instead of silently rewriting what LEAN receives.
        if ($key -ne $key.Trim() -or $value -ne $value.Trim()) {
            $problems.Add("-Parameters entry `"$text`" has leading or trailing whitespace in its key or value. LEAN keeps the text exactly as given (Configuration/ApplicationParser.cs), so the algorithm would look up a different key or receive a padded value and silently use its default; write the pairs without spaces, for example -Parameters ema-fast:10,ema-slow:20.")
            continue
        }
        if ($value.IndexOf(':') -ge 0) {
            $problems.Add("-Parameters entry `"$text`" has a second ':' in its value. LEAN keeps only the text between the first and the second ':' (Configuration/ApplicationParser.cs), so this value cannot be passed on the command line; put it in the `"parameters`" object of a config copy passed with -Config instead.")
            continue
        }
        # Windows PowerShell 5.1 passes arguments to native executables without
        # escaping embedded double quotes, so q:a"b would reach LEAN as q:ab with
        # exit code 0 and no message (observed in Batch D; pwsh 7 delivers it
        # intact). The value is refused on both shells so the helper behaves the
        # same everywhere; a quote has no place in a LEAN parameter value anyway.
        if ($text.IndexOf('"') -ge 0) {
            $problems.Add("-Parameters entry `"$text`" contains a double quote. Windows PowerShell 5.1 does not deliver an embedded `"`"`" intact to the launcher (the algorithm would receive a different value with exit code 0), so quotes are refused on every shell; put such a value in the `"parameters`" object of a config copy passed with -Config instead.")
            continue
        }
        if (-not $seenKeys.Add($key)) {
            $problems.Add("-Parameters entry `"$text`" repeats the key `"$key`" (keys are compared exactly, as LEAN does). LEAN would silently keep the last value; pass each key once.")
            continue
        }
        $parameterPairs += $text
    }
    # The pairs travel as ONE launcher argument. When that argument contains
    # whitespace anywhere, Windows PowerShell 5.1 wraps the whole of it in
    # quotes, and a trailing backslash then escapes the closing quote
    # (observed in Batch D: p:hello world\ arrived as p:hello world", and
    # ema-fast:10,p:hello world,z:dir\ delivered z as dir"; pwsh 7 delivers
    # both intact). Refused on every shell, on the joined value.
    if ($parameterPairs.Count -gt 0) {
        $joined = $parameterPairs -join ','
        if ($joined.EndsWith('\') -and $joined -match '\s') {
            $problems.Add("-Parameters list `"$joined`" contains whitespace and its last entry ends with a backslash. Windows PowerShell 5.1 quotes the whole --parameters argument when it contains whitespace, and the trailing backslash then escapes the closing quote, so the algorithm would receive a different value with exit code 0; it is refused on every shell. Drop the trailing backslash, move that entry away from the end, or use the `"parameters`" object of a config copy passed with -Config.")
        }
    }
}

if (-not (Test-Path -LiteralPath $dataFolderPath -PathType Container)) {
    $problems.Add("Data folder `"$dataFolderPath`" is not a directory. Pass -DataFolder <LEAN data root> (the checkout ships one at <LeanRoot>\Data).")
}
else {
    foreach ($aux in @('market-hours\market-hours-database.json', 'symbol-properties\symbol-properties-database.csv')) {
        $auxPath = Join-Path $dataFolderPath $aux
        if (-not (Test-Path -LiteralPath $auxPath -PathType Leaf)) {
            $problems.Add("Data folder `"$dataFolderPath`" is missing the required auxiliary file `"$aux`". LEAN cannot start without it; point -DataFolder at a LEAN-format data root (see <LeanRoot>\Data).")
        }
    }
}

$configObject = $null
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    $problems.Add("Config file `"$configPath`" does not exist. Pass -Config <file> or restore MarketLab\config\backtesting.json. (LEAN would silently fall back to a config.json in the working directory; this script does not allow that.)")
}
else {
    try {
        $rawText = [System.IO.File]::ReadAllText($configPath)
        $configObject = ConvertFrom-Json -InputObject (Remove-JsonComments $rawText)
        if (-not ($configObject -is [System.Management.Automation.PSCustomObject])) {
            throw "the document is a JSON $(Get-JsonKind $configObject), not an object"
        }
    }
    catch {
        $problems.Add("Config file `"$configPath`" is not valid JSON: $($_.Exception.Message)")
        $configObject = $null
    }
}

if ($null -ne $configObject) {
    # Backtesting-only invariants. LEAN layers environments.<environment> over
    # the top level and recurses into an environment that names its own
    # environment (Configuration/Config.cs GetToken); every layer is checked and
    # nesting is refused, so the configuration LEAN resolves is the one checked.
    $environment = Get-JsonProperty $configObject 'environment'
    if (-not (Test-JsonPropertyExists $configObject 'environment')) {
        $problems.Add("Config `"$configPath`": top-level `"environment`" is missing. It must be exactly the JSON string `"backtesting`".")
    }
    elseif (-not ($environment -is [string]) -or $environment -cne 'backtesting') {
        $problems.Add("Config `"$configPath`": top-level `"environment`" is $(Format-JsonValue $environment) (JSON $(Get-JsonKind $environment)) but must be exactly the JSON string `"backtesting`". The MarketLab path is backtesting-only; it does not run live or paper environments.")
    }

    $topLiveMode = Get-JsonProperty $configObject 'live-mode'
    if (-not (Test-JsonPropertyExists $configObject 'live-mode')) {
        $problems.Add("Config `"$configPath`": top-level `"live-mode`" is missing. It must be the JSON boolean false.")
    }
    elseif (-not ($topLiveMode -is [bool]) -or $topLiveMode) {
        $problems.Add("Config `"$configPath`": top-level `"live-mode`" is $(Format-JsonValue $topLiveMode) (JSON $(Get-JsonKind $topLiveMode)) but must be the JSON boolean false. Live mode is outside the MarketLab boundary.")
    }

    Test-HandlerSet $configObject 'top-level ' $configPath $problems

    $environments = Get-JsonProperty $configObject 'environments'
    if (-not (Test-JsonPropertyExists $configObject 'environments') -or $null -eq $environments) {
        $problems.Add("Config `"$configPath`": `"environments`" is missing. It must be a JSON object defining exactly one environment, `"backtesting`", with `"live-mode`": false.")
    }
    elseif (-not ($environments -is [System.Management.Automation.PSCustomObject])) {
        $problems.Add("Config `"$configPath`": `"environments`" is a JSON $(Get-JsonKind $environments) but must be a JSON object defining exactly one environment, `"backtesting`".")
    }
    else {
        $envNames = @($environments.PSObject.Properties | ForEach-Object { $_.Name })
        $extra = @($envNames | Where-Object { $_ -cne 'backtesting' })
        if ($extra.Count -gt 0) {
            $problems.Add("Config `"$configPath`": `"environments`" defines [$($extra -join ', ')] in addition to or instead of `"backtesting`". Only `"backtesting`" may be defined; remove the other environment(s).")
        }
        if ($envNames -cnotcontains 'backtesting') {
            $problems.Add("Config `"$configPath`": `"environments.backtesting`" is missing.")
        }
        foreach ($name in $envNames) {
            $envObject = Get-JsonProperty $environments $name
            if (-not ($envObject -is [System.Management.Automation.PSCustomObject])) {
                $problems.Add("Config `"$configPath`": `"environments.$name`" is a JSON $(Get-JsonKind $envObject) but must be a JSON object.")
                continue
            }
            foreach ($nested in @('environment', 'environments')) {
                if (Test-JsonPropertyExists $envObject $nested) {
                    $problems.Add("Config `"$configPath`": `"environments.$name`" contains `"$nested`". LEAN nests environments through this key (Configuration/Config.cs GetToken), which would layer settings this script cannot see; the MarketLab path allows exactly one flat `"backtesting`" environment. Remove `"environments.$name.$nested`".")
                }
            }
            $envLiveMode = Get-JsonProperty $envObject 'live-mode'
            if (-not (Test-JsonPropertyExists $envObject 'live-mode')) {
                $problems.Add("Config `"$configPath`": `"environments.$name.live-mode`" is missing. It must be the JSON boolean false.")
            }
            elseif (-not ($envLiveMode -is [bool]) -or $envLiveMode) {
                $problems.Add("Config `"$configPath`": `"environments.$name.live-mode`" is $(Format-JsonValue $envLiveMode) (JSON $(Get-JsonKind $envLiveMode)) but must be the JSON boolean false.")
            }
            Test-HandlerSet $envObject "`"environments.$name`" " $configPath $problems
        }
    }
}

# Output root: an existing directory, or creatable under an existing ancestor.
if (Test-Path -LiteralPath $outputRootPath -PathType Leaf) {
    $problems.Add("Output root `"$outputRootPath`" is an existing file, not a directory. Pass -OutputRoot <directory> or remove the file.")
}
elseif (-not (Test-Path -LiteralPath $outputRootPath -PathType Container)) {
    $ancestor = $outputRootPath
    $ancestorOk = $false
    while ($true) {
        $parent = [System.IO.Path]::GetDirectoryName($ancestor)
        if ([string]::IsNullOrEmpty($parent)) { break }
        if (Test-Path -LiteralPath $parent -PathType Leaf) { break }
        if (Test-Path -LiteralPath $parent -PathType Container) { $ancestorOk = $true; break }
        $ancestor = $parent
    }
    if (-not $ancestorOk) {
        $problems.Add("Output root `"$outputRootPath`" cannot be created: no existing parent directory (missing drive, or a file in the path). Pass -OutputRoot <directory on an existing drive>.")
    }
}

# Baseline contract identity and runtime set for -RunEvidence: the pre-run
# evidence must be able to name the exact frozen contract (contract hash and
# register pin, verified equal) and the qualified runtime it is about to run.
$baselineContractPathResolved = $null
$baselineRegisterPathResolved = $null
$baselineContractSha256 = $null
$baselineRegisterPin = $null
$runtimeBinaryHashes = [ordered]@{}
$repositoryHead = $null
$repositoryDirty = $null
$baselineBuild = $null
$baselinePreflight = $null
if ($RunEvidence) {
    # Repository state: captured in pre-flight so a dirty working tree or a
    # missing Git HEAD stops the run before LEAN launches.
    try {
        $previousGitPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $gitHead = @(& git -C $leanRootPath rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $gitHead.Count -gt 0) { $repositoryHead = ([string]$gitHead[0]).Trim() }
            $gitStatus = @(& git -C $leanRootPath status --porcelain 2>$null)
            if ($LASTEXITCODE -eq 0) { $repositoryDirty = ($gitStatus.Count -gt 0) }
        }
        finally {
            $ErrorActionPreference = $previousGitPreference
        }
    }
    catch {
        $repositoryHead = $null
        $repositoryDirty = $null
    }
    if ([string]::IsNullOrWhiteSpace($repositoryHead)) {
        $problems.Add("Could not read the Git HEAD of `"$leanRootPath`" with git; -RunEvidence needs the reviewed commit identity. Install Git or launch from the checkout.")
    }
    elseif ($repositoryDirty -ne $false) {
        $problems.Add("The working tree at `"$leanRootPath`" is dirty; the authoritative baseline must run from the reviewed and merged freeze commit (commit or stash local changes, then rerun).")
    }
    foreach ($name in $script:RuntimeBinaryFileNames) {
        $runtimePath = Join-Path $launcherDir $name
        if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
            $problems.Add("Runtime binary `"$runtimePath`" is missing; -RunEvidence needs the qualified Release runtime set (build it with MarketLab\scripts\build.ps1).")
        }
        else {
            $runtimeBinaryHashes[$name] = Get-Sha256Hex $runtimePath
        }
    }
    if ([string]::IsNullOrWhiteSpace($BaselineContract) -and [string]::IsNullOrWhiteSpace($BaselineRegister)) {
        Write-WarningLine "-RunEvidence without -BaselineContract/-BaselineRegister: the evidence will not bind a baseline contract identity, so the baseline classifier will refuse the run."
    }
    elseif ([string]::IsNullOrWhiteSpace($BaselineContract) -or [string]::IsNullOrWhiteSpace($BaselineRegister)) {
        $problems.Add("-BaselineContract and -BaselineRegister must be passed together with -RunEvidence.")
    }
    else {
        try { $baselineContractPathResolved = ConvertTo-AbsolutePath $BaselineContract }
        catch { $problems.Add("-BaselineContract `"$BaselineContract`" is not a usable path: $($_.Exception.Message)") }
        try { $baselineRegisterPathResolved = ConvertTo-AbsolutePath $BaselineRegister }
        catch { $problems.Add("-BaselineRegister `"$BaselineRegister`" is not a usable path: $($_.Exception.Message)") }
        if ($null -ne $baselineContractPathResolved) {
            if (-not (Test-Path -LiteralPath $baselineContractPathResolved -PathType Leaf)) {
                $problems.Add("Baseline contract `"$baselineContractPathResolved`" does not exist.")
            }
            else {
                $baselineContractSha256 = Get-Sha256Hex $baselineContractPathResolved -LfNormalized
            }
        }
        if ($null -ne $baselineRegisterPathResolved) {
            if (-not (Test-Path -LiteralPath $baselineRegisterPathResolved -PathType Leaf)) {
                $problems.Add("Baseline register `"$baselineRegisterPathResolved`" does not exist.")
            }
            else {
                try {
                    $baselineRegisterObject = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($baselineRegisterPathResolved))
                    $baselineRegisterPin = [string](Get-JsonProperty $baselineRegisterObject 'frozenBaselineContractSha256')
                }
                catch {
                    $problems.Add("Baseline register `"$baselineRegisterPathResolved`" is unreadable: $($_.Exception.Message)")
                }
            }
        }
        if ($null -ne $baselineContractSha256 -and $null -ne $baselineRegisterPin -and $baselineContractSha256 -ne $baselineRegisterPin) {
            $problems.Add("Baseline contract hash $baselineContractSha256 does not match the register pin $baselineRegisterPin; refusing to launch the frozen baseline with an unpinned contract.")
        }
        if ($null -ne $baselineContractSha256) {
            try {
                $frozenBaseline = [IO.File]::ReadAllText($baselineContractPathResolved) | ConvertFrom-Json
                Assert-BaselineLaunch $frozenBaseline $leanRootPath $Configuration $configPath $AlgorithmTypeName `
                    $AlgorithmLanguage $algorithmLocationPath $dataFolderPath ($parameterPairs -join ',') `
                    ([bool]$AllowMissingData) ([bool]$AllowEngineErrors) $ExpectedTerminalException
                if (-not $BuildReceipt) { $BuildReceipt = Join-Path $leanRootPath 'MarketLab\output\baseline-build.json' }
                $BuildReceipt = [IO.Path]::GetFullPath($BuildReceipt)
                $baselineBuild = Assert-BaselineBuild $BuildReceipt $leanRootPath $ReviewedCommit $dotnet $baselineContractSha256
            } catch { $problems.Add($_.Exception.Message) }
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($BaselineContract) -or -not [string]::IsNullOrWhiteSpace($BaselineRegister)) {
    $problems.Add("-BaselineContract/-BaselineRegister are only meaningful with -RunEvidence; pass -RunEvidence or omit them.")
}

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-ErrorLine $problem }
    Write-ErrorLine "Pre-flight validation failed with $($problems.Count) problem(s); LEAN was not launched. Exit code $script:ExitPreflight."
    exit $script:ExitPreflight
}

# An authoritative launch always rechecks the qualified tree and the same build immediately
# before launch. -CheckOnly returns the receipt in memory, preserving DryRun's no-write contract.
if ($null -ne $baselineBuild) {
    $checkArguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-SingleAnchorBaselineFailedData.ps1'),
        '-Preflight', '-CheckOnly', '-Contract', $baselineContractPathResolved, '-Register', $baselineRegisterPathResolved,
        '-ReviewedCommit', $ReviewedCommit, '-BuildReceipt', $BuildReceipt, '-DotnetPath', $dotnet)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $checkOutput = @(& pwsh @checkArguments 2>&1)
        $checkExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($checkExit -ne 0) {
        Write-ErrorLine ("Mandatory baseline preflight failed; LEAN was not launched. " + ($checkOutput -join "`n"))
        exit $script:ExitPreflight
    }
    try { $baselinePreflight = ($checkOutput -join "`n") | ConvertFrom-Json }
    catch { Write-ErrorLine 'Mandatory preflight returned no valid receipt.'; exit $script:ExitPreflight }
    if ($baselinePreflight.qualification -ne 'PREFLIGHT-PASS' -or $baselinePreflight.authoritative -ne $true) {
        Write-ErrorLine 'Mandatory preflight did not authorize this baseline.'
        exit $script:ExitPreflight
    }
}

# ----------------------------------------------------------------------------
# Run directory and command line
# ----------------------------------------------------------------------------

$safeName = $AlgorithmTypeName
foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) {
    $safeName = $safeName.Replace([string]$bad, '_')
}
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$runDir = Join-Path $outputRootPath ($stamp + '-' + $safeName)
$suffix = 0
while (Test-Path -LiteralPath $runDir) {
    $suffix++
    $runDir = Join-Path $outputRootPath ($stamp + '-' + $safeName + '-' + $suffix)
}
$logPath = Join-Path $runDir 'log.txt'

# Exactly these options; all are declared in Configuration/LeanArgumentParser.cs.
# live-mode has no CLI option: it comes from the validated config file only.
$launcherArgs = @(
    $launcherDll,
    '--config', $configPath,
    '--environment', 'backtesting',
    '--data-folder', $dataFolderPath,
    '--results-destination-folder', $runDir,
    '--algorithm-type-name', $AlgorithmTypeName,
    '--algorithm-language', $AlgorithmLanguage,
    '--algorithm-location', $algorithmLocationPath,
    '--close-automatically', 'true'
)
if ($parameterPairs.Count -gt 0) {
    $launcherArgs += @('--parameters', ($parameterPairs -join ','))
}
if ($null -ne $baselineBuild) {
    $launcherArgs = @('exec', '--fx-version', $baselineBuild.runtime.version, '--roll-forward', 'Disable') + $launcherArgs
}
$commandLine = Format-CommandLine $dotnet $launcherArgs

Write-Info 'MarketLab LEAN local backtest'
Write-Info "  LEAN root:        $leanRootPath"
Write-Info "  configuration:    $Configuration"
Write-Info "  dotnet:           $dotnet"
Write-Info "  launcher:         $launcherDll"
Write-Info "  config file:      $configPath"
Write-Info "  algorithm:        $AlgorithmTypeName ($AlgorithmLanguage) from $algorithmLocationPath"
if ($parameterPairs.Count -gt 0) {
    Write-Info "  parameters:       $($parameterPairs -join ',')"
}
Write-Info "  data folder:      $dataFolderPath"
if ($AlgorithmLanguage -eq 'Python') {
    Write-Info "  PYTHONNET_PYDLL:  $pythonDllPath (from $pythonDllSource)"
    Write-Info "  PYTHONPATH:       $launcherDir"
    if ($null -ne $script:PythonProbe) {
        Write-Info "  python / pandas:  $($script:PythonProbe) ($pythonExe)"
    }
}
Write-Info "  run directory:    $runDir"
Write-Info "  log file:         $logPath"
Write-Info "  working dir:      $runDir"
Write-Info "  command line:     $commandLine"

if ($DryRun) {
    Write-Info 'Dry run: pre-flight passed; LEAN was not launched and no run directory was created. Exit code 0.'
    exit 0
}

# ----------------------------------------------------------------------------
# Launch
# ----------------------------------------------------------------------------

try {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
}
catch {
    Write-ErrorLine "Could not create run directory `"$runDir`": $($_.Exception.Message)"
    exit $script:ExitPreflight
}

if ($RunEvidence) {
    # Persistent pre-run invocation evidence: what this run actually resolved
    # to, written before LEAN is launched so a later audit never has to
    # reconstruct the invocation from the machine state.
    $invocationEvidencePath = Join-Path $runDir 'marketlab-run-invocation.json'
    try {
        $evidenceParameters = @($parameterPairs)
        if ($null -ne $baselineBuild) {
            [IO.File]::WriteAllText((Join-Path $runDir 'baseline-build.json'), [IO.File]::ReadAllText($BuildReceipt), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $runDir 'baseline-preflight.json'), ($baselinePreflight | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        }
        $invocationEvidence = [ordered]@{
            contract = 'marketlab-run-invocation-evidence-v1'
            generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            leanRoot = $leanRootPath
            configuration = $Configuration
            dotnet = $dotnet
            launcher = $launcherDll
            launcherSha256 = Get-Sha256Hex $launcherDll
            configPath = $configPath
            configSha256LfNormalized = Get-Sha256Hex $configPath -LfNormalized
            algorithmTypeName = $AlgorithmTypeName
            algorithmLanguage = $AlgorithmLanguage
            algorithmLocation = $algorithmLocationPath
            algorithmSha256 = Get-Sha256Hex $algorithmLocationPath
            dataFolder = $dataFolderPath
            parameters = $evidenceParameters
            parametersString = ($evidenceParameters -join ',')
            closeAutomatically = $true
            allowMissingData = [bool]$AllowMissingData
            allowEngineErrors = [bool]$AllowEngineErrors
            commandLine = @($launcherArgs)
            workingDirectory = $runDir
            runDirectory = $runDir
            baselineContractPath = $baselineContractPathResolved
            baselineContractSha256 = $baselineContractSha256
            baselineRegisterPath = $baselineRegisterPathResolved
            baselineRegisterPin = $baselineRegisterPin
            repositoryHead = $repositoryHead
            repositoryDirty = $repositoryDirty
            runtimeBinariesRoot = $launcherDir
            runtimeBinaries = $runtimeBinaryHashes
            expectedTerminalException = $ExpectedTerminalException
            reviewedCommit = $ReviewedCommit
            buildReceiptSha256 = if ($baselineBuild) { Get-Sha256Hex (Join-Path $runDir 'baseline-build.json') } else { $null }
            preflightSha256 = if ($baselinePreflight) { Get-Sha256Hex (Join-Path $runDir 'baseline-preflight.json') } else { $null }
        }
        [System.IO.File]::WriteAllText($invocationEvidencePath, ($invocationEvidence | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "  run evidence:     $invocationEvidencePath"
    }
    catch {
        Write-ErrorLine "Could not write the run invocation evidence to `"$invocationEvidencePath`": $($_.Exception.Message)"
        exit $script:ExitPreflight
    }
}

$leanExitCode = $null
$startedUtc = [DateTime]::UtcNow
Write-Info "Launching LEAN at $($startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')) ..."
# LEAN writes its ERROR:: lines to stderr. Under Windows PowerShell 5.1, when a
# caller redirects this script's stderr inside PowerShell (`& run-backtest.ps1
# ... 2>&1`), each such line becomes a NativeCommandError record, and with
# $ErrorActionPreference = 'Stop' the first one would terminate the script
# mid-run. Native output is never an error for this script, so the preference
# is relaxed for the duration of the launcher call only.
$previousErrorActionPreference = $ErrorActionPreference
# Python runs: hand Python.NET its DLL and put the launcher build directory on
# the embedded interpreter's path (AlgorithmImports.py lives there; the working
# directory is the run directory, not Launcher\bin\<Configuration>). Both
# variables are set for this process only and restored afterwards; the caller's
# environment is not changed.
$previousPythonDll = $env:PYTHONNET_PYDLL
$previousPythonPath = $env:PYTHONPATH
if ($AlgorithmLanguage -eq 'Python') {
    if (-not [string]::IsNullOrEmpty($previousPythonPath) -and $previousPythonPath -ne $launcherDir) {
        Write-WarningLine "Inherited PYTHONPATH `"$previousPythonPath`" is replaced by `"$launcherDir`" for the launcher process. Use the config key python-additional-paths for extra import paths."
    }
    $env:PYTHONNET_PYDLL = $pythonDllPath
    $env:PYTHONPATH = $launcherDir
}
Push-Location -LiteralPath $runDir
try {
    $ErrorActionPreference = 'Continue'
    & $dotnet @launcherArgs
    $leanExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    $env:PYTHONNET_PYDLL = $previousPythonDll
    $env:PYTHONPATH = $previousPythonPath
    Pop-Location
}
$elapsed = [DateTime]::UtcNow - $startedUtc
Write-Info ("LEAN exited with code {0} after {1:N1} s." -f $leanExitCode, $elapsed.TotalSeconds)

# ----------------------------------------------------------------------------
# Post-run data check (the engine's own DataMonitor report)
# ----------------------------------------------------------------------------

$exitCode = $leanExitCode
$failed = $null
$total = $null
$report = Get-ChildItem -LiteralPath $runDir -Filter 'data-monitor-report-*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object -Property Name -Descending | Select-Object -First 1

if ($null -eq $report) {
    Write-WarningLine "No data-monitor-report-*.json was written to `"$runDir`"; the data-request check could not be performed. Propagating LEAN's exit code $leanExitCode."
}
else {
    $reportObject = $null
    try {
        $reportObject = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($report.FullName))
    }
    catch {
        Write-WarningLine "Could not parse `"$($report.FullName)`": $($_.Exception.Message). Propagating LEAN's exit code $leanExitCode."
    }
    if ($null -ne $reportObject) {
        $total = Get-JsonProperty $reportObject 'total-data-requests-count'
        $succeeded = Get-JsonProperty $reportObject 'succeeded-data-requests-count'
        # failed-data-requests-count already includes universe (coarse/universe
        # file) failures: Common/Data/DataMonitor.cs OnNewDataRequest increments
        # it for every failed request and increments the universe counter in
        # addition, so this one number covers all failed local data requests.
        $failed = Get-JsonProperty $reportObject 'failed-data-requests-count'
        Write-Info "Data requests (from $($report.Name)): total $total, succeeded $succeeded, failed $failed."
        if ($null -ne $failed -and [int]$failed -gt 0) {
            $failedList = Get-ChildItem -LiteralPath $runDir -Filter 'failed-data-requests-*.txt' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name -Descending | Select-Object -First 1
            $failedListPath = '(no failed-data-requests-*.txt found)'
            if ($null -ne $failedList) { $failedListPath = $failedList.FullName }
            $lines = @(
                "$failed local data request(s) FAILED: the engine looked for data files under `"$dataFolderPath`" that do not exist, so the algorithm ran without that data.",
                "List of missing files: $failedListPath",
                "Fix: put the required LEAN-format data under the data folder (or pass -DataFolder <root that has it>); rerun with -AllowMissingData only if the gap is intentional."
            )
            if ($null -ne $failedList) {
                $preview = @(Get-Content -LiteralPath $failedList.FullName -TotalCount 10)
                foreach ($p in $preview) { $lines += "  missing: $p" }
                if ([int]$failed -gt $preview.Count) { $lines += "  ... ($([int]$failed - $preview.Count) more in the list file)" }
            }
            if ($AllowMissingData) {
                foreach ($l in $lines) { Write-WarningLine $l }
                Write-WarningLine "-AllowMissingData was given; keeping LEAN's exit code $leanExitCode."
            }
            else {
                foreach ($l in $lines) { Write-ErrorLine $l }
                if ($leanExitCode -eq 0) {
                    $exitCode = $script:ExitMissingData
                }
                else {
                    Write-ErrorLine "LEAN's own exit code $leanExitCode is propagated unchanged."
                }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Post-run engine-error check (ERROR:: lines in the engine log)
# ----------------------------------------------------------------------------
# LEAN exits 0 whenever the algorithm reaches Completed, even when the engine
# logged errors along the way and carried on: a corrupt data file is skipped
# (Engine/DataFeeds/ZipDataCacheProvider.cs logs "Corrupt zip file/entry" and
# fill-forward covers the gap; the data monitor still counts the request as
# succeeded), an existing file that yields no data is reported only as
# "InvalidSource(): File not found" (Engine/DataFeeds/SubscriptionDataSourceReader.cs;
# the data monitor counted the request as succeeded because the file opened),
# and a statistics failure leaves the statistics block empty
# (Engine/Results/BaseResultsHandler.cs GenerateStatisticsResults). All were
# observed in Batch C with helper exit code 0. Every qualified clean run has
# zero ERROR:: lines. Two kinds of ERROR:: line are NOT engine errors and are
# not counted:
#  - lines whose message starts with the algorithm time ("2013-10-07 09:31:00 ..."):
#    LEAN routes the algorithm's own Error() output and handled simulation
#    errors such as rejected orders through Log.Error with that prefix
#    (Messaging/Messaging.cs HandledError; BaseResultsHandler.cs
#    PrefixWithAlgorithmTime). They are the algorithm's messages and appear in
#    its result packet; a completed backtest with them is still a clean run;
#  - "InvalidSource(): File not found" lines whose path is in the run's
#    failed-data-requests list: those files do not exist and the data-monitor
#    check above already owns them (exit 3 / -AllowMissingData). The same line
#    for a file that is NOT in that list means the file exists but produced no
#    data (empty entry, unreadable content) and is counted.
$engineErrorCheckPerformed = $false
$engineErrorCountForEvidence = $null
$terminalExceptionLineCount = 0
$engineErrorMessages = @()
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $missingFiles = @()
    $missingList = Get-ChildItem -LiteralPath $runDir -Filter 'failed-data-requests-*.txt' -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending | Select-Object -First 1
    if ($null -ne $missingList) {
        try { $missingFiles = @(Get-Content -LiteralPath $missingList.FullName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().Replace('/', '\') }) }
        catch { $missingFiles = @() }
    }
    $missingMarker = 'SubscriptionDataSourceReader.InvalidSource(): File not found: '
    $engineErrors = New-Object 'System.Collections.Generic.List[string]'
    $terminalExceptionLines = New-Object 'System.Collections.Generic.List[string]'
    $engineErrorCheckPerformed = $true
    try {
        # The audit always runs when the log exists, including for non-zero
        # exits, so a modeled AccountStopOut run still proves there were no
        # unrelated engine errors. The only additionally excluded lines are
        # those containing the declared expected terminal exception.
        foreach ($line in [System.IO.File]::ReadLines($logPath)) {
            $index = $line.IndexOf(' ERROR:: ', [System.StringComparison]::Ordinal)
            if ($index -lt 0) { continue }
            $message = $line.Substring($index + 9)
            if ($message -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} ') { continue }
            $isKnownMissing = $false
            $markerIndex = $message.IndexOf($missingMarker, [System.StringComparison]::Ordinal)
            if ($markerIndex -ge 0) {
                $path = $message.Substring($markerIndex + $missingMarker.Length).Trim().Replace('/', '\')
                foreach ($missing in $missingFiles) {
                    if ($path.EndsWith($missing, [System.StringComparison]::OrdinalIgnoreCase)) { $isKnownMissing = $true; break }
                }
            }
            if ($isKnownMissing) { continue }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedTerminalException) -and $message.Contains($ExpectedTerminalException)) {
                $terminalExceptionLines.Add($line)
                continue
            }
            $engineErrors.Add($line)
        }
    }
    catch {
        $engineErrorCheckPerformed = $false
        Write-WarningLine "Could not read `"$logPath`" for the engine-error check: $($_.Exception.Message)."
    }
    $engineErrorCountForEvidence = if ($engineErrorCheckPerformed) { $engineErrors.Count } else { $null }
    $terminalExceptionLineCount = $terminalExceptionLines.Count
    $engineErrorMessages = @($engineErrors | Select-Object -First 5)
    if ($leanExitCode -eq 0 -and $engineErrors.Count -gt 0) {
        $lines = @(
            "$($engineErrors.Count) engine ERROR:: line(s) in `"$logPath`" although LEAN exited 0: the algorithm completed, but the engine reported errors on the way (for example a corrupt or empty data file it skipped, or a failure while generating the statistics), so the results are not a clean backtest.",
            "Fix: read the ERROR:: lines in the log and correct the cause; rerun with -AllowEngineErrors only if the errors are understood and acceptable."
        )
        $shown = 0
        foreach ($e in $engineErrors) {
            if ($shown -ge 5) { $lines += "  ... ($($engineErrors.Count - $shown) more in the log)"; break }
            $text = $e
            if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + ' ...' }
            $lines += "  $text"
            $shown++
        }
        if ($AllowEngineErrors) {
            foreach ($l in $lines) { Write-WarningLine $l }
            Write-WarningLine "-AllowEngineErrors was given; not changing the exit code."
        }
        else {
            foreach ($l in $lines) { Write-ErrorLine $l }
            if ($exitCode -eq 0) {
                $exitCode = $script:ExitEngineErrors
            }
        }
    }
}

if ($RunEvidence) {
    # Post-run outcome evidence: the helper's own verdict on the run (exit
    # codes, engine-error check, data-monitor result) plus a re-hash of the
    # runtime set so a binary changed mid-run is visible. Bound to the exact
    # pre-run evidence file by its SHA-256.
    $outcomePath = Join-Path $runDir 'marketlab-run-outcome.json'
    try {
        $runtimeBinariesAfter = [ordered]@{}
        foreach ($name in $script:RuntimeBinaryFileNames) {
            $runtimePath = Join-Path $launcherDir $name
            if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
                $runtimeBinariesAfter[$name] = Get-Sha256Hex $runtimePath
            }
        }
        $runtimeBinariesUnchanged = $true
        foreach ($name in $script:RuntimeBinaryFileNames) {
            if (-not $runtimeBinariesAfter.Contains($name) -or [string]$runtimeBinariesAfter[$name] -ne [string]$runtimeBinaryHashes[$name]) {
                $runtimeBinariesUnchanged = $false
            }
        }
        $baselineArtifactsAfter = $null
        if ($null -ne $baselineBuild) {
            $baselineArtifactsAfter = Get-BaselineArtifacts $leanRootPath $dotnet $baselineBuild.runtime
            try { Assert-BaselineArtifactEquality $baselineBuild.artifacts $baselineArtifactsAfter }
            catch { $runtimeBinariesUnchanged = $false }
        }
        $outcome = [ordered]@{
            contract = 'marketlab-run-outcome-evidence-v1'
            generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            invocationEvidence = 'marketlab-run-invocation.json'
            invocationEvidenceSha256 = Get-Sha256Hex $invocationEvidencePath
            leanExitCode = $leanExitCode
            helperExitCode = $exitCode
            leanElapsedSeconds = [math]::Round($elapsed.TotalSeconds, 1)
            engineErrorCheckPerformed = $engineErrorCheckPerformed
            engineErrorCount = $engineErrorCountForEvidence
            expectedTerminalException = $ExpectedTerminalException
            terminalExceptionLineCount = $terminalExceptionLineCount
            engineErrorMessages = $engineErrorMessages
            dataMonitorReport = if ($null -ne $report) { $report.Name } else { $null }
            failedDataRequestCount = $failed
            totalDataRequestCount = $total
            runtimeBinariesAfter = $runtimeBinariesAfter
            runtimeBinariesUnchanged = $runtimeBinariesUnchanged
            baselineArtifactsAfter = $baselineArtifactsAfter
            strategyResultsSha256 = if (Test-Path -LiteralPath (Join-Path $runDir 'storage\single-anchor\results.json') -PathType Leaf) {
                Get-Sha256Hex (Join-Path $runDir 'storage\single-anchor\results.json')
            } else { $null }
        }
        [System.IO.File]::WriteAllText($outcomePath, ($outcome | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "  run outcome:      $outcomePath"
    }
    catch {
        Write-ErrorLine "Could not write the run outcome evidence to `"$outcomePath`": $($_.Exception.Message)"
        if ($exitCode -eq 0) { $exitCode = $script:ExitPreflight }
    }
}

Write-Info "run-backtest: exit code $exitCode; run directory: $runDir; log: $logPath"
exit $exitCode
