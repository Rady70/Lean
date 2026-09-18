<#
.SYNOPSIS
Self-contained checks for the MarketLab LEAN local-backtesting path.

.DESCRIPTION
Asserts the backtesting-only invariants of MarketLab\config\backtesting.json,
the -DryRun behaviour of MarketLab\scripts\run-backtest.ps1, and that the helper
exits 2 with an ERROR: line for each pre-flight failure it guards against
(missing build/config/data/output, live-mode, foreign or nested environments,
live handler names, ApiDataProvider, wrong JSON types).
Every helper invocation is a child process of the same PowerShell executable
that runs this script, so exit codes are the real process exit codes.

No Pester, no module, no network, no LEAN CLI. Without -IncludeSmoke nothing is
launched and the run finishes in a few seconds. With -IncludeSmoke one real
backtest (the Batch A representative algorithm on the shipped sample data) is
run into a temporary output root that is deleted afterwards. All fixtures live
under %TEMP%\marketlab-tests-<guid>, which is removed when the script ends.

Prints PASS:/FAIL: per assertion and a final count. Exit code 0 when every
assertion passed, 1 otherwise.

.PARAMETER LeanRoot
Root of the LEAN checkout. Default: two levels above this script.

.PARAMETER IncludeSmoke
Also run one real backtest through the helper (needs the Release build output).

.EXAMPLE
pwsh -File MarketLab\tests\Test-MarketLabBacktesting.ps1

.EXAMPLE
powershell -File MarketLab\tests\Test-MarketLabBacktesting.ps1 -IncludeSmoke
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [switch]$IncludeSmoke
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
function Invoke-Helper([string[]]$Arguments) {
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:HelperPath) + $Arguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ShellExe
    $psi.Arguments = (($argList | ForEach-Object { Format-ProcessArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $script:TempRoot
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
$script:ShellExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('marketlab-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

Write-Host "Test-MarketLabBacktesting"
Write-Host "  shell:      $script:ShellExe ($($PSVersionTable.PSVersion))"
Write-Host "  LEAN root:  $script:LeanRootPath"
Write-Host "  helper:     $script:HelperPath"
Write-Host "  temp root:  $script:TempRoot"
Write-Host "  smoke:      $IncludeSmoke"

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
