<#
.SYNOPSIS
Runs one local LEAN backtest through the MarketLab backtesting-only path.

.DESCRIPTION
Validates the local build output, the MarketLab configuration, the algorithm
and the local data folder, then invokes the LEAN Launcher DIRECTLY
(`dotnet QuantConnect.Lean.Launcher.dll ...`) with the backtesting environment
and absolute local paths, with the process working directory set to a fresh
per-run output directory under -OutputRoot. After the run it reads the engine's
own data-monitor report and fails if any local data request failed.

Pre-flight rejects (exit code 2, nothing launched) a config that is not
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

The script never calls the LEAN CLI (`lean`), Docker, pip, QuantConnect Cloud or
any broker, needs no QuantConnect account, login, API token or organization,
and reads no credential from the environment: the only environment variables
it reads are PATH, DOTNET_ROOT and ProgramFiles (to find dotnet). LEAN's
configuration layer itself does not read environment variables (no
GetEnvironmentVariable in Configuration/).

Exit codes (observable via $LASTEXITCODE when invoked with `-File`):
  0  backtest completed, every local data request succeeded
  1  LEAN reported that the algorithm did not complete (Launcher/Program.cs),
     or PowerShell rejected a parameter value before the script ran
  2  pre-flight validation failed; nothing was launched
  3  LEAN exited 0 but its data-monitor report counts failed data requests
     (suppressed to a warning by -AllowMissingData)
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
CSharp (default) or Python. Python is passed through but is NOT qualified by
MarketLab (Batch A observation 7); it needs a Python 3.11 runtime that this
script does not set up.

.PARAMETER AlgorithmLocation
Assembly (.dll) or Python file containing the algorithm (`--algorithm-location`).
Default: <LeanRoot>\Launcher\bin\<Configuration>\QuantConnect.Algorithm.CSharp.dll.
Required when -AlgorithmLanguage is Python.

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

.PARAMETER DryRun
Validate everything, print the resolved paths and the exact command line, create
nothing and exit 0.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1
Runs the representative Batch A backtest (BasicTemplateFrameworkAlgorithm) on
the shipped sample data.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -AlgorithmTypeName BasicTemplateAlgorithm
Runs another algorithm compiled into QuantConnect.Algorithm.CSharp.dll.

.EXAMPLE
pwsh -File MarketLab\scripts\run-backtest.ps1 -DryRun
Shows what would be run without launching anything.

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
    [string]$DataFolder,
    [string]$OutputRoot,
    [switch]$AllowMissingData,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# The launcher's exit code is read from $LASTEXITCODE and propagated by this
# script; never let PowerShell 7.4+ turn a non-zero native exit into an exception.
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

$script:ExitPreflight = 2
$script:ExitMissingData = 3

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
    Write-ErrorLine "Pre-flight validation failed with $($problems.Count) problem(s); nothing was launched. Exit code $script:ExitPreflight."
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
    $problems.Add("-AlgorithmLanguage Python requires -AlgorithmLocation <algorithm .py file>. (Python algorithms are not qualified by MarketLab; see MarketLab\README.md.)")
}
if (-not (Test-Path -LiteralPath $algorithmLocationPath -PathType Leaf)) {
    $problems.Add("Algorithm location `"$algorithmLocationPath`" does not exist. Build first, or pass -AlgorithmLocation <assembly or .py file>.")
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

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-ErrorLine $problem }
    Write-ErrorLine "Pre-flight validation failed with $($problems.Count) problem(s); nothing was launched. Exit code $script:ExitPreflight."
    exit $script:ExitPreflight
}

if ($AlgorithmLanguage -eq 'Python') {
    Write-WarningLine 'Python algorithms are passed through to LEAN but are NOT qualified by MarketLab (no Python runtime is configured by this script).'
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
$commandLine = Format-CommandLine $dotnet $launcherArgs

Write-Info 'MarketLab LEAN local backtest'
Write-Info "  LEAN root:        $leanRootPath"
Write-Info "  configuration:    $Configuration"
Write-Info "  dotnet:           $dotnet"
Write-Info "  launcher:         $launcherDll"
Write-Info "  config file:      $configPath"
Write-Info "  algorithm:        $AlgorithmTypeName ($AlgorithmLanguage) from $algorithmLocationPath"
Write-Info "  data folder:      $dataFolderPath"
Write-Info "  run directory:    $runDir"
Write-Info "  log file:         $logPath"
Write-Info "  working dir:      $runDir"
Write-Info "  command line:     $commandLine"

if ($DryRun) {
    Write-Info 'Dry run: pre-flight passed; nothing was created or launched. Exit code 0.'
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
Push-Location -LiteralPath $runDir
try {
    $ErrorActionPreference = 'Continue'
    & $dotnet @launcherArgs
    $leanExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}
$elapsed = [DateTime]::UtcNow - $startedUtc
Write-Info ("LEAN exited with code {0} after {1:N1} s." -f $leanExitCode, $elapsed.TotalSeconds)

# ----------------------------------------------------------------------------
# Post-run data check (the engine's own DataMonitor report)
# ----------------------------------------------------------------------------

$exitCode = $leanExitCode
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

Write-Info "run-backtest: exit code $exitCode; run directory: $runDir; log: $logPath"
exit $exitCode
