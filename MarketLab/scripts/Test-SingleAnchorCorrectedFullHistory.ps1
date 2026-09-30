<#
.SYNOPSIS
Preflight and classification for the corrected untouched full-history SingleAnchor run (Phase D)
under the finalized Phase B broker-forced-liquidation model.

.DESCRIPTION
The corrected full-history run executes exactly the frozen Phase A strategy/account/data values
unchanged and differs from the historical baseline only in the account Stop Out behavior. Its
evidence chain is deliberately separate from the frozen pre-liquidation baseline classifier
(scripts\Test-SingleAnchorBaselineFailedData.ps1), which stays bound to the historical terminal
AccountStopOut result shape and is never used to certify a Phase D run.

1. The corrected-full-history descriptor (config\corrected-full-history-contract.json) must be
   the frozen immutable corrected contract, must name the finalized Phase B broker-liquidation
   model identity (marketlab-single-anchor-broker-liquidation-v1 / BrokerLiquidation), and must
   pin the actual frozen baseline contract hash (LF-normalized). In the authoritative mode the
   frozen baseline register pin is checked as well, so the descriptor cannot silently point at
   an edited baseline contract.
2. Every effective value of the run comes from the frozen baseline contract: the symbol/market/
   security identity, the full qualified window, the 30 single-anchor-* parameters, the research
   account/margin contract and the failed-data policy. The run's invocation evidence and
   persisted parameter block must match it exactly.
3. The machine-local continuous tree must still be the qualified tree: the composition manifest,
   the replay qualification record anchor, every one of the 2,332 partition zips, the market-hours
   and symbol-properties databases and the session map are hash-verified. This is what makes a
   Phase D preflight possible without replaying the 413,750,130 rows.
4. In the authoritative mode the checkout must be clean at the explicit reviewed commit and a
   successful source-bound build receipt must bind that tree and the frozen contract hash; the
   run's own copied build receipt and preflight record are re-verified and the launcher's exact
   command line, runtime pinning and algorithm artifact hash are checked.
5. The result must name modelRevision 'marketlab-single-anchor-broker-liquidation-v1' and
   stopOutModel 'BrokerLiquidation'. Delivery is verified with the current-model verifier
   (Assert-BrokerLiquidationDelivery in scripts\SingleAnchorDelivery.ps1):
   - a completed run must carry the full qualified stream (2,332 partitions, 413,750,130 quotes,
     the qualified first/last quotes and global semantic digest) and a clean helper outcome
     (LEAN exit 0, helper exit 0, engine-error audit performed, zero engine ERROR:: lines);
   - a terminal run (one of the current model's own run-ending failure kinds with its exact
     reviewed condition) must carry the exact qualified prefix ending at its last processed
     quote, with the partial terminal day proven by reading the native ZIP prefix, LEAN exit 1 /
     helper exit 1, and exactly one terminal engine ERROR:: line (the SetRuntimeError line
     naming the recorded failure's exception type and message) with no unrelated engine
     ERROR:: lines. The faulting quote is bound to the engine's semantics: the final processed
     quote for accepted-then-faulted kinds, and the next qualified source quote after the
     verified prefix for pre-acceptance kinds. AccountStopOut is refused: it belongs to the
     historical model.
6. Every failed data request is classified against the frozen window, the qualified tree and the
   run's processed horizon (a completed run's horizon is the full window; a terminal run's is its
   last processed day). A source-absent calendar day inside the horizon that was never requested,
   a post-horizon failed request, a failed request for a qualified partition, an out-of-window or
   unknown request, an accounting mismatch or a contract/evidence mismatch invalidates the run.

The -Preflight -CheckOnly mode is the exact non-result-dependent stage run-backtest.ps1 invokes
immediately before launching the corrected run; only result-dependent checks remain for the
post-run classification.

Exit codes:
  0  the corrected run is classified EXPECTED (completed full stream or an exactly evidenced
     current-model terminal failure) with an authoritative provenance chain
  1  at least one unexpected failed-request condition: the corrected run is INVALID
  2  controlled configuration failure: bad/mismatched descriptor, unpinned baseline contract,
     a run that is not the corrected full-history run, a non-current-model result, a terminal
     condition outside the current model's kinds, a delivery/evidence mismatch, or a data tree
     that no longer matches its composition manifest

.PARAMETER Contract
Path to the frozen corrected-full-history contract. Required.

.PARAMETER RunDirectory
The corrected run directory (contains storage\single-anchor\results.json,
marketlab-run-invocation.json, marketlab-run-outcome.json, baseline-build.json,
corrected-history-preflight.json, data-monitor-report-*.json, failed-data-requests-*.txt).
Required unless -Preflight is used.

.PARAMETER ReviewedCommit
The explicitly reviewed full commit SHA. Required for the authoritative preflight and post-run
classification; the run's recorded reviewed SHA must equal it.

.PARAMETER BuildReceipt
Successful receipt produced by Build-SingleAnchorBaseline.ps1 for the reviewed commit. Default:
MarketLab\output\baseline-build.json.

.PARAMETER DotnetPath
The dotnet executable selected by the helper. Defaults to the first dotnet on PATH.

.PARAMETER Evidence
Path to the tracked continuous-history evidence. Default: the frozen baseline contract's
qualifiedDataIdentity.evidence path (the tracked PR 13 record). An override is only accepted
together with -AllowNonAuthoritativeOverride.

.PARAMETER DataFolder
Test-only override of the qualified data folder; only accepted together with
-AllowNonAuthoritativeOverride.

.PARAMETER Preflight
Run only the pre-run stage: descriptor identity, frozen-baseline pin, register pin, clean reviewed
checkout, source-bound build receipt and the complete qualified tree. Writes the preflight record
(or, with -CheckOnly, returns it as JSON on stdout without writing).

.PARAMETER CheckOnly
With -Preflight: return the preflight JSON in memory and write no record. Used by the helper's
mandatory launch check, including DryRun.

.PARAMETER AllowNonAuthoritativeOverride
Test-only: permits synthetic fixtures and skipped Git/build checks. The record is marked
authoritative:false and must never be presented as the authoritative Phase D classification.

.PARAMETER OutputPath
Where to write the preflight/classification record. Defaults: MarketLab\output\
corrected-history-preflight.json for -Preflight, <RunDirectory>\corrected-full-history-classification.json
otherwise.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Contract,
    [string]$RunDirectory,
    [string]$ReviewedCommit,
    [string]$BuildReceipt,
    [string]$DotnetPath,
    [string]$Evidence,
    [string]$DataFolder,
    [switch]$Preflight,
    [switch]$CheckOnly,
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
$script:CorrectedContractId = 'marketlab-single-anchor-corrected-full-history-contract-v1'
$script:BaselineContractId = 'marketlab-single-anchor-baseline-contract-v1'
$script:ModelRevision = 'marketlab-single-anchor-broker-liquidation-v1'
$script:StopOutModel = 'BrokerLiquidation'
# The kind-to-exception map of the current implementation's run-ending conditions. It is locked
# here (and by the C# tests of the host) so the classifier cannot be pointed at a different class.
$script:TerminalExceptionByKind = [ordered]@{
    'StrategyInvariant' = 'MarketLab.SingleAnchor.StrategyInvariantException'
    'DataQuality'       = 'MarketLab.SingleAnchor.DataQualityException'
    'SessionMap'        = 'MarketLab.SingleAnchor.SessionMapException'
    'AccountSurvival'   = 'MarketLab.SingleAnchor.AccountSurvivalException'
    'BrokerLiquidation' = 'MarketLab.SingleAnchor.BrokerLiquidationException'
}
# The exact, case-sensitive condition each kind may carry (Execution.cs / SingleAnchorEngine.cs
# of the reviewed implementation). A kind outside this map, or a condition outside its list,
# can never certify a terminal Phase D classification.
$script:ConditionsByKind = [ordered]@{
    'StrategyInvariant' = @('HardBreakevenViolatedByFill')
    'DataQuality'       = @('InvalidQuote', 'OutOfOrderQuote')
    'SessionMap'        = @('QuoteOutsideMapCoverage')
    'AccountSurvival'   = @('ExecutableMarkUnavailable')
    'BrokerLiquidation' = @('ForcedCloseFailed')
}
# Which faults happen after the faulting quote was accepted and counted (so failure.Quote equals
# the final processed quote), and which are raised before acceptance (DataQuality/SessionMap: the
# refused quote is not counted and is the next qualified source quote after the delivered prefix).
$script:ProcessedFaultKinds = @('StrategyInvariant', 'AccountSurvival', 'BrokerLiquidation')
$script:PreAcceptanceFaultKinds = @('DataQuality', 'SessionMap')

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

