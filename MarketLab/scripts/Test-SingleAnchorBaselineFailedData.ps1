<#
.SYNOPSIS
Classifies every failed data request of a SingleAnchor baseline run against the frozen
baseline contract and the qualified continuous-history tree.

.DESCRIPTION
The approved baseline procedure runs the helper with -AllowMissingData, which merely
downgrades failed local data requests to a warning. This script performs the missing
audit step: it reads the run's failed-data-requests-*.txt, rebuilds the expected
source absence from the qualified continuous tree itself (calendar days inside the
frozen window whose YYYYMMDD_quote.zip partition does not exist), and classifies every
distinct failed request as:

  expected-source-absent-calendar-day     accepted: an always-open calendar day the qualified tree does not contain
  known-non-strategy-auxiliary-request    accepted: only the enumerated benchmark hour path, recorded explicitly
  recorded-absence-after-terminated-horizon
                                          accepted and recorded: a source-absent day after the actually processed
                                          horizon of a run ended by an approved run-ending condition (for example
                                          terminal stop-out); it was never requested because the run ended
  unexpected-missing-qualified-partition  INVALID: a failed request for a partition carrying qualified rows
  unexpected-out-of-window-request        INVALID: a failed XAUUSD/dukascopy partition request outside the window
  unexpected-unknown-request              INVALID: any other failed request path
  unexpected-unrequested-absence          INVALID: a source-absent day within the run's processed horizon that was not requested at all

It also verifies that the run is the frozen baseline run: the run's results file
(storage\single-anchor\results.json) must carry the contract's symbol, market, period,
research account, margin mode, session map and every mapped strategy parameter. A run
that is not the frozen baseline, or a data tree whose identity no longer matches the
contract, fails as a controlled configuration failure (exit 2) instead of being
classified.

The classification record is written as JSON next to the run
(baseline-failed-data-classification.json by default) and includes the baseline
contract identity (LF-normalized SHA-256), so the audit binds the run to the contract.

This script launches nothing: no LEAN, no build, no network. It reads the run
directory, the contract, the tracked evidence and the data tree.

Exit codes:
  0  every failed request is expected; the baseline run's failed-data behavior is compatible with the qualified coverage
  1  at least one unexpected failed request: the baseline run is INVALID
  2  controlled configuration failure: missing/invalid inputs, a run that is not the frozen baseline, or a data tree that no longer matches the contract identity

.PARAMETER RunDirectory
The run directory produced by run-backtest.ps1 (contains failed-data-requests-*.txt and storage\single-anchor\results.json).

.PARAMETER Contract
Path to the frozen baseline contract. Default: <script root>\..\config\baseline-contract.json.

.PARAMETER Evidence
Path to the tracked continuous-history evidence. Default: <contract directory>\..\tools\historical-data\fixtures\continuous-history-evidence.json.

.PARAMETER DataFolder
Override the qualified data folder. Default: the contract's qualifiedDataIdentity.dataFolder. The authoritative audit uses the default.

.PARAMETER OutputPath
Where to write the classification record. Default: <RunDirectory>\baseline-failed-data-classification.json.

.EXAMPLE
pwsh -File MarketLab\scripts\Test-SingleAnchorBaselineFailedData.ps1 -RunDirectory MarketLab\output\20260926-002240-SingleAnchorVNextAlgorithm
Classifies the run's failed data requests and writes baseline-failed-data-classification.json into the run directory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDirectory,
    [string]$Contract,
    [string]$Evidence,
    [string]$DataFolder,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ExitExpected = 0
$script:ExitInvalid = 1
$script:ExitPreflight = 2

