<#
.SYNOPSIS
Self-contained checks for the MarketLab LEAN local-backtesting path.

.DESCRIPTION
Asserts the backtesting-only invariants of MarketLab\config\backtesting.json,
the -DryRun behaviour of MarketLab\scripts\run-backtest.ps1, and that the helper
exits 2 with an ERROR: line for each pre-flight failure it guards against
(missing build/config/data/output, live-mode, foreign or nested environments,
live handler names, ApiDataProvider, wrong JSON types, and the Python runtime
requirements: -AlgorithmLocation, -Configuration Debug, an existing
-PythonDll / PYTHONNET_PYDLL).
Every helper invocation is a child process of the same PowerShell executable
that runs this script, so exit codes are the real process exit codes.

No Pester, no module, no network, no LEAN CLI. Without -IncludeSmoke nothing is
launched and the run finishes in a few seconds. With -IncludeSmoke real
backtests are run into a temporary output root that is deleted afterwards: the
Batch A representative C# algorithm on the shipped sample data, the same
algorithm on a temporary copy of that data with one corrupted zip file (helper
exit code 4, and 0 with -AllowEngineErrors), and, when -PythonDll is given and
the Debug build exists, the Python representative algorithm
(Algorithm.Python\BasicTemplateAlgorithm.py). All fixtures live under
%TEMP%\marketlab-tests-<guid>, which is removed when the script ends.

Prints PASS:/FAIL: per assertion and a final count. Exit code 0 when every
assertion passed, 1 otherwise. Checks that need an absent Debug build or an
absent -PythonDll print SKIP: and count as neither.

.PARAMETER LeanRoot
Root of the LEAN checkout. Default: two levels above this script.

.PARAMETER IncludeSmoke
Also run real backtests through the helper (needs the Release build output;
the Python smoke additionally needs the Debug build and -PythonDll).

.PARAMETER PythonDll
python311.dll of the qualified Python runtime (see MarketLab\README.md section
9). Enables the Python dry-run check and, with -IncludeSmoke, the Python smoke
backtest.

.EXAMPLE
pwsh -File MarketLab\tests\Test-MarketLabBacktesting.ps1

.EXAMPLE
powershell -File MarketLab\tests\Test-MarketLabBacktesting.ps1 -IncludeSmoke

.EXAMPLE
pwsh -File MarketLab\tests\Test-MarketLabBacktesting.ps1 -IncludeSmoke -PythonDll C:\Python311\python311.dll
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [switch]$IncludeSmoke,
    [string]$PythonDll
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:Passed = 0
$script:Failed = 0

# ----------------------------------------------------------------------------
# Assertion helpers
# ----------------------------------------------------------------------------

function Report([bool]$Ok, [string]$Name, [string]$Detail) {
    if ($Ok) {
        $script:Passed++
        Write-Host "PASS: $Name"
    }
    else {
        $script:Failed++
        Write-Host "FAIL: $Name -- $Detail"
    }
}

function Assert-True([bool]$Condition, [string]$Name, [string]$Detail = 'condition was false') {
    Report $Condition $Name $Detail
}

function Assert-Equal($Expected, $Actual, [string]$Name) {
    $ok = ($null -ne $Actual) -and ($Actual -eq $Expected) -and ($Expected -eq $Actual)
    if ($null -eq $Expected) { $ok = ($null -eq $Actual) }
    Report $ok $Name "expected [$Expected] but got [$Actual]"
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Name, [switch]$CaseSensitive) {
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($CaseSensitive) { $comparison = [System.StringComparison]::Ordinal }
    $ok = ($null -ne $Text) -and ($Text.IndexOf($Needle, $comparison) -ge 0)
    Report $ok $Name "text does not contain [$Needle]"
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$Name, [switch]$CaseSensitive) {
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if ($CaseSensitive) { $comparison = [System.StringComparison]::Ordinal }
    $ok = ($null -eq $Text) -or ($Text.IndexOf($Needle, $comparison) -lt 0)
    Report $ok $Name "text unexpectedly contains [$Needle]"
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Name) {
    $ok = ($null -ne $Text) -and ([System.Text.RegularExpressions.Regex]::IsMatch($Text, $Pattern))
    Report $ok $Name "text does not match /$Pattern/"
}

function Assert-NotMatch([string]$Text, [string]$Pattern, [string]$Name) {
    $ok = ($null -eq $Text) -or (-not [System.Text.RegularExpressions.Regex]::IsMatch($Text, $Pattern))
    Report $ok $Name "text unexpectedly matches /$Pattern/"
}

function Skip([string]$Name, [string]$Reason) {
    Write-Host "SKIP: $Name -- $Reason"
}

# ----------------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------------

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
            if ($c -eq [char]'"') { $inString = $false }
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

# The unary comma keeps a JSON array intact instead of unrolling a
# one-element array into its element.
function Get-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return , $prop.Value
}

# Returns every property name at every nesting level of a parsed JSON object.
function Get-AllPropertyNames($Object) {
    $names = @()
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { return $names }
    foreach ($prop in $Object.PSObject.Properties) {
        $names += $prop.Name
        if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $names += Get-AllPropertyNames $prop.Value
        }
    }
    return $names
}