# Strict JSON-boolean tests: a string "false" must never satisfy a true check (nor a string
# "true" a false check), so evidence fields cannot be smuggled past the classifier by type.
function Test-JsonTrue($Value) {
    return (($Value -is [bool]) -and [bool]$Value)
}

function Test-JsonFalse($Value) {
    return (($Value -is [bool]) -and -not [bool]$Value)
}

# Exact quote identity (Time, Bid, Ask) of two quote-shaped records. Missing or unparseable
# members are a mismatch, never a pass.
function Test-SameQuote($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $false }
    try {
        $sameTime = (ConvertTo-BaselineUtc (Get-PropertyOrNull $A 'Time')) -eq (ConvertTo-BaselineUtc (Get-PropertyOrNull $B 'Time'))
        $sameBid = ([decimal](Get-RequiredProperty $A 'Bid')) -eq ([decimal](Get-RequiredProperty $B 'Bid'))
        $sameAsk = ([decimal](Get-RequiredProperty $A 'Ask')) -eq ([decimal](Get-RequiredProperty $B 'Ask'))
        return $sameTime -and $sameBid -and $sameAsk
    }
    catch { return $false }
}

function Get-LfNormalizedSha256([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# A contract path is repository-relative in the tracked file; synthetic fixtures may supply an
# absolute path. Rooted paths are used as-is, everything else resolves against the repository.
function Resolve-RepoRelativePath([string]$RepoRoot, [string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

# Controlled configuration failure: report, write a record next to the run when possible, exit 2.
function Fail-Preflight([string]$Message, [string]$RecordPath, [bool]$Authoritative) {
    Write-ErrorLine $Message
    if ($RecordPath -and -not $CheckOnly) {
        $record = [ordered]@{}
        $record['contract'] = 'marketlab-single-anchor-corrected-full-history-classification-v1'
        $record['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $record['runDirectory'] = $RunDirectory
        $record['authoritative'] = $Authoritative
        $record['qualification'] = 'CONTROLLED_FAILURE'
        $record['failure'] = $Message
        try {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $RecordPath))
            $json = $record | ConvertTo-Json -Depth 4
            [System.IO.File]::WriteAllText($RecordPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-WarningLine "could not write the classification record to '$RecordPath': $($_.Exception.Message)"
        }
    }
    exit $script:ExitPreflight
}

# --- Inputs ---------------------------------------------------------------------
$correctedContractPath = [System.IO.Path]::GetFullPath($Contract)
$authoritative = -not $AllowNonAuthoritativeOverride
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($RunDirectory) -and -not $Preflight) {
    Write-ErrorLine 'the post-run classification requires -RunDirectory (or pass -Preflight for the pre-run verification stage).'
    exit $script:ExitPreflight
}
$runPath = $null
if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
    $runPath = [System.IO.Path]::GetFullPath($RunDirectory)
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if ($Preflight) {
        $OutputPath = Join-Path $repoRoot 'MarketLab\output\corrected-history-preflight.json'
    }
    else {
        $OutputPath = Join-Path $runPath 'corrected-full-history-classification.json'
    }
}
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not $BuildReceipt) { $BuildReceipt = Join-Path $repoRoot 'MarketLab\output\baseline-build.json' }
$BuildReceipt = [System.IO.Path]::GetFullPath($BuildReceipt)
if ($CheckOnly -and -not $Preflight) { throw '-CheckOnly is only supported with -Preflight.' }
if (-not [string]::IsNullOrWhiteSpace($DataFolder) -and -not $AllowNonAuthoritativeOverride) {
    Fail-Preflight 'the data folder must not be overridden for an authoritative classification; pass -AllowNonAuthoritativeOverride only for synthetic tests.' $outputFullPath $authoritative
}
if ($authoritative -and [string]::IsNullOrWhiteSpace($ReviewedCommit)) {
    Fail-Preflight 'an authoritative corrected-full-history classification requires -ReviewedCommit (the explicitly approved full Git commit SHA).' $outputFullPath $authoritative
}
if ($authoritative) {
    # The descriptor controls the terminal-failure policy, so an authoritative classification
    # must consume the canonical tracked descriptor from the reviewed checkout, not an arbitrary
    # file that merely hashes to whatever the invocation recorded. Synthetic fixtures use the
    # explicit -AllowNonAuthoritativeOverride mode.
    $canonicalDescriptorPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'MarketLab\config\corrected-full-history-contract.json'))
    if ($correctedContractPath -ne $canonicalDescriptorPath) {
        Fail-Preflight "an authoritative corrected-full-history classification requires the canonical tracked descriptor '$canonicalDescriptorPath' from the reviewed checkout (got '$correctedContractPath')." $outputFullPath $authoritative
    }
}
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

# --- Corrected-full-history descriptor and its frozen-baseline pin --------------
if (-not (Test-Path -LiteralPath $correctedContractPath -PathType Leaf)) {
    Fail-Preflight "the corrected-full-history contract '$correctedContractPath' does not exist." $outputFullPath $authoritative
}
$correctedSha256 = Get-LfNormalizedSha256 $correctedContractPath
try {
    $correctedData = [System.IO.File]::ReadAllText($correctedContractPath) | ConvertFrom-Json
    $correctedId = [string](Get-RequiredProperty $correctedData 'contract')
    $correctedStatus = [string](Get-RequiredProperty $correctedData 'status')
    $correctedImmutable = Test-JsonTrue (Get-RequiredProperty $correctedData 'immutable')
}
catch {
    Fail-Preflight "the corrected-full-history contract is unreadable: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($correctedId -ne $script:CorrectedContractId -or $correctedStatus -ne 'frozen' -or -not $correctedImmutable) {
    Fail-Preflight 'the contract is not the frozen immutable corrected-full-history contract.' $outputFullPath $authoritative
}
try {
    $modelRevision = [string](Get-RequiredProperty (Get-RequiredProperty $correctedData 'model') 'revision')
    $stopOutModel = [string](Get-RequiredProperty (Get-RequiredProperty $correctedData 'model') 'stopOutModel')
    $terminalKinds = @(Get-RequiredProperty (Get-RequiredProperty $correctedData 'model') 'terminalFailureKinds')
}
catch {
    Fail-Preflight "the corrected-full-history contract model block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($modelRevision -cne $script:ModelRevision -or $stopOutModel -cne $script:StopOutModel) {
    Fail-Preflight "the corrected-full-history contract does not name the finalized model ($script:ModelRevision / $script:StopOutModel); got '$modelRevision' / '$stopOutModel'." $outputFullPath $authoritative
}
if ($terminalKinds.Count -eq 0) { Fail-Preflight 'the corrected-full-history contract lists no terminal failure kinds.' $outputFullPath $authoritative }
foreach ($kind in $terminalKinds) {
    if ([string]$kind -ceq 'AccountStopOut') {
        Fail-Preflight 'the corrected-full-history contract must not list the historical AccountStopOut kind; the current model never raises it.' $outputFullPath $authoritative
    }
    if (-not $script:TerminalExceptionByKind.Contains([string]$kind)) {
        Fail-Preflight "the corrected-full-history contract lists unknown terminal failure kind '$kind'." $outputFullPath $authoritative
    }
}

