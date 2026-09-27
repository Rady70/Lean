<#
.SYNOPSIS
Windows-local tests for scripts\Test-SingleAnchorBaselineFailedData.ps1 on synthetic fixtures.

.DESCRIPTION
Creates a temporary synthetic data tree, contract, evidence and run directories outside the
repository and checks the classifier's expected, invalid and controlled-failure paths:

  A expected-only failed list                     -> exit 0, qualification EXPECTED
  B failed request for an existing partition      -> exit 1, unexpected-missing-qualified-partition
  C unknown failed request path                   -> exit 1, unexpected-unknown-request
  D out-of-window partition failed request        -> exit 1, unexpected-out-of-window-request
  E frozen-window absent day not requested at all -> exit 1, unexpected-unrequested-absence
  F data tree partition count no longer matches   -> exit 2, controlled failure
  G run is not the frozen baseline identity       -> exit 2, controlled failure
  H approved early termination bounds the horizon -> exit 0, absence after termination recorded
  I unrequested absence within a terminated horizon -> exit 1, unexpected-unrequested-absence
  J contract missing top-level fields             -> exit 2, controlled failure

No real market data is used and nothing outside the temporary directory is touched.

Exit code: 0 when every case behaves as expected; 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Checks = 0

function Check([string]$Description, [bool]$Condition) {
    $script:Checks++
    if ($Condition) {
        Write-Host "  PASS: $Description"
    }
    else {
        $script:Failures++
        [Console]::Error.WriteLine("  FAIL: $Description")
    }
}

