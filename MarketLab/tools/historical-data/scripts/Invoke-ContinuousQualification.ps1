<#
.SYNOPSIS
Runs the continuous full-history qualification path: compose the already-qualified
monthly native partitions into one continuous LEAN data folder, run one continuous
LEAN replay probe over it, and verify the continuous delivery against the monthly
qualification evidence.

.DESCRIPTION
This driver orchestrates the existing pieces; it implements no validation of its own:

  1. python -m marketlab_historical_data compose-history
     Validates the 90 month records with the tracked full-history aggregation,
     copies every qualified daily native partition byte for byte (SHA-256 checked
     against its month manifest), rebuilds the continuous ordered semantic digest
     and the continuous replay expectation, derives the always-open runtime
     identity into the continuous folder and copies the qualified source-derived
     session map when supplied. Nothing is re-converted and no source is re-read.
  2. MarketLab\scripts\run-backtest.ps1 with the MarketLab replay probe
     (MarketLab.HistoricalDataProbeAlgorithm). The probe runs inside the unchanged
     LEAN engine over the continuous data folder, one uninterrupted run covering
     the qualified window, and writes
     <run dir>\storage\single-anchor-replay-probe\replay-result.json.
     The helper is invoked with -AllowMissingData because LEAN requests every
     calendar day under the always-open identity; the final record classifies every
     failed request.
  3. python -m marketlab_historical_data verify-continuous
     Combines the continuous composition, the probe result and the helper's
     failed-data-request list into
     <DataFolder>\marketlab-qualification\continuous-qualification-record.json
     with an explicit overall PASS/FAIL. The driver's exit code is that record's
     verdict.

The continuous data folder and all generated qualification outputs stay outside Git.

.PARAMETER MonthsRoot
The per-file sweep layout: one subdirectory per month holding
data\marketlab-qualification\qualification-record.json and the native partitions.

.PARAMETER DataFolder
The continuous runtime LEAN data folder. The composed native history, the
expectation, the composition record and the qualification record are written here;
it must be outside the LEAN Git worktree.

.PARAMETER SessionMap
The qualified source-derived session map. It is verified by hash and copied into
the continuous folder under marketlab-sessions\xauusd-sessions.json.

.PARAMETER LeanRoot
Root of the LEAN checkout. Default: four levels above this script.

.PARAMETER PythonExe
Python executable for the offline tool (default: python on PATH).

.PARAMETER OutputRoot
Root for the LEAN run directories (default: <LeanRoot>\MarketLab\output).

.PARAMETER AuxiliaryDataSource
Runtime data folder that already contains the auxiliary databases and engine
fixtures (default: <LeanRoot>\Data).

.PARAMETER NoAuxiliaryLinks
Do not link auxiliary data; expect missing-data warnings from the helper.

.PARAMETER SkipCompose
Skip the composition step (the continuous folder must already be composed).

.PARAMETER Force
Replace an existing composition generation the previous composition record owns.

