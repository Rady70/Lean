<#
.SYNOPSIS
Windows-local tests for scripts\Test-SingleAnchorCorrectedFullHistory.ps1 on synthetic fixtures.

.DESCRIPTION
Creates a temporary synthetic qualified tree for the 2019-01-01..2019-01-03 window (present
days 2019-01-01 and 2019-01-03, absent day 2019-01-02), a synthetic baseline contract derived
from the real frozen baseline contract, a synthetic decision register, a synthetic corrected
full-history contract and synthetic run directories outside the repository, then checks the
classifier's provenance chain, its current-model delivery verification and its classification
paths:

  A completed full-stream run                          -> exit 0, EXPECTED (phase-b-full-stream)
  B BrokerLiquidation/ForcedCloseFailed exact prefix   -> exit 0, EXPECTED (terminal prefix)
  Z AccountSurvival/ExecutableMarkUnavailable prefix   -> exit 0, EXPECTED (other terminal kind)
  Z2 StrategyInvariant/DataQuality/SessionMap prefixes -> exit 0, EXPECTED (remaining terminal kinds)
  C AccountStopOut terminal kind                       -> exit 2, controlled failure
  D unknown terminal kind                              -> exit 2, controlled failure
  E result names a wrong modelRevision                 -> exit 2, controlled failure
  F completed run delivers only a prefix               -> exit 2, controlled failure
  G terminal run records two engine ERROR:: lines      -> exit 2, controlled failure
  H terminal engine line does not name the failure     -> exit 2, controlled failure
  I failed request for an existing qualified partition -> exit 1, INVALID
  J absent day not requested within the horizon        -> exit 1, INVALID
  K absent day after the terminated horizon            -> exit 0, EXPECTED (recorded absence)
  L corrected contract baseline pin mismatch           -> exit 2, controlled failure
  M frozen baseline contract edited after pinning      -> exit 2, controlled failure
  N partition zip modified after the manifest          -> exit 2, controlled failure
  O invocation parametersString mismatch               -> exit 2, controlled failure
  P invocation runMode 'baseline'                      -> exit 2, controlled failure
  Q invocation carries a baseline contract path        -> exit 2, controlled failure
  R results missing the research margin block          -> exit 2, controlled failure
  S preflight pass (identity + tree, no run)           -> exit 0, PREFLIGHT-PASS
  T preflight catches tree drift before any run        -> exit 2, controlled failure
  U data-folder override without the test override     -> exit 2, controlled failure
  V runtime binary changed after the run               -> exit 2, controlled failure
  W -CheckOnly preflight JSON on stdout, no record     -> exit 0, PREFLIGHT-PASS

The run-path cases use -AllowNonAuthoritativeOverride, so the authoritative-only checks (clean
reviewed checkout, source-bound build receipt, the run's copied corrected preflight binding,
runtime pinning, build-artifact equality and the exact reconstructed launcher command) are not
exercised here; they run in the real corrected run's mandatory preflight and post-run
classification. Cases U/U2 additionally exercise the authoritative data-folder-override and
-ReviewedCommit gates. The corrected launch guard (Assert-CorrectedFullHistoryLaunch) and the
helper's mode mutual exclusion are covered by tests\Test-SingleAnchorBaselineGuards.ps1. No
real market data is used and nothing outside the temporary directory is touched.

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

