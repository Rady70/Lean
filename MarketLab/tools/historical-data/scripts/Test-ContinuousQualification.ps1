<#
.SYNOPSIS
Synthetic end-to-end test of the continuous full-history qualification driver.

.DESCRIPTION
Builds a one-month qualified native layout from the committed fixtures (no
historical data), then exercises Invoke-ContinuousQualification.ps1 on real LEAN
runs:

  pass     a new destination is created by the driver, composed and replayed;
           the continuous record is PASS and the driver exits 0
  mismatch a deliberately tampered continuous expectation makes the probe report
           a replay mismatch; the driver must produce a machine-readable FAIL
           record and exit 1, not exit 3 as an unrecorded unclean run
  replace  a forced recomposition must invalidate the previous continuous record
           before it replaces anything, so a replacement can never leave a stale
           PASS/FAIL describing a changed generation

Exit code 0 only when every assertion passes. The scratch tree lives outside the
repository and is removed at the end; auxiliary junctions are removed as links.
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [string]$PythonExe = 'python'
)

$ErrorActionPreference = 'Stop'

if (-not $LeanRoot) {
    $LeanRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
}
$LeanRoot = (Resolve-Path -LiteralPath $LeanRoot).Path
$monthDriver = Join-Path $PSScriptRoot 'Invoke-ReplayQualification.ps1'
$continuousDriver = Join-Path $PSScriptRoot 'Invoke-ContinuousQualification.ps1'
$fixtures = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\fixtures')).Path
$pythonPackageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\python')).Path

$script:passed = 0
$script:failed = 0
$script:externalExit = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) {
        $script:passed++
        Write-Host "  OK: $Message"
    }
    else {
        $script:failed++
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

function Read-Json([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
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
    $script:externalExit = $LASTEXITCODE
    return $output
}

function Remove-Junctions([string]$Root) {
    $relativeJunctions = @(
        'market-hours',
        'symbol-properties',
        'alternative',
        'equity',
        'cfd\oanda\hour'
    )
    foreach ($relative in $relativeJunctions) {
        $path = Join-Path $Root $relative
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.LinkType -eq 'Junction') {
                [System.IO.Directory]::Delete($path, $false)
            }
        }
    }
}