Exit codes:
  0  continuous qualification record PASS (the LEAN helper completed cleanly)
  1  continuous qualification record FAIL
  2  configuration error (missing path, unusable data folder, Python failure, or
     the LEAN helper's own pre-flight refusal: LEAN was not launched)
  3  the LEAN helper reported errors or an unclean run; no qualification record
     was written

.REQUIRES Windows PowerShell 5.1 or PowerShell 7+, and the built LEAN Launcher
and replay probe (Build-Configuration note in the tools README).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MonthsRoot,
    [Parameter(Mandatory = $true)][string]$DataFolder,
    [string]$SessionMap,
    [string]$LeanRoot,
    [string]$PythonExe = 'python',
    [string]$OutputRoot,
    [string]$AuxiliaryDataSource,
    [switch]$NoAuxiliaryLinks,
    [switch]$SkipCompose,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-ErrorMessage([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Resolve-RequiredPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ErrorMessage "$Label not found: $Path"
        exit 2
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-External([string]$Executable, $Arguments) {
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& $Executable @Arguments 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $script:externalExitCode = $LASTEXITCODE
    return $output
}

if (-not $LeanRoot) {
    $LeanRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
}
$LeanRoot = (Resolve-Path -LiteralPath $LeanRoot).Path
if (-not $OutputRoot) { $OutputRoot = Join-Path $LeanRoot 'MarketLab\output' }
if (-not $AuxiliaryDataSource) { $AuxiliaryDataSource = Join-Path $LeanRoot 'Data' }

$monthsRootPath = Resolve-RequiredPath $MonthsRoot 'months root'
$dataRoot = Resolve-RequiredPath $DataFolder 'data folder'
if ($SessionMap) { $sessionMapPath = Resolve-RequiredPath $SessionMap 'session map' }

$scriptCheckout = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).FullName
foreach ($checkout in @($LeanRoot, $scriptCheckout) | Select-Object -Unique) {
    if ($dataRoot.Equals($checkout, [StringComparison]::OrdinalIgnoreCase) -or
        $dataRoot.StartsWith($checkout + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-ErrorMessage "the data folder is inside a LEAN worktree ($checkout): continuous native history and qualification outputs must stay outside the repository"
        exit 2
    }
}

$pythonPackageRoot = Join-Path $PSScriptRoot '..\python'
$pythonPackageRoot = (Resolve-Path -LiteralPath $pythonPackageRoot).Path
$helperScript = Resolve-RequiredPath (Join-Path $LeanRoot 'MarketLab\scripts\run-backtest.ps1') 'run-backtest helper'
$probeDll = Resolve-RequiredPath (Join-Path $LeanRoot 'MarketLab\tools\historical-data\probe\bin\Release\MarketLab.HistoricalDataProbe.dll') 'replay probe'
$runtimeBinaryPaths = @(
    $probeDll,
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Lean.Launcher.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Lean.Engine.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.AlgorithmFactory.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Algorithm.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Common.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Configuration.dll'),
    (Join-Path $LeanRoot 'Launcher\bin\Release\QuantConnect.Logging.dll')
)
$runtimeBinaryHashes = [ordered]@{}
foreach ($binaryPath in $runtimeBinaryPaths) {
    if (Test-Path -LiteralPath $binaryPath) {
        $runtimeBinaryHashes[(Split-Path -Leaf $binaryPath)] =
            (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
if ($runtimeBinaryHashes.Count -eq 0) {
    Write-ErrorMessage "no runtime binaries could be hashed; check the Launcher build output"
    exit 2
}
if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
}

$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $pythonPackageRoot
try {
    if (-not $SkipCompose) {
        $composeArguments = @(
            '-m', 'marketlab_historical_data', 'compose-history',
            '--months-root', $monthsRootPath,
            '--data-folder', $dataRoot,
            '--expected-first-month', '2019_01',
            '--expected-last-month', '2026_06',
            '--source-data-folder', $AuxiliaryDataSource,
            '--symbol', 'XAUUSD', '--market', 'dukascopy', '--security-type', 'Cfd'
        )
        if ($SessionMap) { $composeArguments += @('--session-map', $sessionMapPath) }
        if ($Force) { $composeArguments += '--force' }
        Write-Host "compose: $PythonExe $($composeArguments -join ' ')"
        $composeOutput = Invoke-External $PythonExe $composeArguments
        $composeExit = $script:externalExitCode
        Write-Host $composeOutput
        if ($composeExit -ne 0) {
            Write-ErrorMessage "the continuous composition did not pass (exit $composeExit); LEAN was not run"
            exit 2
        }
    }

    if (-not $NoAuxiliaryLinks) {
        $auxiliaryLinks = @(
            'alternative',
            'equity'
        )
        foreach ($relative in $auxiliaryLinks) {
            $target = Join-Path $dataRoot $relative
            if (Test-Path -LiteralPath $target) { continue }
            $source = Join-Path $AuxiliaryDataSource $relative
            if (-not (Test-Path -LiteralPath $source)) {
                Write-ErrorMessage "auxiliary data not found for linking: $source (pass -NoAuxiliaryLinks to skip)"
                exit 2
            }
            try {
                New-Item -ItemType Junction -Path $target -Target $source | Out-Null
                Write-Host "linked auxiliary data: $target -> $source"
            }
            catch {
                Write-ErrorMessage "could not create the auxiliary junction $target -> $source : $($_.Exception.Message)"
                exit 2
            }
        }
    }

    $runDirectoriesBefore = @()
    if (Test-Path -LiteralPath $OutputRoot) {
        $runDirectoriesBefore = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    $helperParameters = @{
        LeanRoot          = $LeanRoot
        AlgorithmTypeName = 'SingleAnchorReplayProbeAlgorithm'
        AlgorithmLocation = $probeDll
        DataFolder        = $dataRoot
        OutputRoot        = $OutputRoot
        Configuration     = 'Release'
        AllowMissingData  = $true
        Parameters        = 'probe-symbol:XAUUSD,probe-market:dukascopy,probe-security-type:Cfd'
    }
    Write-Host "replay: run-backtest.ps1 $((($helperParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))"
    $helperOutput = Invoke-External $helperScript $helperParameters
    $helperExit = $script:externalExitCode
    Write-Host $helperOutput
    if ($helperExit -eq 2) {
        Write-ErrorMessage "the LEAN helper refused the run in pre-flight (exit 2): LEAN was not launched and no qualification record was written"
        exit 2
    }
    if ($helperExit -eq 4) {
        Write-ErrorMessage "the LEAN helper exited 4: the engine reported errors during the run; the run is not clean and no qualification record was written"
        exit 3
    }

    $runtimeBinaryHashesAfter = [ordered]@{}
    foreach ($binaryPath in $runtimeBinaryPaths) {
        if (Test-Path -LiteralPath $binaryPath) {
            $runtimeBinaryHashesAfter[(Split-Path -Leaf $binaryPath)] =
                (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    foreach ($binaryName in $runtimeBinaryHashes.Keys) {
        if ($runtimeBinaryHashesAfter[$binaryName] -ne $runtimeBinaryHashes[$binaryName]) {
            Write-ErrorMessage "runtime binary changed while the run was in progress: $binaryName; the run is not clean and no qualification record was written"
            exit 3
        }
    }

    $runDirectory = $null
    $match = [regex]::Match($helperOutput, 'run directory:\s*(.+?);\s*log:')
    if ($match.Success) {
        $runDirectory = $match.Groups[1].Value.Trim()
    }
    if (-not $runDirectory -or -not (Test-Path -LiteralPath $runDirectory)) {
        $newDirectories = @(Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $runDirectoriesBefore -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending)
        if ($newDirectories.Count -gt 0) { $runDirectory = $newDirectories[0].FullName }
    }

    $probeResult = $null
    $failedRequests = $null
    $runtimeBinariesFile = $null
    if ($runDirectory -and (Test-Path -LiteralPath $runDirectory)) {
        $probeResult = Join-Path $runDirectory 'storage\single-anchor-replay-probe\replay-result.json'
        if (-not (Test-Path -LiteralPath $probeResult)) { $probeResult = $null }
        $failedFile = Get-ChildItem -LiteralPath $runDirectory -Filter 'failed-data-requests-*.txt' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($failedFile) { $failedRequests = $failedFile.FullName }
        $runtimeBinariesFile = Join-Path $runDirectory 'runtime-binaries.json'
        $runtimePayload = [ordered]@{
            source = 'MarketLab continuous driver hashes taken before the run'
            files  = $runtimeBinaryHashes
        } | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath $runtimeBinariesFile -Value $runtimePayload -Encoding UTF8
    }

    if ($helperExit -ne 0) {
        Write-ErrorMessage "the LEAN helper exited ${helperExit}: the run is not clean and no qualification record was written"
        exit 3
    }

    $verifyArguments = @(
        '-m', 'marketlab_historical_data', 'verify-continuous',
        '--composition', (Join-Path $dataRoot 'marketlab-qualification\continuous-composition.json'),
        '--data-folder', $dataRoot,
        '--helper-exit-code', [string]$helperExit
    )
    if ($probeResult) { $verifyArguments += @('--probe-result', $probeResult) }
    if ($failedRequests) { $verifyArguments += @('--failed-data-requests', $failedRequests) }
    if ($runtimeBinariesFile) { $verifyArguments += @('--runtime-binaries', $runtimeBinariesFile) }
    if ($Force) { $verifyArguments += '--force' }

    Write-Host "verify: $PythonExe $($verifyArguments -join ' ')"
    $verifyOutput = Invoke-External $PythonExe $verifyArguments
    $verifyExit = $script:externalExitCode
    Write-Host $verifyOutput

    if ($verifyExit -eq 2) {
        Write-Host "continuous qualification driver: the record could not be written (exit 2)"
        exit 2
    }
    if ($verifyExit -eq 0) {
        Write-Host "continuous qualification driver: PASS"
    }
    else {
        Write-Host "continuous qualification driver: FAIL"
    }
    exit $verifyExit
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