$baselineContractPath = $null
$baselineRegisterPath = $null
$baselineContractSha256 = $null
$baselineRegisterPin = ''
try {
    $baselineContractPath = Resolve-RepoRelativePath $repoRoot ([string](Get-RequiredProperty (Get-RequiredProperty $correctedData 'baselineContract') 'path'))
    $baselinePin = [string](Get-RequiredProperty (Get-RequiredProperty $correctedData 'baselineContract') 'sha256LfNormalized')
    $baselineRegisterPath = Resolve-RepoRelativePath $repoRoot ([string](Get-RequiredProperty (Get-RequiredProperty $correctedData 'baselineContract') 'registerPath'))
}
catch {
    Fail-Preflight "the corrected-full-history contract baseline pin block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if (-not (Test-Path -LiteralPath $baselineContractPath -PathType Leaf)) {
    Fail-Preflight "the corrected-full-history contract references baseline contract '$baselineContractPath' which does not exist." $outputFullPath $authoritative
}
$baselineContractSha256 = Get-LfNormalizedSha256 $baselineContractPath
if ($baselineContractSha256 -ne $baselinePin) {
    Fail-Preflight "the corrected-full-history contract pins baseline hash $baselinePin but '$baselineContractPath' hashes to $baselineContractSha256; the frozen baseline contract changed." $outputFullPath $authoritative
}
try {
    $baselineData = [System.IO.File]::ReadAllText($baselineContractPath) | ConvertFrom-Json
    $baselineId = [string](Get-RequiredProperty $baselineData 'contract')
    $baselineStatus = [string](Get-RequiredProperty $baselineData 'status')
    $baselineImmutable = Test-JsonTrue (Get-RequiredProperty $baselineData 'immutable')
    $dataIdentity = Get-RequiredProperty $baselineData 'qualifiedDataIdentity'
    $policy = Get-RequiredProperty $baselineData 'failedDataRequestPolicy'
    $runHost = Get-RequiredProperty $baselineData 'runHost'
    $baselineParameters = @(Get-RequiredProperty $baselineData 'parameters')
}
catch {
    Fail-Preflight "the frozen baseline contract is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($baselineId -ne $script:BaselineContractId -or $baselineStatus -ne 'frozen' -or -not $baselineImmutable) {
    Fail-Preflight 'the corrected-full-history contract does not reference the frozen immutable baseline contract.' $outputFullPath $authoritative
}
if ($baselineParameters.Count -eq 0) { Fail-Preflight 'the frozen baseline contract carries no parameters.' $outputFullPath $authoritative }

if ($authoritative) {
    if (-not (Test-Path -LiteralPath $baselineRegisterPath -PathType Leaf)) {
        Fail-Preflight "the authoritative decision register '$baselineRegisterPath' does not exist; the frozen baseline contract hash cannot be checked against its pin." $outputFullPath $authoritative
    }
    try {
        $registerData = [System.IO.File]::ReadAllText($baselineRegisterPath) | ConvertFrom-Json
        $registerId = [string](Get-RequiredProperty $registerData 'contract')
        $baselineRegisterPin = [string](Get-RequiredProperty $registerData 'frozenBaselineContractSha256')
    }
    catch {
        Fail-Preflight "the authoritative decision register is unreadable: $($_.Exception.Message)" $outputFullPath $authoritative
    }
    if ($registerId -ne 'marketlab-baseline-decision-audit-v1') {
        Fail-Preflight "the register contract '$registerId' is not 'marketlab-baseline-decision-audit-v1'." $outputFullPath $authoritative
    }
    if ($baselineRegisterPin -ne $baselineContractSha256) {
        Fail-Preflight "the frozen baseline contract hash $baselineContractSha256 does not match the register pin $baselineRegisterPin; the corrected run cannot be based on this contract." $outputFullPath $authoritative
    }
}

