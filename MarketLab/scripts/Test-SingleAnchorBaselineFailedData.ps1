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
   run-backtest.ps1 -RunEvidence -BaselineContract ... -BaselineRegister ...
   (marketlab-run-invocation.json): this script requires the recorded contract path,
   SHA-256 and register pin to equal the canonical contract/pin, the resolved build
   configuration, config file and its hash, algorithm location and hash, data folder,
   exact parameter pairs and allow flags to equal the contract's, the Git HEAD to be
   present with a clean working tree, and the qualified runtime binary set to be
   recorded and unchanged on disk.
3. The run must carry the post-run outcome evidence
   (marketlab-run-outcome.json) written by the helper, bound to the pre-run file by its
   SHA-256: the engine log audit must have run in every case. A completed run must show
   LEAN exit 0, helper exit 0 and zero engine ERROR:: lines; an AccountStopOut run must
   show exactly LEAN exit 1, helper exit 1, the expected AccountStopOutException lines
   recorded separately and zero unrelated engine ERROR:: lines. The recorded
   failed-data count must equal the data-monitor count and the runtime binaries must be
   unchanged during the run.
4. The machine-local continuous tree must still be the qualified PR 13 tree: the
   composition manifest (marketlab-qualification\continuous-composition.json) is checked
   against the contract, every one of the 2,332 partition zips is SHA-256 verified against
   the manifest's recorded zip_sha256, the partition name set must match exactly, the
   per-day semantic map must describe the same days, the market-hours database,
   symbol-properties database and session map are hash-verified, and the manifest file is
   anchored to the replay qualification record
   (continuous-qualification-record.json: PASS with continuous.composition_sha256 equal
   to the actual manifest hash). This catches a modified partition, or a
   present/absent-day swap that keeps the count at 2,332, without replaying the
   413,750,130 rows.
5. The run must be the frozen baseline run: storage\single-anchor\results.json must carry
   the contract's symbol, market, period, research account, margin mode, session map and
   every mapped strategy parameter.
6. The engine's data-monitor report must exist (exactly one) and its
   failed-data-requests-count must equal the total number of failed-request lines; every
   line is classified (occurrences are counted, distinct paths are compared), and the
   known auxiliary request count must equal the tracked evidence's expected count.