function Get-RawSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
    }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-LfSha256([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Write-JsonFile([string]$Path, $Object) {
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-MonitorFailedCount([string]$RunDirectory) {
    $monitor = [System.IO.File]::ReadAllText((Join-Path $RunDirectory 'data-monitor-report-20190101000000000.json')) | ConvertFrom-Json
    return [int]$monitor.'failed-data-requests-count'
}

function Get-PropertyValue($Object, [string[]]$Path) {
    $current = $Object
    foreach ($name in $Path) {
        if ($null -eq $current) { return $null }
        if (-not ($current.PSObject.Properties.Name -contains $name)) { return $null }
        $current = $current.$name
    }
    return $current
}

$classifier = Join-Path $PSScriptRoot '..\scripts\Test-SingleAnchorCorrectedFullHistory.ps1'
if (-not (Test-Path -LiteralPath $classifier -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: classifier script not found at '$classifier'.")
    exit 1
}
$marketLabRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $marketLabRoot '..')).Path
$realBaselineContract = Join-Path $marketLabRoot 'config\baseline-contract.json'
$realCorrectedContract = Join-Path $marketLabRoot 'config\corrected-full-history-contract.json'
$realConfig = Join-Path $marketLabRoot 'config\backtesting.json'
$realConfigHash = Get-LfSha256 $realConfig
$algorithmFilePath = Join-Path $marketLabRoot 'scripts\run-backtest.ps1'
$algorithmFileHash = Get-RawSha256 $algorithmFilePath

$root = Join-Path $env:TEMP ("marketlab-corrected-classifier-" + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $root 'data'
$runRoot = Join-Path $root 'run'
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$startText = '2019-01-01'
$endDateText = '2019-01-03'
$presentDays = @('20190101', '20190103')
$absentDay = '20190102'
$repositorySha = ('a' * 40)
$terminalExceptionByKind = [ordered]@{
    'StrategyInvariant' = 'MarketLab.SingleAnchor.StrategyInvariantException'
    'DataQuality'       = 'MarketLab.SingleAnchor.DataQualityException'
    'SessionMap'        = 'MarketLab.SingleAnchor.SessionMapException'
    'AccountSurvival'   = 'MarketLab.SingleAnchor.AccountSurvivalException'
    'BrokerLiquidation' = 'MarketLab.SingleAnchor.BrokerLiquidationException'
    'AccountStopOut'    = 'MarketLab.SingleAnchor.AccountStopOutException'
}
$runtimeNames = @(
    'QuantConnect.Lean.Launcher.dll',
    'QuantConnect.Lean.Engine.dll',
    'QuantConnect.Common.dll',
    'QuantConnect.Algorithm.dll',
    'QuantConnect.AlgorithmFactory.dll',
    'QuantConnect.Configuration.dll',
    'QuantConnect.Logging.dll'
)

function Get-TerminalEngineMessage([string]$Kind) {
    $exception = $terminalExceptionByKind[$Kind]
    return "Extensions.SetRuntimeError(): Extensions.SetRuntimeError(): RuntimeError at 01/01/2019 12:00:00 UTC. Context: OnData ${exception}: synthetic terminal failure $Kind"
}

function New-RuntimeSet([string]$RuntimeRoot) {
    New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
    $hashes = [ordered]@{}
    foreach ($name in $runtimeNames) {
        $path = Join-Path $RuntimeRoot $name
        [System.IO.File]::WriteAllText($path, ("synthetic runtime binary " + $name))
        $hashes[$name] = Get-RawSha256 $path
    }
    return $hashes
}

function New-Tree([string]$TreeRoot, [string[]]$Days) {
    $tick = Join-Path $TreeRoot 'cfd\dukascopy\tick\xauusd'
    $mh = Join-Path $TreeRoot 'market-hours'
    $sp = Join-Path $TreeRoot 'symbol-properties'
    $sm = Join-Path $TreeRoot 'marketlab-sessions'
    $mq = Join-Path $TreeRoot 'marketlab-qualification'
    foreach ($dir in @($tick, $mh, $sp, $sm, $mq)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $zipHashes = @{}
    foreach ($day in $Days) {
        $zipPath = Join-Path $tick ($day + '_quote.zip')
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression
        $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $member = $zip.CreateEntry($day + '_xauusd_tick_quote.csv')
            $member.LastWriteTime = [DateTimeOffset]::Parse('2019-01-01T00:00:00Z')
            $writer = [IO.StreamWriter]::new($member.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write("43200000,100,100.5`n46800000,101,101.5`n") } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        $zipHashes[$day] = Get-RawSha256 $zipPath
    }
    $mhPath = Join-Path $mh 'market-hours-database.json'
    $spPath = Join-Path $sp 'symbol-properties-database.csv'
    $smPath = Join-Path $sm 'xauusd-sessions.json'
    [System.IO.File]::WriteAllText($mhPath, '{"syntheticMarketHours":true}')
    [System.IO.File]::WriteAllText($spPath, 'synthetic,symbol,properties')
    [System.IO.File]::WriteAllText($smPath, '{"syntheticSessionMap":true}')
    return [pscustomobject]@{
        Root = $TreeRoot
        ZipHashes = $zipHashes
        MarketHoursHash = Get-RawSha256 $mhPath
        SymbolPropertiesHash = Get-RawSha256 $spPath
        SessionMapHash = Get-RawSha256 $smPath
    }
}

function Get-TextDigest([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return 'sha256:' + ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function New-Delivery([string]$Through) {
    $global = ''
    $parts = [ordered]@{}
    $quotes = @()
    $seenDays = @()
    foreach ($day in $presentDays) {
        $date = [DateTime]::ParseExact($day, 'yyyyMMdd', $invariant).ToString('yyyy-MM-dd')
        $local = ''
        $count = 0
        foreach ($hour in @(12, 13)) {
            $time = $date + 'T' + $hour + ':00:00.000Z'
            if ($Through -and [DateTime]::Parse($time).ToUniversalTime() -gt [DateTime]::Parse($Through).ToUniversalTime()) { continue }
            $bid = 100 + $hour - 12
            $ask = $bid + 0.5
            $quotes += [ordered]@{ Time = $time; Bid = $bid; Ask = $ask }
            $count++
            $tuple = "|$time|$bid|$($ask.ToString($invariant))`n"
            $local += $count.ToString() + $tuple
            $global += $quotes.Count.ToString() + $tuple
        }
        if ($count) {
            $parts[$date] = [ordered]@{ quote_count = $count; semantic_digest = Get-TextDigest $local }
            $seenDays += $date
        }
    }
    return [ordered]@{
        quote_count = $quotes.Count; semantic_digest = Get-TextDigest $global
        first_canonical_utc = $quotes[0].Time; last_canonical_utc = $quotes[-1].Time
        last_quote = $quotes[-1]; per_partition = $parts
    }
}

function New-Manifest($Tree, [string[]]$Days, $Contract) {
    $partitions = @()
    $perPartition = [ordered]@{}
    foreach ($day in $Days) {
        $dayText = $day.Substring(0, 4) + '-' + $day.Substring(4, 2) + '-' + $day.Substring(6, 2)
        $partitions += [ordered]@{
            zip_relative_path = 'cfd/dukascopy/tick/xauusd/' + $day + '_quote.zip'
            zip_sha256 = $Tree.ZipHashes[$day]
        }
        $qualified = (New-Delivery '').per_partition[$dayText]
        $perPartition[$dayText] = [ordered]@{ accepted_row_count = $qualified.quote_count; semantic_digest = $qualified.semantic_digest }
    }
    $identity = $Contract.qualifiedDataIdentity
    $manifest = [ordered]@{
        contract = 'marketlab-historical-data-qualification-v1'
        composition = [ordered]@{
            contract = 'marketlab-continuous-history-composition-v1'
            partition_count = $Days.Count
            month_count = [int]$identity.continuousHistoryMonthCount
            ordered_source_semantic_digest = $identity.continuousHistorySemanticDigest
            source_file_set_sha256 = $identity.sourceFileSetSha256
            ordered_month_digest_chain_sha256 = $identity.orderedMonthDigestChainSha256
            session_map = [ordered]@{ relative_path = 'marketlab-sessions/xauusd-sessions.json'; sha256 = $Tree.SessionMapHash }
            lean_run_window = [ordered]@{ start_date = $startText; end_date = $endDateText }
            first_canonical_utc = $identity.continuousHistoryFirstQuoteUtc
            last_canonical_utc = $identity.continuousHistoryLastQuoteUtc
        }
        counts = [ordered]@{
            accepted_row_count = [long]$identity.continuousHistoryQuoteCount
            converted_row_count = [long]$identity.continuousHistoryQuoteCount
            rejected_row_count = 0
        }
        lean = [ordered]@{
            market_hours_database = [ordered]@{ database_sha256 = $Tree.MarketHoursHash }
            symbol_properties_database = [ordered]@{ sha256 = $Tree.SymbolPropertiesHash }
        }
        native = [ordered]@{ partitions = $partitions }
        semantic = [ordered]@{ per_partition = $perPartition }
        qualification = [ordered]@{
            source_qualification = 'PASS'
            native_conversion = 'PASS'
            native_lean_timestamp_parity = 'PASS'
            native_price_decimal_parity = 'PASS'
        }
    }
    $manifestPath = Join-Path $Tree.Root 'marketlab-qualification\continuous-composition.json'
    Write-JsonFile $manifestPath $manifest
    $record = [ordered]@{
        contract = 'marketlab-historical-data-qualification-record-v1'
        overall_qualification = 'PASS'
        helper_exit_code = 0
        continuous = [ordered]@{
            composition_sha256 = Get-RawSha256 $manifestPath
            partition_count = $Days.Count
            month_count = [int]$identity.continuousHistoryMonthCount
            session_map = [ordered]@{ relative_path = 'marketlab-sessions/xauusd-sessions.json'; sha256 = $Tree.SessionMapHash }
        }
    }
    Write-JsonFile (Join-Path $Tree.Root 'marketlab-qualification\continuous-qualification-record.json') $record
}

function New-BaselineContract([string]$Path, $Tree) {
    $contract = [System.IO.File]::ReadAllText($realBaselineContract) | ConvertFrom-Json
    $identity = $contract.qualifiedDataIdentity
    $identity.dataFolder = $Tree.Root
    $identity.startDate = $startText
    $identity.endDate = $endDateText
    $identity.continuousHistoryPartitionCount = $presentDays.Count
    $delivered = New-Delivery ''
    $identity.continuousHistoryQuoteCount = $delivered.quote_count
    $identity.continuousHistoryFirstQuoteUtc = $delivered.first_canonical_utc
    $identity.continuousHistoryLastQuoteUtc = $delivered.last_canonical_utc
    $identity.continuousHistorySemanticDigest = $delivered.semantic_digest
    $identity.sessionMapSha256 = $Tree.SessionMapHash
    $identity.marketHoursDatabaseSha256 = $Tree.MarketHoursHash
    $identity.symbolPropertiesDatabaseSha256 = $Tree.SymbolPropertiesHash
    $contract.runHost.algorithmLocation = 'MarketLab\scripts\run-backtest.ps1'
    Write-JsonFile $Path $contract
    return $contract
}

function Get-ContractParametersString($Contract) {
    return (@($Contract.parameters | ForEach-Object { $_.name + ':' + $_.value }) -join ',')
}

function New-Evidence([string]$Path) {
    $evidence = [ordered]@{
        replay = [ordered]@{
            record_sha256 = Get-RawSha256 (Join-Path $script:dataTree.Root 'marketlab-qualification\continuous-qualification-record.json')
            source_absent_days = 1
            missing_native_partitions = 0
            source_coverage_gap_days = 0
            unrelated_failed_data_requests = 1
        }
    }
    Write-JsonFile $Path $evidence
}

function New-CorrectedContract([string]$Path, [string]$BaselinePath, [string]$RegisterPath, [string]$BaselineSha) {
    $corrected = [System.IO.File]::ReadAllText($realCorrectedContract) | ConvertFrom-Json
    $corrected.baselineContract.path = $BaselinePath
    $corrected.baselineContract.registerPath = $RegisterPath
    $corrected.baselineContract.sha256LfNormalized = $BaselineSha
    Write-JsonFile $Path $corrected
}

function New-Results([string]$Path, $Contract, [string]$Through, [string]$FailureKind, [string]$FailureCondition) {
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
    $frozenByName = @{}
    foreach ($parameter in $Contract.parameters) { $frozenByName[[string]$parameter.name] = [string]$parameter.value }
    $resultParameters = [ordered]@{}
    foreach ($entry in $parameterToResult.GetEnumerator()) {
        $text = $frozenByName[$entry.Key]
        if ($text -eq 'true') { $resultParameters[$entry.Value] = $true }
        elseif ($text -eq 'false') { $resultParameters[$entry.Value] = $false }
        else { $resultParameters[$entry.Value] = [decimal]::Parse($text, $invariant) }
    }
    $cash = [decimal]::Parse($frozenByName['single-anchor-cash'], $invariant)
    $delivered = New-Delivery $Through
    $results = [ordered]@{
        modelRevision = 'marketlab-single-anchor-broker-liquidation-v1'
        stopOutModel = 'BrokerLiquidation'
        completed = -not [bool]$FailureKind
        algorithmTimeZone = 'UTC'; quoteTimeZone = 'UTC'
        startUtc = '2019-01-01T00:00:00Z'; endUtc = '2019-01-03T23:59:59.9999999Z'
        quoteTicksProcessed = $delivered.quote_count; strategyEligibleQuotes = $delivered.quote_count
        quoteOnlyQuotes = 0; nonQuoteTicksUnused = 0; delivered = $delivered
        symbol = 'XAUUSD'
        market = 'dukascopy'
        startDate = $startText
        endDate = $endDateText
        parameters = $resultParameters
        researchAccount = [ordered]@{ InitialBalance = $cash; CurrentOpenPositions = 1; Equity = $cash }
        researchMargin = [ordered]@{ MarginCallActive = $false; CurrentUsedMargin = 10 }
        sessionMap = [ordered]@{ Sha256 = $script:dataTree.SessionMapHash }
        failure = $null
        lastProcessedQuote = $delivered.last_quote
    }
    if ($FailureKind) {
        $results['failure'] = [ordered]@{
            Kind = $FailureKind
            Condition = $FailureCondition
            Quote = $delivered.last_quote
            Message = "synthetic terminal failure $FailureKind"
        }
    }
    Write-JsonFile $Path $results
}

function New-InvocationEvidence([string]$Path, $Contract, [string]$DataFolder, [string]$RunDirectory, $RuntimeRoot, $RuntimeHashes) {
    $invocation = [ordered]@{
        contract = 'marketlab-run-invocation-evidence-v1'
        generatedUtc = '2019-01-01T00:00:00Z'
        leanRoot = $repoRoot
        runMode = 'corrected-full-history'
        configuration = 'Release'
        dotnet = 'synthetic'
        launcher = (Join-Path $marketLabRoot 'scripts\run-backtest.ps1')
        launcherSha256 = 'synthetic-launcher-sha256'
        configPath = $realConfig
        configSha256LfNormalized = $realConfigHash
        algorithmTypeName = [string]$Contract.runHost.algorithmTypeName
        algorithmLanguage = [string]$Contract.runHost.algorithmLanguage
        algorithmLocation = $algorithmFilePath
        algorithmSha256 = $algorithmFileHash
        dataFolder = $DataFolder
        parametersString = Get-ContractParametersString $Contract
        closeAutomatically = $true
        allowMissingData = $true
        allowEngineErrors = $false
        commandLine = @('synthetic')
        workingDirectory = $RunDirectory
        runDirectory = $RunDirectory
        baselineContractPath = $null
        baselineContractSha256 = $null
        baselineRegisterPath = $null
        baselineRegisterPin = $null
        correctedHistoryContractPath = $script:correctedContractPath
        correctedHistoryContractSha256 = $script:correctedContractSha
        repositoryHead = $repositorySha
        repositoryDirty = $false
        runtimeBinariesRoot = $RuntimeRoot
        runtimeBinaries = $RuntimeHashes
        expectedTerminalException = ''
        reviewedCommit = $repositorySha
        buildReceiptSha256 = $null
        preflightSha256 = $null
        correctedHistoryPreflightSha256 = $null
    }
    Write-JsonFile $Path $invocation
}

function New-Outcome {
    param(
        [string]$RunDirectory,
        [int]$LeanExit,
        [int]$HelperExit,
        [bool]$EnginePerformed,
        $EngineCount,
        [object[]]$EngineMessages = @(),
        [int]$TerminalLines = 0,
        $RuntimeAfter
    )
    $invocationPath = Join-Path $RunDirectory 'marketlab-run-invocation.json'
    $resultsPath = Join-Path $RunDirectory 'storage\single-anchor\results.json'
    $outcome = [ordered]@{
        contract = 'marketlab-run-outcome-evidence-v1'
        generatedUtc = '2019-01-01T00:00:00Z'
        invocationEvidence = 'marketlab-run-invocation.json'
        invocationEvidenceSha256 = Get-RawSha256 $invocationPath
        leanExitCode = $LeanExit
        helperExitCode = $HelperExit
        engineErrorCheckPerformed = $EnginePerformed
        engineErrorCount = $EngineCount
        expectedTerminalException = ''
        terminalExceptionLineCount = $TerminalLines
        engineErrorMessages = [object[]]@($EngineMessages)
        dataMonitorReport = 'data-monitor-report-20190101000000000.json'
        failedDataRequestCount = Get-MonitorFailedCount $RunDirectory
        runtimeBinariesAfter = $RuntimeAfter
        runtimeBinariesUnchanged = $true
        strategyResultsSha256 = Get-RawSha256 $resultsPath
    }
    Write-JsonFile (Join-Path $RunDirectory 'marketlab-run-outcome.json') $outcome
}

function New-FailedRequests([string]$RunDirectory, [string[]]$Lines) {
    $failedPath = Join-Path $RunDirectory 'failed-data-requests-20190101000000000.txt'
    [System.IO.File]::WriteAllLines($failedPath, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Monitor([string]$RunDirectory, [int]$FailedCount) {
    $monitor = [ordered]@{ 'failed-data-requests-count' = $FailedCount; 'total-data-requests-count' = $FailedCount }
    Write-JsonFile (Join-Path $RunDirectory 'data-monitor-report-20190101000000000.json') $monitor
}

function New-RunCase {
    param(
        [string]$Name,
        [string]$DataFolder,
        [string[]]$FailedLines,
        [int]$MonitorCount,
        [string]$FailureKind = '',
        [string]$FailureCondition = '',
        [string]$Through = '',
        $RuntimeRoot,
        $RuntimeHashes
    )
    $caseDir = Join-Path $runRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $caseDir 'storage\single-anchor') -Force | Out-Null
    New-Results (Join-Path $caseDir 'storage\single-anchor\results.json') $script:baselineContract $Through $FailureKind $FailureCondition
    New-InvocationEvidence (Join-Path $caseDir 'marketlab-run-invocation.json') $script:baselineContract $DataFolder $caseDir $RuntimeRoot $RuntimeHashes
    New-FailedRequests $caseDir $FailedLines
    New-Monitor $caseDir $MonitorCount
    if ($FailureKind) {
        New-Outcome -RunDirectory $caseDir -LeanExit 1 -HelperExit 1 -EnginePerformed $true -EngineCount 1 -EngineMessages @(Get-TerminalEngineMessage $FailureKind) -RuntimeAfter $RuntimeHashes
    }
    else {
        New-Outcome -RunDirectory $caseDir -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $RuntimeHashes
    }
    return $caseDir
}

function Invoke-CorrectedClassifier {
    param(
        [string]$ContractPath,
        [string]$CaseDirectory,
        [string]$DataFolderOverride,
        [string]$ReviewedCommit,
        [switch]$Preflight,
        [switch]$CheckOnly,
        [switch]$NoOverride
    )
    if ($Preflight) {
        $recordPath = Join-Path $runRoot ('preflight-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    else {
        $recordPath = Join-Path $CaseDirectory 'classification.json'
    }
    $arguments = @('-NoProfile', '-File', $classifier, '-Contract', $ContractPath, '-Evidence', $script:syntheticEvidencePath, '-OutputPath', $recordPath)
    if ($Preflight) { $arguments += '-Preflight' } else { $arguments += @('-RunDirectory', $CaseDirectory) }
    if ($CheckOnly) { $arguments += '-CheckOnly' }
    if ($DataFolderOverride) { $arguments += @('-DataFolder', $DataFolderOverride) }
    if ($ReviewedCommit) { $arguments += @('-ReviewedCommit', $ReviewedCommit) }
    if (-not $NoOverride) { $arguments += '-AllowNonAuthoritativeOverride' }
    $stdout = @()
    if ($CheckOnly) {
        $stdout = @(& powershell @arguments)
        $code = $LASTEXITCODE
    }
    else {
        & powershell @arguments | Out-Null
        $code = $LASTEXITCODE
    }
    $record = $null
    if (Test-Path -LiteralPath $recordPath) {
        $record = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    }
    return [pscustomobject]@{ Code = $code; Record = $record; StdOut = $stdout; RecordPath = $recordPath }
}

New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$tree = New-Tree $dataRoot $presentDays
$script:dataTree = $tree
$syntheticBaselinePath = Join-Path $root 'baseline-contract.json'
$script:baselineContract = New-BaselineContract $syntheticBaselinePath $tree
$syntheticBaselineSha = Get-LfSha256 $syntheticBaselinePath
$syntheticRegisterPath = Join-Path $root 'baseline-decision-audit.json'
Write-JsonFile $syntheticRegisterPath ([ordered]@{ contract = 'marketlab-baseline-decision-audit-v1'; frozenBaselineContractSha256 = $syntheticBaselineSha })
New-Manifest $tree $presentDays $script:baselineContract
$script:syntheticEvidencePath = Join-Path $root 'continuous-history-evidence.json'
New-Evidence $script:syntheticEvidencePath
$script:correctedContractPath = Join-Path $root 'corrected-full-history-contract.json'
New-CorrectedContract $script:correctedContractPath $syntheticBaselinePath $syntheticRegisterPath $syntheticBaselineSha
$script:correctedContractSha = Get-LfSha256 $script:correctedContractPath
$runtimeRoot = Join-Path $root 'runtime'
$runtimeHashes = New-RuntimeSet $runtimeRoot
$absentRequest = '\cfd\dukascopy\tick\xauusd\' + $absentDay + '_quote.zip'
$auxiliaryRequest = '\cfd\dukascopy\hour\xauusd.zip'

try {
    Write-Host 'Case A: completed full-stream run'
    $caseA = New-RunCase -Name 'case-a-completed' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultA = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseA
    Check 'exit 0' ($resultA.Code -eq 0)
    Check 'qualification EXPECTED' ($resultA.Record.qualification -eq 'EXPECTED')
    Check 'delivery mode phase-b-full-stream' ($resultA.Record.deliveryVerification.mode -eq 'phase-b-full-stream')
    Check 'runTerminated false' ($resultA.Record.runTerminated -eq $false)
    Check 'modelRevision recorded' ($resultA.Record.modelRevision -eq 'marketlab-single-anchor-broker-liquidation-v1')
    Check 'stopOutModel recorded' ($resultA.Record.stopOutModel -eq 'BrokerLiquidation')
    Check 'verifiedPartitionCount 2' ($resultA.Record.verifiedPartitionCount -eq 2)
    Check 'invocationEvidenceVerified' ($resultA.Record.invocationEvidenceVerified -eq $true)

    Write-Host 'Case B: BrokerLiquidation/ForcedCloseFailed exact terminal prefix'
    $caseB = New-RunCase -Name 'case-b-broker-liquidation' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -FailureKind 'BrokerLiquidation' -FailureCondition 'ForcedCloseFailed' -Through '2019-01-03T12:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultB = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseB
    Check 'exit 0' ($resultB.Code -eq 0)
    Check 'qualification EXPECTED' ((Get-PropertyValue $resultB.Record @('qualification')) -eq 'EXPECTED')
    Check 'runTerminated true' ((Get-PropertyValue $resultB.Record @('runTerminated')) -eq $true)
    Check 'terminationKind BrokerLiquidation' ((Get-PropertyValue $resultB.Record @('terminationKind')) -eq 'BrokerLiquidation')
    Check 'delivery mode phase-b-terminal-prefix' ((Get-PropertyValue $resultB.Record @('deliveryVerification', 'mode')) -eq 'phase-b-terminal-prefix')
    Check 'terminalDayPrefixRead true' ((Get-PropertyValue $resultB.Record @('deliveryVerification', 'terminalDayPrefixRead')) -eq $true)
    Check 'coverageEndDay is the terminal day' ((Get-PropertyValue $resultB.Record @('coverageEndDay')) -eq '2019-01-03')
    Check 'terminationCondition ForcedCloseFailed' ((Get-PropertyValue $resultB.Record @('terminationCondition')) -eq 'ForcedCloseFailed')

    Write-Host 'Case Z: AccountSurvival/ExecutableMarkUnavailable is also an accepted terminal kind'
    $caseZ = New-RunCase -Name 'case-z-account-survival' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -FailureKind 'AccountSurvival' -FailureCondition 'ExecutableMarkUnavailable' -Through '2019-01-03T12:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultZ = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseZ
    Check 'exit 0' ($resultZ.Code -eq 0)
    Check 'qualification EXPECTED' ((Get-PropertyValue $resultZ.Record @('qualification')) -eq 'EXPECTED')
    Check 'runTerminated true' ((Get-PropertyValue $resultZ.Record @('runTerminated')) -eq $true)
    Check 'terminationKind AccountSurvival' ((Get-PropertyValue $resultZ.Record @('terminationKind')) -eq 'AccountSurvival')
    Check 'terminationCondition ExecutableMarkUnavailable' ((Get-PropertyValue $resultZ.Record @('terminationCondition')) -eq 'ExecutableMarkUnavailable')
    Check 'delivery mode phase-b-terminal-prefix' ((Get-PropertyValue $resultZ.Record @('deliveryVerification', 'mode')) -eq 'phase-b-terminal-prefix')
    Check 'terminalDayPrefixRead true' ((Get-PropertyValue $resultZ.Record @('deliveryVerification', 'terminalDayPrefixRead')) -eq $true)

    foreach ($kind in @('StrategyInvariant', 'DataQuality', 'SessionMap')) {
        Write-Host "Case Z2: $kind is also an accepted terminal kind"
        $caseZ2 = New-RunCase -Name ('case-z2-' + $kind.ToLowerInvariant()) -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -FailureKind $kind -FailureCondition 'SyntheticCondition' -Through '2019-01-03T12:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
        $resultZ2 = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseZ2
        Check "exit 0 ($kind)" ($resultZ2.Code -eq 0)
        Check "qualification EXPECTED ($kind)" ((Get-PropertyValue $resultZ2.Record @('qualification')) -eq 'EXPECTED')
        Check "terminationKind recorded ($kind)" ((Get-PropertyValue $resultZ2.Record @('terminationKind')) -eq $kind)
    }

    Write-Host 'Case C: AccountStopOut belongs to the historical model'
    $caseC = New-RunCase -Name 'case-c-account-stop-out' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -FailureKind 'AccountStopOut' -FailureCondition 'MarginLevel' -Through '2019-01-01T12:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultC = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseC
    Check 'exit 2' ($resultC.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultC.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names AccountStopOut' ($resultC.Record.failure -match 'AccountStopOut')

    Write-Host 'Case D: unknown terminal kind'
    $caseD = New-RunCase -Name 'case-d-unknown-kind' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -FailureKind 'SomethingElse' -FailureCondition 'ForcedCloseFailed' -Through '2019-01-01T12:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultD = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseD
    Check 'exit 2' ($resultD.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultD.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the unknown kind' ($resultD.Record.failure -match 'SomethingElse')

    Write-Host 'Case E: result names a wrong modelRevision'
    $caseE = New-RunCase -Name 'case-e-wrong-model' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultsEPath = Join-Path $caseE 'storage\single-anchor\results.json'
    $resultsE = [IO.File]::ReadAllText($resultsEPath) | ConvertFrom-Json
    $resultsE.modelRevision = 'marketlab-single-anchor-wrong-model-v1'
    Write-JsonFile $resultsEPath $resultsE
    New-Outcome -RunDirectory $caseE -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultE = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseE
    Check 'exit 2' ($resultE.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultE.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names modelRevision' ($resultE.Record.failure -match 'modelRevision')

    Write-Host 'Case F: completed run delivers only a prefix'
    $caseF = New-RunCase -Name 'case-f-prefix-completed' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultsFPath = Join-Path $caseF 'storage\single-anchor\results.json'
    $resultsF = [IO.File]::ReadAllText($resultsFPath) | ConvertFrom-Json
    $resultsF.delivered = New-Delivery '2019-01-01T13:00:00Z'
    $resultsF.quoteTicksProcessed = $resultsF.delivered.quote_count
    $resultsF.strategyEligibleQuotes = $resultsF.delivered.quote_count
    $resultsF.lastProcessedQuote = $resultsF.delivered.last_quote
    Write-JsonFile $resultsFPath $resultsF
    New-Outcome -RunDirectory $caseF -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultF = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseF
    Check 'exit 2' ($resultF.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultF.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the full-stream requirement' ($resultF.Record.failure -match 'not the qualified full stream')

    Write-Host 'Case G: terminal run records two engine ERROR:: lines'
    $caseG = New-RunCase -Name 'case-g-two-engine-errors' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -FailureKind 'BrokerLiquidation' -FailureCondition 'ForcedCloseFailed' -Through '2019-01-01T13:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    New-Outcome -RunDirectory $caseG -LeanExit 1 -HelperExit 1 -EnginePerformed $true -EngineCount 2 -EngineMessages @(Get-TerminalEngineMessage 'BrokerLiquidation') -RuntimeAfter $runtimeHashes
    $resultG = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseG
    Check 'exit 2' ($resultG.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultG.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the engine ERROR count' ($resultG.Record.failure -match 'engine ERROR')

    Write-Host 'Case H: terminal engine line does not name the recorded failure'
    $caseH = New-RunCase -Name 'case-h-wrong-engine-message' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -FailureKind 'BrokerLiquidation' -FailureCondition 'ForcedCloseFailed' -Through '2019-01-01T13:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $wrongMessage = 'Extensions.SetRuntimeError(): Extensions.SetRuntimeError(): RuntimeError at 01/01/2019 12:00:00 UTC. Context: OnData MarketLab.SingleAnchor.BrokerLiquidationException: an unrelated engine message'
    New-Outcome -RunDirectory $caseH -LeanExit 1 -HelperExit 1 -EnginePerformed $true -EngineCount 1 -EngineMessages @($wrongMessage) -RuntimeAfter $runtimeHashes
    $resultH = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseH
    Check 'exit 2' ($resultH.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ((Get-PropertyValue $resultH.Record @('qualification')) -eq 'CONTROLLED_FAILURE')
    Check 'failure names the recorded-failure mismatch' ((Get-PropertyValue $resultH.Record @('failure')) -match 'does not name the recorded failure')

    Write-Host 'Case I: failed request for an existing qualified partition'
    $caseI = New-RunCase -Name 'case-i-missing-qualified' -DataFolder $dataRoot -FailedLines @('\cfd\dukascopy\tick\xauusd\20190101_quote.zip', $absentRequest, $auxiliaryRequest) -MonitorCount 3 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultI = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseI
    Check 'exit 1' ($resultI.Code -eq 1)
    Check 'qualification INVALID' ($resultI.Record.qualification -eq 'INVALID')
    Check 'missing qualified partition classified' ($resultI.Record.occurrencesByCategory.'unexpected-missing-qualified-partition' -eq 1)

    Write-Host 'Case J: absent day not requested within the horizon'
    $caseJ = New-RunCase -Name 'case-j-unrequested-absence' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultJ = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseJ
    Check 'exit 1' ($resultJ.Code -eq 1)
    Check 'qualification INVALID' ($resultJ.Record.qualification -eq 'INVALID')
    Check 'unrequested absence classified' ($resultJ.Record.occurrencesByCategory.'unexpected-unrequested-absence' -eq 1)

    Write-Host 'Case K: absent day after the terminated horizon is recorded, not required'
    $caseK = New-RunCase -Name 'case-k-after-horizon-absence' -DataFolder $dataRoot -FailedLines @($auxiliaryRequest) -MonitorCount 1 -FailureKind 'BrokerLiquidation' -FailureCondition 'ForcedCloseFailed' -Through '2019-01-01T13:00:00Z' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultK = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseK
    Check 'exit 0' ($resultK.Code -eq 0)
    Check 'qualification EXPECTED' ((Get-PropertyValue $resultK.Record @('qualification')) -eq 'EXPECTED')
    Check 'runTerminated true' ((Get-PropertyValue $resultK.Record @('runTerminated')) -eq $true)
    Check 'coverageEndDay is the terminal day' ((Get-PropertyValue $resultK.Record @('coverageEndDay')) -eq '2019-01-01')
    Check 'one absent day after termination' ((Get-PropertyValue $resultK.Record @('sourceAbsentDaysAfterTermination')) -eq 1)

    Write-Host 'Case L: corrected contract baseline pin mismatch'
    $pinMismatch = [IO.File]::ReadAllText($script:correctedContractPath) | ConvertFrom-Json
    $pinMismatch.baselineContract.sha256LfNormalized = ('0' * 64)
    $pinMismatchPath = Join-Path $root 'corrected-pin-mismatch.json'
    Write-JsonFile $pinMismatchPath $pinMismatch
    $resultL = Invoke-CorrectedClassifier -ContractPath $pinMismatchPath -Preflight
    Check 'exit 2' ($resultL.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultL.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the baseline pin' ($resultL.Record.failure -match 'pins baseline hash')

    Write-Host 'Case N: partition zip modified after the manifest was built'
    $treeN = New-Tree (Join-Path $root 'data-drift') $presentDays
    New-Manifest $treeN $presentDays $script:baselineContract
    [System.IO.File]::WriteAllText((Join-Path $treeN.Root 'cfd\dukascopy\tick\xauusd\20190103_quote.zip'), 'tampered after the manifest')
    $caseN = New-RunCase -Name 'case-n-tree-drift' -DataFolder $treeN.Root -FailedLines @($auxiliaryRequest) -MonitorCount 1 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultN = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseN -DataFolderOverride $treeN.Root
    Check 'exit 2' ($resultN.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultN.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the changed partition' ($resultN.Record.failure -match '20190103_quote.zip')

    Write-Host 'Case O: invocation parametersString mismatch'
    $caseO = New-RunCase -Name 'case-o-wrong-parameters' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $invocationOPath = Join-Path $caseO 'marketlab-run-invocation.json'
    $invocationO = [IO.File]::ReadAllText($invocationOPath) | ConvertFrom-Json
    $invocationO.parametersString = 'single-anchor-step-percent:999'
    Write-JsonFile $invocationOPath $invocationO
    New-Outcome -RunDirectory $caseO -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultO = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseO
    Check 'exit 2' ($resultO.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultO.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the parameters mismatch' ($resultO.Record.failure -match 'parameters')

    Write-Host 'Case P: invocation runMode baseline is refused'
    $caseP = New-RunCase -Name 'case-p-baseline-run-mode' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $invocationPPath = Join-Path $caseP 'marketlab-run-invocation.json'
    $invocationP = [IO.File]::ReadAllText($invocationPPath) | ConvertFrom-Json
    $invocationP.runMode = 'baseline'
    Write-JsonFile $invocationPPath $invocationP
    New-Outcome -RunDirectory $caseP -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultP = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseP
    Check 'exit 2' ($resultP.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultP.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names runMode' ($resultP.Record.failure -match 'runMode')

    Write-Host 'Case Q: invocation carries a baseline contract path'
    $caseQ = New-RunCase -Name 'case-q-baseline-contract-path' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $invocationQPath = Join-Path $caseQ 'marketlab-run-invocation.json'
    $invocationQ = [IO.File]::ReadAllText($invocationQPath) | ConvertFrom-Json
    $invocationQ.baselineContractPath = 'MarketLab/config/baseline-contract.json'
    Write-JsonFile $invocationQPath $invocationQ
    New-Outcome -RunDirectory $caseQ -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultQ = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseQ
    Check 'exit 2' ($resultQ.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultQ.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names baselineContractPath' ($resultQ.Record.failure -match 'noBaselineContract')

    Write-Host 'Case R: results missing the research margin block'
    $caseR = New-RunCase -Name 'case-r-missing-margin' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRoot -RuntimeHashes $runtimeHashes
    $resultsRPath = Join-Path $caseR 'storage\single-anchor\results.json'
    $resultsR = [IO.File]::ReadAllText($resultsRPath) | ConvertFrom-Json
    $resultsR.PSObject.Properties.Remove('researchMargin')
    Write-JsonFile $resultsRPath $resultsR
    New-Outcome -RunDirectory $caseR -LeanExit 0 -HelperExit 0 -EnginePerformed $true -EngineCount 0 -EngineMessages @() -RuntimeAfter $runtimeHashes
    $resultR = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseR
    Check 'exit 2' ($resultR.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultR.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the research margin' ($resultR.Record.failure -match 'research margin')

    Write-Host 'Case S: preflight pass without a run directory'
    $resultS = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight
    Check 'exit 0' ($resultS.Code -eq 0)
    Check 'qualification PREFLIGHT-PASS' ($resultS.Record.qualification -eq 'PREFLIGHT-PASS')
    Check 'mode corrected-full-history' ($resultS.Record.mode -eq 'corrected-full-history')
    Check 'authoritative false for the test override' ($resultS.Record.authoritative -eq $false)
    Check 'verifiedPartitionCount 2' ($resultS.Record.verifiedPartitionCount -eq 2)
    Check 'dataFolderSource contract' ($resultS.Record.dataFolderSource -eq 'contract')

    Write-Host 'Case T: preflight catches tree drift before any run'
    $resultT = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight -DataFolderOverride $treeN.Root
    Check 'exit 2' ($resultT.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultT.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the changed partition' ($resultT.Record.failure -match '20190103_quote.zip')

    Write-Host 'Case U: data-folder override without the test override'
    $resultU = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight -DataFolderOverride $dataRoot -NoOverride -ReviewedCommit $repositorySha
    Check 'exit 2' ($resultU.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultU.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the override gate' ($resultU.Record.failure -match 'must not be overridden')
    $resultU2 = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight -NoOverride
    Check 'exit 2 without -ReviewedCommit' ($resultU2.Code -eq 2)
    Check 'controlled failure without -ReviewedCommit' ($resultU2.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the -ReviewedCommit requirement' ($resultU2.Record.failure -match 'requires -ReviewedCommit')

    Write-Host 'Case V: runtime binary changed after the run'
    $runtimeRootV = Join-Path $root 'runtime-v'
    $runtimeHashesV = New-RuntimeSet $runtimeRootV
    $caseV = New-RunCase -Name 'case-v-runtime-changed' -DataFolder $dataRoot -FailedLines @($absentRequest, $auxiliaryRequest) -MonitorCount 2 -Through '' -RuntimeRoot $runtimeRootV -RuntimeHashes $runtimeHashesV
    [System.IO.File]::WriteAllText((Join-Path $runtimeRootV 'QuantConnect.Common.dll'), 'changed after the run')
    $resultV = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -CaseDirectory $caseV
    Check 'exit 2' ($resultV.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultV.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the runtime binary' ($resultV.Record.failure -match 'runtime binary')

    Write-Host 'Case W: -CheckOnly preflight prints JSON and writes no record'
    $resultW = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight -CheckOnly
    Check 'exit 0' ($resultW.Code -eq 0)
    Check 'stdout carries the preflight JSON' ($resultW.StdOut.Count -gt 0)
    $preflightW = ($resultW.StdOut -join "`n") | ConvertFrom-Json
    Check 'stdout qualification PREFLIGHT-PASS' ($preflightW.qualification -eq 'PREFLIGHT-PASS')
    Check 'stdout verifiedPartitionCount 2' ($preflightW.verifiedPartitionCount -eq 2)
    Check 'no record file written' (-not (Test-Path -LiteralPath $resultW.RecordPath))

    Write-Host 'Case M: frozen baseline contract edited after the corrected contract was built'
    $baselineText = [System.IO.File]::ReadAllText($syntheticBaselinePath)
    try {
        [System.IO.File]::WriteAllText($syntheticBaselinePath, $baselineText + "`n")
        $resultM = Invoke-CorrectedClassifier -ContractPath $script:correctedContractPath -Preflight
    }
    finally {
        [System.IO.File]::WriteAllText($syntheticBaselinePath, $baselineText)
    }
    Check 'exit 2' ($resultM.Code -eq 2)
    Check 'qualification CONTROLLED_FAILURE' ($resultM.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the changed baseline' ($resultM.Record.failure -match 'frozen baseline contract changed')
}
finally {
    if (Test-Path -LiteralPath $root) {
        $fullRoot = [IO.Path]::GetFullPath($root)
        if (-not $fullRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\marketlab-corrected-classifier-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Write-Host "corrected full-history classifier tests: $($script:Checks - $script:Failures)/$($script:Checks) passed"
if ($script:Failures -gt 0) {
    [Console]::Error.WriteLine("ERROR: $($script:Failures) check(s) failed.")
    exit 1
}
exit 0
