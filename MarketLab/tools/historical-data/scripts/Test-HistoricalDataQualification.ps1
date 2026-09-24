<#
.SYNOPSIS
End-to-end test of the PR 1 historical-data qualification path on committed
fixtures: strict CSV qualification, native LEAN conversion, the actual LEAN
replay probe, and the final PASS/FAIL record.

.DESCRIPTION
Creates a temporary research data folder outside the repository for every case,
runs MarketLab\tools\historical-data\scripts\Invoke-ReplayQualification.ps1, and
asserts the observable outcome:

  replay-pass          strict PASS: accepted = converted = LEAN-delivered,
                       equal semantic digests, zero session difference
  dukascopy-identity   the same session-gap source under the derived
                       always-open Dukascopy identity: PASS with every quote
                       delivered (the Oanda fixture identity filters one)
  session-filter-gap   LEAN session filtering removes one accepted quote under
                       the Oanda fixture identity: the record must FAIL with a
                       delivery difference
  sub-millisecond      meaningful sub-millisecond source precision:
                       qualification FAIL before any native file exists
  crossed-quote        a crossed quote: strict source qualification FAIL,
                       no cleaning, no conversion
  unsupported-identity a non-qualified subscription identity is refused
                       (exit 2) before any Python or LEAN work
  in-worktree folder   a data folder inside the checkout is refused (exit 2)

Requires the built LEAN Launcher (MarketLab\scripts\build.ps1) and the built
replay probe. The auxiliary runtime data paths are linked by the driver from
<LeanRoot>\Data; the cleanup removes junctions as links (never recursing into
their targets) before deleting the scratch directory.

Exit code 0 only when every assertion passes.
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [string]$PythonExe = 'python',
    [switch]$KeepScratch
)

$ErrorActionPreference = 'Stop'

if (-not $LeanRoot) {
    $LeanRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
}
$LeanRoot = (Resolve-Path -LiteralPath $LeanRoot).Path
$driver = Join-Path $PSScriptRoot 'Invoke-ReplayQualification.ps1'
$fixtures = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\fixtures')).Path

$script:passed = 0
$script:failed = 0

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

function Invoke-Driver([string]$Driver, [hashtable]$Parameters) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Driver)
    foreach ($key in $Parameters.Keys) {
        $arguments += "-$key"
        $arguments += [string]$Parameters[$key]
    }
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& powershell.exe @arguments 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $script:driverExit = $LASTEXITCODE
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

