<#
.SYNOPSIS
Classifies every failed data request of a SingleAnchor baseline run against the frozen
baseline contract, the run's persisted invocation evidence and the qualified continuous tree.

.DESCRIPTION
The approved baseline procedure runs the helper with -AllowMissingData, which merely
downgrades failed local data requests to a warning. This script performs the missing
audit step and proves the chain around it:

1. The contract file must be the frozen contract pinned by the authoritative decision
   register (frozenBaselineContractSha256), unless the caller explicitly opts into a
   non-authoritative test override.
2. The run must carry the pre-run invocation evidence written by
   run-backtest.ps1 -RunEvidence (marketlab-run-invocation.json): this script verifies the
   resolved build configuration, config file and its hash, algorithm location and hash,
   data folder, exact parameter pairs and the allow flags against the contract. A run
   without it, or one whose actual resolved invocation differs from the frozen contract,
   is refused as a controlled configuration failure.
3. The machine-local continuous tree must still be the qualified PR 13 tree: the
   composition manifest (marketlab-qualification\continuous-composition.json) is checked
   against the contract, every one of the 2,332 partition zips is SHA-256 verified against
   the manifest's recorded zip_sha256, the partition name set must match exactly, and the
   market-hours database, symbol-properties database and session map are hash-verified.
   This catches a modified partition, or a present/absent-day swap that keeps the count at
   2,332, without replaying the 413,750,130 rows.
4. The run must be the frozen baseline run: storage\single-anchor\results.json must carry
   the contract's symbol, market, period, research account, margin mode, session map and
   every mapped strategy parameter.
5. The engine's data-monitor report must exist (exactly one) and its
   failed-data-requests-count must equal the total number of failed-request lines; every
   line is classified (occurrences are counted, distinct paths are compared), and the
   known auxiliary request count must equal the tracked evidence's expected count.
6. Only a normally completed run or an AccountStopOut (the intended modeled terminal
   target-account stop-out) is classifiable; any other run-ending condition is refused as
   a controlled failure and cannot receive failed-data qualification EXPECTED.

Every distinct failed request is classified as:

  expected-source-absent-calendar-day     accepted: an always-open calendar day the qualified tree does not contain
  known-non-strategy-auxiliary-request    accepted: only the enumerated benchmark hour path, recorded explicitly
  recorded-absence-after-terminated-horizon
                                          accepted and recorded: a source-absent day after the actually processed
                                          horizon of an AccountStopOut run; it was never requested because the run ended
  unexpected-missing-qualified-partition  INVALID: a failed request for a partition carrying qualified rows
  unexpected-out-of-window-request        INVALID: a failed XAUUSD/dukascopy partition request outside the window
  unexpected-unknown-request              INVALID: any other failed request path
  unexpected-unrequested-absence          INVALID: a source-absent day within the run's processed horizon that was not requested at all
  failed-request-accounting-mismatch      INVALID: the data-monitor failed-request count and the failed-request lines disagree

The classification record is written as JSON next to the run
(baseline-failed-data-classification.json by default) and includes the baseline contract
identity (LF-normalized SHA-256), the invocation-evidence verification and the tree
verification, so the run directory is bound to the reviewed contract.

This script launches nothing: no LEAN, no build, no network. It reads the run directory,
the contract, the register, the tracked evidence and the data tree.

Exit codes:
  0  every failed request is expected and every provenance check passed; the baseline run's failed-data behavior is compatible with the qualified coverage
  1  at least one unexpected failed request or an accounting mismatch: the baseline run is INVALID
  2  controlled configuration failure: missing/invalid inputs, a contract that is not the register-pinned frozen contract, a run without matching invocation evidence, a run that is not the frozen baseline, a run ended by a non-approved condition, or a data tree that no longer matches its composition manifest

.PARAMETER RunDirectory
The run directory produced by run-backtest.ps1 (contains failed-data-requests-*.txt, data-monitor-report-*.json, marketlab-run-invocation.json and storage\single-anchor\results.json).

.PARAMETER Contract
Path to the frozen baseline contract. Default: <script root>\..\config\baseline-contract.json.

.PARAMETER Register
Path to the authoritative decision register that pins the frozen contract hash. Default: <contract directory>\baseline-decision-audit.json.

.PARAMETER Evidence
Path to the tracked continuous-history evidence. Default: <contract directory>\..\tools\historical-data\fixtures\continuous-history-evidence.json.

.PARAMETER DataFolder
Override the qualified data folder. Only accepted together with -AllowNonAuthoritativeOverride; the authoritative audit uses the contract's folder.

.PARAMETER AllowNonAuthoritativeOverride
Test-only: permits a non-register-pinned contract file and/or a -DataFolder override so the classifier's logic can be exercised on synthetic fixtures. The record is marked authoritative:false and the result must never be presented as the authoritative baseline classification.

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
    [string]$Register,
    [string]$Evidence,
    [string]$DataFolder,
    [switch]$AllowNonAuthoritativeOverride,
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