# --- Effective frozen values used by every check below --------------------------
try {
    $contractEvidencePath = Resolve-RepoRelativePath $repoRoot ([string](Get-RequiredProperty $dataIdentity 'evidence'))
    if ([string]::IsNullOrWhiteSpace($Evidence)) { $evidencePath = $contractEvidencePath }
    else { $evidencePath = [IO.Path]::GetFullPath($Evidence) }
    if ($authoritative -and $evidencePath -ne $contractEvidencePath) {
        throw 'the authoritative qualification must use the frozen contract-named tracked evidence file'
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
    Fail-Preflight "the frozen baseline contract identity/policy block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
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
    $replayEvidence = Get-RequiredProperty $evidenceData 'replay'
    $evidenceAbsentDays = [int](Get-RequiredProperty $replayEvidence 'source_absent_days')
    $evidenceMissingPartitions = [int](Get-RequiredProperty $replayEvidence 'missing_native_partitions')
    $evidenceCoverageGaps = [int](Get-RequiredProperty $replayEvidence 'source_coverage_gap_days')
    $evidenceUnrelated = [int](Get-RequiredProperty $replayEvidence 'unrelated_failed_data_requests')
}
catch {
    Fail-Preflight "the continuous-history evidence replay block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
try {
    $startDate = [System.DateTime]::ParseExact($startText, 'yyyy-MM-dd', $invariant)
    $endDate = [System.DateTime]::ParseExact($endText, 'yyyy-MM-dd', $invariant)
}
catch {
    Fail-Preflight "the frozen window '$startText'..'$endText' is not parseable: $($_.Exception.Message)" $outputFullPath $authoritative
}
$contractParameterValues = [ordered]@{}
$contractParameterNames = @()
foreach ($parameter in $baselineParameters) {
    $name = [string](Get-RequiredProperty $parameter 'name')
    $contractParameterNames += $name
    $contractParameterValues[$name] = [string](Get-RequiredProperty $parameter 'value')
}
$contractParametersString = (@($contractParameterNames | ForEach-Object { $_ + ':' + $contractParameterValues[$_] }) -join ',')

# --- Qualified continuous tree --------------------------------------------------
if ($AllowNonAuthoritativeOverride -and -not [string]::IsNullOrWhiteSpace($DataFolder)) {
    $resolvedDataFolder = [System.IO.Path]::GetFullPath($DataFolder)
    $dataFolderSource = 'override'
}
else {
    $resolvedDataFolder = [string](Get-RequiredProperty $dataIdentity 'dataFolder')
    $dataFolderSource = 'contract'
}
$manifestPath = Join-Path (Join-Path $resolvedDataFolder 'marketlab-qualification') 'continuous-composition.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Fail-Preflight "the qualified tree's composition manifest '$manifestPath' does not exist; the tree identity cannot be established." $outputFullPath $authoritative
}
try {
    $manifestData = [System.IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $manifestComposition = Get-RequiredProperty $manifestData 'composition'
    $manifestContract = [string](Get-RequiredProperty $manifestComposition 'contract')
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
    Fail-Preflight ("the composition manifest does not match the frozen baseline contract: " + ($manifestProblems -join ', ') + ".") $outputFullPath $authoritative
}

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
    $recordContract = [string](Get-RequiredProperty $qualificationRecord 'contract')
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
    Fail-Preflight "the qualified tree carries $($actualNames.Count) partitions and the manifest records $($manifestZips.Count); the frozen contract binds $partitionCount." $outputFullPath $authoritative
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

$semanticBlock = Get-PropertyOrNull $manifestData 'semantic'
$perPartition = Get-PropertyOrNull $semanticBlock 'per_partition'
if ($null -eq $perPartition) {
    Fail-Preflight 'the composition manifest carries no semantic.per_partition day map.' $outputFullPath $authoritative
}
$semanticDays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($property in $perPartition.PSObject.Properties) {
    $parsed = [System.DateTime]::MinValue
    try { $parsed = [System.DateTime]::ParseExact($property.Name, 'yyyy-MM-dd', $invariant) }
    catch { $parsed = [System.DateTime]::MinValue }
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
    Fail-Preflight "the tree's market-hours database does not match the frozen baseline contract hash $marketHoursSha256." $outputFullPath $authoritative
}
$symbolPropertiesPath = Join-Path (Join-Path $resolvedDataFolder 'symbol-properties') 'symbol-properties-database.csv'
if (-not (Test-Path -LiteralPath $symbolPropertiesPath -PathType Leaf) -or (Get-FileSha256 $symbolPropertiesPath) -ne $symbolPropertiesSha256) {
    Fail-Preflight "the tree's symbol-properties database does not match the frozen baseline contract hash $symbolPropertiesSha256." $outputFullPath $authoritative
}
$sessionMapPath = Join-Path $resolvedDataFolder $sessionMapRelative
if (-not (Test-Path -LiteralPath $sessionMapPath -PathType Leaf) -or (Get-FileSha256 $sessionMapPath) -ne $sessionMapSha256) {
    Fail-Preflight "the qualified session map does not match the frozen baseline contract hash $sessionMapSha256." $outputFullPath $authoritative
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

# --- Pre-run verification stage (-Preflight) ------------------------------------
if ($Preflight) {
    $preflightRepositoryHead = $null
    $preflightRepositoryDirty = $null
    $preflightBuild = $null
    if ($authoritative) {
        try {
            if (-not $DotnetPath) { $DotnetPath = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
            $source = Get-BaselineSourceState $repoRoot
            Assert-BaselineReviewedSource $source $ReviewedCommit
            $preflightRepositoryHead = $source.head
            $preflightRepositoryDirty = $source.dirty
            $preflightBuild = Assert-BaselineBuild $BuildReceipt $repoRoot $ReviewedCommit $DotnetPath $baselineContractSha256
        }
        catch {
            Fail-Preflight $_.Exception.Message $outputFullPath $authoritative
        }
    }
    $preflightRecord = [ordered]@{}
    $preflightRecord['contract'] = 'marketlab-single-anchor-corrected-full-history-preflight-v1'
    $preflightRecord['mode'] = 'corrected-full-history'
    $preflightRecord['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $preflightRecord['authoritative'] = $authoritative
    $preflightRecord['correctedContractPath'] = $correctedContractPath
    $preflightRecord['correctedContractSha256'] = $correctedSha256
    $preflightRecord['modelRevision'] = $modelRevision
    $preflightRecord['stopOutModel'] = $stopOutModel
    $preflightRecord['baselineContractPath'] = $baselineContractPath
    $preflightRecord['baselineContractSha256'] = $baselineContractSha256
    $preflightRecord['registerPin'] = $baselineRegisterPin
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
    $preflightRecord['partitionCount'] = $partitionCount
    $preflightRecord['sessionMapSha256'] = $sessionMapSha256
    $preflightRecord['marketHoursDatabaseSha256'] = $marketHoursSha256
    $preflightRecord['symbolPropertiesDatabaseSha256'] = $symbolPropertiesSha256
    $preflightRecord['sourceFileSetSha256'] = $sourceFileSetSha256
    $preflightRecord['orderedMonthDigestChainSha256'] = $orderedMonthDigestChainSha256
    $preflightRecord['continuousHistoryQuoteCount'] = $quoteCount
    $preflightRecord['expectedSourceAbsentDayCount'] = $expectedAbsentDays.Count
    $preflightRecord['qualification'] = 'PREFLIGHT-PASS'
    if ($CheckOnly) {
        $preflightRecord | ConvertTo-Json -Depth 6
        exit $script:ExitExpected
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $outputFullPath))
    [System.IO.File]::WriteAllText($outputFullPath, ($preflightRecord | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-InfoLine "corrected contract SHA-256:      $correctedSha256"
    Write-InfoLine "model:                          $modelRevision / $stopOutModel"
    Write-InfoLine "authoritative:                  $authoritative"
    Write-InfoLine "frozen baseline contract:       $baselineContractPath ($baselineContractSha256)"
    Write-InfoLine "qualified tree:                 $verifiedPartitionCount/$partitionCount partitions hash-verified against the composition manifest"
    Write-InfoLine "preflight record:               $outputFullPath"
    if ($authoritative) {
        Write-InfoLine 'corrected full-history preflight: PASS (descriptor, frozen pins, clean reviewed checkout, source-bound build and qualified tree verified before launch)'
    }
    else {
        Write-InfoLine 'corrected full-history preflight: PASS (test override: descriptor, frozen pins and qualified tree verified; checkout/build checks skipped)'
    }
    exit $script:ExitExpected
}

# --- Run identity: results ------------------------------------------------------
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
if ([string](Get-PropertyOrNull $results 'modelRevision') -cne $modelRevision) {
    Fail-Preflight "the run result names modelRevision '$([string](Get-PropertyOrNull $results 'modelRevision'))', not the corrected model '$modelRevision'." $outputFullPath $authoritative
}
if ([string](Get-PropertyOrNull $results 'stopOutModel') -cne $stopOutModel) {
    Fail-Preflight "the run result names stopOutModel '$([string](Get-PropertyOrNull $results 'stopOutModel'))', not '$stopOutModel'." $outputFullPath $authoritative
}
$resultSymbol = [string](Get-PropertyOrNull $results 'symbol')
$resultMarket = [string](Get-PropertyOrNull $results 'market')
$resultStart = [string](Get-PropertyOrNull $results 'startDate')
$resultEnd = [string](Get-PropertyOrNull $results 'endDate')
if ($resultSymbol -ne $symbol -or $resultMarket -ne $market -or $resultStart -ne $startText -or $resultEnd -ne $endText) {
    Fail-Preflight "the run identity ($resultSymbol/$resultMarket, $resultStart..$resultEnd) is not the frozen baseline identity ($symbol/$market, $startText..$endText)." $outputFullPath $authoritative
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
        $matches = ($actualValue -is [bool]) -and ([bool]$actualValue -eq [bool]::Parse($frozenText))
    }
    else {
        $frozenDecimal = [decimal]::Parse($frozenText, $invariant)
        $matches = ([decimal]$actualValue) -eq $frozenDecimal
    }
    if (-not $matches) {
        Fail-Preflight "the run parameter '$resultName' is '$actualValue' but the frozen baseline contract freezes '$frozenText'." $outputFullPath $authoritative
    }
}
if ($null -eq (Get-PropertyOrNull $results 'researchAccount')) {
    Fail-Preflight 'the run results carry no research account; the frozen baseline contract enables single-anchor-research-account.' $outputFullPath $authoritative
}
$resultInitialBalance = Get-PropertyOrNull (Get-PropertyOrNull $results 'researchAccount') 'InitialBalance'
$frozenCash = [decimal]::Parse($contractParameterValues['single-anchor-cash'], $invariant)
if ($null -eq $resultInitialBalance -or ([decimal]$resultInitialBalance) -ne $frozenCash) {
    Fail-Preflight "the run research account InitialBalance is '$resultInitialBalance' but the frozen baseline contract freezes '$frozenCash'." $outputFullPath $authoritative
}
if ($null -eq (Get-PropertyOrNull $results 'researchMargin')) {
    Fail-Preflight 'the run results carry no research margin block; the frozen baseline contract enables single-anchor-margin-enabled.' $outputFullPath $authoritative
}
# The effective account identity exposed in the result must be the frozen one: the numeric
# margin contract (100 oz/lot, 1:500, Margin Call 50%, Stop Out 20%) is checked directly rather
# than inferred from the source binding. The hedged-margin behavior stays source-bound.
try {
    $marginContract = Get-RequiredProperty $baselineData 'marginContract'
    if (-not (Test-JsonTrue (Get-RequiredProperty $marginContract 'enabled'))) {
        Fail-Preflight 'the frozen baseline contract does not enable the margin contract.' $outputFullPath $authoritative
    }
    $resultMarginParameters = Get-PropertyOrNull (Get-PropertyOrNull $results 'researchMargin') 'Parameters'
    if ($null -eq $resultMarginParameters) {
        Fail-Preflight 'the run research margin block carries no effective Parameters.' $outputFullPath $authoritative
    }
    $marginParameterMap = [ordered]@{
        ContractSize = 'contractSizeOzPerLot'
        Leverage = 'leverage'
        MarginCallLevelPercent = 'marginCallThresholdPercent'
        StopOutLevelPercent = 'stopOutThresholdPercent'
    }
    foreach ($entry in $marginParameterMap.GetEnumerator()) {
        $actualMargin = Get-PropertyOrNull $resultMarginParameters $entry.Key
        $expectedMargin = [decimal](Get-RequiredProperty $marginContract $entry.Value)
        if ($null -eq $actualMargin -or ([decimal]$actualMargin) -ne $expectedMargin) {
            Fail-Preflight "the run research margin parameter '$($entry.Key)' is '$actualMargin' but the frozen baseline contract freezes '$expectedMargin'." $outputFullPath $authoritative
        }
    }
}
catch { Fail-Preflight "the margin identity block is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative }
$resultSessionMap = Get-PropertyOrNull $results 'sessionMap'
if ($null -eq $resultSessionMap) {
    Fail-Preflight 'the run used no session map; the frozen baseline contract requires the qualified session map.' $outputFullPath $authoritative
}
$resultSessionMapSha = [string](Get-PropertyOrNull $resultSessionMap 'Sha256')
if ($resultSessionMapSha -ne $sessionMapSha256) {
    Fail-Preflight "the run session map hashes to '$resultSessionMapSha' but the frozen baseline contract binds '$sessionMapSha256'." $outputFullPath $authoritative
}

# --- Invocation evidence --------------------------------------------------------
$invocationEvidencePath = Join-Path $runPath 'marketlab-run-invocation.json'
if (-not (Test-Path -LiteralPath $invocationEvidencePath -PathType Leaf)) {
    Fail-Preflight "the run has no invocation evidence '$invocationEvidencePath'; launch the corrected run with run-backtest.ps1 -RunEvidence -CorrectedHistoryContract so the actual invocation is provable." $outputFullPath $authoritative
}
try {
    $invocation = [System.IO.File]::ReadAllText($invocationEvidencePath) | ConvertFrom-Json
    $invocationContract = [string](Get-RequiredProperty $invocation 'contract')
}
catch {
    Fail-Preflight "the run invocation evidence is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
}
if ($invocationContract -ne 'marketlab-run-invocation-evidence-v1') {
    Fail-Preflight "the run invocation evidence contract '$invocationContract' is not 'marketlab-run-invocation-evidence-v1'." $outputFullPath $authoritative
}
if ([string](Get-PropertyOrNull $invocation 'runMode') -cne 'corrected-full-history') {
    Fail-Preflight "the run invocation names runMode '$([string](Get-PropertyOrNull $invocation 'runMode'))', not 'corrected-full-history'; the corrected run must not be certified from another mode's evidence." $outputFullPath $authoritative
}
$invocationDataFolder = [string](Get-PropertyOrNull $invocation 'dataFolder')
$invocationDataFolderMatches = -not [string]::IsNullOrWhiteSpace($invocationDataFolder) -and
    ([System.IO.Path]::GetFullPath($invocationDataFolder) -eq [System.IO.Path]::GetFullPath($resolvedDataFolder))
$invocationRunDirectory = [string](Get-PropertyOrNull $invocation 'runDirectory')
$invocationRunDirectoryMatches = -not [string]::IsNullOrWhiteSpace($invocationRunDirectory) -and
    ([System.IO.Path]::GetFullPath($invocationRunDirectory) -eq $runPath)
$invocationWorkingDirectory = [string](Get-PropertyOrNull $invocation 'workingDirectory')
$invocationWorkingDirectoryMatches = -not [string]::IsNullOrWhiteSpace($invocationWorkingDirectory) -and
    ([System.IO.Path]::GetFullPath($invocationWorkingDirectory) -eq $runPath)
$invocationCorrectedPath = [string](Get-PropertyOrNull $invocation 'correctedHistoryContractPath')
$invocationCorrectedPathMatches = -not [string]::IsNullOrWhiteSpace($invocationCorrectedPath) -and
    ([System.IO.Path]::GetFullPath($invocationCorrectedPath) -eq $correctedContractPath)
$invocationChecks = [ordered]@{
    configuration = ([string](Get-PropertyOrNull $invocation 'configuration') -eq [string](Get-RequiredProperty $runHost 'buildConfiguration'))
    algorithmTypeName = ([string](Get-PropertyOrNull $invocation 'algorithmTypeName') -eq [string](Get-RequiredProperty $runHost 'algorithmTypeName'))
    algorithmLanguage = ([string](Get-PropertyOrNull $invocation 'algorithmLanguage') -eq [string](Get-RequiredProperty $runHost 'algorithmLanguage'))
    dataFolder = $invocationDataFolderMatches
    parameters = ([string](Get-PropertyOrNull $invocation 'parametersString') -eq $contractParametersString)
    closeAutomatically = Test-JsonTrue (Get-PropertyOrNull $invocation 'closeAutomatically')
    allowMissingData = Test-JsonTrue (Get-PropertyOrNull $invocation 'allowMissingData')
    allowEngineErrors = Test-JsonFalse (Get-PropertyOrNull $invocation 'allowEngineErrors')
    runDirectory = $invocationRunDirectoryMatches
    workingDirectory = $invocationWorkingDirectoryMatches
    noDeclaredTerminalException = [string]::IsNullOrEmpty([string](Get-PropertyOrNull $invocation 'expectedTerminalException'))
    noBaselineContract = [string]::IsNullOrEmpty([string](Get-PropertyOrNull $invocation 'baselineContractPath')) -and
        [string]::IsNullOrEmpty([string](Get-PropertyOrNull $invocation 'baselineContractSha256')) -and
        [string]::IsNullOrEmpty([string](Get-PropertyOrNull $invocation 'baselineRegisterPath')) -and
        [string]::IsNullOrEmpty([string](Get-PropertyOrNull $invocation 'baselineRegisterPin'))
    correctedContractPath = $invocationCorrectedPathMatches
    correctedContractSha256 = ([string](Get-PropertyOrNull $invocation 'correctedHistoryContractSha256') -eq $correctedSha256)
}
$invocationProblems = @()
foreach ($check in $invocationChecks.GetEnumerator()) {
    if (-not $check.Value) { $invocationProblems += $check.Key }
}
$invocationDirty = Get-PropertyOrNull $invocation 'repositoryDirty'
if ($null -eq $invocationDirty -or [bool]$invocationDirty) {
    $invocationProblems += 'repositoryDirty'
}
$expectedLocation = ([string](Get-RequiredProperty $runHost 'algorithmLocation')).Replace('/', '\')
$actualLocation = ([string](Get-PropertyOrNull $invocation 'algorithmLocation')).Replace('/', '\')
if ($actualLocation.Length -eq 0 -or -not $actualLocation.EndsWith($expectedLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
    $invocationProblems += 'algorithmLocation'
}
$invocationRepositoryHead = [string](Get-PropertyOrNull $invocation 'repositoryHead')
if ([string]::IsNullOrWhiteSpace($invocationRepositoryHead) -or
    (-not [string]::IsNullOrWhiteSpace($ReviewedCommit) -and $invocationRepositoryHead -cne $ReviewedCommit)) {
    $invocationProblems += 'repositoryHead'
}
$invocationReviewedCommit = [string](Get-PropertyOrNull $invocation 'reviewedCommit')
if ([string]::IsNullOrWhiteSpace($invocationReviewedCommit) -or
    (-not [string]::IsNullOrWhiteSpace($ReviewedCommit) -and $invocationReviewedCommit -cne $ReviewedCommit)) {
    $invocationProblems += 'reviewedCommit'
}
if ($invocationProblems.Count -gt 0) {
    Fail-Preflight ("the run's persisted invocation does not match the corrected full-history contract: " + ($invocationProblems -join ', ') + ".") $outputFullPath $authoritative
}
$invocationConfigPath = [string](Get-PropertyOrNull $invocation 'configPath')
if (-not (Test-Path -LiteralPath $invocationConfigPath -PathType Leaf)) {
    Fail-Preflight "the run invocation evidence config file '$invocationConfigPath' does not exist." $outputFullPath $authoritative
}
$actualConfigHash = Get-LfNormalizedSha256 $invocationConfigPath
$frozenConfigHash = [string](Get-RequiredProperty $runHost 'leanConfigSha256LfNormalized')
if ($actualConfigHash -ne $frozenConfigHash -or [string](Get-PropertyOrNull $invocation 'configSha256LfNormalized') -ne $frozenConfigHash) {
    Fail-Preflight "the run's LEAN config hashes to $actualConfigHash but the frozen baseline contract binds $frozenConfigHash." $outputFullPath $authoritative
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

$verifiedBuild = $null
if ($authoritative) {
    try {
        if (-not $DotnetPath) { $DotnetPath = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
        $runBuildPath = Join-Path $runPath 'baseline-build.json'
        $runPreflightPath = Join-Path $runPath 'corrected-history-preflight.json'
        if ((Get-FileSha256 $runBuildPath) -cne (Get-RequiredProperty $invocation 'buildReceiptSha256') -or
            (Get-FileSha256 $runPreflightPath) -cne (Get-RequiredProperty $invocation 'correctedHistoryPreflightSha256')) {
            throw 'The run build/preflight evidence is missing or differs from its invocation binding.'
        }
        $verifiedBuild = Assert-BaselineBuild $runBuildPath $repoRoot $invocationReviewedCommit $invocation.dotnet $baselineContractSha256
        $runPreflight = [IO.File]::ReadAllText($runPreflightPath) | ConvertFrom-Json
        if (-not (Test-JsonTrue (Get-RequiredProperty $runPreflight 'authoritative')) -or
            [string](Get-RequiredProperty $runPreflight 'qualification') -cne 'PREFLIGHT-PASS' -or
            [string](Get-RequiredProperty $runPreflight 'mode') -cne 'corrected-full-history' -or
            [string](Get-RequiredProperty $runPreflight 'correctedContractSha256') -cne $correctedSha256 -or
            [string](Get-RequiredProperty $runPreflight 'baselineContractSha256') -cne $baselineContractSha256 -or
            [string](Get-RequiredProperty $runPreflight 'reviewedCommit') -cne $invocationReviewedCommit -or
            [string](Get-RequiredProperty $runPreflight 'buildReceiptSha256') -cne (Get-RequiredProperty $invocation 'buildReceiptSha256') -or
            -not (Test-JsonTrue (Get-RequiredProperty $runPreflight 'launchInputsVerified')) -or
            [string](Get-RequiredProperty $runPreflight 'compositionManifestSha256') -cne $manifestFileSha256 -or
            [string](Get-RequiredProperty $runPreflight 'qualificationRecordSha256') -cne $qualificationRecordSha256 -or
            [int](Get-RequiredProperty $runPreflight 'verifiedPartitionCount') -ne $verifiedPartitionCount) {
            throw 'The mandatory corrected preflight is not bound to this run, build, contract and qualified tree.'
        }
        if ($results.runtimeVersion -cne $verifiedBuild.runtime.version -or
            ([IO.Path]::GetFullPath($results.runtimeDirectory)).TrimEnd('\', '/') -ne ([IO.Path]::GetFullPath($verifiedBuild.runtime.directory)).TrimEnd('\', '/')) {
            throw 'The host did not execute under the pinned .NET runtime.'
        }
        $launcherArtifact = [string]$verifiedBuild.artifacts.'launcher/QuantConnect.Lean.Launcher.dll'
        $algorithmArtifact = [string]$verifiedBuild.artifacts.'algorithm/MarketLab.SingleAnchor.dll'
        if ($recordedAlgorithmHash -cne $algorithmArtifact) {
            throw 'The run algorithm assembly is not the source-bound build receipt artifact.'
        }
        if ([string](Get-PropertyOrNull $invocation 'launcherSha256') -cne $launcherArtifact) {
            throw 'The run launcher is not the source-bound build receipt launcher.'
        }
        $expectedCommand = @('exec', '--fx-version', $verifiedBuild.runtime.version, '--roll-forward', 'Disable',
            [string](Get-PropertyOrNull $invocation 'launcher'),
            '--config', $invocationConfigPath,
            '--environment', 'backtesting',
            '--data-folder', $resolvedDataFolder,
            '--results-destination-folder', $runPath,
            '--algorithm-type-name', [string](Get-RequiredProperty $runHost 'algorithmTypeName'),
            '--algorithm-language', [string](Get-RequiredProperty $runHost 'algorithmLanguage'),
            '--algorithm-location', $invocationAlgorithmPath,
            '--close-automatically', 'true',
            '--parameters', $contractParametersString)
        $recordedCommand = @((Get-RequiredProperty $invocation 'commandLine'))
        # Path-valued arguments are compared case-insensitively (Windows path semantics, as in
        # Assert-CorrectedFullHistoryLaunch); every other argument is compared exactly.
        $pathValueIndices = @(5, 7, 11, 13, 19)
        $commandMatches = $recordedCommand.Count -eq $expectedCommand.Count
        if ($commandMatches) {
            for ($i = 0; $i -lt $expectedCommand.Count; $i++) {
                $same = if ($pathValueIndices -contains $i) {
                    [string]$recordedCommand[$i] -ieq [string]$expectedCommand[$i]
                }
                else {
                    [string]$recordedCommand[$i] -ceq [string]$expectedCommand[$i]
                }
                if (-not $same) { $commandMatches = $false; break }
            }
        }
        if (-not $commandMatches) {
            throw 'The recorded launcher command line is not the exact expected corrected full-history invocation.'
        }
    } catch { Fail-Preflight $_.Exception.Message $outputFullPath $authoritative }
}

# --- Delivery verification (current-model verifier) -----------------------------
try {
    $deliveryVerification = Assert-BrokerLiquidationDelivery $results $manifestData $dataIdentity $resolvedDataFolder -AllowTerminalFailure
} catch { Fail-Preflight ("Current-model delivery verification failed: " + $_.Exception.Message) $outputFullPath $authoritative }

$failure = Get-PropertyOrNull $results 'failure'
$runTerminated = $null -ne $failure
$terminationKind = ''
$terminationCondition = ''
$failureQuoteObject = $null
$failureQuoteSource = ''
$coverageEndDay = $endDate
if ($runTerminated) {
    $terminationKind = [string](Get-PropertyOrNull $failure 'Kind')
    $terminationCondition = [string](Get-PropertyOrNull $failure 'Condition')
    if ($terminationKind -eq 'AccountStopOut') {
        Fail-Preflight 'the run ended with the historical AccountStopOut condition, which the current model never raises; this is not a corrected full-history outcome.' $outputFullPath $authoritative
    }
    if (-not $script:TerminalExceptionByKind.Contains($terminationKind) -or -not ($terminalKinds -contains $terminationKind)) {
        Fail-Preflight "the run ended by '$terminationKind', which is not one of the current model's terminal failure kinds ($($terminalKinds -join ', '))." $outputFullPath $authoritative
    }
    $validConditions = @($script:ConditionsByKind[$terminationKind])
    if ($null -eq $validConditions -or -not ($validConditions -ccontains $terminationCondition)) {
        Fail-Preflight "the terminal failure pair '$terminationKind' / '$terminationCondition' is not a valid current-model condition for that kind ($($validConditions -join ', ')); the terminal outcome is not the reviewed implementation's." $outputFullPath $authoritative
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyOrNull $failure 'Message'))) {
        Fail-Preflight 'the terminal failure record carries no message; the terminal engine line cannot be matched against an empty failure.' $outputFullPath $authoritative
    }
    $failureQuoteObject = Get-PropertyOrNull $failure 'Quote'
    $failureQuoteTimeValue = Get-PropertyOrNull $failureQuoteObject 'Time'
    $parsedFailureQuote = [System.DateTime]::MinValue
    if ($null -ne $failureQuoteTimeValue) {
        try { $parsedFailureQuote = ConvertTo-BaselineUtc $failureQuoteTimeValue }
        catch { $parsedFailureQuote = [System.DateTime]::MinValue }
    }
    if ($parsedFailureQuote -eq [System.DateTime]::MinValue) {
        Fail-Preflight 'the terminal failure record carries no parseable failure quote; the terminal outcome is incomplete.' $outputFullPath $authoritative
    }
    $lastProcessed = Get-PropertyOrNull $results 'lastProcessedQuote'
    $lastProcessedTime = Get-PropertyOrNull $lastProcessed 'Time'
    if ($null -eq $lastProcessedTime) {
        Fail-Preflight 'the terminal run carries no last processed quote; the processed horizon cannot be established.' $outputFullPath $authoritative
    }
    $parsedLastProcessed = [System.DateTime]::MinValue
    try { $parsedLastProcessed = ConvertTo-BaselineUtc $lastProcessedTime }
    catch { $parsedLastProcessed = [System.DateTime]::MinValue }
    if ($parsedLastProcessed -eq [System.DateTime]::MinValue) {
        Fail-Preflight 'the terminal run carries no parseable last processed quote time; the processed horizon cannot be established.' $outputFullPath $authoritative
    }
    if ($deliveryVerification.mode -cne 'phase-b-terminal-prefix') {
        Fail-Preflight "the terminal run's delivery was verified as '$($deliveryVerification.mode)', not the exact qualified prefix." $outputFullPath $authoritative
    }
    # Bind the faulting quote to the verified historical execution, exactly as the engine
    # semantics define it. Accepted-then-faulted kinds: the faulting quote is the final processed
    # quote (the verifier already equates that to the delivered last quote). Pre-acceptance kinds
    # (DataQuality/SessionMap): the refused quote is not counted, so it must be the next qualified
    # source row after the verified delivered prefix.
    if ($script:ProcessedFaultKinds -ccontains $terminationKind) {
        if (-not (Test-SameQuote $failureQuoteObject $lastProcessed)) {
            Fail-Preflight "the terminal failure quote for '$terminationKind' is not the final processed quote; the terminal state is not the externally evidenced one." $outputFullPath $authoritative
        }
        $failureQuoteSource = 'final-processed-quote'
    }
    elseif ($script:PreAcceptanceFaultKinds -ccontains $terminationKind) {
        $prefixLastDayText = $parsedLastProcessed.Date.ToString('yyyy-MM-dd')
        $terminalPartitionName = $parsedLastProcessed.Date.ToString('yyyyMMdd') + '_quote.zip'
        $resultsDelivered = Get-PropertyOrNull $results 'delivered'
        $terminalPartition = Get-PropertyOrNull (Get-PropertyOrNull $resultsDelivered 'per_partition') $prefixLastDayText
        if ($null -eq $terminalPartition) {
            Fail-Preflight 'the terminal prefix has no delivered partition for its last day; the refused quote cannot be located.' $outputFullPath $authoritative
        }
        $terminalDeliveredCount = [long](Get-RequiredProperty $terminalPartition 'quote_count')
        $terminalAcceptedCount = [long](Get-RequiredProperty (Get-PropertyOrNull $manifestData.semantic.per_partition $prefixLastDayText) 'accepted_row_count')
        $nextQuote = $null
        if ($terminalDeliveredCount -lt $terminalAcceptedCount) {
            $nativeEntries = @($manifestData.native.partitions | Where-Object { [IO.Path]::GetFileName($_.zip_relative_path) -ceq $terminalPartitionName })
            if ($nativeEntries.Count -ne 1) { Fail-Preflight 'cannot resolve the terminal native partition for the refused quote.' $outputFullPath $authoritative }
            $nextQuote = Get-BaselineNativeNextQuote (Join-Path $resolvedDataFolder $nativeEntries[0].zip_relative_path) $prefixLastDayText $terminalDeliveredCount
        }
        else {
            $laterDays = @($manifestData.semantic.per_partition.PSObject.Properties.Name | Where-Object { $_ -cgt $prefixLastDayText } | Sort-Object)
            if ($laterDays.Count -gt 0) {
                $nextDayText = $laterDays[0]
                $nextPartitionName = ($nextDayText -replace '-', '') + '_quote.zip'
                $nextEntries = @($manifestData.native.partitions | Where-Object { [IO.Path]::GetFileName($_.zip_relative_path) -ceq $nextPartitionName })
                if ($nextEntries.Count -ne 1) { Fail-Preflight 'cannot resolve the next native partition for the refused quote.' $outputFullPath $authoritative }
                $nextQuote = Get-BaselineNativeNextQuote (Join-Path $resolvedDataFolder $nextEntries[0].zip_relative_path) $nextDayText 0
            }
        }
        if ($null -eq $nextQuote -or -not (Test-SameQuote $failureQuoteObject $nextQuote)) {
            Fail-Preflight "the terminal failure quote for '$terminationKind' is not the next qualified source quote after the delivered prefix; the refused quote cannot be externally evidenced." $outputFullPath $authoritative
        }
        $failureQuoteSource = 'next-qualified-source-quote'
    }
    $coverageEndDay = $parsedLastProcessed.Date
    if ($coverageEndDay -lt $startDate) { $coverageEndDay = $startDate }
    if ($coverageEndDay -gt $endDate) { $coverageEndDay = $endDate }
}
else {
    if ($deliveryVerification.mode -cne 'phase-b-full-stream') {
        Fail-Preflight "a completed corrected run must deliver the full qualified stream (verifier mode '$($deliveryVerification.mode)')." $outputFullPath $authoritative
    }
}
$coverageEndText = $coverageEndDay.ToString('yyyy-MM-dd')

$expectedAbsentWithinHorizon = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$absentDaysAfterTermination = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($absent in $expectedAbsentDays) {
    $absentDate = [System.DateTime]::ParseExact($absent, 'yyyyMMdd', $invariant)
    if ($absentDate -le $coverageEndDay) { [void]$expectedAbsentWithinHorizon.Add($absent) }
    else { [void]$absentDaysAfterTermination.Add($absent) }
}

# --- Outcome evidence -----------------------------------------------------------
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
$outcomePath = Join-Path $runPath 'marketlab-run-outcome.json'
if (-not (Test-Path -LiteralPath $outcomePath -PathType Leaf)) {
    Fail-Preflight "the run has no outcome evidence '$outcomePath'; launch the corrected run with run-backtest.ps1 -RunEvidence so the helper's verdict is provable." $outputFullPath $authoritative
}
try {
    $outcome = [System.IO.File]::ReadAllText($outcomePath) | ConvertFrom-Json
    $outcomeContract = [string](Get-RequiredProperty $outcome 'contract')
    $outcomeInvocationSha = [string](Get-RequiredProperty $outcome 'invocationEvidenceSha256')
    $outcomeLeanExit = [int](Get-RequiredProperty $outcome 'leanExitCode')
    $outcomeHelperExit = [int](Get-RequiredProperty $outcome 'helperExitCode')
    $outcomeEnginePerformed = Test-JsonTrue (Get-RequiredProperty $outcome 'engineErrorCheckPerformed')
    $outcomeEngineCount = Get-PropertyOrNull $outcome 'engineErrorCount'
    $outcomeTerminalException = [string](Get-PropertyOrNull $outcome 'expectedTerminalException')
    $outcomeTerminalLines = Get-PropertyOrNull $outcome 'terminalExceptionLineCount'
    $outcomeMessagesValue = Get-PropertyOrNull $outcome 'engineErrorMessages'
    $outcomeEngineMessages = @()
    if ($null -ne $outcomeMessagesValue) { $outcomeEngineMessages = @($outcomeMessagesValue) }
    $outcomeFailedCount = Get-PropertyOrNull $outcome 'failedDataRequestCount'
    $outcomeMonitor = [string](Get-PropertyOrNull $outcome 'dataMonitorReport')
    $outcomeBinariesUnchanged = Test-JsonTrue (Get-RequiredProperty $outcome 'runtimeBinariesUnchanged')
    $outcomeBinariesAfter = Get-RequiredProperty $outcome 'runtimeBinariesAfter'
}
catch {
    Fail-Preflight "the run outcome evidence is incomplete: $($_.Exception.Message)" $outputFullPath $authoritative
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
if ((Get-PropertyOrNull $outcome 'strategyResultsSha256') -cne (Get-FileSha256 $resultsPath)) {
    Fail-Preflight 'The strategy results differ from the helper outcome evidence.' $outputFullPath $authoritative
}
if ($authoritative) {
    try {
        $afterArtifacts = Get-RequiredProperty $outcome 'baselineArtifactsAfter'
        $afterDictionary = [ordered]@{}
        foreach ($property in $afterArtifacts.PSObject.Properties) { $afterDictionary[$property.Name] = $property.Value }
        Assert-BaselineArtifactEquality $verifiedBuild.artifacts $afterDictionary
    } catch { Fail-Preflight $_.Exception.Message $outputFullPath $authoritative }
}
if ($runTerminated) {
    if ($outcomeLeanExit -ne 1 -or $outcomeHelperExit -ne 1 -or -not $outcomeEnginePerformed) {
        Fail-Preflight "the terminal run outcome shape is not the approved current-model shape (LEAN exit $outcomeLeanExit, helper exit $outcomeHelperExit, engine check performed $outcomeEnginePerformed)." $outputFullPath $authoritative
    }
    if (-not [string]::IsNullOrEmpty($outcomeTerminalException)) {
        Fail-Preflight "the corrected run declared an expected terminal exception '$outcomeTerminalException'; the current model declares none." $outputFullPath $authoritative
    }
    if ($null -eq $outcomeEngineCount -or [int]$outcomeEngineCount -ne 1) {
        Fail-Preflight "the terminal run outcome records '$outcomeEngineCount' engine ERROR:: line(s) beyond the recorded failure; exactly one terminal engine ERROR:: line (the recorded failure's runtime-error line) is required and no unrelated engine ERROR:: lines may exist." $outputFullPath $authoritative
    }
    $expectedException = [string]$script:TerminalExceptionByKind[$terminationKind]
    $failureMessage = [string](Get-PropertyOrNull $failure 'Message')
    if ($outcomeEngineMessages.Count -ne 1) {
        Fail-Preflight "the terminal run outcome records $($outcomeEngineMessages.Count) engine ERROR:: message(s); exactly one is expected." $outputFullPath $authoritative
    }
    $terminalMessage = [string]$outcomeEngineMessages[0]
    if ($terminalMessage -notmatch [regex]::Escape("Context: OnData ${expectedException}: ") -or
        [string]::IsNullOrWhiteSpace($failureMessage) -or -not $terminalMessage.Contains($failureMessage)) {
        Fail-Preflight "the terminal engine ERROR:: line does not name the recorded failure ('$expectedException'): $terminalMessage" $outputFullPath $authoritative
    }
}
else {
    if ($outcomeLeanExit -ne 0 -or $outcomeHelperExit -ne 0 -or -not $outcomeEnginePerformed) {
        Fail-Preflight "the completed run outcome is not clean (LEAN exit $outcomeLeanExit, helper exit $outcomeHelperExit, engine check performed $outcomeEnginePerformed)." $outputFullPath $authoritative
    }
    if ($null -eq $outcomeEngineCount -or [int]$outcomeEngineCount -ne 0) {
        Fail-Preflight "the completed run outcome records '$outcomeEngineCount' engine ERROR:: line(s); a clean completed corrected run must have none." $outputFullPath $authoritative
    }
    if ($null -ne $outcomeTerminalLines -and [int]$outcomeTerminalLines -ne 0) {
        Fail-Preflight 'a completed run records expected terminal exception lines; the corrected run is invalid.' $outputFullPath $authoritative
    }
}

# --- Failed-request classification (occurrences and distinct paths) --------------
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
    'unexpected-post-horizon-request' = 0
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
            try { $parsedDay = [System.DateTime]::ParseExact($dayText, 'yyyyMMdd', $invariant) }
            catch { $parsedDay = [System.DateTime]::MinValue }
            if ($parsedDay -ne [System.DateTime]::MinValue -and $parsedDay -ge $startDate -and $parsedDay -le $endDate) {
                if ($runTerminated -and $parsedDay -gt $coverageEndDay) {
                    $category = 'unexpected-post-horizon-request'
                    $detail = "the run terminated on $coverageEndText before this day was ever processed; a post-horizon failed request cannot be an expected source-absent day"
                }
                else {
                    $category = 'expected-source-absent-calendar-day'
                    [void]$requestedAbsentDays.Add($dayText)
                }
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

# --- Classification record ------------------------------------------------------
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
$record['contract'] = 'marketlab-single-anchor-corrected-full-history-classification-v1'
$record['mode'] = 'corrected-full-history'
$record['generatedUtc'] = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record['authoritative'] = $authoritative
$record['correctedContract'] = $correctedContractPath
$record['correctedContractSha256'] = $correctedSha256
$record['baselineContract'] = $baselineContractPath
$record['baselineContractSha256'] = $baselineContractSha256
$record['baselineRegisterPin'] = $baselineRegisterPin
$record['modelRevision'] = $modelRevision
$record['stopOutModel'] = $stopOutModel
$record['runDirectory'] = $runPath
$record['resultsFile'] = $resultsPath
$record['resultsSha256'] = Get-FileSha256 $resultsPath
$record['resultsBytes'] = (Get-Item -LiteralPath $resultsPath).Length
$record['deliveryVerification'] = $deliveryVerification
$record['invocationEvidenceFile'] = $invocationEvidencePath
$record['invocationEvidenceVerified'] = $true
$record['preRunCorrectedContractSha256'] = [string](Get-PropertyOrNull $invocation 'correctedHistoryContractSha256')
$record['repositoryHead'] = $invocationRepositoryHead
$record['repositoryDirty'] = [bool](Get-PropertyOrNull $invocation 'repositoryDirty')
$record['runReviewedCommit'] = $invocationReviewedCommit
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
$record['terminationCondition'] = $terminationCondition
$record['failureQuote'] = $failureQuoteObject
$record['failureQuoteSource'] = $failureQuoteSource
$record['failureMessage'] = Get-PropertyOrNull $failure 'Message'
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
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $outputFullPath))
[System.IO.File]::WriteAllText($outputFullPath, $recordJson, (New-Object System.Text.UTF8Encoding($false)))
Write-InfoLine "corrected contract SHA-256:      $correctedSha256"
Write-InfoLine "model:                          $modelRevision / $stopOutModel"
Write-InfoLine "authoritative:                  $authoritative"
Write-InfoLine "run directory:                  $runPath"
Write-InfoLine "qualified tree:                 $verifiedPartitionCount/$partitionCount partitions hash-verified against the composition manifest"
Write-InfoLine "run outcome:                    completed=$(-not $runTerminated) leanExit=$outcomeLeanExit helperExit=$outcomeHelperExit engineErrors=$outcomeEngineCount"
if ($runTerminated) {
    Write-InfoLine "termination:                    $terminationKind / $terminationCondition at $coverageEndText"
}
Write-InfoLine "failed requests (lines/distinct): $($failedLines.Count) / $distinctFailedRequestCount (data-monitor count $monitorFailedCount)"
Write-InfoLine "expected source-absent days:      $($expectedAbsentDays.Count) derived from the qualified tree"
foreach ($key in $occurrenceCounts.Keys) {
    Write-InfoLine ("  {0,-42} occurrences {1,3}  distinct {2,3}" -f $key, $occurrenceCounts[$key], $distinctCounts[$key])
}
Write-InfoLine "classification record:            $outputFullPath"
if ($invalidEntries.Count -gt 0) {
    Write-ErrorLine "the corrected full-history run is INVALID: $($invalidEntries.Count) unexpected failed-data condition(s)."
    foreach ($invalid in $invalidEntries) {
        Write-ErrorLine "  $($invalid.category): $($invalid.path) - $($invalid.detail)"
    }
    exit $script:ExitInvalid
}
Write-InfoLine 'corrected full-history classification: EXPECTED (the corrected model was executed and evidenced faithfully: current-model delivery, provenance chain and failed-data behavior all reconcile)'
exit $script:ExitExpected