function Format-ProcessArgument([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

# Runs run-backtest.ps1 as a child process of the current PowerShell executable
# and returns exit code, stdout and stderr. stdin is closed immediately so no
# keypress wait can ever block the tests.
function Invoke-Helper([string[]]$Arguments, [hashtable]$Environment = @{}) {
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:HelperPath) + $Arguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ShellExe
    $psi.Arguments = (($argList | ForEach-Object { Format-ProcessArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $script:TempRoot
    foreach ($key in $Environment.Keys) {
        $psi.Environment[$key] = [string]$Environment[$key]
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    return New-Object PSObject -Property @{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        All      = ($stdout + "`n" + $stderr)
    }
}

function Assert-PreflightFailure([string]$Name, [string[]]$Arguments, [string]$ErrorPattern) {
    $r = Invoke-Helper $Arguments
    Assert-Equal 2 $r.ExitCode "$Name -> exit code 2"
    Assert-Match $r.StdErr ('(?m)^ERROR: .*' + $ErrorPattern) "$Name -> ERROR line matches /$ErrorPattern/"
    Assert-NotContains $r.All 'Launching LEAN' "$Name -> nothing launched"
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ([string]::IsNullOrEmpty($LeanRoot)) {
    $LeanRoot = Join-Path $PSScriptRoot '..\..'
}
$script:LeanRootPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $LeanRoot)).TrimEnd([char]'\', [char]'/')
$script:HelperPath = Join-Path $script:LeanRootPath 'MarketLab\scripts\run-backtest.ps1'
$script:ConfigPath = Join-Path $script:LeanRootPath 'MarketLab\config\backtesting.json'
$script:DataPath = Join-Path $script:LeanRootPath 'Data'
$script:PythonAlgorithm = Join-Path $script:LeanRootPath 'Algorithm.Python\BasicTemplateAlgorithm.py'
$script:DebugLauncher = Join-Path $script:LeanRootPath 'Launcher\bin\Debug\QuantConnect.Lean.Launcher.dll'
$script:HasDebugBuild = Test-Path -LiteralPath $script:DebugLauncher -PathType Leaf
$script:HasPythonDll = (-not [string]::IsNullOrEmpty($PythonDll)) -and (Test-Path -LiteralPath $PythonDll -PathType Leaf)
$script:ShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('marketlab-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

# The helper falls back to an inherited PYTHONNET_PYDLL; the "no DLL" check
# below must not depend on the caller's environment. Cleared for this test
# process (and its child helper processes) only.
Remove-Item -Path Env:PYTHONNET_PYDLL -ErrorAction SilentlyContinue
Remove-Item -Path Env:PYTHONPATH -ErrorAction SilentlyContinue

Write-Host "Test-MarketLabBacktesting"
Write-Host "  shell:      $script:ShellExe ($($PSVersionTable.PSVersion))"
Write-Host "  LEAN root:  $script:LeanRootPath"
Write-Host "  helper:     $script:HelperPath"
Write-Host "  temp root:  $script:TempRoot"
Write-Host "  smoke:      $IncludeSmoke"
Write-Host "  Debug build: $script:HasDebugBuild"
Write-Host "  Python DLL: $(if ($script:HasPythonDll) { $PythonDll } else { '(none)' })"

try {
    Assert-True (Test-Path -LiteralPath $script:HelperPath -PathType Leaf) 'helper script exists'
    Assert-True (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) 'config file exists'

    # ------------------------------------------------------------------------
    # Configuration invariants
    # ------------------------------------------------------------------------
    $rawConfig = ''
    if (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf) {
        $rawConfig = [System.IO.File]::ReadAllText($script:ConfigPath)
    }
    $config = $null
    try {
        if ([string]::IsNullOrWhiteSpace($rawConfig)) { throw 'config file is missing or empty' }
        $config = ConvertFrom-Json -InputObject (Remove-JsonComments $rawConfig)
        Assert-True $true 'config parses as JSON after comment stripping'
    }
    catch {
        Assert-True $false 'config parses as JSON after comment stripping' $_.Exception.Message
    }

    if ($null -ne $config) {
        $environment = Get-JsonProperty $config 'environment'
        Assert-True (($environment -is [string]) -and ($environment -ceq 'backtesting')) 'config: environment is exactly "backtesting"' "got [$environment]"

        $liveMode = Get-JsonProperty $config 'live-mode'
        Assert-True (($liveMode -is [bool]) -and (-not $liveMode)) 'config: top-level live-mode is boolean false' "got [$liveMode]"

        $closeAuto = Get-JsonProperty $config 'close-automatically'
        Assert-True (($closeAuto -is [bool]) -and $closeAuto) 'config: close-automatically is boolean true' "got [$closeAuto]"

        $environments = Get-JsonProperty $config 'environments'
        $envNames = @()
        if ($null -ne $environments) { $envNames = @($environments.PSObject.Properties | ForEach-Object { $_.Name }) }
        Assert-True (($envNames.Count -eq 1) -and ($envNames[0] -ceq 'backtesting')) 'config: environments defines only "backtesting"' "got [$($envNames -join ', ')]"

        $backtesting = Get-JsonProperty $environments 'backtesting'
        $envLiveMode = Get-JsonProperty $backtesting 'live-mode'
        Assert-True (($envLiveMode -is [bool]) -and (-not $envLiveMode)) 'config: environments.backtesting.live-mode is boolean false' "got [$envLiveMode]"

        $setupHandler = [string](Get-JsonProperty $backtesting 'setup-handler')
        Assert-True $setupHandler.EndsWith('BacktestingSetupHandler') 'config: backtesting setup-handler is BacktestingSetupHandler' "got [$setupHandler]"
        $dataFeed = [string](Get-JsonProperty $backtesting 'data-feed-handler')
        Assert-True $dataFeed.EndsWith('FileSystemDataFeed') 'config: backtesting data-feed-handler is FileSystemDataFeed' "got [$dataFeed]"

        $allNames = @(Get-AllPropertyNames $config)
        $credentialShaped = @($allNames | Where-Object { $_ -match 'api-key|secret|password' })
        Assert-True ($credentialShaped.Count -eq 0) 'config: no key matching api-key|secret|password at any level' "found [$($credentialShaped -join ', ')]"

        Assert-Equal '' ([string](Get-JsonProperty $config 'api-access-token')) 'config: api-access-token is empty'
        Assert-Equal '' ([string](Get-JsonProperty $config 'job-organization-id')) 'config: job-organization-id is empty'
        Assert-Equal '0' ([string](Get-JsonProperty $config 'job-user-id')) 'config: job-user-id is "0"'
    }

    Assert-NotMatch $rawConfig '"live-mode"\s*:\s*true' 'config text: no live-mode true anywhere'
    foreach ($forbidden in @('PaperBrokerage', 'LiveTrading', 'BrokerageSetupHandler', 'live-data-url', '"ib-', 'api-key')) {
        Assert-NotContains $rawConfig $forbidden "config text: does not contain [$forbidden]"
    }

    # ------------------------------------------------------------------------
    # Helper -DryRun with defaults
    # ------------------------------------------------------------------------
    $dry = Invoke-Helper @('-DryRun')
    Assert-Equal 0 $dry.ExitCode 'dry run: exit code 0'
    Assert-Contains $dry.StdOut 'QuantConnect.Lean.Launcher.dll' 'dry run: command line names QuantConnect.Lean.Launcher.dll'
    Assert-Contains $dry.StdOut '--environment backtesting' 'dry run: command line has --environment backtesting'
    Assert-Contains $dry.StdOut '--close-automatically true' 'dry run: command line has --close-automatically true'
    Assert-Contains $dry.StdOut ('--config ' + $script:ConfigPath) 'dry run: command line has --config <MarketLab config>'
    Assert-Contains $dry.StdOut ('--data-folder ' + $script:DataPath) 'dry run: command line has --data-folder <LeanRoot>\Data'
    Assert-Contains $dry.StdOut '--results-destination-folder ' 'dry run: command line has --results-destination-folder'
    Assert-NotContains $dry.All ' lean ' 'dry run: no " lean " (LEAN CLI) in output' -CaseSensitive
    Assert-NotContains $dry.All 'docker' 'dry run: no "docker" in output'
    Assert-NotContains $dry.All 'login' 'dry run: no "login" in output'
    Assert-NotContains $dry.All 'live-paper' 'dry run: no "live-paper" in output'
    Assert-NotContains $dry.All 'pip install' 'dry run: no "pip install" in output'
    Assert-NotContains $dry.All 'Launching LEAN' 'dry run: nothing launched'
    Assert-NotContains $dry.StdOut '--live-mode' 'dry run: live-mode is not passed on the command line'
    Assert-Match $dry.StdOut "(?m)^  command line:     & '" 'dry run: command line is a pasteable PowerShell call'

    # ------------------------------------------------------------------------
    # Pre-flight failures (exit 2, ERROR: line naming the problem)
    # ------------------------------------------------------------------------
    $fakeRoot = Join-Path $script:TempRoot 'fake-lean-root'
    New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
    Assert-PreflightFailure 'missing build output (fake -LeanRoot)' @('-LeanRoot', $fakeRoot, '-Config', $script:ConfigPath, '-DataFolder', $script:DataPath, '-DryRun') 'QuantConnect\.Lean\.Launcher\.dll'

    $missingConfig = Join-Path $script:TempRoot 'does-not-exist.json'
    Assert-PreflightFailure 'nonexistent -Config' @('-Config', $missingConfig, '-DryRun') ([regex]::Escape($missingConfig))

    $badJson = Join-Path $script:TempRoot 'bad.json'
    [System.IO.File]::WriteAllText($badJson, '{ "environment": "backtesting", ')
    Assert-PreflightFailure 'config that is not valid JSON' @('-Config', $badJson, '-DryRun') 'not valid JSON'

    $liveTrue = Join-Path $script:TempRoot 'live-mode-true.json'
    $liveTrueText = $rawConfig -replace '"live-mode": false', '"live-mode": true'
    Assert-True ($liveTrueText -ne $rawConfig) 'fixture: live-mode true copy differs from the original'
    [System.IO.File]::WriteAllText($liveTrue, $liveTrueText)
    Assert-PreflightFailure 'config copy with live-mode true' @('-Config', $liveTrue, '-DryRun') 'live-mode'

    $livePaper = Join-Path $script:TempRoot 'environment-live-paper.json'
    $livePaperText = $rawConfig -replace '"environment": "backtesting"', '"environment": "live-paper"'
    Assert-True ($livePaperText -ne $rawConfig) 'fixture: environment live-paper copy differs from the original'
    [System.IO.File]::WriteAllText($livePaper, $livePaperText)
    Assert-PreflightFailure 'config copy with environment live-paper' @('-Config', $livePaper, '-DryRun') '"environment".*live-paper'

    $secondEnv = Join-Path $script:TempRoot 'second-environment.json'
    $secondEnvText = $rawConfig -replace '"environments": \{', '"environments": { "paper": { "live-mode": false },'
    Assert-True ($secondEnvText -ne $rawConfig) 'fixture: second-environment copy differs from the original'
    [System.IO.File]::WriteAllText($secondEnv, $secondEnvText)
    Assert-PreflightFailure 'config copy with a second environment' @('-Config', $secondEnv, '-DryRun') '"environments".*paper'

    $missingData = Join-Path $script:TempRoot 'no-such-data'
    Assert-PreflightFailure 'nonexistent -DataFolder' @('-DataFolder', $missingData, '-DryRun') ([regex]::Escape($missingData))

    $emptyData = Join-Path $script:TempRoot 'empty-data'
    New-Item -ItemType Directory -Path $emptyData -Force | Out-Null
    Assert-PreflightFailure 'empty -DataFolder without auxiliary databases' @('-DataFolder', $emptyData, '-DryRun') 'market-hours-database\.json'

    $fileAsOutput = Join-Path $script:TempRoot 'output-is-a-file.txt'
    [System.IO.File]::WriteAllText($fileAsOutput, 'not a directory')
    Assert-PreflightFailure '-OutputRoot pointing at an existing file' @('-OutputRoot', $fileAsOutput, '-DryRun') 'existing file'

    Assert-PreflightFailure '-AlgorithmLanguage Python without -AlgorithmLocation' @('-AlgorithmLanguage', 'Python', '-DryRun') 'AlgorithmLocation'

    # ------------------------------------------------------------------------
    # Python runtime pre-flight (Batch C)
    # ------------------------------------------------------------------------
    $fakeDllDir = Join-Path $script:TempRoot 'fake-python'
    New-Item -ItemType Directory -Path $fakeDllDir -Force | Out-Null
    $fakeDll = Join-Path $fakeDllDir 'python311.dll'
    [System.IO.File]::WriteAllText($fakeDll, 'not a dll')
    $pyArgs = @('-AlgorithmLanguage', 'Python', '-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-AlgorithmLocation', $script:PythonAlgorithm)

    # Release (the default configuration) is refused for Python: upstream #9708.
    Assert-PreflightFailure 'Python with the Release configuration' ($pyArgs + @('-PythonDll', $fakeDll, '-DryRun')) 'requires -Configuration Debug.*#9708'
    # No DLL from either source.
    Assert-PreflightFailure 'Python without -PythonDll or PYTHONNET_PYDLL' ($pyArgs + @('-Configuration', 'Debug', '-DryRun')) 'PYTHONNET_PYDLL'
    # A DLL path that does not exist.
    $missingDll = Join-Path $script:TempRoot 'no-such\python311.dll'
    Assert-PreflightFailure 'Python with a nonexistent -PythonDll' ($pyArgs + @('-Configuration', 'Debug', '-PythonDll', $missingDll, '-DryRun')) 'does not exist'
    # PYTHONNET_PYDLL is honoured as the fallback source and reported as such.
    $pyEnv = Invoke-Helper ($pyArgs + @('-Configuration', 'Debug', '-DryRun')) @{ PYTHONNET_PYDLL = $missingDll }
    Assert-Equal 2 $pyEnv.ExitCode 'Python with PYTHONNET_PYDLL pointing at a missing file -> exit code 2'
    Assert-Match $pyEnv.StdErr '(?m)^ERROR: .*\(from PYTHONNET_PYDLL\) does not exist' 'Python with PYTHONNET_PYDLL pointing at a missing file -> ERROR names the environment variable'

    if ($script:HasDebugBuild) {
        # An existing DLL with no python.exe next to it: pre-flight passes with a
        # warning that the pandas probe was skipped, and the dry run shows both
        # variables the launcher process would receive.
        $pyFake = Invoke-Helper ($pyArgs + @('-Configuration', 'Debug', '-PythonDll', $fakeDll, '-DryRun'))
        Assert-Equal 0 $pyFake.ExitCode 'Python dry run with a DLL but no python.exe -> exit code 0'
        Assert-Match $pyFake.StdErr '(?m)^WARNING: No python\.exe next to' 'Python dry run with a DLL but no python.exe -> WARNING that the pandas check was skipped'
        Assert-Contains $pyFake.StdOut ('PYTHONNET_PYDLL:  ' + $fakeDll + ' (from -PythonDll)') 'Python dry run: PYTHONNET_PYDLL line shows the DLL and its source'
        Assert-Contains $pyFake.StdOut ('PYTHONPATH:       ' + (Join-Path $script:LeanRootPath 'Launcher\bin\Debug')) 'Python dry run: PYTHONPATH line is the Debug launcher directory'
        Assert-Contains $pyFake.StdOut '--algorithm-language Python' 'Python dry run: command line has --algorithm-language Python'
        Assert-Contains $pyFake.StdOut 'Launcher\bin\Debug\QuantConnect.Lean.Launcher.dll' 'Python dry run: command line uses the Debug launcher'
        Assert-NotContains $pyFake.All 'Launching LEAN' 'Python dry run: nothing launched'
        Assert-NotContains $pyFake.All 'NOT qualified' 'Python dry run: no stale "not qualified" warning'
        if ($script:HasPythonDll) {
            $pyReal = Invoke-Helper ($pyArgs + @('-Configuration', 'Debug', '-PythonDll', $PythonDll, '-DryRun'))
            Assert-Equal 0 $pyReal.ExitCode 'Python dry run with the real DLL -> exit code 0'
            Assert-Match $pyReal.StdOut '(?m)^  python / pandas:  3\.\d+\.\d+ \d+\.\d+\.\d+ \(' 'Python dry run with the real DLL: pandas probe reports python and pandas versions'
            Assert-NotMatch $pyReal.StdErr '(?m)^WARNING: No python\.exe' 'Python dry run with the real DLL: pandas probe ran'
        }
        else {
            Skip 'Python dry run with the real DLL' 'no -PythonDll given'
        }
    }
    else {
        Skip 'Python dry run checks' "no Debug build at $script:DebugLauncher"
    }

    # Nested environment: LEAN's Config.GetToken recurses into
    # environments.backtesting.environment -> environments.backtesting.environments.live,
    # which would resolve live-mode to true although both visible levels say false.
    $nestedLive = Join-Path $script:TempRoot 'nested-live.json'
    $nestedLiveText = $rawConfig -replace '"backtesting": \{', '"backtesting": { "environment": "live", "environments": { "live": { "live-mode": true } },'
    Assert-True ($nestedLiveText -ne $rawConfig) 'fixture: nested-environment copy differs from the original'
    [System.IO.File]::WriteAllText($nestedLive, $nestedLiveText)
    Assert-PreflightFailure 'config copy with a nested environment inside backtesting' @('-Config', $nestedLive, '-DryRun') '"environments\.backtesting" contains "environment'

    # Live handler names with live-mode still false.
    $liveHandlers = Join-Path $script:TempRoot 'live-handlers.json'
    $liveHandlersText = $rawConfig -replace 'Setup\.BacktestingSetupHandler', 'Setup.BrokerageSetupHandler' -replace 'DataFeeds\.FileSystemDataFeed', 'DataFeeds.LiveTradingDataFeed'
    $liveHandlersText = $liveHandlersText -replace '"backtesting": \{', '"backtesting": { "live-mode-brokerage": "PaperBrokerage", "data-queue-handler": [ "QuantConnect.Lean.Engine.DataFeeds.Queues.LiveDataQueue" ],'
    Assert-True ($liveHandlersText -ne $rawConfig) 'fixture: live-handlers copy differs from the original'
    [System.IO.File]::WriteAllText($liveHandlers, $liveHandlersText)
    $lh = Invoke-Helper @('-Config', $liveHandlers, '-DryRun')
    Assert-Equal 2 $lh.ExitCode 'config copy with live handlers (live-mode false) -> exit code 2'
    Assert-Match $lh.StdErr '(?m)^ERROR: .*"setup-handler" is .*BrokerageSetupHandler' 'config copy with live handlers -> ERROR names setup-handler'
    Assert-Match $lh.StdErr '(?m)^ERROR: .*"data-feed-handler" is .*LiveTradingDataFeed' 'config copy with live handlers -> ERROR names data-feed-handler'
    Assert-Match $lh.StdErr '(?m)^ERROR: .*"live-mode-brokerage" is present' 'config copy with live handlers -> ERROR names live-mode-brokerage'
    Assert-Match $lh.StdErr '(?m)^ERROR: .*"data-queue-handler" is present' 'config copy with live handlers -> ERROR names data-queue-handler'
    Assert-NotContains $lh.All 'Launching LEAN' 'config copy with live handlers -> nothing launched'

    # ApiDataProvider downloads through the QuantConnect API (account/token gated).
    $apiProvider = Join-Path $script:TempRoot 'api-data-provider.json'
    $apiProviderText = $rawConfig -replace 'DataFeeds\.DefaultDataProvider', 'DataFeeds.ApiDataProvider'
    Assert-True ($apiProviderText -ne $rawConfig) 'fixture: ApiDataProvider copy differs from the original'
    [System.IO.File]::WriteAllText($apiProvider, $apiProviderText)
    Assert-PreflightFailure 'config copy with data-provider ApiDataProvider' @('-Config', $apiProvider, '-DryRun') '"data-provider" is .*ApiDataProvider'

    # A one-element array must not pass as a boolean.
    $liveArray = Join-Path $script:TempRoot 'live-mode-array.json'
    $liveArrayText = (New-Object System.Text.RegularExpressions.Regex '"live-mode": false').Replace($rawConfig, '"live-mode": [false]', 1)
    Assert-True ($liveArrayText -ne $rawConfig) 'fixture: live-mode array copy differs from the original'
    [System.IO.File]::WriteAllText($liveArray, $liveArrayText)
    Assert-PreflightFailure 'config copy with live-mode [false]' @('-Config', $liveArray, '-DryRun') '"live-mode" is \[false\] \(JSON array\)'

    # environments must be an object.
    $envString = Join-Path $script:TempRoot 'environments-string.json'
    $envStringObject = ConvertFrom-Json -InputObject (Remove-JsonComments $rawConfig)
    $envStringObject.environments = 'backtesting'
    [System.IO.File]::WriteAllText($envString, (ConvertTo-Json -InputObject $envStringObject -Depth 20))
    Assert-PreflightFailure 'config copy with environments as a string' @('-Config', $envString, '-DryRun') '"environments" is a JSON string but must be a JSON object'

    # Parameter validation: an empty algorithm name is rejected before the script runs.
    $emptyName = Invoke-Helper @('-AlgorithmTypeName', '', '-DryRun')
    Assert-True ($emptyName.ExitCode -ne 0) 'empty -AlgorithmTypeName -> non-zero exit code' "got exit code $($emptyName.ExitCode)"
    Assert-Contains $emptyName.All 'AlgorithmTypeName' 'empty -AlgorithmTypeName -> error names the parameter'
    Assert-NotContains $emptyName.All 'Launching LEAN' 'empty -AlgorithmTypeName -> nothing launched'

    # ------------------------------------------------------------------------
    # Optional smoke run
    # ------------------------------------------------------------------------
    if ($IncludeSmoke) {
        $smokeOutput = Join-Path $script:TempRoot 'smoke-output'
        $smoke = Invoke-Helper @('-OutputRoot', $smokeOutput)
        Assert-Equal 0 $smoke.ExitCode 'smoke: helper exit code 0'
        Assert-NotContains $smoke.All 'Press any key' 'smoke: no keypress wait'
        $runDirs = @()
        if (Test-Path -LiteralPath $smokeOutput -PathType Container) {
            $runDirs = @(Get-ChildItem -LiteralPath $smokeOutput -Directory)
        }
        Assert-Equal 1 $runDirs.Count 'smoke: exactly one run directory created'
        if ($runDirs.Count -eq 1) {
            $runDir = $runDirs[0].FullName
            Assert-Contains $smoke.StdOut $runDir 'smoke: run directory is printed'
            Assert-True (Test-Path -LiteralPath (Join-Path $runDir 'BasicTemplateFrameworkAlgorithm.json') -PathType Leaf) 'smoke: result JSON exists in run dir'
            Assert-True (Test-Path -LiteralPath (Join-Path $runDir 'log.txt') -PathType Leaf) 'smoke: log.txt exists in run dir'
            Assert-True (Test-Path -LiteralPath (Join-Path $runDir 'storage') -PathType Container) 'smoke: storage\ (object store, cwd-relative) is in run dir'
            $reports = @(Get-ChildItem -LiteralPath $runDir -Filter 'data-monitor-report-*.json' -File)
            Assert-Equal 1 $reports.Count 'smoke: one data-monitor-report in run dir'
            if ($reports.Count -eq 1) {
                $report = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($reports[0].FullName))
                Assert-Equal 0 ([int](Get-JsonProperty $report 'failed-data-requests-count')) 'smoke: failed-data-requests-count is 0'
                Assert-True ([int](Get-JsonProperty $report 'succeeded-data-requests-count') -gt 0) 'smoke: succeeded-data-requests-count > 0'
            }
            $logText = [System.IO.File]::ReadAllText((Join-Path $runDir 'log.txt'))
            Assert-Contains $logText 'BacktestingSetupHandler' 'smoke: log shows BacktestingSetupHandler'
            Assert-NotContains $logText 'BrokerageSetupHandler' 'smoke: log has no BrokerageSetupHandler'
            Assert-NotContains $logText 'LiveTradingDataFeed' 'smoke: log has no LiveTradingDataFeed'
            Assert-NotContains $logText ' ERROR:: ' 'smoke: clean run has no engine ERROR:: line'
        }

        # --------------------------------------------------------------------
        # Damaged data files: LEAN logs an ERROR:: and exits 0 (Batch C cases
        # F2a, F2c); the helper must turn that into exit code 4. A missing file
        # (exit code 3) takes precedence and is not double-counted (F2d).
        # --------------------------------------------------------------------
        function New-SampleDataRoot([string]$Name) {
            $root = Join-Path $script:TempRoot $Name
            foreach ($rel in @('market-hours\market-hours-database.json', 'symbol-properties\symbol-properties-database.csv',
                               'equity\usa\map_files\spy.csv', 'equity\usa\factor_files\spy.csv',
                               'equity\usa\hour\spy.zip', 'equity\usa\daily\spy.zip', 'alternative\interest-rate\usa\interest-rate.csv')) {
                $target = Join-Path $root $rel
                New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($target)) -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $script:DataPath $rel) -Destination $target
            }
            $minute = Join-Path $root 'equity\usa\minute\spy'
            New-Item -ItemType Directory -Path $minute -Force | Out-Null
            foreach ($day in @('20131007', '20131008', '20131009', '20131010', '20131011')) {
                foreach ($kind in @('trade', 'quote')) {
                    Copy-Item -LiteralPath (Join-Path $script:DataPath "equity\usa\minute\spy\${day}_$kind.zip") -Destination $minute
                }
            }
            return $root
        }

        # F2a: the zip is garbage (all zero bytes, no PK signature).
        $corruptData = New-SampleDataRoot 'corrupt-data'
        $corruptFile = Join-Path $corruptData 'equity\usa\minute\spy\20131009_trade.zip'
        $corruptBytes = New-Object byte[] ([System.IO.FileInfo]$corruptFile).Length
        [System.IO.File]::WriteAllBytes($corruptFile, $corruptBytes)
        $corruptHead = [System.IO.File]::ReadAllBytes($corruptFile)
        Assert-True (($corruptHead.Length -gt 2) -and -not (($corruptHead[0] -eq 0x50) -and ($corruptHead[1] -eq 0x4B))) 'fixture: corrupt zip no longer starts with the PK signature'

        $corruptOutput = Join-Path $script:TempRoot 'corrupt-output'
        $corrupt = Invoke-Helper @('-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-DataFolder', $corruptData, '-OutputRoot', $corruptOutput)
        Assert-Equal 4 $corrupt.ExitCode 'corrupt zip: helper exit code 4'
        Assert-Contains $corrupt.StdOut 'LEAN exited with code 0' 'corrupt zip: LEAN itself exited 0'
        Assert-Match $corrupt.StdErr '(?m)^ERROR: \d+ engine ERROR:: line\(s\) in ' 'corrupt zip: ERROR names the engine ERROR:: count'
        Assert-Match $corrupt.StdErr '(?m)^ERROR:   .*ZipDataCacheProvider\.Fetch\(\): Corrupt zip file/entry' 'corrupt zip: ERROR quotes the engine line'
        Assert-Contains $corrupt.StdOut 'failed 0.' 'corrupt zip: data monitor still reports 0 failed requests (why the log check exists)'

        $corruptAllowed = Invoke-Helper @('-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-DataFolder', $corruptData, '-OutputRoot', $corruptOutput, '-AllowEngineErrors')
        Assert-Equal 0 $corruptAllowed.ExitCode 'corrupt zip with -AllowEngineErrors: exit code 0'
        Assert-Match $corruptAllowed.StdErr '(?m)^WARNING: \d+ engine ERROR:: line\(s\) in ' 'corrupt zip with -AllowEngineErrors: downgraded to WARNING'

        # F2c: a valid zip whose only entry is empty. The file opens, so the
        # data monitor counts success; LEAN's only signal is an
        # "InvalidSource(): File not found" line for a file that exists.
        $emptyData = New-SampleDataRoot 'empty-entry-data'
        $emptyFile = Join-Path $emptyData 'equity\usa\minute\spy\20131009_trade.zip'
        Remove-Item -LiteralPath $emptyFile -Force
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::Open($emptyFile, [System.IO.Compression.ZipArchiveMode]::Create)
        try { $null = $archive.CreateEntry('20131009_spy_minute_trade.csv') } finally { $archive.Dispose() }
        $emptyHead = [System.IO.File]::ReadAllBytes($emptyFile)
        Assert-True (($emptyHead.Length -gt 2) -and ($emptyHead[0] -eq 0x50) -and ($emptyHead[1] -eq 0x4B)) 'fixture: empty-entry zip is a valid zip'

        $emptyOutput = Join-Path $script:TempRoot 'empty-entry-output'
        $empty = Invoke-Helper @('-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-DataFolder', $emptyData, '-OutputRoot', $emptyOutput)
        Assert-Equal 4 $empty.ExitCode 'empty zip entry: helper exit code 4'
        Assert-Contains $empty.StdOut 'failed 0.' 'empty zip entry: data monitor reports 0 failed requests'
        Assert-Match $empty.StdErr '(?m)^ERROR:   .*SubscriptionDataSourceReader\.InvalidSource\(\): File not found: .*20131009_trade\.zip' 'empty zip entry: ERROR quotes the InvalidSource line for the existing file'

        # F2d: one file missing AND one corrupt: exit 3 wins, both blocks are
        # printed, and the missing file's InvalidSource line is not counted as
        # an engine error.
        $bothData = New-SampleDataRoot 'missing-and-corrupt-data'
        Remove-Item -LiteralPath (Join-Path $bothData 'equity\usa\minute\spy\20131010_quote.zip') -Force
        $bothCorrupt = Join-Path $bothData 'equity\usa\minute\spy\20131009_trade.zip'
        [System.IO.File]::WriteAllBytes($bothCorrupt, (New-Object byte[] ([System.IO.FileInfo]$bothCorrupt).Length))
        $bothOutput = Join-Path $script:TempRoot 'missing-and-corrupt-output'
        $both = Invoke-Helper @('-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-DataFolder', $bothData, '-OutputRoot', $bothOutput)
        Assert-Equal 3 $both.ExitCode 'missing + corrupt: exit code 3 takes precedence'
        Assert-Match $both.StdErr '(?m)^ERROR: 1 local data request\(s\) FAILED' 'missing + corrupt: missing-data block printed'
        Assert-Match $both.StdErr '(?m)^ERROR:   missing: \\equity\\usa\\minute\\spy\\20131010_quote\.zip' 'missing + corrupt: the missing file is named'
        Assert-Match $both.StdErr '(?m)^ERROR: 2 engine ERROR:: line\(s\) in ' 'missing + corrupt: engine-error block counts only the corrupt file''s two lines'
        Assert-NotMatch $both.StdErr '(?m)^ERROR:   .*InvalidSource\(\): File not found: .*20131010_quote\.zip' 'missing + corrupt: the missing file''s InvalidSource line is not quoted as an engine error'

        # --------------------------------------------------------------------
        # Python representative (Debug build + qualified runtime only).
        # --------------------------------------------------------------------
        if ($script:HasDebugBuild -and $script:HasPythonDll) {
            $pyOutput = Join-Path $script:TempRoot 'python-output'
            $py = Invoke-Helper @('-Configuration', 'Debug', '-AlgorithmLanguage', 'Python', '-AlgorithmTypeName', 'BasicTemplateAlgorithm', '-AlgorithmLocation', $script:PythonAlgorithm, '-PythonDll', $PythonDll, '-OutputRoot', $pyOutput)
            Assert-Equal 0 $py.ExitCode 'python smoke: helper exit code 0'
            Assert-Contains $py.StdOut 'Importing python module BasicTemplateAlgorithm' 'python smoke: LEAN imported the Python module'
            Assert-Contains $py.StdOut 'Program.Main(): Exiting Lean...' 'python smoke: LEAN reached its normal exit line'
            Assert-NotContains $py.All 'Unhandled exception' 'python smoke: no unhandled exception at shutdown'
            Assert-Match $py.StdOut '(?m)^STATISTICS:: Total Orders \d+' 'python smoke: statistics were produced'
            $pyRunDirs = @()
            if (Test-Path -LiteralPath $pyOutput -PathType Container) { $pyRunDirs = @(Get-ChildItem -LiteralPath $pyOutput -Directory) }
            Assert-Equal 1 $pyRunDirs.Count 'python smoke: exactly one run directory created'
            if ($pyRunDirs.Count -eq 1) {
                $pyLog = [System.IO.File]::ReadAllText((Join-Path $pyRunDirs[0].FullName 'log.txt'))
                Assert-Contains $pyLog 'BacktestingSetupHandler' 'python smoke: log shows BacktestingSetupHandler'
                Assert-NotContains $pyLog ' ERROR:: ' 'python smoke: no engine ERROR:: line'
                Assert-True (Test-Path -LiteralPath (Join-Path $pyRunDirs[0].FullName 'BasicTemplateAlgorithm-order-events.json') -PathType Leaf) 'python smoke: order events written'
            }

            # The algorithm's own Error() output goes through Log.Error with
            # an algorithm-time prefix; it is the algorithm's message, not an
            # engine error, and must not produce exit code 4.
            $errorAlgorithmDir = Join-Path $script:TempRoot 'error-algorithm'
            New-Item -ItemType Directory -Path $errorAlgorithmDir -Force | Out-Null
            $errorAlgorithm = Join-Path $errorAlgorithmDir 'ErrorOutputAlgorithm.py'
            [System.IO.File]::WriteAllText($errorAlgorithm, @'
from AlgorithmImports import *

class ErrorOutputAlgorithm(QCAlgorithm):
    def initialize(self):
        self.set_start_date(2013, 10, 7)
        self.set_end_date(2013, 10, 11)
        self.set_cash(100000)
        self.add_equity("SPY", Resolution.MINUTE)
        self.error("test fixture: algorithm Error() output on a completed backtest")

    def on_data(self, data):
        if not self.portfolio.invested:
            self.set_holdings("SPY", 1)
'@)
            $errOutput = Join-Path $script:TempRoot 'error-algorithm-output'
            $err = Invoke-Helper @('-Configuration', 'Debug', '-AlgorithmLanguage', 'Python', '-AlgorithmTypeName', 'ErrorOutputAlgorithm', '-AlgorithmLocation', $errorAlgorithm, '-PythonDll', $PythonDll, '-OutputRoot', $errOutput)
            Assert-Equal 0 $err.ExitCode 'python Error() output: helper exit code 0 (not an engine error)'
            Assert-Match $err.StdOut '(?m)^STATISTICS:: Total Orders 1' 'python Error() output: the backtest completed with its order'
            $errRunDirs = @()
            if (Test-Path -LiteralPath $errOutput -PathType Container) { $errRunDirs = @(Get-ChildItem -LiteralPath $errOutput -Directory) }
            if ($errRunDirs.Count -eq 1) {
                $errLog = [System.IO.File]::ReadAllText((Join-Path $errRunDirs[0].FullName 'log.txt'))
                Assert-Match $errLog '(?m) ERROR:: 2013-10-07 00:00:00 test fixture: algorithm Error\(\) output' 'python Error() output: the message is in the engine log with the algorithm-time prefix'
            }

            # Environment restore: after an in-process launch the caller's
            # PYTHONNET_PYDLL / PYTHONPATH are exactly what they were.
            $env:PYTHONNET_PYDLL = 'sentinel-dll'
            $env:PYTHONPATH = 'sentinel-path'
            $restoreOutput = Join-Path $script:TempRoot 'restore-output'
            $previousLocation = Get-Location
            try {
                Set-Location -LiteralPath $script:TempRoot
                & $script:HelperPath -Configuration Debug -AlgorithmLanguage Python -AlgorithmTypeName BasicTemplateAlgorithm -AlgorithmLocation $script:PythonAlgorithm -PythonDll $PythonDll -OutputRoot $restoreOutput *> $null
                $restoreExit = $LASTEXITCODE
            }
            finally {
                Set-Location -LiteralPath $previousLocation
            }
            Assert-Equal 0 $restoreExit 'env restore: in-process Python launch exit code 0'
            Assert-Equal 'sentinel-dll' $env:PYTHONNET_PYDLL 'env restore: PYTHONNET_PYDLL restored after the launch'
            Assert-Equal 'sentinel-path' $env:PYTHONPATH 'env restore: PYTHONPATH restored after the launch'
            Remove-Item -Path Env:PYTHONNET_PYDLL -ErrorAction SilentlyContinue
            Remove-Item -Path Env:PYTHONPATH -ErrorAction SilentlyContinue
        }
        else {
            Skip 'python smoke' 'needs the Debug build and -PythonDll'
        }
    }
}
finally {
    try { Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

$stopwatch.Stop()
Write-Host ("Passed: {0}, Failed: {1}, elapsed {2:N1} s" -f $script:Passed, $script:Failed, $stopwatch.Elapsed.TotalSeconds)
if ($script:Failed -gt 0) { exit 1 }
exit 0