function Write-InfoLine([string]$Message) {
    Write-Host $Message
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
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
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

# Controlled configuration failure: report, write a record next to the run when possible,
# exit 2. The classifier must never leave an unclassified run without a written reason.
function Fail-Preflight([string]$Message, [string]$RecordPath, [bool]$Authoritative) {
    Write-ErrorLine $Message
    if ($RecordPath) {
        $record = [ordered]@{}
        $record['contract'] = 'marketlab-single-anchor-baseline-failed-data-classification-v1'
        $record['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $record['runDirectory'] = $RunDirectory
        $record['authoritative'] = $Authoritative
        $record['qualification'] = 'CONTROLLED_FAILURE'
        $record['failure'] = $Message
        try {
            $json = $record | ConvertTo-Json -Depth 4
            [System.IO.File]::WriteAllText($RecordPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-WarningLine "could not write the classification record to '$RecordPath': $($_.Exception.Message)"
        }
    }
    exit $script:ExitPreflight
}

if ([string]::IsNullOrWhiteSpace($Contract)) {
    $Contract = Join-Path $PSScriptRoot '..\config\baseline-contract.json'
}
$contractPath = [System.IO.Path]::GetFullPath($Contract)
if ([string]::IsNullOrWhiteSpace($Register)) {
    $Register = Join-Path (Split-Path -Parent $contractPath) 'baseline-decision-audit.json'
}
$registerPath = [System.IO.Path]::GetFullPath($Register)
if ([string]::IsNullOrWhiteSpace($Evidence)) {
    $Evidence = Join-Path (Split-Path -Parent $contractPath) '..\tools\historical-data\fixtures\continuous-history-evidence.json'
}
$evidencePath = [System.IO.Path]::GetFullPath($Evidence)
$runPath = [System.IO.Path]::GetFullPath($RunDirectory)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $runPath 'baseline-failed-data-classification.json'
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$authoritative = -not $AllowNonAuthoritativeOverride

# --- Contract, register pin and tracked evidence --------------------------------
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    Fail-Preflight "the baseline contract '$contractPath' does not exist." $outputFullPath $authoritative
}
try {
    $contractData = [System.IO.File]::ReadAllText($contractPath) | ConvertFrom-Json
    $contractId = Get-RequiredProperty $contractData 'contract'
    $contractStatus = Get-RequiredProperty $contractData 'status'
    $contractImmutable = Get-RequiredProperty $contractData 'immutable'
}
catch {
    Fail-Preflight "the baseline contract is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($contractId -ne 'marketlab-single-anchor-baseline-contract-v1' `
    -or $contractStatus -ne 'frozen' `
    -or -not $contractImmutable) {
    Fail-Preflight 'the contract is not the frozen immutable baseline contract.' $outputFullPath $authoritative
}
$contractSha256 = Get-LfNormalizedSha256 $contractPath
$registerPin = ''
if ($authoritative) {
    if (-not (Test-Path -LiteralPath $registerPath -PathType Leaf)) {
        Fail-Preflight "the authoritative decision register '$registerPath' does not exist; the contract hash cannot be checked against its pin." $outputFullPath $authoritative
    }
    try {
        $registerData = [System.IO.File]::ReadAllText($registerPath) | ConvertFrom-Json
        $registerId = Get-RequiredProperty $registerData 'contract'
        $registerPin = Get-RequiredProperty $registerData 'frozenBaselineContractSha256'
    }
    catch {
        Fail-Preflight "the authoritative decision register is unreadable: $($_.Exception.Message)" $outputFullPath $authoritative
    }
    if ($registerId -ne 'marketlab-baseline-decision-audit-v1') {
        Fail-Preflight "the register contract '$registerId' is not 'marketlab-baseline-decision-audit-v1'." $outputFullPath $authoritative
    }
    if ($registerPin -ne $contractSha256) {
        Fail-Preflight "the contract hash $contractSha256 does not match the authoritative register pin $registerPin; the classification cannot be based on this contract." $outputFullPath $authoritative
    }
}

if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    Fail-Preflight "the tracked continuous-history evidence '$evidencePath' does not exist." $outputFullPath $authoritative
}
try {
    $evidenceData = [System.IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json
}
catch {
    Fail-Preflight "the continuous-history evidence is not valid JSON: $($_.Exception.Message)" $outputFullPath $authoritative
}

try {
    $dataIdentity = Get-RequiredProperty $contractData 'qualifiedDataIdentity'
    $policy = Get-RequiredProperty $contractData 'failedDataRequestPolicy'
    if (-not [string]::IsNullOrWhiteSpace($DataFolder) -and -not $AllowNonAuthoritativeOverride) {
        Fail-Preflight 'the data folder must not be overridden for an authoritative classification; pass -AllowNonAuthoritativeOverride only for synthetic tests.' $outputFullPath $authoritative
    }
    if (-not [string]::IsNullOrWhiteSpace($DataFolder)) {
        $resolvedDataFolder = [System.IO.Path]::GetFullPath($DataFolder)
        $dataFolderSource = 'override'
    }
    else {
        $resolvedDataFolder = [string](Get-RequiredProperty $dataIdentity 'dataFolder')
        $dataFolderSource = 'contract'
    }
    $symbol = [string](Get-RequiredProperty $dataIdentity 'symbol')
    $market = [string](Get-RequiredProperty $dataIdentity 'market')
    $startText = [string](Get-RequiredProperty $dataIdentity 'startDate')
    $endText = [string](Get-RequiredProperty $dataIdentity 'endDate')
    $sessionMapRelative = [string](Get-RequiredProperty $dataIdentity 'sessionMapPath')
    $sessionMapSha256 = [string](Get-RequiredProperty $dataIdentity 'sessionMapSha256')
    $partitionCount = [int](Get-RequiredProperty $dataIdentity 'continuousHistoryPartitionCount')
    $marketHoursSha256 = [string](Get-RequiredProperty $dataIdentity 'marketHoursDatabaseSha256')
    $symbolPropertiesSha256 = [string](Get-RequiredProperty $dataIdentity 'symbolPropertiesDatabaseSha256')
    $semanticDigest = [string](Get-RequiredProperty $dataIdentity 'continuousHistorySemanticDigest')
    $knownAuxiliary = @(Get-RequiredProperty $policy 'knownAuxiliaryRequestPaths')
    $expectedCategories = @(Get-RequiredProperty $policy 'expectedCategories')
}
catch {
    Fail-Preflight "the contract identity/policy block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
try {
    $startDate = [System.DateTime]::ParseExact($startText, 'yyyy-MM-dd', $invariant)
    $endDate = [System.DateTime]::ParseExact($endText, 'yyyy-MM-dd', $invariant)
}
catch {
    Fail-Preflight "the contract window '$startText'..'$endText' is not parseable: $($_.Exception.Message)" $outputFullPath $authoritative
}

# --- Qualified continuous tree: verify against its composition manifest ---------
$manifestPath = Join-Path (Join-Path $resolvedDataFolder 'marketlab-qualification') 'continuous-composition.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Fail-Preflight "the qualified tree's composition manifest '$manifestPath' does not exist; the tree identity cannot be established." $outputFullPath $authoritative
}
try {
    $manifestData = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $manifestComposition = Get-RequiredProperty $manifestData 'composition'
    $manifestContract = Get-RequiredProperty $manifestComposition 'contract'
    $manifestNative = Get-RequiredProperty $manifestData 'native'
    $manifestLean = Get-RequiredProperty $manifestData 'lean'
    $manifestQualification = Get-RequiredProperty $manifestData 'qualification'
    $manifestSessionMap = Get-RequiredProperty $manifestComposition 'session_map'
    $manifestNativePartitions = @(Get-RequiredProperty $manifestNative 'partitions')
}
catch {
    Fail-Preflight "the composition manifest is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($manifestContract -ne 'marketlab-continuous-history-composition-v1') {
    Fail-Preflight "the composition manifest contract '$manifestContract' is not 'marketlab-continuous-history-composition-v1'." $outputFullPath $authoritative
}

try {
    $manifestChecks = [ordered]@{
        partitionCount = ([int](Get-RequiredProperty $manifestComposition 'partition_count') -eq $partitionCount)
        orderedSourceDigest = ([string](Get-RequiredProperty $manifestComposition 'ordered_source_semantic_digest') -eq $semanticDigest)
        sessionMapSha256 = ([string](Get-RequiredProperty $manifestSessionMap 'sha256') -eq $sessionMapSha256)
        sessionMapPath = ([string](Get-RequiredProperty $manifestSessionMap 'relative_path') -eq $sessionMapRelative)
        windowStart = ([string](Get-PropertyOrNull (Get-RequiredProperty $manifestComposition 'lean_run_window') 'start_date') -eq $startText)
        windowEnd = ([string](Get-PropertyOrNull (Get-RequiredProperty $manifestComposition 'lean_run_window') 'end_date') -eq $endText)
        firstCanonicalUtc = ([string](Get-RequiredProperty $manifestComposition 'first_canonical_utc') -eq [string](Get-RequiredProperty $dataIdentity 'continuousHistoryFirstQuoteUtc'))
        lastCanonicalUtc = ([string](Get-RequiredProperty $manifestComposition 'last_canonical_utc') -eq [string](Get-RequiredProperty $dataIdentity 'continuousHistoryLastQuoteUtc'))
        marketHoursSha256 = ([string](Get-PropertyOrNull (Get-RequiredProperty $manifestLean 'market_hours_database') 'database_sha256') -eq $marketHoursSha256)
        symbolPropertiesSha256 = ([string](Get-RequiredProperty (Get-RequiredProperty $manifestLean 'symbol_properties_database') 'sha256') -eq $symbolPropertiesSha256)
        qualificationPass = (
            (Get-RequiredProperty $manifestQualification 'source_qualification') -eq 'PASS' -and
            (Get-RequiredProperty $manifestQualification 'native_conversion') -eq 'PASS' -and
            (Get-RequiredProperty $manifestQualification 'native_lean_timestamp_parity') -eq 'PASS' -and
            (Get-RequiredProperty $manifestQualification 'native_price_decimal_parity') -eq 'PASS')
    }
}
catch {
    Fail-Preflight "the composition manifest is missing one of the identity fields: $($_.Exception.Message)" $outputFullPath $authoritative
}
$manifestProblems = @()
foreach ($check in $manifestChecks.GetEnumerator()) {
    if (-not $check.Value) { $manifestProblems += $check.Key }
}
if ($manifestProblems.Count -gt 0) {
    Fail-Preflight ("the composition manifest does not match the frozen contract: " + ($manifestProblems -join ', ') + ".") $outputFullPath $authoritative
}

# Every partition zip must exist and hash exactly as the manifest recorded it: this is
# what makes the machine-local tree the qualified tree without replaying the rows.
$tickRelative = 'cfd/' + $market + '/tick/' + $symbol.ToLowerInvariant()
$tickDirectory = Join-Path (Join-Path (Join-Path (Join-Path $resolvedDataFolder 'cfd') $market) 'tick') $symbol.ToLowerInvariant()
if (-not (Test-Path -LiteralPath $tickDirectory -PathType Container)) {
    Fail-Preflight "the qualified tick directory '$tickDirectory' does not exist; the data identity cannot be established." $outputFullPath $authoritative
}
$partitionFiles = @(Get-ChildItem -LiteralPath $tickDirectory -Filter '*_quote.zip' -File -ErrorAction Stop)
$actualNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $partitionFiles) { [void]$actualNames.Add($file.Name) }
$manifestZips = @{}
foreach ($partition in $manifestNativePartitions) {
    $relative = ([string](Get-RequiredProperty $partition 'zip_relative_path')).Replace('\', '/')
    $name = [System.IO.Path]::GetFileName($relative)
    if ($manifestZips.ContainsKey($name)) {
        Fail-Preflight "the composition manifest records partition '$name' more than once." $outputFullPath $authoritative
    }
    $manifestZips[$name] = [string](Get-RequiredProperty $partition 'zip_sha256')
}
if ($manifestZips.Count -ne $partitionCount -or $manifestZips.Count -ne $actualNames.Count) {
    Fail-Preflight "the qualified tree carries $($actualNames.Count) partitions and the manifest records $($manifestZips.Count); the contract binds $partitionCount." $outputFullPath $authoritative
}
foreach ($name in $manifestZips.Keys) {
    if (-not $actualNames.Contains($name)) {
        Fail-Preflight "the qualified tree is missing the manifest partition '$name'; the tree identity has changed." $outputFullPath $authoritative
    }
}
foreach ($name in $actualNames) {
    if (-not $manifestZips.ContainsKey($name)) {
        Fail-Preflight "the qualified tree contains partition '$name' that the composition manifest does not record; the tree identity has changed." $outputFullPath $authoritative
    }
}
$verifiedPartitionCount = 0
foreach ($file in $partitionFiles) {
    $actualHash = Get-FileSha256 $file.FullName
    if ($actualHash -ne $manifestZips[$file.Name]) {
        Fail-Preflight "partition '$($file.Name)' hashes to $actualHash but the composition manifest records $($manifestZips[$file.Name]); the qualified data identity has changed." $outputFullPath $authoritative
    }
    $verifiedPartitionCount++
}

# The manifest's per-day semantic map must describe exactly the same days as the native
# partition list: a name swap patched into one block but not the other is caught here.
$semanticBlock = Get-PropertyOrNull $manifestData 'semantic'
$perPartition = Get-PropertyOrNull $semanticBlock 'per_partition'
if ($null -eq $perPartition) {
    Fail-Preflight 'the composition manifest carries no semantic.per_partition day map.' $outputFullPath $authoritative
}
$semanticDays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($property in $perPartition.PSObject.Properties) {
    $parsed = [System.DateTime]::MinValue
    try {
        $parsed = [System.DateTime]::ParseExact($property.Name, 'yyyy-MM-dd', $invariant)
    }
    catch {
        $parsed = [System.DateTime]::MinValue
    }
    if ($parsed -eq [System.DateTime]::MinValue) {
        Fail-Preflight "the composition manifest's semantic.per_partition key '$($property.Name)' is not a yyyy-MM-dd day." $outputFullPath $authoritative
    }
    [void]$semanticDays.Add($parsed.ToString('yyyyMMdd'))
}
foreach ($name in $actualNames) {
    $dayText = $name.Substring(0, 8)
    if (-not $semanticDays.Contains($dayText)) {
        Fail-Preflight "partition '$name' is not described by the composition manifest's semantic.per_partition map; the tree identity has changed." $outputFullPath $authoritative
    }
}
if ($semanticDays.Count -ne $actualNames.Count) {
    Fail-Preflight "the composition manifest's semantic.per_partition map describes $($semanticDays.Count) days but the tree carries $($actualNames.Count) partitions." $outputFullPath $authoritative
}
$marketHoursPath = Join-Path (Join-Path $resolvedDataFolder 'market-hours') 'market-hours-database.json'
if (-not (Test-Path -LiteralPath $marketHoursPath -PathType Leaf) -or (Get-FileSha256 $marketHoursPath) -ne $marketHoursSha256) {
    Fail-Preflight "the tree's market-hours database does not match the contract hash $marketHoursSha256." $outputFullPath $authoritative
}
$symbolPropertiesPath = Join-Path (Join-Path $resolvedDataFolder 'symbol-properties') 'symbol-properties-database.csv'
if (-not (Test-Path -LiteralPath $symbolPropertiesPath -PathType Leaf) -or (Get-FileSha256 $symbolPropertiesPath) -ne $symbolPropertiesSha256) {
    Fail-Preflight "the tree's symbol-properties database does not match the contract hash $symbolPropertiesSha256." $outputFullPath $authoritative
}
$sessionMapPath = Join-Path $resolvedDataFolder $sessionMapRelative
if (-not (Test-Path -LiteralPath $sessionMapPath -PathType Leaf) -or (Get-FileSha256 $sessionMapPath) -ne $sessionMapSha256) {
    Fail-Preflight "the qualified session map does not match the contract hash $sessionMapSha256." $outputFullPath $authoritative
}

try {
    $replay = Get-RequiredProperty $evidenceData 'replay'
    $evidenceAbsentDays = [int](Get-RequiredProperty $replay 'source_absent_days')
    $evidenceMissingPartitions = [int](Get-RequiredProperty $replay 'missing_native_partitions')
    $evidenceCoverageGaps = [int](Get-RequiredProperty $replay 'source_coverage_gap_days')
    $evidenceUnrelated = [int](Get-RequiredProperty $replay 'unrelated_failed_data_requests')
}
catch {
    Fail-Preflight "the continuous-history evidence replay block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
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

# --- Run identity: the frozen baseline run and its persisted invocation evidence -
$resultsPath = Join-Path (Join-Path (Join-Path $runPath 'storage') 'single-anchor') 'results.json'
if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) {
    Fail-Preflight "the run's strategy results '$resultsPath' do not exist; the run is not a completed SingleAnchor strategy run." $outputFullPath $authoritative
}
try {
    $results = [System.IO.File]::ReadAllText($resultsPath) | ConvertFrom-Json
}
catch {
    Fail-Preflight "the run's strategy results are not valid JSON: $($_.Exception.Message)" $outputFullPath $authoritative
}

$resultSymbol = [string](Get-PropertyOrNull $results 'symbol')
$resultMarket = [string](Get-PropertyOrNull $results 'market')
$resultStart = [string](Get-PropertyOrNull $results 'startDate')
$resultEnd = [string](Get-PropertyOrNull $results 'endDate')
if ($resultSymbol -ne $symbol -or $resultMarket -ne $market -or $resultStart -ne $startText -or $resultEnd -ne $endText) {
    Fail-Preflight "the run identity ($resultSymbol/$resultMarket, $resultStart..$resultEnd) is not the frozen baseline identity ($symbol/$market, $startText..$endText)." $outputFullPath $authoritative
}

$contractParameterValues = @{}
$contractParameterNames = @()
try {
    $contractParameters = @(Get-RequiredProperty $contractData 'parameters')
}
catch {
    Fail-Preflight "the contract parameter block is missing: $($_.Exception.Message)" $outputFullPath $authoritative
}
foreach ($parameter in $contractParameters) {
    $contractParameterNames += [string]$parameter.name
    $contractParameterValues[[string]$parameter.name] = [string]$parameter.value
}
$contractParametersString = (@($contractParameterNames | ForEach-Object { $_ + ':' + $contractParameterValues[$_] }) -join ',')

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
    Fail-Preflight 'the run results carry no strategy parameter block.' $outputFullPath $authoritative
}
foreach ($entry in $resultParameterMap.GetEnumerator()) {
    $resultName = $entry.Key
    $contractName = $entry.Value
    $actualValue = Get-PropertyOrNull $resultParameters $resultName
    if ($null -eq $actualValue) {
        Fail-Preflight "the run parameter block is missing '$resultName' (contract '$contractName')." $outputFullPath $authoritative
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
        Fail-Preflight "the run parameter '$resultName' is '$actualValue' but the contract freezes '$frozenText'." $outputFullPath $authoritative
    }
}

if ($null -eq (Get-PropertyOrNull $results 'researchAccount')) {
    Fail-Preflight 'the run results carry no research account; the contract enables single-anchor-research-account.' $outputFullPath $authoritative
}
$resultInitialBalance = Get-PropertyOrNull (Get-PropertyOrNull $results 'researchAccount') 'InitialBalance'
$frozenCash = [decimal]::Parse($contractParameterValues['single-anchor-cash'], $invariant)
if ($null -eq $resultInitialBalance -or ([decimal]$resultInitialBalance) -ne $frozenCash) {
    Fail-Preflight "the run research account InitialBalance is '$resultInitialBalance' but the contract freezes '$frozenCash'." $outputFullPath $authoritative
}
if ($null -eq (Get-PropertyOrNull $results 'researchMargin')) {
    Fail-Preflight 'the run results carry no research margin block; the contract enables single-anchor-margin-enabled.' $outputFullPath $authoritative
}
$resultSessionMap = Get-PropertyOrNull $results 'sessionMap'
if ($null -eq $resultSessionMap) {
    Fail-Preflight 'the run used no session map; the frozen baseline requires the qualified session map.' $outputFullPath $authoritative
}
$resultSessionMapSha = [string](Get-PropertyOrNull $resultSessionMap 'Sha256')
if ($resultSessionMapSha -ne $sessionMapSha256) {
    Fail-Preflight "the run session map hashes to '$resultSessionMapSha' but the contract binds '$sessionMapSha256'." $outputFullPath $authoritative
}

# The pre-run invocation evidence persisted by run-backtest.ps1 -RunEvidence: what the
# run actually resolved to, checked field by field against the frozen contract.
$invocationEvidencePath = Join-Path $runPath 'marketlab-run-invocation.json'
if (-not (Test-Path -LiteralPath $invocationEvidencePath -PathType Leaf)) {
    Fail-Preflight "the run has no invocation evidence '$invocationEvidencePath'; launch the baseline with run-backtest.ps1 -RunEvidence so the actual invocation is provable." $outputFullPath $authoritative
}
try {
    $invocation = [System.IO.File]::ReadAllText($invocationEvidencePath) | ConvertFrom-Json
    $invocationContract = Get-RequiredProperty $invocation 'contract'
    $runHost = Get-RequiredProperty $contractData 'runHost'
}
catch {
    Fail-Preflight "the run invocation evidence is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($invocationContract -ne 'marketlab-run-invocation-evidence-v1') {
    Fail-Preflight "the run invocation evidence contract '$invocationContract' is not 'marketlab-run-invocation-evidence-v1'." $outputFullPath $authoritative
}
$invocationDataFolder = [string](Get-PropertyOrNull $invocation 'dataFolder')
$invocationDataFolderMatches = $false
if (-not [string]::IsNullOrWhiteSpace($invocationDataFolder)) {
    $invocationDataFolderMatches = ([System.IO.Path]::GetFullPath($invocationDataFolder) -eq [System.IO.Path]::GetFullPath($resolvedDataFolder))
}
$invocationRunDirectory = [string](Get-PropertyOrNull $invocation 'runDirectory')
$invocationRunDirectoryMatches = $false
if (-not [string]::IsNullOrWhiteSpace($invocationRunDirectory)) {
    $invocationRunDirectoryMatches = ([System.IO.Path]::GetFullPath($invocationRunDirectory) -eq $runPath)
}
$invocationChecks = [ordered]@{
    configuration = ([string](Get-PropertyOrNull $invocation 'configuration') -eq [string](Get-RequiredProperty $runHost 'buildConfiguration'))
    algorithmTypeName = ([string](Get-PropertyOrNull $invocation 'algorithmTypeName') -eq [string](Get-RequiredProperty $runHost 'algorithmTypeName'))
    algorithmLanguage = ([string](Get-PropertyOrNull $invocation 'algorithmLanguage') -eq [string](Get-RequiredProperty $runHost 'algorithmLanguage'))
    dataFolder = $invocationDataFolderMatches
    parameters = ([string](Get-PropertyOrNull $invocation 'parametersString') -eq $contractParametersString)
    closeAutomatically = ([bool](Get-PropertyOrNull $invocation 'closeAutomatically') -eq $true)
    allowMissingData = ([bool](Get-PropertyOrNull $invocation 'allowMissingData') -eq $true)
    allowEngineErrors = ([bool](Get-PropertyOrNull $invocation 'allowEngineErrors') -eq $false)
    runDirectory = $invocationRunDirectoryMatches
}
$invocationProblems = @()
foreach ($check in $invocationChecks.GetEnumerator()) {
    if (-not $check.Value) { $invocationProblems += $check.Key }
}
$expectedLocation = ([string](Get-RequiredProperty $runHost 'algorithmLocation')).Replace('/', '\')
$actualLocation = ([string](Get-PropertyOrNull $invocation 'algorithmLocation')).Replace('/', '\')
if (-not $actualLocation.EndsWith($expectedLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
    $invocationProblems += 'algorithmLocation'
}
if ($invocationProblems.Count -gt 0) {
    Fail-Preflight ("the run's persisted invocation does not match the frozen contract: " + ($invocationProblems -join ', ') + ".") $outputFullPath $authoritative
}
$invocationConfigPath = [string](Get-PropertyOrNull $invocation 'configPath')
if (-not (Test-Path -LiteralPath $invocationConfigPath -PathType Leaf)) {
    Fail-Preflight "the run invocation evidence config file '$invocationConfigPath' does not exist." $outputFullPath $authoritative
}
$actualConfigHash = Get-LfNormalizedSha256 $invocationConfigPath
$frozenConfigHash = [string](Get-RequiredProperty $runHost 'leanConfigSha256LfNormalized')
if ($actualConfigHash -ne $frozenConfigHash -or [string](Get-PropertyOrNull $invocation 'configSha256LfNormalized') -ne $frozenConfigHash) {
    Fail-Preflight "the run's LEAN config hashes to $actualConfigHash but the contract binds $frozenConfigHash." $outputFullPath $authoritative
}
$invocationAlgorithmPath = [string](Get-PropertyOrNull $invocation 'algorithmLocation')
if (-not (Test-Path -LiteralPath $invocationAlgorithmPath -PathType Leaf)) {
    Fail-Preflight "the run's algorithm assembly '$invocationAlgorithmPath' no longer exists; the run binary identity cannot be proven." $outputFullPath $authoritative
}
$actualAlgorithmHash = Get-FileSha256 $invocationAlgorithmPath
$recordedAlgorithmHash = [string](Get-PropertyOrNull $invocation 'algorithmSha256')
if ($actualAlgorithmHash -ne $recordedAlgorithmHash) {
    Fail-Preflight "the run's algorithm assembly now hashes to $actualAlgorithmHash but the invocation evidence recorded $recordedAlgorithmHash; the run binary changed after the run." $outputFullPath $authoritative
}

# --- Data-monitor reconciliation and approved termination -----------------------
$monitorFiles = @(Get-ChildItem -LiteralPath $runPath -Filter 'data-monitor-report-*.json' -File -ErrorAction SilentlyContinue)
if ($monitorFiles.Count -ne 1) {
    Fail-Preflight "the run directory carries $($monitorFiles.Count) data-monitor reports; exactly one is required to reconcile the failed-request accounting." $outputFullPath $authoritative
}
try {
    $monitor = [System.IO.File]::ReadAllText($monitorFiles[0].FullName) | ConvertFrom-Json
    $monitorFailedCount = [int](Get-RequiredProperty $monitor 'failed-data-requests-count')
}
catch {
    Fail-Preflight "the data-monitor report is unreadable: $($_.Exception.Message)" $outputFullPath $authoritative
}

$failure = Get-PropertyOrNull $results 'failure'
$runTerminated = $null -ne $failure
$terminationKind = ''
$coverageEndDay = $endDate
if ($runTerminated) {
    $terminationKind = [string](Get-PropertyOrNull $failure 'Kind')
    if ($terminationKind -ne 'AccountStopOut') {
        Fail-Preflight "the run ended by '$terminationKind', which is not an approved baseline outcome (only a normally completed run or AccountStopOut is classifiable); the baseline is invalid regardless of its failed-data list." $outputFullPath $authoritative
    }
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
        Fail-Preflight 'the run reports an AccountStopOut but carries no parseable failure/last-processed quote time; the processed horizon cannot be established.' $outputFullPath $authoritative
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

# --- Failed-request classification (occurrences and distinct paths) -------------
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
$occurrenceCounts = [ordered]@{
    'expected-source-absent-calendar-day' = 0
    'known-non-strategy-auxiliary-request' = 0
    'recorded-absence-after-terminated-horizon' = 0
    'unexpected-missing-qualified-partition' = 0
    'unexpected-out-of-window-request' = 0
    'unexpected-unknown-request' = 0
    'unexpected-unrequested-absence' = 0
    'failed-request-accounting-mismatch' = 0
    'contract-evidence-mismatch' = 0
}
$distinctCounts = [ordered]@{}
foreach ($key in $occurrenceCounts.Keys) { $distinctCounts[$key] = 0 }
$seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$repeatedFailedPaths = [ordered]@{}
$requestedAbsentDays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$invalidEntries = New-Object 'System.Collections.Generic.List[object]'
$distinctFailedRequestCount = 0

foreach ($line in $failedLines) {
    $normalized = $line.Replace('\', '/').TrimStart('/')
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
    $occurrenceCounts[$category] = [int]$occurrenceCounts[$category] + 1
    if ($seenPaths.Add($normalized)) {
        $distinctFailedRequestCount++
        $distinctCounts[$category] = [int]$distinctCounts[$category] + 1
        $entry = [ordered]@{ path = $line; normalized = $normalized; category = $category }
        if ($detail) { $entry['detail'] = $detail }
        if ($category -like 'unexpected-*') { $invalidEntries.Add([pscustomobject]$entry) }
        $repeatedFailedPaths[$normalized] = 1
    }
    else {
        if ($repeatedFailedPaths.Contains($normalized)) {
            $repeatedFailedPaths[$normalized] = [int]$repeatedFailedPaths[$normalized] + 1
        }
    }
}

if ($failedLines.Count -ne $monitorFailedCount) {
    $occurrenceCounts['failed-request-accounting-mismatch'] = 1
    $distinctCounts['failed-request-accounting-mismatch'] = 1
    $invalidEntries.Add([pscustomobject]@{
        path = $monitorFiles[0].Name
        normalized = $monitorFiles[0].Name
        category = 'failed-request-accounting-mismatch'
        detail = "the data-monitor reports $monitorFailedCount failed data requests but the failed-data-requests files carry $($failedLines.Count) line(s); not every failed request was captured/classified"
    })
}

$unrequested = New-Object 'System.Collections.Generic.List[string]'
foreach ($absent in $expectedAbsentWithinHorizon) {
    if (-not $requestedAbsentDays.Contains($absent)) { $unrequested.Add($absent) }
}
foreach ($absent in $unrequested) {
    $occurrenceCounts['unexpected-unrequested-absence'] = [int]$occurrenceCounts['unexpected-unrequested-absence'] + 1
    $distinctCounts['unexpected-unrequested-absence'] = [int]$distinctCounts['unexpected-unrequested-absence'] + 1
    $invalidEntries.Add([pscustomobject]@{
        path = "cfd/$market/tick/$($symbol.ToLowerInvariant())/${absent}_quote.zip (expected-absent, not requested)"
        normalized = "cfd/$market/tick/$($symbol.ToLowerInvariant())/${absent}_quote.zip"
        category = 'unexpected-unrequested-absence'
        detail = 'a source-absent calendar day within the run''s processed horizon was not requested at all'
    })
}
$occurrenceCounts['recorded-absence-after-terminated-horizon'] = $absentDaysAfterTermination.Count
$distinctCounts['recorded-absence-after-terminated-horizon'] = $absentDaysAfterTermination.Count

$auxiliaryOccurrences = [int]$occurrenceCounts['known-non-strategy-auxiliary-request']
if ($auxiliaryOccurrences -ne $evidenceUnrelated) {
    $occurrenceCounts['contract-evidence-mismatch'] = 1
    $distinctCounts['contract-evidence-mismatch'] = 1
    $invalidEntries.Add([pscustomobject]@{
        path = 'continuous-history-evidence.json'
        normalized = 'continuous-history-evidence.json'
        category = 'contract-evidence-mismatch'
        detail = "the run recorded $auxiliaryOccurrences known auxiliary failed request(s) but the tracked evidence records $evidenceUnrelated"
    })
}
if ($evidenceMissingPartitions -ne 0 -or $evidenceCoverageGaps -ne 0 -or $evidenceAbsentDays -ne $expectedAbsentDays.Count) {
    if (-not ($invalidEntries | Where-Object { $_.category -eq 'contract-evidence-mismatch' })) {
        $occurrenceCounts['contract-evidence-mismatch'] = 1
        $distinctCounts['contract-evidence-mismatch'] = 1
        $invalidEntries.Add([pscustomobject]@{
            path = 'continuous-history-evidence.json'
            normalized = 'continuous-history-evidence.json'
            category = 'contract-evidence-mismatch'
            detail = "evidence source_absent_days=$evidenceAbsentDays, missing_native_partitions=$evidenceMissingPartitions, source_coverage_gap_days=$evidenceCoverageGaps; the qualified tree derives $($expectedAbsentDays.Count) absent days"
        })
    }
}

$qualification = if ($invalidEntries.Count -eq 0) { 'EXPECTED' } else { 'INVALID' }
$evidenceCounts = [ordered]@{
    sourceAbsentCalendarDayRequests = $evidenceAbsentDays
    unrelatedAuxiliaryRequests = $evidenceUnrelated
    missingQualifiedPartitions = $evidenceMissingPartitions
    coverageGaps = $evidenceCoverageGaps
}
$repeatedPathCount = 0
foreach ($key in $repeatedFailedPaths.Keys) { if ([int]$repeatedFailedPaths[$key] -gt 1) { $repeatedPathCount++ } }

$record = [ordered]@{}
$record['contract'] = 'marketlab-single-anchor-baseline-failed-data-classification-v1'
$record['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record['authoritative'] = $authoritative
$record['baselineContract'] = 'config/baseline-contract.json'
$record['baselineContractSha256'] = $contractSha256
$record['registerPin'] = $registerPin
$record['runDirectory'] = $runPath
$record['resultsFile'] = $resultsPath
$record['invocationEvidenceFile'] = $invocationEvidencePath
$record['invocationEvidenceVerified'] = $true
$record['symbol'] = $symbol
$record['market'] = $market
$record['startDate'] = $startText
$record['endDate'] = $endText
$record['resolvedDataFolder'] = $resolvedDataFolder
$record['dataFolderSource'] = $dataFolderSource
$record['compositionManifest'] = $manifestPath
$record['verifiedPartitionCount'] = $verifiedPartitionCount
$record['sessionMapSha256'] = $sessionMapSha256
$record['marketHoursDatabaseSha256'] = $marketHoursSha256
$record['symbolPropertiesDatabaseSha256'] = $symbolPropertiesSha256
$record['runTerminated'] = $runTerminated
$record['terminationKind'] = $terminationKind
$record['coverageEndDay'] = $coverageEndText
$record['expectedSourceAbsentDayCount'] = $expectedAbsentDays.Count
$record['expectedSourceAbsentDayCountWithinHorizon'] = $expectedAbsentWithinHorizon.Count
$record['sourceAbsentDaysAfterTermination'] = $absentDaysAfterTermination.Count
$record['sourceAbsentDayListAfterTermination'] = [string[]]@($absentDaysAfterTermination | Sort-Object)
$record['failedRequestMonitorCount'] = $monitorFailedCount
$record['failedRequestLineCount'] = $failedLines.Count
$record['failedRequestAccountingMatches'] = ($failedLines.Count -eq $monitorFailedCount)
$record['distinctFailedRequestCount'] = $distinctFailedRequestCount
$record['repeatedFailedPathCount'] = $repeatedPathCount
$record['repeatedFailedPaths'] = $repeatedFailedPaths
$record['occurrencesByCategory'] = $occurrenceCounts
$record['distinctPathsByCategory'] = $distinctCounts
$record['expectedCategories'] = $expectedCategories
$record['knownAuxiliaryRequestPaths'] = $knownAuxiliary
$record['evidence'] = $evidenceCounts
$record['invalidCount'] = $invalidEntries.Count
$record['invalidEntries'] = [object[]]$invalidEntries
$record['qualification'] = $qualification

$recordJson = $record | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($outputFullPath, $recordJson, (New-Object System.Text.UTF8Encoding($false)))

Write-InfoLine "baseline contract SHA-256:        $contractSha256"
Write-InfoLine "authoritative:                    $authoritative (register pin verified: $(if ($authoritative) { 'yes' } else { 'skipped (test override)' }))"
Write-InfoLine "run directory:                    $runPath"
Write-InfoLine "invocation evidence verified:     $invocationEvidencePath"
Write-InfoLine "qualified tree:                   $verifiedPartitionCount/$partitionCount partitions hash-verified against the composition manifest"
Write-InfoLine "failed requests (lines/distinct): $($failedLines.Count) / $distinctFailedRequestCount (data-monitor count $monitorFailedCount)"
Write-InfoLine "expected source-absent days:      $($expectedAbsentDays.Count) derived from the qualified tree"
foreach ($key in $occurrenceCounts.Keys) {
    Write-InfoLine ("  {0,-42} occurrences {1,3}  distinct {2,3}" -f $key, $occurrenceCounts[$key], $distinctCounts[$key])
}
Write-InfoLine "classification record:            $outputFullPath"

if ($invalidEntries.Count -gt 0) {
    Write-ErrorLine "the baseline run is INVALID: $($invalidEntries.Count) unexpected failed-data condition(s)."
    foreach ($invalid in $invalidEntries) {
        Write-ErrorLine "  $($invalid.category): $($invalid.path) - $($invalid.detail)"
    }
    exit $script:ExitInvalid
}

Write-InfoLine 'baseline failed-data classification: EXPECTED (every failed request is an expected source-absent day or the enumerated known auxiliary path, and every provenance check passed)'
exit $script:ExitExpected
