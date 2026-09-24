<#
.SYNOPSIS
End-to-end check of the SingleAnchor five-minute trading-availability gate through the
unchanged LEAN engine, with a deterministic native tick fixture.

.DESCRIPTION
Builds a scratch research data folder outside the repository and runs the real
`MarketLab\scripts\run-backtest.ps1` strategy path twice on one small native
`cfd\oanda\tick\xauusd` partition (2024-01-10, five quotes):

  without -single-anchor-session-map : quote 2 (inside the first five minutes) opens a BUY;
  with    -single-anchor-session-map : the same five delivered quotes are unchanged, but the
                                       four quotes in the fixture session's five-minute buffers
                                       are quote-only and no position opens.

The source-derived map bounds one session 09:00-09:13 New York with its exact first and last
quote, and the run is configured with the map as a data-folder-relative path. The check asserts
the delivered count is identical in both runs, the quote-only and eligible counts are distinct,
the position difference is real, and the results carry the map's source provenance.

The fixture is synthetic and outside Git; the historical dataset is not touched.

Exit codes: 0 all checks passed; 1 a check failed; 2 prerequisites missing.

.EXAMPLE
powershell -File MarketLab\tests\Test-TradingAvailabilityEndToEnd.ps1
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$KeepScratch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# ----------------------------------------------------------------------------
# Assertions
# ----------------------------------------------------------------------------

$script:ChecksPassed = 0
$script:ChecksFailed = 0

function Assert-Equal($Expected, $Actual, [string]$Label) {
    if ("$Expected" -eq "$Actual") {
        $script:ChecksPassed++
        Write-Host "  PASS $Label"
    }
    else {
        $script:ChecksFailed++
        Write-Host "  FAIL $Label (expected '$Expected', got '$Actual')"
    }
}

function Assert-True([bool]$Condition, [string]$Label) {
    if ($Condition) {
        $script:ChecksPassed++
        Write-Host "  PASS $Label"
    }
    else {
        $script:ChecksFailed++
        Write-Host "  FAIL $Label"
    }
}

# ----------------------------------------------------------------------------
# Prerequisites and paths
# ----------------------------------------------------------------------------