$scratch = Join-Path $env:TEMP ("marketlab-continuous-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$continuous = Join-Path $scratch 'continuous'
$aux = Join-Path $scratch 'aux'
$monthData = Join-Path $scratch 'months\2014_05\data'
Write-Host "Test-ContinuousQualification scratch: $scratch"

try {
    Write-Host 'setup: qualify the committed fixture as the synthetic month 2014_05'
    $raw = Join-Path $scratch 'raw'
    New-Item -ItemType Directory -Force -Path $raw | Out-Null
    $sourceCsv = Join-Path $raw 'XAUUSD_2014_05_DUKASCOPY_JFOREX_FULL.csv'
    Copy-Item -LiteralPath (Join-Path $fixtures 'session-filter-gap.csv') -Destination $sourceCsv
    New-Item -ItemType Directory -Force -Path $monthData | Out-Null
    New-Item -ItemType Directory -Force -Path $aux | Out-Null
    foreach ($relative in @('market-hours', 'symbol-properties', 'alternative', 'equity')) {
        New-Item -ItemType Junction -Path (Join-Path $aux $relative) `
            -Target (Join-Path $LeanRoot "Data\$relative") | Out-Null
    }
    $monthLog = Invoke-External 'powershell.exe' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $monthDriver,
        '-SourceCsv', $sourceCsv, '-DataFolder', $monthData, '-Market', 'dukascopy',
        '-TimestampColumn', 'timestamp', '-BidColumn', 'bid', '-AskColumn', 'ask',
        '-SourceTimezone', 'UTC', '-LeanRoot', $LeanRoot, '-PythonExe', $PythonExe,
        '-OutputRoot', (Join-Path $scratch 'output'), '-AuxiliaryDataSource', $aux
    )
    Set-Content -LiteralPath (Join-Path $scratch 'month.log') -Value $monthLog -Encoding UTF8
    Assert-True ($script:externalExit -eq 0) "the month qualification driver exits 0 (was $($script:externalExit))"
    # The full-history aggregation correctly refuses records produced from a dirty
    # checkout. This synthetic record is only a fixture for the driver test, so
    # normalize the recorded checkout state; no other field is touched.
    $monthRecordPath = Join-Path $monthData 'marketlab-qualification\qualification-record.json'
    $monthRecord = Read-Json $monthRecordPath
    $monthRecord.manifest.lean.converter_checkout.dirty = $false
    ($monthRecord | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $monthRecordPath -Encoding UTF8
    $monthRecord = Read-Json $monthRecordPath
    Assert-True ($monthRecord.overall_qualification -eq 'PASS') 'the month record is PASS'

    Write-Host 'case 1: the driver creates a new destination, composes and re-qualifies (expected PASS)'
    $passLog = Invoke-External 'powershell.exe' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $continuousDriver,
        '-MonthsRoot', (Join-Path $scratch 'months'), '-DataFolder', $continuous,
        '-ExpectedFirstMonth', '2014_05', '-ExpectedLastMonth', '2014_05',
        '-PythonExe', $PythonExe, '-OutputRoot', (Join-Path $scratch 'output')
    )
    Set-Content -LiteralPath (Join-Path $scratch 'continuous-pass.log') -Value $passLog -Encoding UTF8
    $exitPass = $script:externalExit
    Assert-True ($exitPass -eq 0) "the continuous driver exits 0 (was $exitPass)"
    Assert-True (Test-Path -LiteralPath $continuous) 'the driver created the new destination folder'
    $recordPath = Join-Path $continuous 'marketlab-qualification\continuous-qualification-record.json'
    $record = Read-Json $recordPath
    Assert-True ($record.overall_qualification -eq 'PASS') 'the continuous record is PASS'
    Assert-True ($record.helper_exit_code -eq 0) 'the record carries the clean helper exit code'
    Assert-True ($record.native_replay.lean_delivered_row_count -eq 5) 'the continuous delivery holds 5 quotes'

    Write-Host 'case 2: a destination inside the raw source is refused without being created'
    $unsafeDestination = Join-Path $raw 'accidental-child'
    $unsafeLog = Invoke-External 'powershell.exe' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $continuousDriver,
        '-MonthsRoot', (Join-Path $scratch 'months'), '-DataFolder', $unsafeDestination,
        '-ExpectedFirstMonth', '2014_05', '-ExpectedLastMonth', '2014_05',
        '-PythonExe', $PythonExe, '-OutputRoot', (Join-Path $scratch 'output')
    )
    Set-Content -LiteralPath (Join-Path $scratch 'continuous-unsafe.log') -Value $unsafeLog -Encoding UTF8
    $exitUnsafe = $script:externalExit
    Assert-True ($exitUnsafe -eq 2) "an unsafe destination is refused with exit 2 (was $exitUnsafe)"
    Assert-True (-not (Test-Path -LiteralPath $unsafeDestination)) 'the unsafe destination was not created'
    Assert-True ($unsafeLog -match 'DataFolderOverlapsInput') 'the refusal names the overlap guard'

    Write-Host 'case 3: a deliberate replay mismatch yields a recorded FAIL and exit 1 (not exit 3)'
    $expectationPath = Join-Path $continuous 'marketlab-qualification\replay-expectation.json'
    $expectation = Read-Json $expectationPath
    $firstDay = @($expectation.partitions.PSObject.Properties.Name)[0]
    $partition = $expectation.partitions.PSObject.Properties[$firstDay].Value
    $digest = [string]$partition.semantic_digest
    $partition.semantic_digest = $digest.Substring(0, $digest.Length - 1) + $(if ($digest.EndsWith('0')) { '1' } else { '0' })
    ($expectation | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $expectationPath -Encoding UTF8
    $failLog = Invoke-External 'powershell.exe' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $continuousDriver,
        '-MonthsRoot', (Join-Path $scratch 'months'), '-DataFolder', $continuous,
        '-ExpectedFirstMonth', '2014_05', '-ExpectedLastMonth', '2014_05',
        '-PythonExe', $PythonExe, '-OutputRoot', (Join-Path $scratch 'output'),
        '-SkipCompose', '-Force'
    )
    Set-Content -LiteralPath (Join-Path $scratch 'continuous-fail.log') -Value $failLog -Encoding UTF8
    $exitFail = $script:externalExit
    Assert-True ($exitFail -eq 1) "the deliberate mismatch yields exit 1, not exit 3 (was $exitFail)"
    Assert-True (Test-Path -LiteralPath $recordPath) 'the FAIL record was written'
    $failRecord = Read-Json $recordPath
    Assert-True ($failRecord.overall_qualification -eq 'FAIL') 'the written record is FAIL'
    Assert-True ($failRecord.helper_exit_code -ne 0) 'the FAIL record carries the nonzero helper exit'
    $runMatch = [regex]::Match($failLog, 'run directory:\s*(.+?);\s*log:')
    Assert-True $runMatch.Success 'the FAIL run directory is identifiable'
    if ($runMatch.Success) {
        $probeResult = Read-Json (Join-Path $runMatch.Groups[1].Value.Trim() 'storage\single-anchor-replay-probe\replay-result.json')
        Assert-True ($probeResult.completed -eq $true) 'the probe completed rather than crashed'
        Assert-True ($probeResult.qualification -eq 'FAIL') 'the probe deliberately reported the mismatch'
    }

    Write-Host 'case 4: a forced recomposition invalidates the previous record before replacing'
    $env:PYTHONPATH = $pythonPackageRoot
    $composeLog = Invoke-External $PythonExe @(
        '-m', 'marketlab_historical_data', 'compose-history',
        '--months-root', (Join-Path $scratch 'months'), '--data-folder', $continuous,
        '--expected-first-month', '2014_05', '--expected-last-month', '2014_05',
        '--source-data-folder', (Join-Path $LeanRoot 'Data'), '--force'
    )
    Set-Content -LiteralPath (Join-Path $scratch 'compose-force.log') -Value $composeLog -Encoding UTF8
    Assert-True ($script:externalExit -eq 0) "the forced recomposition exits 0 (was $($script:externalExit))"
    Assert-True (-not (Test-Path -LiteralPath $recordPath)) 'the previous record was invalidated by the forced recomposition'
    Assert-True (Test-Path -LiteralPath (Join-Path $continuous 'marketlab-qualification\continuous-composition.json')) 'the replacement composition exists'
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Junctions $aux
        Remove-Junctions $continuous
        Remove-Junctions $monthData
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Test-ContinuousQualification: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