$scratch = Join-Path $env:TEMP ("marketlab-historical-data-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$dataPass = $null
$dataDukascopy = $null
$dataGap = $null
$dataPrecision = $null
$dataCrossed = $null
$dataUnsupported = $null
Write-Host "Test-HistoricalDataQualification scratch: $scratch"

try {
    Write-Host 'case 1: replay-pass (expected PASS)'
    $dataPass = Join-Path $scratch 'case-pass'
    New-Item -ItemType Directory -Force -Path $dataPass | Out-Null
    $passLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'replay-pass.csv'
        DataFolder = $dataPass
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-pass.log') -Value $passLog -Encoding UTF8
    $exitPass = $script:driverExit
    Assert-True ($exitPass -eq 0) "driver exit code is 0 (was $exitPass)"
    $recordPass = Read-Json (Join-Path $dataPass 'marketlab-qualification\qualification-record.json')
    Assert-True ($recordPass.overall_qualification -eq 'PASS') 'overall qualification is PASS'
    Assert-True ($recordPass.native_replay.accepted_row_count -eq 5) 'accepted row count is 5'
    Assert-True ($recordPass.native_replay.converted_row_count -eq 5) 'converted row count is 5'
    Assert-True ($recordPass.native_replay.lean_delivered_row_count -eq 5) 'LEAN-delivered row count is 5'
    Assert-True ($recordPass.native_replay.session_delivery_difference -eq 0) 'session/delivery difference is 0'
    Assert-True ($recordPass.native_replay.ordered_source_semantic_digest -eq $recordPass.native_replay.ordered_lean_delivered_semantic_digest) 'source and delivered semantic digests are equal'
    Assert-True ($recordPass.native_replay.ordered_source_semantic_digest -eq 'sha256:b133c1366422e3b4e975e176c44b726edc20bee8c5a5e9054b00a816266c69d9') 'semantic digest matches the committed fixture vector (including the round price)'
    $manifestPass = $recordPass.manifest
    Assert-True ($manifestPass.qualification.source_qualification -eq 'PASS') 'source qualification is PASS'
    Assert-True ($manifestPass.qualification.native_lean_timestamp_parity -eq 'PASS') 'native timestamp parity is PASS'
    Assert-True ($manifestPass.counts.duplicate_timestamp_count -eq 1) 'duplicate timestamp is preserved and counted'
    Assert-True ($manifestPass.counts.maximum_rows_per_lean_millisecond -eq 2) 'two rows share one LEAN millisecond'
    Assert-True ($manifestPass.session_preview.session_excluded_rows -eq 0) 'offline session preview excludes no accepted row'
    Assert-True ($recordPass.probe.completed -eq $true) 'probe completed'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataPass 'cfd\oanda\tick\xauusd\20140505_quote.zip')) 'native partition 20140505 exists'
    Assert-True ($recordPass.probe.runtime.market_hours_database_sha256.Length -eq 64) 'probe recorded the runtime market-hours database SHA-256'
    $runtimeBinaryNames = @($recordPass.runtime_binaries.files.PSObject.Properties.Name)
    Assert-True ($runtimeBinaryNames -contains 'MarketLab.HistoricalDataProbe.dll') 'runtime binaries include the probe assembly'
    Assert-True ($runtimeBinaryNames -contains 'QuantConnect.Lean.Engine.dll') 'runtime binaries include the LEAN Engine assembly'
    Assert-True ($runtimeBinaryNames -contains 'QuantConnect.Lean.Launcher.dll') 'runtime binaries include the Launcher assembly'
    Assert-True ($recordPass.helper_exit_code -eq 0) 'the record carries the clean helper exit code 0'

    Write-Host 'case 2: dukascopy identity resolves the same source with no session filter (expected PASS)'
    $dataDukascopy = Join-Path $scratch 'case-dukascopy'
    New-Item -ItemType Directory -Force -Path $dataDukascopy | Out-Null
    $dukascopyLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'session-filter-gap.csv'
        DataFolder = $dataDukascopy
        Market = 'dukascopy'
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-dukascopy.log') -Value $dukascopyLog -Encoding UTF8
    $exitDukascopy = $script:driverExit
    Assert-True ($exitDukascopy -eq 0) "driver exit code is 0 (was $exitDukascopy)"
    Assert-True ($dukascopyLog -match 'prepare identity:') 'driver prepared the derived runtime identity'
    $recordDukascopy = Read-Json (Join-Path $dataDukascopy 'marketlab-qualification\qualification-record.json')
    Assert-True ($recordDukascopy.overall_qualification -eq 'PASS') 'dukascopy overall qualification is PASS'
    Assert-True ($recordDukascopy.manifest.lean.market -eq 'dukascopy') 'manifest identity is dukascopy'
    Assert-True ($recordDukascopy.manifest.lean.market_hours_database.always_open -eq $true) 'resolved entry is always open'
    Assert-True ($recordDukascopy.manifest.lean.runtime_identity.contract -eq 'marketlab-runtime-identity-v1') 'runtime identity provenance is recorded'
    Assert-True ($recordDukascopy.manifest.lean.runtime_identity.derived_market_hours_database.sha256 -eq $recordDukascopy.manifest.lean.market_hours_database.database_sha256) 'recorded provenance hash matches the resolved database'
    Assert-True ($recordDukascopy.native_replay.accepted_row_count -eq 5) 'dukascopy accepted row count is 5'
    Assert-True ($recordDukascopy.native_replay.lean_delivered_row_count -eq 5) 'dukascopy delivered all 5 accepted rows'
    Assert-True ($recordDukascopy.native_replay.session_delivery_difference -eq 0) 'dukascopy session/delivery difference is 0'
    Assert-True ($recordDukascopy.native_replay.ordered_source_semantic_digest -eq $recordDukascopy.native_replay.ordered_lean_delivered_semantic_digest) 'dukascopy source and delivered semantic digests are equal'
    Assert-True ($recordDukascopy.manifest.session_preview.session_excluded_rows -eq 0) 'dukascopy offline session preview excludes no accepted row'
    Assert-True (Test-Path -LiteralPath (Join-Path $dataDukascopy 'cfd\dukascopy\tick\xauusd\20140505_quote.zip')) 'dukascopy native partition exists under cfd\dukascopy'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataDukascopy 'cfd\oanda\tick\xauusd'))) 'no Oanda-path partition was written for the Dukascopy identity'

    $dukascopyForceLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'session-filter-gap.csv'
        DataFolder = $dataDukascopy
        Market = 'dukascopy'
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
        Force = $true
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-dukascopy-force.log') -Value $dukascopyForceLog -Encoding UTF8
    Assert-True ($script:driverExit -eq 0) "forced dukascopy rerun exit code is 0 (was $($script:driverExit))"
    $recordDukascopyForce = Read-Json (Join-Path $dataDukascopy 'marketlab-qualification\qualification-record.json')
    Assert-True ($recordDukascopyForce.overall_qualification -eq 'PASS') 'forced dukascopy rerun is still PASS'
    Assert-True ($recordDukascopyForce.native_replay.lean_delivered_row_count -eq 5) 'forced dukascopy rerun still delivers all 5 quote rows'

    Write-Host 'case 3: session-filter-gap under the Oanda fixture identity (expected FAIL with a delivery difference)'
    $dataGap = Join-Path $scratch 'case-gap'
    New-Item -ItemType Directory -Force -Path $dataGap | Out-Null
    $gapLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'session-filter-gap.csv'
        DataFolder = $dataGap
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-gap.log') -Value $gapLog -Encoding UTF8
    $exitGap = $script:driverExit
    Assert-True ($exitGap -eq 1) "driver exit code is 1 (was $exitGap)"
    $recordGap = Read-Json (Join-Path $dataGap 'marketlab-qualification\qualification-record.json')
    Assert-True ($recordGap.overall_qualification -eq 'FAIL') 'overall qualification is FAIL'
    Assert-True ($recordGap.native_replay.accepted_row_count -eq 5) 'accepted row count is 5'
    Assert-True ($recordGap.native_replay.lean_delivered_row_count -eq 4) 'LEAN delivered 4 of 5 accepted rows'
    Assert-True ($recordGap.native_replay.session_delivery_difference -eq 1) 'session/delivery difference is 1'
    Assert-True ($recordGap.helper_exit_code -eq 1) 'the record carries the deliberate probe-mismatch helper exit code 1'
    Assert-True ($recordGap.manifest.session_preview.session_excluded_rows -eq 1) 'offline session preview identifies the excluded row'
    Assert-True ($recordGap.failure_reasons -contains 'LeanDeliveredCountDiffersFromAcceptedCount') 'failure reasons name the delivered-count difference'
    Assert-True (@($recordGap.failure_reasons) -join ',' -match 'ExpectedAndDeliveredCountsDiffer|DeliveredSemanticDigestMismatches') 'failure reasons name the probe mismatch'

    Write-Host 'case 4: sub-millisecond (expected strict FAIL before conversion)'
    $dataPrecision = Join-Path $scratch 'case-precision'
    New-Item -ItemType Directory -Force -Path $dataPrecision | Out-Null
    $precisionLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'sub-millisecond.csv'
        DataFolder = $dataPrecision
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-precision.log') -Value $precisionLog -Encoding UTF8
    $exitPrecision = $script:driverExit
    Assert-True ($exitPrecision -eq 1) "driver exit code is 1 (was $exitPrecision)"
    $manifestPrecision = Read-Json (Join-Path $dataPrecision 'marketlab-qualification\qualification-manifest.json')
    Assert-True ($manifestPrecision.qualification.native_lean_timestamp_parity -eq 'FAIL') 'native timestamp parity is FAIL'
    Assert-True ($manifestPrecision.qualification.failure_reasons -contains 'SourcePrecisionExceedsLeanTickFormat') 'failure reason is SourcePrecisionExceedsLeanTickFormat'
    Assert-True ($manifestPrecision.counts.sub_millisecond_row_count -eq 1) 'sub-millisecond row count is 1'
    Assert-True ($manifestPrecision.qualification.native_conversion -eq 'NOT_RUN') 'conversion did not run'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataPrecision 'cfd\oanda\tick\xauusd')) -or @(Get-ChildItem -LiteralPath (Join-Path $dataPrecision 'cfd\oanda\tick\xauusd') -Filter '*_quote.zip' -ErrorAction SilentlyContinue).Count -eq 0) 'no native partition was written'

    Write-Host 'case 5: crossed-quote (expected strict source FAIL, no cleaning)'
    $dataCrossed = Join-Path $scratch 'case-crossed'
    New-Item -ItemType Directory -Force -Path $dataCrossed | Out-Null
    $crossedLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'crossed-quote.csv'
        DataFolder = $dataCrossed
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-crossed.log') -Value $crossedLog -Encoding UTF8
    $exitCrossed = $script:driverExit
    Assert-True ($exitCrossed -eq 1) "driver exit code is 1 (was $exitCrossed)"
    $manifestCrossed = Read-Json (Join-Path $dataCrossed 'marketlab-qualification\qualification-manifest.json')
    Assert-True ($manifestCrossed.qualification.source_qualification -eq 'FAIL') 'source qualification is FAIL'
    Assert-True ($manifestCrossed.counts.rejected_row_count -eq 1) 'exactly one rejected row'
    Assert-True ($manifestCrossed.counts.rejected_row_reasons.ask_less_than_bid -eq 1) 'rejection reason is ask_less_than_bid'
    Assert-True ($manifestCrossed.counts.converted_row_count -eq 0) 'nothing was converted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataCrossed 'cfd\oanda\tick\xauusd')) -or @(Get-ChildItem -LiteralPath (Join-Path $dataCrossed 'cfd\oanda\tick\xauusd') -Filter '*_quote.zip' -ErrorAction SilentlyContinue).Count -eq 0) 'no native partition was written'

    Write-Host 'case 6: unsupported identity (expected exit 2 before any Python or LEAN work)'
    $dataUnsupported = Join-Path $scratch 'case-unsupported'
    New-Item -ItemType Directory -Force -Path $dataUnsupported | Out-Null
    $unsupportedLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'replay-pass.csv'
        DataFolder = $dataUnsupported
        Market = 'fxcm'
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-unsupported.log') -Value $unsupportedLog -Encoding UTF8
    $exitUnsupported = $script:driverExit
    Assert-True ($exitUnsupported -eq 2) "driver exit code is 2 for an unsupported identity (was $exitUnsupported)"
    Assert-True ($unsupportedLog -match 'only the qualified') 'driver names the qualified identity scope'
    Assert-True (@(Get-ChildItem -LiteralPath $dataUnsupported -ErrorAction SilentlyContinue).Count -eq 0) 'the refused identity wrote nothing into the data folder'

    Write-Host 'case 7: data folder inside the LEAN worktree (expected exit 2 before any junction)'
    $worktreeFolder = Join-Path $LeanRoot 'MarketLab'
    $worktreeLog = Invoke-Driver $driver @{
        SourceCsv = Join-Path $fixtures 'replay-pass.csv'
        DataFolder = $worktreeFolder
        TimestampColumn = 'timestamp'
        BidColumn = 'bid'
        AskColumn = 'ask'
        SourceTimezone = 'UTC'
        LeanRoot = $LeanRoot
        PythonExe = $PythonExe
        OutputRoot = Join-Path $scratch 'output'
    }
    Set-Content -LiteralPath (Join-Path $scratch 'case-worktree.log') -Value $worktreeLog -Encoding UTF8
    $exitWorktree = $script:driverExit
    Assert-True ($exitWorktree -eq 2) "driver exit code is 2 for an in-worktree data folder (was $exitWorktree)"
    Assert-True ($worktreeLog -match 'inside a LEAN worktree') 'driver names the worktree refusal'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $worktreeFolder 'market-hours'))) 'no auxiliary junction was created inside the worktree'
}
finally {
    if ($KeepScratch) {
        Write-Host "kept scratch: $scratch"
    }
    else {
        foreach ($caseDirectory in @($dataPass, $dataDukascopy, $dataGap, $dataPrecision, $dataCrossed, $dataUnsupported)) {
            if ($caseDirectory) { Remove-Junctions $caseDirectory }
        }
        Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue
    }
}

Write-Host "Test-HistoricalDataQualification: $script:passed passed, $script:failed failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