7. Only a normally completed run or an AccountStopOut (the intended modeled terminal
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

The -Preflight mode runs the same non-result-dependent stage before the authoritative
run: the contract/register pin, the clean Git checkout and the complete qualified-tree
identity (manifest, qualification-record anchor, all partition hashes and the auxiliary
database/session-map hashes) are verified before LEAN is launched, so an accidental
drift cannot consume the one-off full-history run. Only result-dependent checks remain
for the post-run classification.

This script launches nothing: no LEAN, no build, no network. It reads the run directory,
the contract, the register, the tracked evidence and the data tree.

Exit codes:
  0  every failed request is expected and every provenance check passed; the baseline run's failed-data behavior is compatible with the qualified coverage
  1  at least one unexpected failed request or an accounting mismatch: the baseline run is INVALID
  2  controlled configuration failure: missing/invalid inputs, a contract that is not the register-pinned frozen contract, a run without matching invocation evidence, a run that is not the frozen baseline, a run ended by a non-approved condition, or a data tree that no longer matches its composition manifest

.PARAMETER RunDirectory
The run directory produced by run-backtest.ps1 (contains failed-data-requests-*.txt, data-monitor-report-*.json, marketlab-run-invocation.json, marketlab-run-outcome.json and storage\single-anchor\results.json). Required unless -Preflight is used.

.PARAMETER ReviewedCommit
The explicitly reviewed full commit SHA. Required for authoritative preflight;
post-run verification also checks it against the run's recorded reviewed SHA.

.PARAMETER BuildReceipt
Successful receipt produced by Build-SingleAnchorBaseline.ps1. Authoritative
preflight validates its source, contract and complete runtime dependency set.

.PARAMETER CheckOnly
With -Preflight, return the preflight JSON in memory and write no record. Used
by the helper's mandatory launch check, including DryRun.

.PARAMETER DotnetPath
The dotnet executable selected by the helper. Defaults to the first dotnet on PATH.
It must match the successful build receipt.

.PARAMETER Preflight
Run only the pre-run verification stage (contract/register pin, clean Git checkout, qualified-tree identity) against the planned run configuration and write the preflight record; no run directory is read. The authoritative baseline procedure runs this before run-backtest.ps1 so no pre-run-knowable drift can consume the one-off run.

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
    [string]$RunDirectory,
    [string]$Contract,
    [string]$Register,
    [string]$Evidence,
    [string]$DataFolder,
    [switch]$Preflight,
    [switch]$CheckOnly,
    [string]$ReviewedCommit,
    [string]$BuildReceipt,
    [string]$DotnetPath,
    [switch]$AllowNonAuthoritativeOverride,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SingleAnchorBaseline.ps1')
. (Join-Path $PSScriptRoot 'SingleAnchorDelivery.ps1')

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
    if ($RecordPath -and -not $CheckOnly) {
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
if (-not $Preflight -and [string]::IsNullOrWhiteSpace($RunDirectory)) {
    Write-ErrorLine 'the post-run classification requires -RunDirectory (or pass -Preflight for the pre-run verification stage).'
    exit $script:ExitPreflight
}
$runPath = $null
if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
    $runPath = [System.IO.Path]::GetFullPath($RunDirectory)
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if ($Preflight) {
        $OutputPath = Join-Path (Join-Path $PSScriptRoot '..\output') 'baseline-preflight.json'
    }
    else {
        $OutputPath = Join-Path $runPath 'baseline-failed-data-classification.json'
    }
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$authoritative = -not $AllowNonAuthoritativeOverride
$baselineRepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($CheckOnly -and -not $Preflight) { throw '-CheckOnly is only supported with -Preflight.' }
if (-not $BuildReceipt) { $BuildReceipt = Join-Path $baselineRepoRoot 'MarketLab\output\baseline-build.json' }

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
    if ($authoritative -and $evidencePath -ne [IO.Path]::GetFullPath((Join-Path $baselineRepoRoot $dataIdentity.evidence))) {
        throw 'Authoritative qualification must use the contract-named tracked evidence file.'
    }
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
    $sourceFileSetSha256 = [string](Get-RequiredProperty $dataIdentity 'sourceFileSetSha256')
    $orderedMonthDigestChainSha256 = [string](Get-RequiredProperty $dataIdentity 'orderedMonthDigestChainSha256')
    $monthCount = [int](Get-RequiredProperty $dataIdentity 'continuousHistoryMonthCount')
    $quoteCount = [long](Get-RequiredProperty $dataIdentity 'continuousHistoryQuoteCount')
    $firstCanonicalUtc = ConvertTo-BaselineUtc (Get-RequiredProperty $dataIdentity 'continuousHistoryFirstQuoteUtc')
    $lastCanonicalUtc = ConvertTo-BaselineUtc (Get-RequiredProperty $dataIdentity 'continuousHistoryLastQuoteUtc')
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
    $manifestCounts = Get-RequiredProperty $manifestData 'counts'
    $manifestChecks = [ordered]@{
        partitionCount = ([int](Get-RequiredProperty $manifestComposition 'partition_count') -eq $partitionCount)
        monthCount = ([int](Get-RequiredProperty $manifestComposition 'month_count') -eq $monthCount)
        orderedSourceDigest = ([string](Get-RequiredProperty $manifestComposition 'ordered_source_semantic_digest') -eq $semanticDigest)
        sourceFileSet = ([string](Get-RequiredProperty $manifestComposition 'source_file_set_sha256') -eq $sourceFileSetSha256)
        orderedMonthChain = ([string](Get-RequiredProperty $manifestComposition 'ordered_month_digest_chain_sha256') -eq $orderedMonthDigestChainSha256)
        sessionMapSha256 = ([string](Get-RequiredProperty $manifestSessionMap 'sha256') -eq $sessionMapSha256)
        sessionMapPath = ([string](Get-RequiredProperty $manifestSessionMap 'relative_path') -eq $sessionMapRelative)
        windowStart = ([string](Get-PropertyOrNull (Get-RequiredProperty $manifestComposition 'lean_run_window') 'start_date') -eq $startText)
        windowEnd = ([string](Get-PropertyOrNull (Get-RequiredProperty $manifestComposition 'lean_run_window') 'end_date') -eq $endText)
        firstCanonicalUtc = ((ConvertTo-BaselineUtc (Get-RequiredProperty $manifestComposition 'first_canonical_utc')) -eq $firstCanonicalUtc)
        lastCanonicalUtc = ((ConvertTo-BaselineUtc (Get-RequiredProperty $manifestComposition 'last_canonical_utc')) -eq $lastCanonicalUtc)
        acceptedRowCount = ([long](Get-RequiredProperty $manifestCounts 'accepted_row_count') -eq $quoteCount)
        convertedRowCount = ([long](Get-RequiredProperty $manifestCounts 'converted_row_count') -eq $quoteCount)
        rejectedRows = ([long](Get-RequiredProperty $manifestCounts 'rejected_row_count') -eq 0L)
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

# The composition manifest itself is anchored to the replay qualification record:
# the record's composition_sha256 must be the actual manifest file hash, and the
# record must be a PASS. This closes the loop manifest -> qualification -> the
# tracked PR #13 evidence without replaying any rows.
$qualificationRecordPath = Join-Path (Join-Path $resolvedDataFolder 'marketlab-qualification') 'continuous-qualification-record.json'
if (-not (Test-Path -LiteralPath $qualificationRecordPath -PathType Leaf)) {
    Fail-Preflight "the qualified tree's replay qualification record '$qualificationRecordPath' does not exist; the composition manifest cannot be anchored." $outputFullPath $authoritative
}
$manifestFileSha256 = Get-FileSha256 $manifestPath
$qualificationRecordSha256 = Get-FileSha256 $qualificationRecordPath
try {
    $expectedRecordSha256 = [string](Get-RequiredProperty (Get-RequiredProperty $evidenceData 'replay') 'record_sha256')
    if ($expectedRecordSha256 -cnotmatch '^[0-9a-f]{64}$' -or $qualificationRecordSha256 -cne $expectedRecordSha256) {
        throw 'The qualification record does not match the tracked replay.record_sha256 anchor.'
    }
    $qualificationRecord = [System.IO.File]::ReadAllText($qualificationRecordPath) | ConvertFrom-Json
    $recordContract = Get-RequiredProperty $qualificationRecord 'contract'
    $recordContinuous = Get-RequiredProperty $qualificationRecord 'continuous'
    $recordChecks = [ordered]@{
        contract = ($recordContract -eq 'marketlab-historical-data-qualification-record-v1')
        overallPass = ((Get-RequiredProperty $qualificationRecord 'overall_qualification') -eq 'PASS')
        helperExitZero = ([int](Get-RequiredProperty $qualificationRecord 'helper_exit_code') -eq 0)
        compositionSha256 = ([string](Get-RequiredProperty $recordContinuous 'composition_sha256') -eq $manifestFileSha256)
        partitionCount = ([int](Get-RequiredProperty $recordContinuous 'partition_count') -eq $partitionCount)
        monthCount = ([int](Get-RequiredProperty $recordContinuous 'month_count') -eq $monthCount)
        sessionMapSha256 = ([string](Get-PropertyOrNull (Get-RequiredProperty $recordContinuous 'session_map') 'sha256') -eq $sessionMapSha256)
    }
}
catch {
    Fail-Preflight "the replay qualification record is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
$recordProblems = @()
foreach ($check in $recordChecks.GetEnumerator()) {
    if (-not $check.Value) { $recordProblems += $check.Key }
}
if ($recordProblems.Count -gt 0) {
    Fail-Preflight ("the replay qualification record does not match the composition manifest: " + ($recordProblems -join ', ') + ".") $outputFullPath $authoritative
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

# --- Pre-run verification stage (-Preflight): everything knowable before launch --
# The authoritative baseline runs exactly once, so the contract identity, the
# clean checkout and the complete qualified-tree identity are verified here,
# before LEAN starts. Only result-dependent checks remain for the post-run
# classification.
if ($Preflight) {
    $preflightRepositoryHead = $null
    $preflightRepositoryDirty = $null
    $preflightBuild = $null
    if ($authoritative) {
        try {
            if (-not $DotnetPath) { $DotnetPath = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
            $frozenHost = $contractData.runHost
            $frozenPairs = @($contractData.parameters | ForEach-Object { $_.name + ':' + $_.value }) -join ','
            Assert-BaselineLaunch $contractData $baselineRepoRoot $frozenHost.buildConfiguration `
                (Join-Path $baselineRepoRoot $frozenHost.leanConfig) $frozenHost.algorithmTypeName $frozenHost.algorithmLanguage `
                (Join-Path $baselineRepoRoot $frozenHost.algorithmLocation) $resolvedDataFolder $frozenPairs `
                $true $false 'MarketLab.SingleAnchor.AccountStopOutException'
            $preflightBuild = Assert-BaselineBuild $BuildReceipt $baselineRepoRoot $ReviewedCommit $DotnetPath $contractSha256
        } catch {
            Fail-Preflight $_.Exception.Message $outputFullPath $authoritative
        }
    }
    if ($authoritative) {
        $preflightRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        try {
            $previousGitPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $gitHead = @(& git -C $preflightRepoRoot rev-parse HEAD 2>$null)
                if ($LASTEXITCODE -eq 0 -and $gitHead.Count -gt 0) { $preflightRepositoryHead = ([string]$gitHead[0]).Trim() }
                $gitStatus = @(& git -C $preflightRepoRoot status --porcelain 2>$null)
                if ($LASTEXITCODE -eq 0) { $preflightRepositoryDirty = ($gitStatus.Count -gt 0) }
            }
            finally {
                $ErrorActionPreference = $previousGitPreference
            }
        }
        catch {
            $preflightRepositoryHead = $null
            $preflightRepositoryDirty = $null
        }
        if ([string]::IsNullOrWhiteSpace($preflightRepositoryHead)) {
            Fail-Preflight "could not read the Git HEAD of '$preflightRepoRoot'; the reviewed freeze commit cannot be established." $outputFullPath $authoritative
        }
        if ($preflightRepositoryDirty -ne $false) {
            Fail-Preflight "the working tree at '$preflightRepoRoot' is dirty; the authoritative baseline must run from the reviewed and merged freeze commit." $outputFullPath $authoritative
        }
    }
    $preflightRecord = [ordered]@{}
    $preflightRecord['contract'] = 'marketlab-single-anchor-baseline-preflight-v1'
    $preflightRecord['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $preflightRecord['authoritative'] = $authoritative
    $preflightRecord['baselineContractSha256'] = $contractSha256
    $preflightRecord['registerPin'] = $registerPin
    $preflightRecord['repositoryHead'] = $preflightRepositoryHead
    $preflightRecord['repositoryDirty'] = $preflightRepositoryDirty
    $preflightRecord['resolvedDataFolder'] = $resolvedDataFolder
    $preflightRecord['dataFolderSource'] = $dataFolderSource
    $preflightRecord['compositionManifest'] = $manifestPath
    $preflightRecord['compositionManifestSha256'] = $manifestFileSha256
    $preflightRecord['qualificationRecord'] = $qualificationRecordPath
    $preflightRecord['qualificationRecordSha256'] = $qualificationRecordSha256
    $preflightRecord['reviewedCommit'] = $ReviewedCommit
    $preflightRecord['buildReceiptSha256'] = if ($preflightBuild) { Get-FileSha256 $BuildReceipt } else { $null }
    $preflightRecord['launchInputsVerified'] = $null -ne $preflightBuild
    $preflightRecord['verifiedPartitionCount'] = $verifiedPartitionCount
    $preflightRecord['sessionMapSha256'] = $sessionMapSha256
    $preflightRecord['marketHoursDatabaseSha256'] = $marketHoursSha256
    $preflightRecord['symbolPropertiesDatabaseSha256'] = $symbolPropertiesSha256
    $preflightRecord['sourceFileSetSha256'] = $sourceFileSetSha256
    $preflightRecord['orderedMonthDigestChainSha256'] = $orderedMonthDigestChainSha256
    $preflightRecord['expectedSourceAbsentDayCount'] = $expectedAbsentDays.Count
    $preflightRecord['qualification'] = 'PREFLIGHT-PASS'
    if ($CheckOnly) {
        $preflightRecord | ConvertTo-Json -Depth 6
        exit $script:ExitExpected
    }
    [System.IO.File]::WriteAllText($outputFullPath, ($preflightRecord | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-InfoLine "baseline contract SHA-256:        $contractSha256"
    Write-InfoLine "authoritative:                    $authoritative"
    Write-InfoLine "qualified tree:                   $verifiedPartitionCount/$partitionCount partitions hash-verified against the composition manifest"
    Write-InfoLine "manifest anchored to record:      $manifestFileSha256"
    Write-InfoLine "preflight record:                 $outputFullPath"
    Write-InfoLine 'baseline preflight: PASS (contract identity, clean checkout and qualified tree verified before launch)'
    exit $script:ExitExpected
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

# Contract identity at launch time: the pre-run evidence must name this exact
# canonical contract and the register pin, and the two must agree. This is what
# binds the run to the frozen contract identity rather than to "whatever
# contract the classifier happens to see now".
$preRunContractPath = [string](Get-PropertyOrNull $invocation 'baselineContractPath')
$preRunContractSha256 = [string](Get-PropertyOrNull $invocation 'baselineContractSha256')
$preRunRegisterPath = [string](Get-PropertyOrNull $invocation 'baselineRegisterPath')
$preRunRegisterPin = [string](Get-PropertyOrNull $invocation 'baselineRegisterPin')
if ([string]::IsNullOrWhiteSpace($preRunContractPath) -or [string]::IsNullOrWhiteSpace($preRunRegisterPath) -or [string]::IsNullOrWhiteSpace($preRunContractSha256) -or [string]::IsNullOrWhiteSpace($preRunRegisterPin)) {
    Fail-Preflight "the run's pre-run invocation evidence names no baseline contract identity; the run cannot be bound to the frozen contract." $outputFullPath $authoritative
}
if ([System.IO.Path]::GetFullPath($preRunContractPath) -ne $contractPath -or [System.IO.Path]::GetFullPath($preRunRegisterPath) -ne $registerPath) {
    Fail-Preflight "the run's pre-run evidence names contract '$preRunContractPath' / register '$preRunRegisterPath', not the canonical '$contractPath' / '$registerPath'." $outputFullPath $authoritative
}
if ($preRunContractSha256 -ne $contractSha256 -or $preRunRegisterPin -ne $preRunContractSha256) {
    Fail-Preflight "the run's pre-run contract hash $preRunContractSha256 / pin $preRunRegisterPin does not match the canonical contract hash $contractSha256." $outputFullPath $authoritative
}

# Repository and qualified runtime provenance captured before the run.
$repositoryHead = [string](Get-PropertyOrNull $invocation 'repositoryHead')
$repositoryDirty = Get-PropertyOrNull $invocation 'repositoryDirty'
if ([string]::IsNullOrWhiteSpace($repositoryHead)) {
    Fail-Preflight "the run's pre-run evidence records no Git HEAD; the reviewed freeze commit cannot be established." $outputFullPath $authoritative
}
if ($null -eq $repositoryDirty -or [bool]$repositoryDirty) {
    Fail-Preflight "the run was launched from a dirty working tree (or the evidence does not say); the authoritative baseline must run from the reviewed and merged freeze commit." $outputFullPath $authoritative
}
$expectedRuntimeBinaries = @(
    'QuantConnect.Lean.Launcher.dll',
    'QuantConnect.Lean.Engine.dll',
    'QuantConnect.Common.dll',
    'QuantConnect.Algorithm.dll',
    'QuantConnect.AlgorithmFactory.dll',
    'QuantConnect.Configuration.dll',
    'QuantConnect.Logging.dll'
)
$runtimeBinariesRoot = [string](Get-PropertyOrNull $invocation 'runtimeBinariesRoot')
$runtimeBinaries = Get-PropertyOrNull $invocation 'runtimeBinaries'
if ([string]::IsNullOrWhiteSpace($runtimeBinariesRoot) -or $null -eq $runtimeBinaries) {
    Fail-Preflight "the run's pre-run evidence records no qualified runtime binary set." $outputFullPath $authoritative
}
$runtimeNames = @($runtimeBinaries.PSObject.Properties.Name)
if ((@($runtimeNames | Sort-Object) -join ',') -ne (@($expectedRuntimeBinaries | Sort-Object) -join ',')) {
    Fail-Preflight "the run's runtime binary set is not the qualified set: $($runtimeNames -join ', ')." $outputFullPath $authoritative
}
foreach ($name in $expectedRuntimeBinaries) {
    $runtimePath = Join-Path $runtimeBinariesRoot $name
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        Fail-Preflight "the qualified runtime binary '$runtimePath' no longer exists; the run runtime identity cannot be proven." $outputFullPath $authoritative
    }
    $runtimeHash = Get-FileSha256 $runtimePath
    if ($runtimeHash -ne [string]$runtimeBinaries.$name) {
        Fail-Preflight "the runtime binary '$name' now hashes to $runtimeHash but the pre-run evidence recorded $($runtimeBinaries.$name); the qualified runtime changed after the run." $outputFullPath $authoritative
    }
}
$invocationTerminalException = [string](Get-PropertyOrNull $invocation 'expectedTerminalException')
if ($invocationTerminalException -ne 'MarketLab.SingleAnchor.AccountStopOutException') {
    Fail-Preflight "the run's pre-run evidence declares expected terminal exception '$invocationTerminalException', not the frozen 'MarketLab.SingleAnchor.AccountStopOutException'." $outputFullPath $authoritative
}

$verifiedBuild = $null
if ($authoritative) {
    try {
        $runReviewedCommit = [string](Get-RequiredProperty $invocation 'reviewedCommit')
        if ($ReviewedCommit -and $ReviewedCommit -cne $runReviewedCommit) { throw 'The requested reviewed commit differs from the run.' }
        if ($repositoryHead -cne $runReviewedCommit) { throw 'The run HEAD differs from the approved revision.' }
        $runBuildPath = Join-Path $runPath 'baseline-build.json'
        $runPreflightPath = Join-Path $runPath 'baseline-preflight.json'
        if ((Get-FileSha256 $runBuildPath) -cne (Get-RequiredProperty $invocation 'buildReceiptSha256') -or
            (Get-FileSha256 $runPreflightPath) -cne (Get-RequiredProperty $invocation 'preflightSha256')) {
            throw 'The run build/preflight evidence is missing or differs from its invocation binding.'
        }
        $verifiedBuild = Assert-BaselineBuild $runBuildPath $baselineRepoRoot $runReviewedCommit $invocation.dotnet $contractSha256
        $runPreflight = [IO.File]::ReadAllText($runPreflightPath) | ConvertFrom-Json
        if ($runPreflight.authoritative -ne $true -or $runPreflight.qualification -cne 'PREFLIGHT-PASS' -or
            $runPreflight.reviewedCommit -cne $runReviewedCommit -or $runPreflight.baselineContractSha256 -cne $contractSha256 -or
            $runPreflight.buildReceiptSha256 -cne $invocation.buildReceiptSha256 -or $runPreflight.launchInputsVerified -ne $true -or
            $runPreflight.compositionManifestSha256 -cne $manifestFileSha256 -or $runPreflight.qualificationRecordSha256 -cne $qualificationRecordSha256) {
            throw 'The mandatory preflight is not bound to this run, build, contract and qualified tree.'
        }
        if ($results.runtimeVersion -cne $verifiedBuild.runtime.version -or
            ([IO.Path]::GetFullPath($results.runtimeDirectory)).TrimEnd('\', '/') -ne ([IO.Path]::GetFullPath($verifiedBuild.runtime.directory)).TrimEnd('\', '/')) {
            throw 'The host did not execute under the pinned .NET runtime.'
        }
        $expectedPrefix = @('exec', '--fx-version', $verifiedBuild.runtime.version, '--roll-forward', 'Disable')
        if ((@($invocation.commandLine | Select-Object -First 5) -join '|') -cne ($expectedPrefix -join '|')) {
            throw 'The run did not pin .NET runtime resolution on the launcher command line.'
        }
    } catch { Fail-Preflight $_.Exception.Message $outputFullPath $authoritative }
}
try {
    $deliveryVerification = Assert-BaselineDelivery $results $manifestData $dataIdentity $resolvedDataFolder
} catch { Fail-Preflight ("Strategy delivery verification failed: " + $_.Exception.Message) $outputFullPath $authoritative }

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
            $parsedFailureTime = ConvertTo-BaselineUtc $failureTime
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

# --- Post-run outcome evidence: the helper's own verdict on the run -------------
# The pre-run evidence says what was launched; this record says how it ended. A
# normally completed run must have a clean helper outcome (LEAN exit 0, helper
# exit 0, engine-error check performed with zero engine errors). An
# AccountStopOut run has exactly the modeled terminal shape (LEAN exit 1,
# helper exit 1, engine-error check not performed because LEAN did not exit 0).
# Anything else is not an authoritative baseline outcome.
$outcomePath = Join-Path $runPath 'marketlab-run-outcome.json'
if (-not (Test-Path -LiteralPath $outcomePath -PathType Leaf)) {
    Fail-Preflight "the run has no outcome evidence '$outcomePath'; launch the baseline with run-backtest.ps1 -RunEvidence so the helper's verdict is provable." $outputFullPath $authoritative
}
try {
    $outcome = [System.IO.File]::ReadAllText($outcomePath) | ConvertFrom-Json
    $outcomeContract = Get-RequiredProperty $outcome 'contract'
    $outcomeInvocationSha = [string](Get-RequiredProperty $outcome 'invocationEvidenceSha256')
    $outcomeLeanExit = [int](Get-RequiredProperty $outcome 'leanExitCode')
    $outcomeHelperExit = [int](Get-RequiredProperty $outcome 'helperExitCode')
    $outcomeEnginePerformed = [bool](Get-RequiredProperty $outcome 'engineErrorCheckPerformed')
    $outcomeEngineCount = Get-PropertyOrNull $outcome 'engineErrorCount'
    $outcomeTerminalException = [string](Get-PropertyOrNull $outcome 'expectedTerminalException')
    $outcomeTerminalLines = Get-PropertyOrNull $outcome 'terminalExceptionLineCount'
    $outcomeFailedCount = Get-PropertyOrNull $outcome 'failedDataRequestCount'
    $outcomeMonitor = [string](Get-PropertyOrNull $outcome 'dataMonitorReport')
    $outcomeBinariesUnchanged = [bool](Get-RequiredProperty $outcome 'runtimeBinariesUnchanged')
    $outcomeBinariesAfter = Get-RequiredProperty $outcome 'runtimeBinariesAfter'
}
catch {
    Fail-Preflight "the run outcome evidence is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($authoritative) {
    try {
        $afterArtifacts = Get-RequiredProperty $outcome 'baselineArtifactsAfter'
        $afterDictionary = [ordered]@{}
        foreach ($property in $afterArtifacts.PSObject.Properties) { $afterDictionary[$property.Name] = $property.Value }
        Assert-BaselineArtifactEquality $verifiedBuild.artifacts $afterDictionary
        if ((Get-RequiredProperty $outcome 'strategyResultsSha256') -cne (Get-FileSha256 $resultsPath)) {
            throw 'The strategy results differ from the helper outcome evidence.'
        }
    } catch { Fail-Preflight $_.Exception.Message $outputFullPath $authoritative }
}
if ($outcomeContract -ne 'marketlab-run-outcome-evidence-v1') {
    Fail-Preflight "the run outcome contract '$outcomeContract' is not 'marketlab-run-outcome-evidence-v1'." $outputFullPath $authoritative
}
if ($outcomeInvocationSha -ne (Get-FileSha256 $invocationEvidencePath)) {
    Fail-Preflight "the run outcome is not bound to the pre-run invocation evidence (recorded $outcomeInvocationSha)." $outputFullPath $authoritative
}
if ($outcomeMonitor -ne $monitorFiles[0].Name) {
    Fail-Preflight "the run outcome names monitor '$outcomeMonitor' but the run directory carries '$($monitorFiles[0].Name)'." $outputFullPath $authoritative
}
if ($null -eq $outcomeFailedCount -or [int]$outcomeFailedCount -ne $monitorFailedCount) {
    Fail-Preflight "the run outcome records failed-data count '$outcomeFailedCount' but the data monitor reports $monitorFailedCount." $outputFullPath $authoritative
}
if (-not $outcomeBinariesUnchanged) {
    Fail-Preflight 'the qualified runtime binaries changed during the run; the run runtime identity is not stable.' $outputFullPath $authoritative
}
$outcomeRuntimeNames = @($outcomeBinariesAfter.PSObject.Properties.Name)
if ((@($outcomeRuntimeNames | Sort-Object) -join ',') -ne (@($expectedRuntimeBinaries | Sort-Object) -join ',')) {
    Fail-Preflight "the run outcome runtime binary set is not the qualified set: $($outcomeRuntimeNames -join ', ')." $outputFullPath $authoritative
}
foreach ($name in $expectedRuntimeBinaries) {
    if ([string]$outcomeBinariesAfter.$name -ne [string]$runtimeBinaries.$name) {
        Fail-Preflight "the run outcome's post-run hash of '$name' differs from the pre-run hash." $outputFullPath $authoritative
    }
}
if ($runTerminated) {
    if ($outcomeLeanExit -ne 1 -or $outcomeHelperExit -ne 1 -or -not $outcomeEnginePerformed) {
        Fail-Preflight "the AccountStopOut run outcome is not the approved terminal shape (LEAN exit $outcomeLeanExit, helper exit $outcomeHelperExit, engine check performed $outcomeEnginePerformed)." $outputFullPath $authoritative
    }
    if ($outcomeTerminalException -ne 'MarketLab.SingleAnchor.AccountStopOutException') {
        Fail-Preflight "the run outcome's expected terminal exception '$outcomeTerminalException' is not the frozen 'MarketLab.SingleAnchor.AccountStopOutException'." $outputFullPath $authoritative
    }
    if ($null -eq $outcomeTerminalLines -or [int]$outcomeTerminalLines -lt 1) {
        Fail-Preflight 'the AccountStopOut run outcome records no expected terminal exception line; the engine log audit did not observe the modeled terminal outcome.' $outputFullPath $authoritative
    }
    if ($null -eq $outcomeEngineCount -or [int]$outcomeEngineCount -ne 0) {
        Fail-Preflight "the AccountStopOut run outcome records $outcomeEngineCount unrelated engine ERROR:: line(s) beyond the expected terminal exception; the baseline is invalid." $outputFullPath $authoritative
    }
}
else {
    if ($outcomeLeanExit -ne 0 -or $outcomeHelperExit -ne 0 -or -not $outcomeEnginePerformed) {
        Fail-Preflight "the run outcome is not clean (LEAN exit $outcomeLeanExit, helper exit $outcomeHelperExit, engine check performed $outcomeEnginePerformed); the baseline is invalid." $outputFullPath $authoritative
    }
    if ($null -eq $outcomeEngineCount -or [int]$outcomeEngineCount -ne 0) {
        Fail-Preflight "the run outcome records $outcomeEngineCount engine ERROR:: line(s); an engine/runtime error makes the baseline invalid." $outputFullPath $authoritative
    }
    if ($null -ne $outcomeTerminalLines -and [int]$outcomeTerminalLines -ne 0) {
        Fail-Preflight 'a completed run records expected terminal exception lines; the baseline is invalid.' $outputFullPath $authoritative
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
$record['resultsSha256'] = Get-FileSha256 $resultsPath
$record['deliveryVerification'] = $deliveryVerification
$record['invocationEvidenceFile'] = $invocationEvidencePath
$record['invocationEvidenceVerified'] = $true
$record['preRunContractSha256'] = $preRunContractSha256
$record['preRunRegisterPin'] = $preRunRegisterPin
$record['repositoryHead'] = $repositoryHead
$record['repositoryDirty'] = $repositoryDirty
$record['runtimeBinaryNames'] = $expectedRuntimeBinaries
$record['runtimeBinariesVerified'] = $true
$record['runOutcomeFile'] = $outcomePath
$record['runOutcomeVerified'] = $true
$record['leanExitCode'] = $outcomeLeanExit
$record['helperExitCode'] = $outcomeHelperExit
$record['engineErrorCheckPerformed'] = $outcomeEnginePerformed
$record['engineErrorCount'] = $outcomeEngineCount
$record['expectedTerminalException'] = $outcomeTerminalException
$record['terminalExceptionLineCount'] = $outcomeTerminalLines
$record['symbol'] = $symbol
$record['market'] = $market
$record['startDate'] = $startText
$record['endDate'] = $endText
$record['resolvedDataFolder'] = $resolvedDataFolder
$record['dataFolderSource'] = $dataFolderSource
$record['compositionManifest'] = $manifestPath
$record['compositionManifestSha256'] = $manifestFileSha256
$record['qualificationRecord'] = $qualificationRecordPath
$record['qualificationRecordSha256'] = $qualificationRecordSha256
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