function Write-ErrorLine([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Write-WarningLine([string]$Message) {
    [Console]::Error.WriteLine("WARNING: $Message")
}

function Get-PropertyOrNull($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-RequiredProperty($Object, [string]$Name) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        throw "missing required property '$Name'"
    }
    return $Object.$Name
}

function Get-LfNormalizedSha256([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Fail-Preflight([string]$Message, [string]$OutputPath) {
    Write-ErrorLine $Message
    if ($OutputPath) {
        $record = [ordered]@{
            contract = 'marketlab-single-anchor-baseline-failed-data-classification-v1'
            generatedUtc = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            runDirectory = $RunDirectory
            qualification = 'CONTROLLED_FAILURE'
            failure = $Message
        }
        try {
            $json = $record | ConvertTo-Json -Depth 4
            [System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-WarningLine "could not write the classification record to '$OutputPath': $($_.Exception.Message)"
        }
    }
    exit $script:ExitPreflight
}

if ([string]::IsNullOrWhiteSpace($Contract)) {
    $Contract = Join-Path $PSScriptRoot '..\config\baseline-contract.json'
}
$contractPath = [System.IO.Path]::GetFullPath($Contract)
if ([string]::IsNullOrWhiteSpace($Evidence)) {
    $Evidence = Join-Path (Split-Path -Parent $contractPath) '..\tools\historical-data\fixtures\continuous-history-evidence.json'
}
$evidencePath = [System.IO.Path]::GetFullPath($Evidence)
$runPath = [System.IO.Path]::GetFullPath($RunDirectory)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $runPath 'baseline-failed-data-classification.json'
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)

# --- Contract and evidence -----------------------------------------------------
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    Fail-Preflight "the baseline contract '$contractPath' does not exist." $outputFullPath
}
try {
    $contractData = [System.IO.File]::ReadAllText($contractPath) | ConvertFrom-Json
}
catch {
    Fail-Preflight "the baseline contract is not valid JSON: $($_.Exception.Message)" $outputFullPath
}
try {
    $contractId = Get-RequiredProperty $contractData 'contract'
    $contractStatus = Get-RequiredProperty $contractData 'status'
    $contractImmutable = Get-RequiredProperty $contractData 'immutable'
}
catch {
    Fail-Preflight "the baseline contract is incomplete: $($_.Exception.Message)" $outputFullPath
}
if ($contractId -ne 'marketlab-single-anchor-baseline-contract-v1' `
    -or $contractStatus -ne 'frozen' `
    -or -not $contractImmutable) {
    Fail-Preflight 'the contract is not the frozen immutable baseline contract.' $outputFullPath
}
$contractSha256 = Get-LfNormalizedSha256 $contractPath

if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    Fail-Preflight "the tracked continuous-history evidence '$evidencePath' does not exist." $outputFullPath
}
try {
    $evidenceData = [System.IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json
}
catch {
    Fail-Preflight "the continuous-history evidence is not valid JSON: $($_.Exception.Message)" $outputFullPath
}

try {
    $dataIdentity = Get-RequiredProperty $contractData 'qualifiedDataIdentity'
    $policy = Get-RequiredProperty $contractData 'failedDataRequestPolicy'
    $resolvedDataFolder = if ([string]::IsNullOrWhiteSpace($DataFolder)) {
        [string](Get-RequiredProperty $dataIdentity 'dataFolder')
    }
    else {
        [System.IO.Path]::GetFullPath($DataFolder)
    }
    $dataFolderSource = if ([string]::IsNullOrWhiteSpace($DataFolder)) { 'contract' } else { 'override' }
    $symbol = [string](Get-RequiredProperty $dataIdentity 'symbol')
    $market = [string](Get-RequiredProperty $dataIdentity 'market')
    $startText = [string](Get-RequiredProperty $dataIdentity 'startDate')
    $endText = [string](Get-RequiredProperty $dataIdentity 'endDate')
    $sessionMapRelative = [string](Get-RequiredProperty $dataIdentity 'sessionMapPath')
    $sessionMapSha256 = [string](Get-RequiredProperty $dataIdentity 'sessionMapSha256')
    $partitionCount = [int](Get-RequiredProperty $dataIdentity 'continuousHistoryPartitionCount')
    $knownAuxiliary = @(Get-RequiredProperty $policy 'knownAuxiliaryRequestPaths')
}
catch {
    Fail-Preflight "the contract identity/policy block is incomplete: $($_.Exception.Message)" $outputFullPath
}

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
try {
    $startDate = [System.DateTime]::ParseExact($startText, 'yyyy-MM-dd', $invariant)
    $endDate = [System.DateTime]::ParseExact($endText, 'yyyy-MM-dd', $invariant)
}
catch {
    Fail-Preflight "the contract window '$startText'..'$endText' is not parseable: $($_.Exception.Message)" $outputFullPath
}

# --- Qualified data tree identity ---------------------------------------------
$tickDirectory = Join-Path (Join-Path (Join-Path (Join-Path $resolvedDataFolder 'cfd') $market) 'tick') $symbol.ToLowerInvariant()
if (-not (Test-Path -LiteralPath $tickDirectory -PathType Container)) {
    Fail-Preflight "the qualified tick directory '$tickDirectory' does not exist; the data identity cannot be established." $outputFullPath
}
$partitionFiles = @(Get-ChildItem -LiteralPath $tickDirectory -Filter '*_quote.zip' -File -ErrorAction Stop)
$actualPartitionCount = $partitionFiles.Count
if ($actualPartitionCount -ne $partitionCount) {
    Fail-Preflight "the data tree carries $actualPartitionCount quote partitions but the contract binds $partitionCount; the qualified data identity has changed." $outputFullPath
}

$sessionMapPath = Join-Path $resolvedDataFolder $sessionMapRelative
if (-not (Test-Path -LiteralPath $sessionMapPath -PathType Leaf)) {
    Fail-Preflight "the qualified session map '$sessionMapPath' does not exist." $outputFullPath
}
$actualSessionMapSha256 = Get-FileSha256 $sessionMapPath
if ($actualSessionMapSha256 -ne $sessionMapSha256) {
    Fail-Preflight "the session map at '$sessionMapPath' hashes to $actualSessionMapSha256 but the contract binds $sessionMapSha256; the qualified identity has changed." $outputFullPath
}

try {
    $replay = Get-RequiredProperty $evidenceData 'replay'
    $evidenceAbsentDays = [int](Get-RequiredProperty $replay 'source_absent_days')
    $evidenceMissingPartitions = [int](Get-RequiredProperty $replay 'missing_native_partitions')
    $evidenceCoverageGaps = [int](Get-RequiredProperty $replay 'source_coverage_gap_days')
    $evidenceUnrelated = [int](Get-RequiredProperty $replay 'unrelated_failed_data_requests')
}
catch {
    Fail-Preflight "the continuous-history evidence replay block is incomplete: $($_.Exception.Message)" $outputFullPath
}

$presentPartitions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$expectedAbsentDays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($file in $partitionFiles) { [void]$presentPartitions.Add($file.Name) }
$day = $startDate
while ($day -le $endDate) {
    $name = $day.ToString('yyyyMMdd') + '_quote.zip'
    if (-not $presentPartitions.Contains($name)) {
        [void]$expectedAbsentDays.Add($day.ToString('yyyyMMdd'))
    }
    $day = $day.AddDays(1)
}

# --- Run identity: the frozen baseline run -------------------------------------
$resultsPath = Join-Path (Join-Path (Join-Path $runPath 'storage') 'single-anchor') 'results.json'
if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) {
    Fail-Preflight "the run's strategy results '$resultsPath' do not exist; the run is not a completed SingleAnchor strategy run." $outputFullPath
}
try {
    $results = [System.IO.File]::ReadAllText($resultsPath) | ConvertFrom-Json
}
catch {
    Fail-Preflight "the run's strategy results are not valid JSON: $($_.Exception.Message)" $outputFullPath
}

$resultSymbol = [string](Get-PropertyOrNull $results 'symbol')
$resultMarket = [string](Get-PropertyOrNull $results 'market')
$resultStart = [string](Get-PropertyOrNull $results 'startDate')
$resultEnd = [string](Get-PropertyOrNull $results 'endDate')
if ($resultSymbol -ne $symbol -or $resultMarket -ne $market -or $resultStart -ne $startText -or $resultEnd -ne $endText) {
    Fail-Preflight "the run identity ($resultSymbol/$resultMarket, $resultStart..$resultEnd) is not the frozen baseline identity ($symbol/$market, $startText..$endText)." $outputFullPath
}

$contractParameterValues = @{}
$contractParameterNames = @()
try {
    $contractParameters = @(Get-RequiredProperty $contractData 'parameters')
}
catch {
    Fail-Preflight "the contract parameter block is missing: $($_.Exception.Message)" $outputFullPath
}
foreach ($parameter in $contractParameters) {
    $contractParameterNames += [string]$parameter.name
    $contractParameterValues[[string]$parameter.name] = [string]$parameter.value
}

$resultParameterMap = [ordered]@{
    StepPercent = 'single-anchor-step-percent'
    BaseLot = 'single-anchor-base-lot'
    NormalTradeCount = 'single-anchor-normal-trade-count'
    HardBreakevenCeilingPercent = 'single-anchor-hard-be-ceiling-percent'
    EscapeEnabled = 'single-anchor-escape-enabled'
    EscapeProfitUnits = 'single-anchor-escape-profit-units'
    EscapeMinimumOpenPositions = 'single-anchor-escape-minimum-open-positions'
    FixedTakeProfitUnits = 'single-anchor-fixed-tp-units'
    TrailingEnabled = 'single-anchor-trailing-enabled'
    TrailingActivationUnits = 'single-anchor-trailing-activation-units'
    TrailingDropUnits = 'single-anchor-trailing-drop-units'
    CommissionBuffer = 'single-anchor-commission-buffer'
    PointValuePerLot = 'single-anchor-point-value-per-lot'
    VolumeStep = 'single-anchor-volume-step'
    MinimumVolume = 'single-anchor-minimum-volume'
    MaximumVolume = 'single-anchor-maximum-volume'
    CommissionPerLot = 'single-anchor-commission-per-lot'
    Slippage = 'single-anchor-slippage'
    ProjectedSpread = 'single-anchor-projected-spread'
    BuySwapPerLotPerDay = 'single-anchor-buy-swap-per-lot-per-day'
    SellSwapPerLotPerDay = 'single-anchor-sell-swap-per-lot-per-day'
}
$resultParameters = Get-PropertyOrNull $results 'parameters'
if ($null -eq $resultParameters) {
    Fail-Preflight 'the run results carry no strategy parameter block.' $outputFullPath
}
foreach ($entry in $resultParameterMap.GetEnumerator()) {
    $resultName = $entry.Key
    $contractName = $entry.Value
    $actualValue = Get-PropertyOrNull $resultParameters $resultName
    if ($null -eq $actualValue) {
        Fail-Preflight "the run parameter block is missing '$resultName' (contract '$contractName')." $outputFullPath
    }
    $frozenText = $contractParameterValues[$contractName]
    $matches = $false
    if ($frozenText -eq 'true' -or $frozenText -eq 'false') {
        $matches = ([bool]$actualValue) -eq ([bool]::Parse($frozenText))
    }
    else {
        $frozenDecimal = [decimal]::Parse($frozenText, $invariant)
        $matches = ([decimal]$actualValue) -eq $frozenDecimal
    }
    if (-not $matches) {
        Fail-Preflight "the run parameter '$resultName' is '$actualValue' but the contract freezes '$frozenText'." $outputFullPath
    }
}

if ($null -eq (Get-PropertyOrNull $results 'researchAccount')) {
    Fail-Preflight 'the run results carry no research account; the contract enables single-anchor-research-account.' $outputFullPath
}
$resultInitialBalance = Get-PropertyOrNull (Get-PropertyOrNull $results 'researchAccount') 'InitialBalance'
$frozenCash = [decimal]::Parse($contractParameterValues['single-anchor-cash'], $invariant)
if ($null -eq $resultInitialBalance -or ([decimal]$resultInitialBalance) -ne $frozenCash) {
    Fail-Preflight "the run research account InitialBalance is '$resultInitialBalance' but the contract freezes '$frozenCash'." $outputFullPath
}
if ($null -eq (Get-PropertyOrNull $results 'researchMargin')) {
    Fail-Preflight 'the run results carry no research margin block; the contract enables single-anchor-margin-enabled.' $outputFullPath
}
$resultSessionMap = Get-PropertyOrNull $results 'sessionMap'
if ($null -eq $resultSessionMap) {
    Fail-Preflight 'the run used no session map; the frozen baseline requires the qualified session map.' $outputFullPath
}
$resultSessionMapSha = [string](Get-PropertyOrNull $resultSessionMap 'Sha256')
if ($resultSessionMapSha -ne $sessionMapSha256) {
    Fail-Preflight "the run session map hashes to '$resultSessionMapSha' but the contract binds '$sessionMapSha256'." $outputFullPath
}

# --- Run horizon: an approved early termination bounds the expected absence ----
# A baseline run may end early through an approved run-ending condition (for example terminal
# target-account stop-out, the intended survival outcome). Days after the actually processed
# horizon were never requested because the run ended; they are recorded, not treated as missing
# qualified data. An absent day within the horizon that was not requested is still invalid.
$failure = Get-PropertyOrNull $results 'failure'
$runTerminated = $null -ne $failure
$terminationKind = ''
$coverageEndDay = $endDate
if ($runTerminated) {
    $terminationKind = [string](Get-PropertyOrNull $failure 'Kind')
    $failureTime = Get-PropertyOrNull (Get-PropertyOrNull $failure 'Quote') 'Time'
    if ($null -eq $failureTime) {
        $failureTime = Get-PropertyOrNull (Get-PropertyOrNull $results 'lastProcessedQuote') 'Time'
    }
    $parsedFailureTime = [System.DateTime]::MinValue
    if ($null -ne $failureTime) {
        try {
            $parsedFailureTime = [System.DateTime]::Parse([string]$failureTime, $invariant)
        }
        catch {
            $parsedFailureTime = [System.DateTime]::MinValue
        }
    }
    if ($parsedFailureTime -eq [System.DateTime]::MinValue) {
        Fail-Preflight 'the run reports a failure but carries no parseable failure/last-processed quote time; the processed horizon cannot be established.' $outputFullPath
    }
    $coverageEndDay = $parsedFailureTime.Date
    if ($coverageEndDay -lt $startDate) { $coverageEndDay = $startDate }
    if ($coverageEndDay -gt $endDate) { $coverageEndDay = $endDate }
}
$coverageEndText = $coverageEndDay.ToString('yyyy-MM-dd')

$expectedAbsentWithinHorizon = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$absentDaysAfterTermination = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($absent in $expectedAbsentDays) {
    $absentDate = [System.DateTime]::ParseExact($absent, 'yyyyMMdd', $invariant)
    if ($absentDate -le $coverageEndDay) {
        [void]$expectedAbsentWithinHorizon.Add($absent)
    }
    else {
        [void]$absentDaysAfterTermination.Add($absent)
    }
}

# --- Failed-request classification ---------------------------------------------
$failedFiles = @(Get-ChildItem -LiteralPath $runPath -Filter 'failed-data-requests-*.txt' -File -ErrorAction SilentlyContinue)
$failedLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $failedFiles) {
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0) { $failedLines.Add($trimmed) }
    }
}

