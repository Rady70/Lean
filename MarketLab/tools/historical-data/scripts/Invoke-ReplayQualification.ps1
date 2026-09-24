<#
.SYNOPSIS
Runs the complete PR 1 historical-data qualification path: strict CSV
qualification and native LEAN conversion (offline Python), an actual LEAN
replay through the MarketLab probe, and the final PASS/FAIL record.

.DESCRIPTION
This driver orchestrates the three existing pieces; it implements no
validation of its own:

  1. python -m marketlab_historical_data qualify
     Strictly validates the historical bid/ask CSV against the SingleAnchor
     quote contract, converts it to native LEAN quote-tick partitions only
     after PASS, and writes the qualification manifest and the replay
     expectation into <DataFolder>\marketlab-qualification\.
  2. MarketLab\scripts\run-backtest.ps1 with the MarketLab replay probe
     (MarketLab.HistoricalDataProbe.dll, SingleAnchorReplayProbeAlgorithm).
     The probe runs inside the unchanged LEAN engine, captures the quotes LEAN
     actually delivers, and writes
     <run dir>\storage\single-anchor-replay-probe\replay-result.json.
     The helper is invoked with -AllowMissingData because LEAN probes the
     trading days adjacent to the qualified window (and only those) for
     continuity; the final record classifies every failed request. A missing
     native partition that carries accepted source rows fails the record.
  3. python -m marketlab_historical_data verify
     Combines the manifest, the probe result and the helper's failed-data
     request list into <DataFolder>\marketlab-qualification\qualification-
     record.json with an explicit overall PASS/FAIL. The driver's exit code is
     that record's verdict.

For -Market dukascopy (the Dukascopy/JForex XAUUSD source) the driver first
runs python -m marketlab_historical_data prepare-identity, which derives an
always-open, holiday-free runtime market-hours entry and symbol-properties row
from the engine fixtures and records their provenance in
marketlab-qualification\runtime-identity.json. The source replay then removes
no quote through session semantics: the source stream itself defines the
sessions. For -Market oanda the runtime databases stay the unchanged engine
fixtures (linked as junctions).

Before the LEAN run, missing auxiliary runtime data is linked (directory
junctions, never copies) from -AuxiliaryDataSource into the data folder:
alternative and equity (plus market-hours, symbol-properties and
cfd\oanda\hour for -Market oanda). The Dukascopy identity does not link or
require the Oanda hour fixture or the Oanda calendar; it derives its own
databases. These are the unchanged engine fixtures the subscription setup
reads (interest rates, map files, the Oanda hour sample). Junctions keep the
assets in place; nothing is copied or redistributed, and an existing path is
never replaced. Use -NoAuxiliaryLinks to skip this and accept the helper's
missing-data warnings.

Historical data and all generated qualification outputs stay outside Git.

.PARAMETER SourceCsv
The historical bid/ask CSV to qualify.

.PARAMETER DataFolder
The runtime LEAN data folder. Converted native partitions and the
marketlab-qualification artifacts are written here; it must be outside the
LEAN Git worktree (the qualifier refuses an in-repository folder because
replacing a generation removes native partitions).

.PARAMETER TimestampColumn,DateColumn,TimeColumn,BidColumn,AskColumn
Explicit source columns; otherwise the deterministic header detection of the
qualifier is used.

.PARAMETER Delimiter
Source delimiter; '\t' means tab. Default: sniffed from the first 4096 bytes.

.PARAMETER TimestampFormat
Explicit strptime format for the timestamp text.

.PARAMETER SourceTimezone
IANA timezone of timezone-naive timestamps. Required when the timestamps carry
no embedded UTC offset, and refused when they do.

.PARAMETER Symbol,Market,SecurityType
Subscription identity. This PR is qualified for XAUUSD/oanda/Cfd (the engine
fixture identity) and XAUUSD/dukascopy/Cfd (the Dukascopy/JForex source
identity with the derived always-open runtime databases); the driver refuses
any other identity instead of launching a probe for an unqualified
subscription (the Python tools remain parameterised).

.PARAMETER LeanRoot
Root of the LEAN checkout. Default: four levels above this script.

.PARAMETER PythonExe
Python executable for the offline tool (default: python on PATH).

.PARAMETER OutputRoot
Root for the LEAN run directories (default: <LeanRoot>\MarketLab\output).

.PARAMETER AuxiliaryDataSource
Runtime data folder that already contains the auxiliary databases and engine
fixtures (default: <LeanRoot>\Data). For -Market dukascopy it is also the
unchanged source the derived always-open identity databases are prepared
from; the Oanda hour fixture is neither read nor required for that identity.