if ([string]::IsNullOrEmpty($LeanRoot)) {
    $LeanRoot = Join-Path $PSScriptRoot '..\..'
}
$leanRootPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $LeanRoot)).TrimEnd([char]'\', [char]'/')
$helperPath = Join-Path $leanRootPath 'MarketLab\scripts\run-backtest.ps1'
$algorithmPath = Join-Path $leanRootPath ("MarketLab\src\SingleAnchor\bin\{0}\MarketLab.SingleAnchor.dll" -f $Configuration)
$launcherPath = Join-Path $leanRootPath ("Launcher\bin\{0}\QuantConnect.Lean.Launcher.dll" -f $Configuration)
$auxRoot = Join-Path $leanRootPath 'Data'
$shellExe = (Get-Process -Id $PID).Path

$missing = @()
foreach ($required in @($helperPath, $algorithmPath, $launcherPath,
        (Join-Path $auxRoot 'market-hours\market-hours-database.json'),
        (Join-Path $auxRoot 'symbol-properties\symbol-properties-database.csv'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { $missing += $required }
}
if ($missing.Count -gt 0) {
    foreach ($path in $missing) { [Console]::Error.WriteLine("ERROR: missing prerequisite: $path") }
    [Console]::Error.WriteLine('Build first: MarketLab\scripts\build.ps1 and dotnet build MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj')
    exit 2
}

function Format-ProcessArgument([string]$Value) {
    if ($Value -match '[\s"]') {
        $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
        $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
        return '"' + $escaped + '"'
    }
    return $Value
}

function Invoke-Helper([string[]]$Arguments, [string]$WorkingDirectory) {
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helperPath) + $Arguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $shellExe
    $psi.Arguments = (($argList | ForEach-Object { Format-ProcessArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $WorkingDirectory
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return New-Object PSObject -Property @{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderr
    }
}

function Get-Results([string]$OutputRoot) {
    $run = Get-ChildItem -LiteralPath $OutputRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $run) { throw "no run directory under $OutputRoot" }
    $resultsPath = Join-Path $run.FullName 'storage\single-anchor\results.json'
    if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) { throw "no results.json under $($run.FullName)" }
    return (Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
}

# ----------------------------------------------------------------------------
# Fixture: one native partition with five quotes around a synthetic session
# ----------------------------------------------------------------------------
# 2024-01-10 is a Wednesday. 50,400,000 ms = 14:00:00Z = 09:00 New York, which is inside the
# resolved Oanda XAUUSD session (00:00-16:58 New York), so LEAN delivers every quote.
# The session map is the fixture's own source-derived identity: one session from the first to
# the last observed quote, 14:00:00Z-14:13:00Z (09:00-09:13 New York).
#
# The unchanged engine fixtures (market-hours, symbol-properties, alternative, equity and the
# Oanda hour sample) are linked as directory junctions, never copied, exactly like the
# historical-data driver does; cleanup removes them as links before deleting the scratch.

$scratch = Join-Path $env:TEMP ('marketlab-trading-availability-' + [Guid]::NewGuid().ToString('N'))
$dataFolder = Join-Path $scratch 'data'
$tickDirectory = Join-Path $dataFolder 'cfd\oanda\tick\xauusd'
$sessionDirectory = Join-Path $dataFolder 'marketlab-sessions'
$outputNoMap = Join-Path $scratch 'output-no-map'
$outputMap = Join-Path $scratch 'output-map'
$tickCsv = Join-Path $scratch '20240110_xauusd_tick_quote.csv'
$partition = Join-Path $tickDirectory '20240110_quote.zip'
$mapPath = Join-Path $sessionDirectory 'xauusd-sessions.json'
$auxiliaryLinks = @(
    @{ Path = 'market-hours'; Target = (Join-Path $auxRoot 'market-hours') },
    @{ Path = 'symbol-properties'; Target = (Join-Path $auxRoot 'symbol-properties') },
    @{ Path = 'alternative'; Target = (Join-Path $auxRoot 'alternative') },
    @{ Path = 'equity'; Target = (Join-Path $auxRoot 'equity') },
    @{ Path = 'cfd\oanda\hour'; Target = (Join-Path $auxRoot 'cfd\oanda\hour') }
)

function Remove-AuxiliaryLinks([string]$Root) {
    foreach ($link in $auxiliaryLinks) {
        $path = Join-Path $Root $link.Path
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.LinkType -eq 'Junction') {
                [System.IO.Directory]::Delete($path, $false)
            }
        }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $tickDirectory, $sessionDirectory | Out-Null
    foreach ($link in $auxiliaryLinks) {
        New-Item -ItemType Junction -Path (Join-Path $dataFolder $link.Path) -Target $link.Target | Out-Null
    }

    # 14:00:00 / 14:00:30 are the opening buffer, 14:06:00 is tradable, 14:12:00 / 14:13:00 are
    # the closing buffer. Ask 2020 crosses the anchor's 0.2% upper level (2004) on quote 2.
    $csv = @(
        '50400000,1999.9,2000.1',
        '50430000,2019.8,2020.0',
        '50760000,2019.8,2020.0',
        '51120000,2019.8,2020.0',
        '51180000,2019.8,2020.0'
    ) -join "`n"
    [System.IO.File]::WriteAllText($tickCsv, $csv, (New-Object System.Text.UTF8Encoding($false)))
    Compress-Archive -LiteralPath $tickCsv -DestinationPath $partition
    Remove-Item -LiteralPath $tickCsv

    $rule = 'A gap between consecutive quote runs is a session junction when it fully contains the New York local settlement interval 17:00:00 <= t < 18:00:00 (America/New_York).'
    $mapJson = @"
{
  "contract": "marketlab-single-anchor-session-map-v1",
  "symbol": "XAUUSD",
  "junctionTimeZone": "America/New_York",
  "junctionRule": "$rule",
  "source": {
    "fileCount": 1,
    "rowCount": 5,
    "sha256Aggregate": "$('a' * 64)",
    "firstQuoteUtc": "2024-01-10T14:00:00.000Z",
    "lastQuoteUtc": "2024-01-10T14:13:00.000Z"
  },
  "sessions": [
    { "startUtc": "2024-01-10T14:00:00.000Z", "endUtc": "2024-01-10T14:13:00.000Z" }
  ]
}
"@
    [System.IO.File]::WriteAllText($mapPath, $mapJson, (New-Object System.Text.UTF8Encoding($false)))

    $baseParameters = 'single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5,single-anchor-start-date:2024-01-09,single-anchor-end-date:2024-01-11'

    Write-Host 'Scenario 1: no session map (the buffer quote is tradable)'
    $noMap = Invoke-Helper @(
        '-AlgorithmTypeName', 'SingleAnchorVNextAlgorithm',
        '-AlgorithmLocation', $algorithmPath,
        '-DataFolder', $dataFolder,
        '-OutputRoot', $outputNoMap,
        '-AllowMissingData',
        '-Parameters', $baseParameters
    ) $scratch
    Assert-Equal 0 $noMap.ExitCode 'without map: helper exit code 0'

    Write-Host 'Scenario 2: with session map (the buffer quotes are quote-only)'
    $withMap = Invoke-Helper @(
        '-AlgorithmTypeName', 'SingleAnchorVNextAlgorithm',
        '-AlgorithmLocation', $algorithmPath,
        '-DataFolder', $dataFolder,
        '-OutputRoot', $outputMap,
        '-AllowMissingData',
        '-Parameters', ($baseParameters + ',single-anchor-session-map:marketlab-sessions/xauusd-sessions.json')
    ) $scratch
    Assert-Equal 0 $withMap.ExitCode 'with map: helper exit code 0'

    $plain = Get-Results $outputNoMap
    $mapped = Get-Results $outputMap

    Assert-Equal 5 $plain.quoteTicksProcessed 'without map: every delivered quote is counted'
    Assert-Equal 5 $mapped.quoteTicksProcessed 'with map: the delivered count is unchanged by the gate'
    Assert-Equal 0 $plain.quoteOnlyQuotes 'without map: no quote-only classification'
    Assert-Equal 4 $mapped.quoteOnlyQuotes 'with map: the four buffer quotes are quote-only'
    Assert-Equal 1 $mapped.strategyEligibleQuotes 'with map: only the tradable quote is eligible'
    Assert-Equal 1 $plain.legsOpened 'without map: the quote-2 trigger opens a position'
    Assert-Equal 0 $mapped.legsOpened 'with map: the same trigger is suppressed in the opening buffer'
    Assert-True ($null -eq $plain.sessionMap) 'without map: no session-map provenance is recorded'
    Assert-Equal 'marketlab-sessions/xauusd-sessions.json' $mapped.sessionMap.Map 'with map: the configured map value is recorded'
    Assert-Equal 5 $mapped.sessionMap.SourceRowCount 'with map: the source row count is surfaced in results'

    Write-Host ''
    Write-Host ("Trading-availability end-to-end: {0} passed, {1} failed." -f $script:ChecksPassed, $script:ChecksFailed)
    if ($script:ChecksFailed -gt 0) { exit 1 }
    exit 0
}
finally {
    if ($KeepScratch) {
        Write-Host "Scratch kept: $scratch"
    }
    else {
        Remove-AuxiliaryLinks $dataFolder
        if (Test-Path -LiteralPath $scratch) {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