$normalizedAuxiliary = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($aux in $knownAuxiliary) {
    [void]$normalizedAuxiliary.Add((([string]$aux).Trim().Replace('\', '/')).TrimStart('/'))
}

$partitionRegex = '^cfd/' + $market + '/tick/' + $symbol.ToLowerInvariant() + '/(\d{8})_quote\.zip$'
$entries = New-Object 'System.Collections.Generic.List[object]'
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$counts = [ordered]@{
    'expected-source-absent-calendar-day' = 0
    'known-non-strategy-auxiliary-request' = 0
    'unexpected-missing-qualified-partition' = 0
    'unexpected-out-of-window-request' = 0
    'unexpected-unknown-request' = 0
    'unexpected-unrequested-absence' = 0
    'recorded-absence-after-terminated-horizon' = 0
}
$requestedAbsentDays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$invalidEntries = New-Object 'System.Collections.Generic.List[object]'

foreach ($line in $failedLines) {
    $normalized = $line.Replace('\', '/').TrimStart('/')
    if (-not $seenPaths.Add($normalized)) { continue }
    $category = ''
    $detail = ''
    if ($normalizedAuxiliary.Contains($normalized)) {
        $category = 'known-non-strategy-auxiliary-request'
    }
    elseif ($normalized -match $partitionRegex) {
        $dayText = $Matches[1]
        $partitionName = $dayText + '_quote.zip'
        if ($presentPartitions.Contains($partitionName)) {
            $category = 'unexpected-missing-qualified-partition'
            $detail = "the qualified tree contains $partitionName"
        }
        else {
            try {
                $parsedDay = [System.DateTime]::ParseExact($dayText, 'yyyyMMdd', $invariant)
            }
            catch {
                $parsedDay = [System.DateTime]::MinValue
            }
            if ($parsedDay -ne [System.DateTime]::MinValue -and $parsedDay -ge $startDate -and $parsedDay -le $endDate) {
                $category = 'expected-source-absent-calendar-day'
                [void]$requestedAbsentDays.Add($dayText)
            }
            else {
                $category = 'unexpected-out-of-window-request'
                $detail = 'the partition request is outside the frozen window'
            }
        }
    }
    else {
        $category = 'unexpected-unknown-request'
        $detail = 'the failed request path is not a frozen-window XAUUSD/dukascopy tick partition or a known auxiliary path'
    }
    $counts[$category] = [int]$counts[$category] + 1
    $entry = [ordered]@{ path = $line; normalized = $normalized; category = $category }
    if ($detail) { $entry['detail'] = $detail }
    $entries.Add([pscustomobject]$entry)
    if ($category -like 'unexpected-*') { $invalidEntries.Add([pscustomobject]$entry) }
}

$unrequested = New-Object 'System.Collections.Generic.List[string]'
foreach ($absent in $expectedAbsentWithinHorizon) {
    if (-not $requestedAbsentDays.Contains($absent)) { $unrequested.Add($absent) }
}
foreach ($absent in $unrequested) {
    $invalidEntries.Add([pscustomobject]@{
        path = "cfd/$market/tick/$($symbol.ToLowerInvariant())/${absent}_quote.zip (expected-absent, not requested)"
        normalized = "cfd/$market/tick/$($symbol.ToLowerInvariant())/${absent}_quote.zip"
        category = 'unexpected-unrequested-absence'
        detail = 'a source-absent calendar day within the run''s processed horizon was not requested at all'
    })
}
$counts['unexpected-unrequested-absence'] = $unrequested.Count
$counts['recorded-absence-after-terminated-horizon'] = $absentDaysAfterTermination.Count

if ($evidenceMissingPartitions -ne 0 -or $evidenceCoverageGaps -ne 0 -or $evidenceAbsentDays -ne $expectedAbsentDays.Count) {
    $invalidEntries.Add([pscustomobject]@{
        path = 'continuous-history-evidence.json'
        normalized = 'continuous-history-evidence.json'
        category = 'contract-evidence-mismatch'
        detail = "evidence source_absent_days=$evidenceAbsentDays, missing_native_partitions=$evidenceMissingPartitions, source_coverage_gap_days=$evidenceCoverageGaps; the qualified tree derives $($expectedAbsentDays.Count) absent days"
    })
    $counts['contract-evidence-mismatch'] = 1
}

$qualification = if ($invalidEntries.Count -eq 0) { 'EXPECTED' } else { 'INVALID' }
$expectedCategories = @(Get-RequiredProperty $policy 'expectedCategories')
$evidenceCounts = [ordered]@{
    sourceAbsentCalendarDayRequests = $evidenceAbsentDays
    unrelatedAuxiliaryRequests = $evidenceUnrelated
    missingQualifiedPartitions = $evidenceMissingPartitions
    coverageGaps = $evidenceCoverageGaps
}
$record = [ordered]@{}
$record['contract'] = 'marketlab-single-anchor-baseline-failed-data-classification-v1'
$record['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record['baselineContract'] = 'config/baseline-contract.json'
$record['baselineContractSha256'] = $contractSha256
$record['runDirectory'] = $runPath
$record['resultsFile'] = $resultsPath
$record['symbol'] = $symbol
$record['market'] = $market
$record['startDate'] = $startText
$record['endDate'] = $endText
$record['resolvedDataFolder'] = $resolvedDataFolder
$record['dataFolderSource'] = $dataFolderSource
$record['partitionCount'] = $actualPartitionCount
$record['sessionMapSha256'] = $actualSessionMapSha256
$record['runTerminated'] = $runTerminated
$record['terminationKind'] = $terminationKind
$record['coverageEndDay'] = $coverageEndText
$record['expectedSourceAbsentDayCount'] = $expectedAbsentDays.Count
$record['expectedSourceAbsentDayCountWithinHorizon'] = $expectedAbsentWithinHorizon.Count
$record['sourceAbsentDaysAfterTermination'] = $absentDaysAfterTermination.Count
$record['sourceAbsentDayListAfterTermination'] = [string[]]@($absentDaysAfterTermination | Sort-Object)
$record['expectedCategories'] = $expectedCategories
$record['knownAuxiliaryRequestPaths'] = $knownAuxiliary
$record['failedRequestFileCount'] = $failedFiles.Count
$record['failedRequestLineCount'] = $failedLines.Count
$record['distinctFailedRequestCount'] = $entries.Count
$record['countsByCategory'] = $counts
$record['evidence'] = $evidenceCounts
$record['invalidCount'] = $invalidEntries.Count
$record['invalidEntries'] = [object[]]$invalidEntries
$record['qualification'] = $qualification
$recordJson = $record | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outputFullPath, $recordJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "baseline contract SHA-256:        $contractSha256"
Write-Host "run directory:                    $runPath"
Write-Host "failed requests (lines/distinct): $($failedLines.Count) / $($entries.Count)"
Write-Host "expected source-absent days:      $($expectedAbsentDays.Count) derived from the qualified tree"
foreach ($key in $counts.Keys) {
    Write-Host ("  {0,-40} {1}" -f $key, $counts[$key])
}
Write-Host "classification record:            $outputFullPath"

if ($invalidEntries.Count -gt 0) {
    Write-ErrorLine "the baseline run is INVALID: $($invalidEntries.Count) unexpected failed-data condition(s)."
    foreach ($invalid in $invalidEntries) {
        Write-ErrorLine "  $($invalid.category): $($invalid.path) - $($invalid.detail)"
    }
    exit $script:ExitInvalid
}

Write-Host 'baseline failed-data classification: EXPECTED (every failed request is an expected source-absent day or the enumerated known auxiliary path)'
exit $script:ExitExpected