.PARAMETER NoAuxiliaryLinks
Do not link auxiliary data; expect missing-data warnings from the helper.

.PARAMETER Force
Replace an existing qualification generation. A forced success invalidates the
previous `qualification-record.json` in the same transaction; a forced
requalification that fails clears the superseded expectation, record and native
partitions while publishing the new failure manifest. Only partitions listed in
the previous MarketLab manifest with a matching SHA-256 are replaced or
removed; any other native ZIP causes exit 2. Without `-Force`, an existing
generation is refused (exit 2) instead of mixed.

Exit codes:
  0  qualification record PASS (the LEAN helper completed cleanly)
  1  qualification record FAIL (or the source failed before conversion)
  2  configuration error (missing path, unusable data folder, Python failure,
     or the LEAN helper's own pre-flight refusal: LEAN was not launched)
  3  the LEAN helper reported errors or an unclean run; no qualification
     record is written. A nonzero helper exit is accepted for a record only
     when the probe deliberately reported a replay mismatch (a FAIL).

.REQUIRES Windows PowerShell 5.1 or PowerShell 7+, and the built LEAN Launcher
and replay probe (Build-Configuration note in the tools README).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceCsv,
    [Parameter(Mandatory = $true)][string]$DataFolder,
    [string]$TimestampColumn,
    [string]$DateColumn,
    [string]$TimeColumn,
    [string]$BidColumn,
    [string]$AskColumn,
    [string]$Delimiter,
    [string]$TimestampFormat,
    [string]$SourceTimezone,
    [string]$Symbol = 'XAUUSD',
    [string]$Market = 'oanda',
    [string]$SecurityType = 'Cfd',
    [string]$LeanRoot,
    [string]$PythonExe = 'python',
    [string]$OutputRoot,
    [string]$AuxiliaryDataSource,
    [switch]$NoAuxiliaryLinks,
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

$sourcePath = Resolve-RequiredPath $SourceCsv 'source CSV'
$dataRoot = Resolve-RequiredPath $DataFolder 'data folder'
$scriptCheckout = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).FullName
foreach ($checkout in @($LeanRoot, $scriptCheckout) | Select-Object -Unique) {
    if ($dataRoot.Equals($checkout, [StringComparison]::OrdinalIgnoreCase) -or
        $dataRoot.StartsWith($checkout + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Write-ErrorMessage "the data folder is inside a LEAN worktree ($checkout): qualification outputs and native partitions must stay outside the repository"
        exit 2
    }
}
$pythonPackageRoot = Join-Path $PSScriptRoot '..\python'
$pythonPackageRoot = (Resolve-Path -LiteralPath $pythonPackageRoot).Path
$helperScript = Resolve-RequiredPath (Join-Path $LeanRoot 'MarketLab\scripts\run-backtest.ps1') 'run-backtest helper'
$probeDll = Join-Path $LeanRoot 'MarketLab\tools\historical-data\probe\bin\Release\MarketLab.HistoricalDataProbe.dll'
if (-not (Test-Path -LiteralPath $probeDll)) {
    Write-ErrorMessage "replay probe not built: $probeDll (build MarketLab\tools\historical-data\probe\MarketLab.HistoricalDataProbe.csproj -c Release)"
    exit 2
}
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

if ($Symbol -ne 'XAUUSD' -or $SecurityType -ne 'Cfd' -or ($Market -ne 'oanda' -and $Market -ne 'dukascopy')) {
    Write-ErrorMessage "only the qualified XAUUSD/oanda/Cfd (engine fixture) and XAUUSD/dukascopy/Cfd (Dukascopy source) subscriptions are supported by this driver (got $Symbol/$Market/$SecurityType); run the Python tools directly for any other identity (not qualified)"
    exit 2
}

if (-not $NoAuxiliaryLinks) {
    $auxiliaryLinks = @(
        'alternative',
        'equity'
    )
    if ($Market -eq 'oanda') {
        # The Oanda fixture identity uses the engine fixture databases and its
        # hour sample. The Dukascopy identity derives its own databases and does
        # not read the Oanda hour sample: the engine requests the Dukascopy hour
        # path, which is absent and recorded as an unrelated failed request.
        $auxiliaryLinks = @(
            'market-hours',
            'symbol-properties',
            'cfd\oanda\hour'
        ) + $auxiliaryLinks
    }
    foreach ($relative in $auxiliaryLinks) {
        $target = Join-Path $dataRoot $relative
        if (Test-Path -LiteralPath $target) { continue }
        $source = Join-Path $AuxiliaryDataSource $relative
        if (-not (Test-Path -LiteralPath $source)) {
            Write-ErrorMessage "auxiliary data not found for linking: $source (pass -NoAuxiliaryLinks to skip)"
            exit 2
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
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

$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $pythonPackageRoot
try {
    if ($Market -eq 'dukascopy') {
        # The Dukascopy/JForex source has no LEAN-shipped calendar. Derive a
        # MarketLab-owned always-open runtime identity database from the engine
        # fixtures and record the provenance; never write through the junctioned
        # fixture paths above (they are not linked for this identity).
        $prepareArguments = @(
            '-m', 'marketlab_historical_data', 'prepare-identity',
            '--data-folder', $dataRoot,
            '--source-data-folder', $AuxiliaryDataSource,
            '--symbol', $Symbol, '--market', $Market, '--security-type', $SecurityType
        )
        if ($Force) { $prepareArguments += '--force' }
        Write-Host "prepare identity: $PythonExe $($prepareArguments -join ' ')"
        $prepareOutput = Invoke-External $PythonExe $prepareArguments
        $prepareExit = $script:externalExitCode
        Write-Host $prepareOutput
        if ($prepareExit -ne 0) {
            Write-ErrorMessage "the runtime identity could not be prepared (exit $prepareExit); LEAN was not run"
            exit 2
        }
    }

    $qualifyArguments = @('-m', 'marketlab_historical_data', 'qualify', '--source', $sourcePath, '--data-folder', $dataRoot)
    if ($TimestampColumn) { $qualifyArguments += @('--timestamp-column', $TimestampColumn) }
    if ($DateColumn) { $qualifyArguments += @('--date-column', $DateColumn) }
    if ($TimeColumn) { $qualifyArguments += @('--time-column', $TimeColumn) }
    if ($BidColumn) { $qualifyArguments += @('--bid-column', $BidColumn) }
    if ($AskColumn) { $qualifyArguments += @('--ask-column', $AskColumn) }
    if ($Delimiter) { $qualifyArguments += @('--delimiter', $Delimiter) }
    if ($TimestampFormat) { $qualifyArguments += @('--timestamp-format', $TimestampFormat) }
    if ($SourceTimezone) { $qualifyArguments += @('--source-timezone', $SourceTimezone) }
    $qualifyArguments += @('--symbol', $Symbol, '--market', $Market, '--security-type', $SecurityType)
    if ($Force) { $qualifyArguments += '--force' }

    Write-Host "qualify: $PythonExe $($qualifyArguments -join ' ')"
    $qualifyOutput = Invoke-External $PythonExe $qualifyArguments
    $qualifyExit = $script:externalExitCode
    Write-Host $qualifyOutput
    if ($qualifyExit -ne 0) {
        Write-Host "qualification driver: source qualification did not pass (exit $qualifyExit); the LEAN replay was not run"
        exit $qualifyExit
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
        Parameters        = "probe-symbol:$Symbol,probe-market:$Market,probe-security-type:$SecurityType"
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
            source = 'MarketLab driver hashes taken before the run'
            files  = $runtimeBinaryHashes
        } | ConvertTo-Json -Depth 3
        Set-Content -LiteralPath $runtimeBinariesFile -Value $runtimePayload -Encoding UTF8
    }

    $probeDeliberateFailure = $false
    if ($probeResult) {
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $probeJson = Get-Content -LiteralPath $probeResult -Raw -Encoding UTF8 | ConvertFrom-Json
            $probeDeliberateFailure = ($probeJson.completed -eq $true -and $probeJson.qualification -eq 'FAIL')
        }
        catch {
            $probeDeliberateFailure = $false
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
    }

    if ($helperExit -ne 0 -and -not ($helperExit -eq 1 -and $probeDeliberateFailure)) {
        Write-ErrorMessage "the LEAN helper exited ${helperExit} without a deliberate probe replay mismatch: the run is not clean and no qualification record was written"
        exit 3
    }

    $verifyArguments = @(
        '-m', 'marketlab_historical_data', 'verify',
        '--manifest', (Join-Path $dataRoot 'marketlab-qualification\qualification-manifest.json'),
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
        Write-Host "qualification driver: the record could not be written (exit 2)"
        exit 2
    }
    if ($helperExit -ne 0 -and $verifyExit -eq 0) {
        Write-ErrorMessage "the LEAN helper exited ${helperExit}: a PASS record cannot be accepted from an unclean run"
        exit 3
    }

    if ($verifyExit -eq 0) {
        Write-Host "qualification driver: PASS"
    }
    else {
        Write-Host "qualification driver: FAIL"
    }
    exit $verifyExit
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