$classifier = Join-Path $PSScriptRoot '..\scripts\Test-SingleAnchorBaselineFailedData.ps1'
if (-not (Test-Path -LiteralPath $classifier -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: classifier script not found at '$classifier'.")
    exit 1
}
$repoContract = Join-Path $PSScriptRoot '..\config\baseline-contract.json'
$contractData = [System.IO.File]::ReadAllText($repoContract) | ConvertFrom-Json

$root = Join-Path $env:TEMP ("marketlab-baseline-classifier-" + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $root 'data'
$tickRoot = Join-Path $dataRoot 'cfd\dukascopy\tick\xauusd'
$sessionRoot = Join-Path $dataRoot 'marketlab-sessions'
$runRoot = Join-Path $root 'run'
New-Item -ItemType Directory -Path $tickRoot -Force | Out-Null
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runRoot 'storage\single-anchor') -Force | Out-Null

$startDate = '2019-01-01'
$endDate = '2019-01-03'
$presentDays = @('20190101', '20190102')
$absentDay = '20190103'
foreach ($day in $presentDays) {
    [System.IO.File]::WriteAllText((Join-Path $tickRoot ($day + '_quote.zip')), 'synthetic')
}
$sessionMapPath = Join-Path $sessionRoot 'xauusd-sessions.json'
[System.IO.File]::WriteAllText($sessionMapPath, '{"syntheticSessionMap":true}')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $stream = [System.IO.File]::OpenRead($sessionMapPath)
    try { $mapBytes = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
}
finally { $sha.Dispose() }
$mapHash = (($mapBytes | ForEach-Object { $_.ToString('x2') }) -join '')

# Synthetic contract: same frozen values, synthetic identity/window/tree.
$contractData.qualifiedDataIdentity.dataFolder = $dataRoot
$contractData.qualifiedDataIdentity.startDate = $startDate
$contractData.qualifiedDataIdentity.endDate = $endDate
$contractData.qualifiedDataIdentity.continuousHistoryPartitionCount = $presentDays.Count
$contractData.qualifiedDataIdentity.sessionMapSha256 = $mapHash
$syntheticContractPath = Join-Path $root 'baseline-contract.json'
$contractJson = $contractData | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($syntheticContractPath, $contractJson, (New-Object System.Text.UTF8Encoding($false)))

# Synthetic evidence: one expected-absent day, no gaps.
$evidence = [ordered]@{
    replay = [ordered]@{
        source_absent_days = 1
        missing_native_partitions = 0
        source_coverage_gap_days = 0
        unrelated_failed_data_requests = 1
    }
}
$syntheticEvidencePath = Join-Path $root 'continuous-history-evidence.json'
[System.IO.File]::WriteAllText($syntheticEvidencePath, ($evidence | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

# results.json carrying the frozen parameter block.
$parameterToResult = [ordered]@{
    'single-anchor-step-percent' = 'StepPercent'
    'single-anchor-base-lot' = 'BaseLot'
    'single-anchor-normal-trade-count' = 'NormalTradeCount'
    'single-anchor-hard-be-ceiling-percent' = 'HardBreakevenCeilingPercent'
    'single-anchor-escape-enabled' = 'EscapeEnabled'
    'single-anchor-escape-profit-units' = 'EscapeProfitUnits'
    'single-anchor-escape-minimum-open-positions' = 'EscapeMinimumOpenPositions'
    'single-anchor-fixed-tp-units' = 'FixedTakeProfitUnits'
    'single-anchor-trailing-enabled' = 'TrailingEnabled'
    'single-anchor-trailing-activation-units' = 'TrailingActivationUnits'
    'single-anchor-trailing-drop-units' = 'TrailingDropUnits'
    'single-anchor-commission-buffer' = 'CommissionBuffer'
    'single-anchor-point-value-per-lot' = 'PointValuePerLot'
    'single-anchor-volume-step' = 'VolumeStep'
    'single-anchor-minimum-volume' = 'MinimumVolume'
    'single-anchor-maximum-volume' = 'MaximumVolume'
    'single-anchor-commission-per-lot' = 'CommissionPerLot'
    'single-anchor-slippage' = 'Slippage'
    'single-anchor-projected-spread' = 'ProjectedSpread'
    'single-anchor-buy-swap-per-lot-per-day' = 'BuySwapPerLotPerDay'
    'single-anchor-sell-swap-per-lot-per-day' = 'SellSwapPerLotPerDay'
}
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$frozenByName = @{}
foreach ($parameter in $contractData.parameters) { $frozenByName[[string]$parameter.name] = [string]$parameter.value }
$resultParameters = [ordered]@{}
foreach ($entry in $parameterToResult.GetEnumerator()) {
    $text = $frozenByName[$entry.Key]
    if ($text -eq 'true') { $resultParameters[$entry.Value] = $true }
    elseif ($text -eq 'false') { $resultParameters[$entry.Value] = $false }
    else { $resultParameters[$entry.Value] = [decimal]::Parse($text, $invariant) }
}
$cash = [decimal]::Parse($frozenByName['single-anchor-cash'], $invariant)
function Write-Results([string]$Market, [string]$Path, [string]$FailureKind, [string]$FailureQuoteTime) {
    $results = [ordered]@{
        symbol = 'XAUUSD'
        market = $Market
        startDate = $startDate
        endDate = $endDate
        parameters = $resultParameters
        researchAccount = [ordered]@{ InitialBalance = $cash }
        researchMargin = [ordered]@{ MarginCallActive = $false }
        sessionMap = [ordered]@{ Sha256 = $mapHash }
        failure = $null
        lastProcessedQuote = $null
    }
    if ($FailureKind) {
        $results['failure'] = [ordered]@{
            Kind = $FailureKind
            Condition = 'synthetic'
            Quote = [ordered]@{ Time = $FailureQuoteTime }
            Message = 'synthetic test failure'
        }
        $results['lastProcessedQuote'] = [ordered]@{ Time = $FailureQuoteTime }
    }
    [System.IO.File]::WriteAllText($Path, ($results | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}
function Write-FailedRequests([string]$RunDirectory, [string[]]$Lines) {
    $failedPath = Join-Path $RunDirectory 'failed-data-requests-20190101000000000.txt'
    [System.IO.File]::WriteAllLines($failedPath, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}
function New-Case([string]$Name) {
    $caseDir = Join-Path $runRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $caseDir 'storage\single-anchor') -Force | Out-Null
    Write-Results 'dukascopy' (Join-Path $caseDir 'storage\single-anchor\results.json')
    return $caseDir
}
function Invoke-Classifier([string]$CaseDirectory, [string]$ContractOverride) {
    $recordPath = Join-Path $CaseDirectory 'classification.json'
    & powershell -NoProfile -File $classifier -RunDirectory $CaseDirectory -Contract $ContractOverride -Evidence $syntheticEvidencePath -DataFolder $dataRoot -OutputPath $recordPath | Out-Null
    $code = $LASTEXITCODE
    $record = $null
    if (Test-Path -LiteralPath $recordPath) {
        $record = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    }
    return [pscustomobject]@{ Code = $code; Record = $record }
}

try {
    Write-Host 'Case A: expected-only failed list'
    $caseA = New-Case 'case-a'
    Write-FailedRequests $caseA @(
        ('\cfd\dukascopy\tick\xauusd\' + $absentDay + '_quote.zip'),
        '\cfd\dukascopy\hour\xauusd.zip'
    )
    $resultA = Invoke-Classifier $caseA $syntheticContractPath
    Check 'exit 0' ($resultA.Code -eq 0)
    Check 'qualification EXPECTED' ($resultA.Record.qualification -eq 'EXPECTED')
    Check 'one expected absent day' ($resultA.Record.countsByCategory.'expected-source-absent-calendar-day' -eq 1)
    Check 'one known auxiliary' ($resultA.Record.countsByCategory.'known-non-strategy-auxiliary-request' -eq 1)

    Write-Host 'Case B: failed request for an existing qualified partition'
    $caseB = New-Case 'case-b'
    Write-FailedRequests $caseB @('\cfd\dukascopy\tick\xauusd\20190101_quote.zip')
    $resultB = Invoke-Classifier $caseB $syntheticContractPath
    Check 'exit 1' ($resultB.Code -eq 1)
    Check 'qualification INVALID' ($resultB.Record.qualification -eq 'INVALID')
    Check 'missing qualified partition classified' ($resultB.Record.countsByCategory.'unexpected-missing-qualified-partition' -eq 1)

    Write-Host 'Case C: unknown failed request path'
    $caseC = New-Case 'case-c'
    Write-FailedRequests $caseC @('\equity\usa\minute\spy\20131009_trade.zip')
    $resultC = Invoke-Classifier $caseC $syntheticContractPath
    Check 'exit 1' ($resultC.Code -eq 1)
    Check 'unknown request classified' ($resultC.Record.countsByCategory.'unexpected-unknown-request' -eq 1)

    Write-Host 'Case D: out-of-window partition failed request'
    $caseD = New-Case 'case-d'
    Write-FailedRequests $caseD @('\cfd\dukascopy\tick\xauusd\20190104_quote.zip')
    $resultD = Invoke-Classifier $caseD $syntheticContractPath
    Check 'exit 1' ($resultD.Code -eq 1)
    Check 'out-of-window request classified' ($resultD.Record.countsByCategory.'unexpected-out-of-window-request' -eq 1)

    Write-Host 'Case E: frozen-window absent day not requested at all'
    $caseE = New-Case 'case-e'
    Write-FailedRequests $caseE @('\cfd\dukascopy\hour\xauusd.zip')
    $resultE = Invoke-Classifier $caseE $syntheticContractPath
    Check 'exit 1' ($resultE.Code -eq 1)
    Check 'unrequested absence classified' ($resultE.Record.countsByCategory.'unexpected-unrequested-absence' -eq 1)

    Write-Host 'Case F: data tree partition count no longer matches the contract'
    $caseF = New-Case 'case-f'
    Write-FailedRequests $caseF @('\cfd\dukascopy\hour\xauusd.zip')
    $driftedContract = [System.IO.File]::ReadAllText($syntheticContractPath) | ConvertFrom-Json
    $driftedContract.qualifiedDataIdentity.continuousHistoryPartitionCount = 7
    $driftedContractPath = Join-Path $root 'baseline-contract-drifted.json'
    [System.IO.File]::WriteAllText($driftedContractPath, ($driftedContract | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $resultF = Invoke-Classifier $caseF $driftedContractPath
    Check 'exit 2' ($resultF.Code -eq 2)
    Check 'controlled failure recorded' ($resultF.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case G: run is not the frozen baseline identity'
    $caseG = Join-Path $runRoot 'case-g'
    New-Item -ItemType Directory -Path (Join-Path $caseG 'storage\single-anchor') -Force | Out-Null
    Write-Results 'oanda' (Join-Path $caseG 'storage\single-anchor\results.json')
    Write-FailedRequests $caseG @('\cfd\dukascopy\hour\xauusd.zip')
    $resultG = Invoke-Classifier $caseG $syntheticContractPath
    Check 'exit 2' ($resultG.Code -eq 2)
    Check 'controlled failure recorded' ($resultG.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case H: approved early termination bounds the expected-absence horizon'
    $caseH = Join-Path $runRoot 'case-h'
    New-Item -ItemType Directory -Path (Join-Path $caseH 'storage\single-anchor') -Force | Out-Null
    Write-Results 'dukascopy' (Join-Path $caseH 'storage\single-anchor\results.json') 'AccountStopOut' '2019-01-01T12:00:00'
    Write-FailedRequests $caseH @('\cfd\dukascopy\hour\xauusd.zip')
    $resultH = Invoke-Classifier $caseH $syntheticContractPath
    Check 'exit 0' ($resultH.Code -eq 0)
    Check 'qualification EXPECTED' ($resultH.Record.qualification -eq 'EXPECTED')
    Check 'run marked terminated' ($resultH.Record.runTerminated -eq $true)
    Check 'termination kind recorded' ($resultH.Record.terminationKind -eq 'AccountStopOut')
    Check 'coverage horizon is the failure day' ($resultH.Record.coverageEndDay -eq '2019-01-01')
    Check 'absence after termination recorded, not invalid' ($resultH.Record.sourceAbsentDaysAfterTermination -eq 1)
    Check 'no unrequested absence within the horizon' ($resultH.Record.countsByCategory.'unexpected-unrequested-absence' -eq 0)

    Write-Host 'Case I: unrequested absence within a terminated run horizon is still invalid'
    $caseI = Join-Path $runRoot 'case-i'
    New-Item -ItemType Directory -Path (Join-Path $caseI 'storage\single-anchor') -Force | Out-Null
    Write-Results 'dukascopy' (Join-Path $caseI 'storage\single-anchor\results.json') 'StrategyInvariant' '2019-01-03T12:00:00'
    Write-FailedRequests $caseI @('\cfd\dukascopy\hour\xauusd.zip')
    $resultI = Invoke-Classifier $caseI $syntheticContractPath
    Check 'exit 1' ($resultI.Code -eq 1)
    Check 'unrequested absence within horizon classified' ($resultI.Record.countsByCategory.'unexpected-unrequested-absence' -eq 1)

    Write-Host 'Case J: a contract missing top-level fields is a controlled failure'
    $caseJ = New-Case 'case-j'
    Write-FailedRequests $caseJ @('\cfd\dukascopy\hour\xauusd.zip')
    $malformedPath = Join-Path $root 'malformed-contract.json'
    [System.IO.File]::WriteAllText($malformedPath, '{}', (New-Object System.Text.UTF8Encoding($false)))
    $resultJ = Invoke-Classifier $caseJ $malformedPath
    Check 'exit 2' ($resultJ.Code -eq 2)
    Check 'controlled failure recorded' ($resultJ.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Invocation reporter: expected-only case record binds the synthetic contract identity'
    Check 'record carries a contract sha' (-not [string]::IsNullOrWhiteSpace($resultA.Record.baselineContractSha256))
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Write-Host "baseline classifier tests: $($script:Checks - $script:Failures)/$($script:Checks) passed"
if ($script:Failures -gt 0) {
    [Console]::Error.WriteLine("ERROR: $($script:Failures) check(s) failed.")
    exit 1
}
exit 0
