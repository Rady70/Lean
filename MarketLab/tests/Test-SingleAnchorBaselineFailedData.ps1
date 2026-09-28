<#
.SYNOPSIS
Windows-local tests for scripts\Test-SingleAnchorBaselineFailedData.ps1 on synthetic fixtures.

.DESCRIPTION
Creates a temporary synthetic qualified tree (partitions, auxiliary databases, session map,
composition manifest and replay qualification record), a synthetic contract/register/evidence
and synthetic run directories outside the repository, then checks the classifier's provenance
chain and its classification paths:

  A expected-only failed list                      -> exit 0, EXPECTED
  B failed request for an existing partition       -> exit 1, unexpected-missing-qualified-partition
  C unknown failed request path                    -> exit 1, unexpected-unknown-request
  D out-of-window partition failed request         -> exit 1, unexpected-out-of-window-request
  E frozen-window absent day not requested at all  -> exit 1, unexpected-unrequested-absence
  F contract partition count drifts from evidence  -> exit 2, controlled failure
  G run is not the frozen baseline identity        -> exit 2, controlled failure
  H AccountStopOut bounds the horizon              -> exit 0, absence after termination recorded
  I unrequested absence within a stop-out horizon  -> exit 1, unexpected-unrequested-absence
  J contract missing top-level fields              -> exit 2, controlled failure
  K modified partition, unchanged partition count  -> exit 2, controlled failure (manifest hash)
  L present/absent day swap, count unchanged       -> exit 2, controlled failure (manifest set)
  M invocation evidence data folder mismatch       -> exit 2, controlled failure
  N data-monitor count vs failed-request lines     -> exit 1, failed-request-accounting-mismatch
  O non-approved run termination                   -> exit 2, controlled failure
  P auxiliary request count vs tracked evidence    -> exit 1, contract-evidence-mismatch
  Q contract not pinned by the register            -> exit 2, controlled failure
  R data-folder override without the test override -> exit 2, controlled failure
  S non-clean helper outcome (engine errors)       -> exit 2, controlled failure
  T missing post-run outcome evidence              -> exit 2, controlled failure
  U pre-run contract hash mismatch                 -> exit 2, controlled failure
  V runtime binary changed after the run           -> exit 2, controlled failure
  W manifest not anchored to the qualification rec -> exit 2, controlled failure
  X AccountStopOut with a non-terminal outcome     -> exit 2, controlled failure
  Y AccountStopOut with an unrelated engine error  -> exit 2, controlled failure
  P1 preflight pass (identity + tree, no run)      -> exit 0, PREFLIGHT-PASS
  P2 preflight catches tree drift before any run   -> exit 2, controlled failure
  P3 preflight refuses an unpinned contract        -> exit 2, controlled failure

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

$classifier = Join-Path $PSScriptRoot '..\scripts\Test-SingleAnchorBaselineFailedData.ps1'
if (-not (Test-Path -LiteralPath $classifier -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: classifier script not found at '$classifier'.")
    exit 1
}
$marketLabRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $marketLabRoot '..')).Path
$realContract = Join-Path $marketLabRoot 'config\baseline-contract.json'
$realConfig = Join-Path $marketLabRoot 'config\backtesting.json'
$realConfigHash = Get-LfSha256 $realConfig
# A stable existing file stands in for the built algorithm assembly in the synthetic contract.
$algorithmFilePath = Join-Path $marketLabRoot 'scripts\run-backtest.ps1'
$algorithmFileHash = Get-RawSha256 $algorithmFilePath
$algorithmFileRelative = 'MarketLab\scripts\run-backtest.ps1'

$root = Join-Path $env:TEMP ("marketlab-baseline-classifier-" + [guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $root 'data'
$runRoot = Join-Path $root 'run'
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$startText = '2019-01-01'
$endDateText = '2019-01-03'
$presentDays = @('20190101', '20190103')
$absentDay = '20190102'
$runtimeNames = @(
    'QuantConnect.Lean.Launcher.dll',
    'QuantConnect.Lean.Engine.dll',
    'QuantConnect.Common.dll',
    'QuantConnect.Algorithm.dll',
    'QuantConnect.AlgorithmFactory.dll',
    'QuantConnect.Configuration.dll',
    'QuantConnect.Logging.dll'
)

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
        if ($count) { $parts[$date] = [ordered]@{ quote_count = $count; semantic_digest = Get-TextDigest $local } }
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
    # The replay qualification record anchors the manifest file hash.
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

function New-Contract([string]$Path, $Tree, [int]$PartitionCount) {
    $contract = [System.IO.File]::ReadAllText($realContract) | ConvertFrom-Json
    $identity = $contract.qualifiedDataIdentity
    $identity.dataFolder = $Tree.Root
    $identity.startDate = $startText
    $identity.endDate = $endDateText
    $identity.continuousHistoryPartitionCount = $PartitionCount
    $delivered = New-Delivery ''
    $identity.continuousHistoryQuoteCount = $delivered.quote_count
    $identity.continuousHistoryFirstQuoteUtc = $delivered.first_canonical_utc
    $identity.continuousHistoryLastQuoteUtc = $delivered.last_canonical_utc
    $identity.continuousHistorySemanticDigest = $delivered.semantic_digest
    $identity.sessionMapSha256 = $Tree.SessionMapHash
    $identity.marketHoursDatabaseSha256 = $Tree.MarketHoursHash
    $identity.symbolPropertiesDatabaseSha256 = $Tree.SymbolPropertiesHash
    $contract.runHost.algorithmLocation = $algorithmFileRelative
    Write-JsonFile $Path $contract
    return $contract
}

function Get-ContractParametersString($Contract) {
    return (@($Contract.parameters | ForEach-Object { $_.name + ':' + $_.value }) -join ',')
}

function New-Evidence([string]$Path, [int]$Unrelated) {
    $evidence = [ordered]@{
        replay = [ordered]@{
            record_sha256 = Get-RawSha256 (Join-Path $script:tree.Root 'marketlab-qualification\continuous-qualification-record.json')
            source_absent_days = 1
            missing_native_partitions = 0
            source_coverage_gap_days = 0
            unrelated_failed_data_requests = $Unrelated
        }
    }
    Write-JsonFile $Path $evidence
}

function New-Results([string]$Path, $Contract, [string]$Market, [string]$FailureKind, [string]$FailureQuoteTime) {
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
    $delivered = New-Delivery $FailureQuoteTime
    $results = [ordered]@{
        completed = -not [bool]$FailureKind
        algorithmTimeZone = 'UTC'; quoteTimeZone = 'UTC'
        startUtc = '2019-01-01T00:00:00Z'; endUtc = '2019-01-03T23:59:59.9999999Z'
        quoteTicksProcessed = $delivered.quote_count; strategyEligibleQuotes = $delivered.quote_count
        quoteOnlyQuotes = 0; nonQuoteTicksUnused = 0; delivered = $delivered
        symbol = 'XAUUSD'
        market = $Market
        startDate = $startText
        endDate = $endDateText
        parameters = $resultParameters
        researchAccount = [ordered]@{ InitialBalance = $cash; CurrentOpenPositions = 1; Equity = 1 }
        researchMargin = [ordered]@{ MarginCallActive = $false; StopOut = $null; CurrentUsedMargin = 10 }
        sessionMap = [ordered]@{ Sha256 = $script:tree.SessionMapHash }
        failure = $null
        lastProcessedQuote = $delivered.last_quote
    }
    if ($FailureKind) {
        $results['failure'] = [ordered]@{
            Kind = $FailureKind
            Condition = 'MarginLevel'
            Quote = $delivered.last_quote
            Message = 'synthetic test failure'
        }
        $results.researchMargin.StopOut = [ordered]@{
            Time = $delivered.last_quote.Time; Reason = 'MarginLevel'; Equity = 1
            UsedMargin = 10; MarginLevelPercent = 10; OpenPositions = 1
        }
    }
    Write-JsonFile $Path $results
}

function New-InvocationEvidence([string]$Path, $Contract, [string]$DataFolder, [string]$ParametersString, [string]$RunDirectory, [string]$AlgorithmLocation, [string]$AlgorithmHash, $ContractSha, $RegisterPath, $RegisterPin, $RuntimeRoot, $RuntimeHashes) {
    $invocation = [ordered]@{
        contract = 'marketlab-run-invocation-evidence-v1'
        generatedUtc = '2019-01-01T00:00:00Z'
        leanRoot = $repoRoot
        configuration = 'Release'
        dotnet = 'synthetic'
        launcher = 'synthetic'
        launcherSha256 = 'synthetic'
        configPath = $realConfig
        configSha256LfNormalized = $realConfigHash
        algorithmTypeName = $Contract.runHost.algorithmTypeName
        algorithmLanguage = $Contract.runHost.algorithmLanguage
        algorithmLocation = $AlgorithmLocation
        algorithmSha256 = $AlgorithmHash
        dataFolder = $DataFolder
        parametersString = $ParametersString
        closeAutomatically = $true
        allowMissingData = $true
        allowEngineErrors = $false
        commandLine = @('synthetic')
        workingDirectory = $RunDirectory
        runDirectory = $RunDirectory
        baselineContractPath = $script:syntheticContractPath
        baselineContractSha256 = $ContractSha
        baselineRegisterPath = $RegisterPath
        baselineRegisterPin = $RegisterPin
        repositoryHead = 'synthetic-head'
        repositoryDirty = $false
        runtimeBinariesRoot = $RuntimeRoot
        runtimeBinaries = $RuntimeHashes
        expectedTerminalException = 'MarketLab.SingleAnchor.AccountStopOutException'
    }
    Write-JsonFile $Path $invocation
}

function Get-MonitorFailedCount([string]$RunDirectory) {
    $monitor = [System.IO.File]::ReadAllText((Join-Path $RunDirectory 'data-monitor-report-20190101000000000.json')) | ConvertFrom-Json
    return [int]$monitor.'failed-data-requests-count'
}

function New-Outcome([string]$RunDirectory, [int]$LeanExit, [int]$HelperExit, [bool]$EnginePerformed, $EngineCount, $RuntimeRoot, $RuntimeAfter, [int]$TerminalLines = 0, [string]$TerminalException = 'MarketLab.SingleAnchor.AccountStopOutException') {
    $invocationPath = Join-Path $RunDirectory 'marketlab-run-invocation.json'
    $outcome = [ordered]@{
        contract = 'marketlab-run-outcome-evidence-v1'
        generatedUtc = '2019-01-01T00:00:00Z'
        invocationEvidence = 'marketlab-run-invocation.json'
        invocationEvidenceSha256 = Get-RawSha256 $invocationPath
        leanExitCode = $LeanExit
        helperExitCode = $HelperExit
        engineErrorCheckPerformed = $EnginePerformed
        engineErrorCount = $EngineCount
        expectedTerminalException = $TerminalException
        terminalExceptionLineCount = $TerminalLines
        dataMonitorReport = 'data-monitor-report-20190101000000000.json'
        failedDataRequestCount = Get-MonitorFailedCount $RunDirectory
        runtimeBinariesAfter = $RuntimeAfter
        runtimeBinariesUnchanged = $true
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

function New-RunCase([string]$Name, $Contract, [string]$DataFolder, [string[]]$FailedLines, [int]$MonitorCount, [string]$FailureKind, [string]$FailureQuoteTime, [string]$EvidenceDataFolder, [string]$AlgorithmLocation, [string]$AlgorithmHash, $RuntimeRoot, $RuntimeHashes) {
    $caseDir = Join-Path $runRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $caseDir 'storage\single-anchor') -Force | Out-Null
    New-Results (Join-Path $caseDir 'storage\single-anchor\results.json') $Contract 'dukascopy' $FailureKind $FailureQuoteTime
    $dataFolderForEvidence = if ($EvidenceDataFolder) { $EvidenceDataFolder } else { $DataFolder }
    New-InvocationEvidence (Join-Path $caseDir 'marketlab-run-invocation.json') $Contract $dataFolderForEvidence (Get-ContractParametersString $Contract) $caseDir $AlgorithmLocation $AlgorithmHash $script:syntheticContractSha $script:syntheticRegisterPath $script:syntheticContractSha $RuntimeRoot $RuntimeHashes
    New-FailedRequests $caseDir $FailedLines
    New-Monitor $caseDir $MonitorCount
    if ($FailureKind -eq 'AccountStopOut') {
        New-Outcome $caseDir 1 1 $true 0 $RuntimeRoot $RuntimeHashes -TerminalLines 1
    }
    else {
        New-Outcome $caseDir 0 0 $true 0 $RuntimeRoot $RuntimeHashes
    }
    return $caseDir
}

function Invoke-Classifier([string]$CaseDirectory, [string]$ContractPath, [switch]$NoOverride, [string]$DataFolderOverride, [switch]$Preflight) {
    if ($Preflight) {
        $recordPath = Join-Path $runRoot ('preflight-' + [guid]::NewGuid().ToString('N') + '.json')
    }
    else {
        $recordPath = Join-Path $CaseDirectory 'classification.json'
    }
    $evidenceForCase = if ($NoOverride -and $DataFolderOverride) { Join-Path $marketLabRoot 'tools\historical-data\fixtures\continuous-history-evidence.json' } else { $syntheticEvidencePath }
    $arguments = @('-NoProfile', '-File', $classifier, '-Contract', $ContractPath, '-Evidence', $evidenceForCase, '-OutputPath', $recordPath)
    if ($Preflight) { $arguments += '-Preflight' } else { $arguments += @('-RunDirectory', $CaseDirectory) }
    if ($DataFolderOverride) { $arguments += @('-DataFolder', $DataFolderOverride) }
    if (-not $NoOverride) { $arguments += '-AllowNonAuthoritativeOverride' }
    & powershell @arguments | Out-Null
    $code = $LASTEXITCODE
    $record = $null
    if (Test-Path -LiteralPath $recordPath) {
        $record = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    }
    return [pscustomobject]@{ Code = $code; Record = $record }
}

New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$tree = New-Tree $dataRoot $presentDays
$script:tree = $tree
$syntheticContractPath = Join-Path $root 'baseline-contract.json'
$script:syntheticContractPath = $syntheticContractPath
$contract = New-Contract $syntheticContractPath $tree $presentDays.Count
$script:syntheticContractSha = Get-LfSha256 $syntheticContractPath
$syntheticRegisterPath = Join-Path $root 'baseline-decision-audit.json'
$script:syntheticRegisterPath = $syntheticRegisterPath
Write-JsonFile $syntheticRegisterPath ([ordered]@{ contract = 'marketlab-baseline-decision-audit-v1'; frozenBaselineContractSha256 = $script:syntheticContractSha })
New-Manifest $tree $presentDays $contract
$syntheticEvidencePath = Join-Path $root 'continuous-history-evidence.json'
New-Evidence $syntheticEvidencePath 1
$parametersString = Get-ContractParametersString $contract
$runtimeRoot = Join-Path $root 'runtime'
$runtimeHashes = New-RuntimeSet $runtimeRoot

try {
    Write-Host 'Case A: expected-only failed list'
    $caseA = New-RunCase 'case-a' $contract $dataRoot @(
        ('\cfd\dukascopy\tick\xauusd\' + $absentDay + '_quote.zip'),
        '\cfd\dukascopy\hour\xauusd.zip'
    ) 2 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultA = Invoke-Classifier $caseA $syntheticContractPath
    Check 'exit 0' ($resultA.Code -eq 0)
    Check 'qualification EXPECTED' ($resultA.Record.qualification -eq 'EXPECTED')
    Check 'authoritative:false for the test override' ($resultA.Record.authoritative -eq $false)
    Check 'one expected absent day' ($resultA.Record.occurrencesByCategory.'expected-source-absent-calendar-day' -eq 1)
    Check 'one known auxiliary' ($resultA.Record.occurrencesByCategory.'known-non-strategy-auxiliary-request' -eq 1)
    Check 'accounting matches the monitor' ($resultA.Record.failedRequestAccountingMatches -eq $true)
    Check 'tree partition hashes verified' ($resultA.Record.verifiedPartitionCount -eq 2)
    Check 'manifest anchored to the qualification record' ($resultA.Record.qualificationRecord -like '*continuous-qualification-record.json')
    Check 'pre-run contract identity verified' ($resultA.Record.preRunContractSha256 -eq $script:syntheticContractSha)
    Check 'run outcome verified' ($resultA.Record.runOutcomeVerified -eq $true)

    Write-Host 'Case B: failed request for an existing qualified partition'
    $caseB = New-RunCase 'case-b' $contract $dataRoot @('\cfd\dukascopy\tick\xauusd\20190101_quote.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultB = Invoke-Classifier $caseB $syntheticContractPath
    Check 'exit 1' ($resultB.Code -eq 1)
    Check 'qualification INVALID' ($resultB.Record.qualification -eq 'INVALID')
    Check 'missing qualified partition classified' ($resultB.Record.occurrencesByCategory.'unexpected-missing-qualified-partition' -eq 1)

    Write-Host 'Case C: unknown failed request path'
    $caseC = New-RunCase 'case-c' $contract $dataRoot @('\equity\usa\minute\spy\20131009_trade.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultC = Invoke-Classifier $caseC $syntheticContractPath
    Check 'exit 1' ($resultC.Code -eq 1)
    Check 'unknown request classified' ($resultC.Record.occurrencesByCategory.'unexpected-unknown-request' -eq 1)

    Write-Host 'Case D: out-of-window partition failed request'
    $caseD = New-RunCase 'case-d' $contract $dataRoot @('\cfd\dukascopy\tick\xauusd\20190104_quote.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultD = Invoke-Classifier $caseD $syntheticContractPath
    Check 'exit 1' ($resultD.Code -eq 1)
    Check 'out-of-window request classified' ($resultD.Record.occurrencesByCategory.'unexpected-out-of-window-request' -eq 1)

    Write-Host 'Case E: frozen-window absent day not requested at all'
    $caseE = New-RunCase 'case-e' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultE = Invoke-Classifier $caseE $syntheticContractPath
    Check 'exit 1' ($resultE.Code -eq 1)
    Check 'unrequested absence classified' ($resultE.Record.occurrencesByCategory.'unexpected-unrequested-absence' -eq 1)

    Write-Host 'Case F: contract partition count drifts from the run evidence'
    $caseF = New-RunCase 'case-f' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $driftedContract = [System.IO.File]::ReadAllText($syntheticContractPath) | ConvertFrom-Json
    $driftedContract.qualifiedDataIdentity.continuousHistoryPartitionCount = 7
    $driftedContractPath = Join-Path $root 'baseline-contract-drifted.json'
    Write-JsonFile $driftedContractPath $driftedContract
    $resultF = Invoke-Classifier $caseF $driftedContractPath
    Check 'exit 2' ($resultF.Code -eq 2)
    Check 'controlled failure recorded' ($resultF.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case G: run is not the frozen baseline identity'
    $caseG = Join-Path $runRoot 'case-g'
    New-Item -ItemType Directory -Path (Join-Path $caseG 'storage\single-anchor') -Force | Out-Null
    New-Results (Join-Path $caseG 'storage\single-anchor\results.json') $contract 'oanda' $null $null
    New-InvocationEvidence (Join-Path $caseG 'marketlab-run-invocation.json') $contract $dataRoot $parametersString $caseG $algorithmFilePath $algorithmFileHash $script:syntheticContractSha $script:syntheticRegisterPath $script:syntheticContractSha $runtimeRoot $runtimeHashes
    New-FailedRequests $caseG @('\cfd\dukascopy\hour\xauusd.zip')
    New-Monitor $caseG 1
    New-Outcome $caseG 0 0 $true 0 $runtimeRoot $runtimeHashes
    $resultG = Invoke-Classifier $caseG $syntheticContractPath
    Check 'exit 2' ($resultG.Code -eq 2)
    Check 'controlled failure recorded' ($resultG.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case H: AccountStopOut bounds the expected-absence horizon'
    $caseH = New-RunCase 'case-h' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultH = Invoke-Classifier $caseH $syntheticContractPath
    Check 'exit 0' ($resultH.Code -eq 0)
    Check 'qualification EXPECTED' ($resultH.Record.qualification -eq 'EXPECTED')
    Check 'run marked terminated' ($resultH.Record.runTerminated -eq $true)
    Check 'termination kind recorded' ($resultH.Record.terminationKind -eq 'AccountStopOut')
    Check 'coverage horizon is the failure day' ($resultH.Record.coverageEndDay -eq '2019-01-01')
    Check 'absence after termination recorded' ($resultH.Record.sourceAbsentDaysAfterTermination -eq 1)
    Check 'terminal outcome shape verified' ($resultH.Record.helperExitCode -eq 1)
    Check 'terminal delivery proven against native prefix' ($resultH.Record.deliveryVerification.terminalDayPrefixRead -eq $true)

    $caseFullDay = New-RunCase 'terminal-full-day' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T13:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $fullDay = Invoke-Classifier $caseFullDay $syntheticContractPath
    Check 'stop-out at a qualified partition end is accepted' ($fullDay.Code -eq 0 -and $fullDay.Record.deliveryVerification.quoteCount -eq 2)
    $fullDayPath = Join-Path $caseFullDay 'storage\single-anchor\results.json'
    $shifted = [IO.File]::ReadAllText($fullDayPath) | ConvertFrom-Json
    $shifted.delivered.last_canonical_utc = '2019-01-02T13:00:00Z'
    $shifted.delivered.last_quote.Time = '2019-01-02T13:00:00Z'
    $shifted.lastProcessedQuote.Time = '2019-01-02T13:00:00Z'
    $shifted.failure.Quote.Time = '2019-01-02T13:00:00Z'
    $shifted.researchMargin.StopOut.Time = '2019-01-02T13:00:00Z'
    Write-JsonFile $fullDayPath $shifted
    $absentTerminal = Invoke-Classifier $caseFullDay $syntheticContractPath
    Check 'invented terminal quote on an absent day is refused' ($absentTerminal.Code -eq 2 -and $absentTerminal.Record.failure -match 'no delivered qualified partition')

    $caseZeroMargin = New-RunCase 'terminal-zero-margin' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $zeroPath = Join-Path $caseZeroMargin 'storage\single-anchor\results.json'
    $zero = [IO.File]::ReadAllText($zeroPath) | ConvertFrom-Json
    $zero.failure.Condition = 'NegativeEquity'
    $zero.researchAccount.Equity = -1
    $zero.researchMargin.CurrentUsedMargin = 0
    $zero.researchMargin.StopOut.Reason = 'NegativeEquity'
    $zero.researchMargin.StopOut.Equity = -1
    $zero.researchMargin.StopOut.UsedMargin = 0
    $zero.researchMargin.StopOut.MarginLevelPercent = $null
    Write-JsonFile $zeroPath $zero
    $zeroChecked = Invoke-Classifier $caseZeroMargin $syntheticContractPath
    Check 'approved zero-margin negative-equity terminal shape is accepted' ($zeroChecked.Code -eq 0)

    Write-Host 'Case I: unrequested absence within a stop-out horizon is still invalid'
    $caseI = New-RunCase 'case-i' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-03T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultI = Invoke-Classifier $caseI $syntheticContractPath
    Check 'exit 1' ($resultI.Code -eq 1)
    Check 'unrequested absence within horizon classified' ($resultI.Record.occurrencesByCategory.'unexpected-unrequested-absence' -eq 1)

    Write-Host 'Case J: a contract missing top-level fields is a controlled failure'
    $caseJ = New-RunCase 'case-j' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $malformedPath = Join-Path $root 'malformed-contract.json'
    [System.IO.File]::WriteAllText($malformedPath, '{}', (New-Object System.Text.UTF8Encoding($false)))
    $resultJ = Invoke-Classifier $caseJ $malformedPath
    Check 'exit 2' ($resultJ.Code -eq 2)
    Check 'controlled failure recorded' ($resultJ.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case K: modified partition with unchanged partition count'
    $treeK = New-Tree (Join-Path $root 'data-k') $presentDays
    New-Manifest $treeK $presentDays $contract
    [System.IO.File]::WriteAllText((Join-Path $treeK.Root 'cfd\dukascopy\tick\xauusd\20190103_quote.zip'), 'tampered-content')
    $caseK = New-RunCase 'case-k' $contract $treeK.Root @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultK = Invoke-Classifier $caseK $syntheticContractPath -DataFolderOverride $treeK.Root
    Check 'exit 2' ($resultK.Code -eq 2)
    Check 'controlled failure recorded' ($resultK.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the partition hash' ($resultK.Record.failure -match '20190103_quote.zip')

    Write-Host 'Case L: present/absent day swap, partition count unchanged'
    $treeL = New-Tree (Join-Path $root 'data-l') @('20190102', '20190103')
    New-Manifest $treeL $presentDays $contract
    $caseL = New-RunCase 'case-l' $contract $treeL.Root @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultL = Invoke-Classifier $caseL $syntheticContractPath -DataFolderOverride $treeL.Root
    Check 'exit 2' ($resultL.Code -eq 2)
    Check 'controlled failure recorded' ($resultL.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case M: invocation evidence data folder mismatch'
    $caseM = New-RunCase 'case-m' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null (Join-Path $root 'other-data') $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultM = Invoke-Classifier $caseM $syntheticContractPath
    Check 'exit 2' ($resultM.Code -eq 2)
    Check 'controlled failure recorded' ($resultM.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case N: data-monitor count disagrees with the failed-request lines'
    $caseN = New-RunCase 'case-n' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 3 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultN = Invoke-Classifier $caseN $syntheticContractPath
    Check 'exit 1' ($resultN.Code -eq 1)
    Check 'accounting mismatch classified' ($resultN.Record.occurrencesByCategory.'failed-request-accounting-mismatch' -eq 1)

    Write-Host 'Case O: a non-approved run termination is a controlled failure'
    $caseO = New-RunCase 'case-o' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'StrategyInvariant' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultO = Invoke-Classifier $caseO $syntheticContractPath
    Check 'exit 2' ($resultO.Code -eq 2)
    Check 'controlled failure recorded' ($resultO.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case P: auxiliary request count disagrees with the tracked evidence'
    $caseP = New-RunCase 'case-p' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip', '\cfd\dukascopy\hour\xauusd.zip') 2 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultP = Invoke-Classifier $caseP $syntheticContractPath
    Check 'exit 1' ($resultP.Code -eq 1)
    Check 'auxiliary/evidence mismatch classified' ($resultP.Record.occurrencesByCategory.'contract-evidence-mismatch' -eq 1)
    Check 'repeated path recorded' ($resultP.Record.repeatedFailedPaths.'cfd/dukascopy/hour/xauusd.zip' -eq 2)

    Write-Host 'Case Q: a contract not pinned by the register is refused without the test override'
    $caseQ = New-RunCase 'case-q' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $unpinnedContract = [System.IO.File]::ReadAllText($syntheticContractPath) | ConvertFrom-Json
    $unpinnedContract.parameters[0].value = 'NOT-XAUUSD'
    $unpinnedContractPath = Join-Path $root 'unpinned-contract.json'
    Write-JsonFile $unpinnedContractPath $unpinnedContract
    $resultQ = Invoke-Classifier $caseQ $unpinnedContractPath -NoOverride
    Check 'exit 2' ($resultQ.Code -eq 2)
    Check 'controlled failure recorded' ($resultQ.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case R: a data-folder override is refused without the test override'
    $caseR = New-RunCase 'case-r' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    # Use the real register-pinned contract so the pin check passes and the override gate itself is exercised.
    $resultR = Invoke-Classifier $caseR $realContract -NoOverride -DataFolderOverride $dataRoot
    Check 'exit 2' ($resultR.Code -eq 2)
    Check 'controlled failure recorded' ($resultR.Record.qualification -eq 'CONTROLLED_FAILURE')
    Check 'failure names the override gate' ($resultR.Record.failure -match 'must not be overridden')

    Write-Host 'Case S: a non-clean helper outcome (engine errors) is refused'
    $caseS = New-RunCase 'case-s' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    New-Outcome $caseS 0 4 $true 1 $runtimeRoot $runtimeHashes
    $resultS = Invoke-Classifier $caseS $syntheticContractPath
    Check 'exit 2' ($resultS.Code -eq 2)
    Check 'controlled failure recorded' ($resultS.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case T: missing post-run outcome evidence is refused'
    $caseT = New-RunCase 'case-t' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    Remove-Item -LiteralPath (Join-Path $caseT 'marketlab-run-outcome.json') -Force
    $resultT = Invoke-Classifier $caseT $syntheticContractPath
    Check 'exit 2' ($resultT.Code -eq 2)
    Check 'controlled failure recorded' ($resultT.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case U: pre-run contract hash mismatch is refused'
    $caseU = New-RunCase 'case-u' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $invocationU = [System.IO.File]::ReadAllText((Join-Path $caseU 'marketlab-run-invocation.json')) | ConvertFrom-Json
    $invocationU.baselineContractSha256 = ('0' * 64)
    Write-JsonFile (Join-Path $caseU 'marketlab-run-invocation.json') $invocationU
    # Re-write the outcome so it still binds the (modified) invocation file.
    New-Outcome $caseU 0 0 $true 0 $runtimeRoot $runtimeHashes
    $resultU = Invoke-Classifier $caseU $syntheticContractPath
    Check 'exit 2' ($resultU.Code -eq 2)
    Check 'controlled failure recorded' ($resultU.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case V: a runtime binary changed after the run is refused'
    $runtimeRootV = Join-Path $root 'runtime-v'
    $runtimeHashesV = New-RuntimeSet $runtimeRootV
    $caseV = New-RunCase 'case-v' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRootV $runtimeHashesV
    [System.IO.File]::WriteAllText((Join-Path $runtimeRootV 'QuantConnect.Common.dll'), 'changed after the run')
    $resultV = Invoke-Classifier $caseV $syntheticContractPath
    Check 'exit 2' ($resultV.Code -eq 2)
    Check 'controlled failure recorded' ($resultV.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case W: a manifest not anchored to the qualification record is refused'
    $treeW = New-Tree (Join-Path $root 'data-w') $presentDays
    New-Manifest $treeW $presentDays $contract
    $manifestW = [System.IO.File]::ReadAllText((Join-Path $treeW.Root 'marketlab-qualification\continuous-composition.json')) | ConvertFrom-Json
    $manifestW | Add-Member -NotePropertyName 'note' -NotePropertyValue 'tampered after the qualification record' -Force
    Write-JsonFile (Join-Path $treeW.Root 'marketlab-qualification\continuous-composition.json') $manifestW
    $caseW = New-RunCase 'case-w' $contract $treeW.Root @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    $resultW = Invoke-Classifier $caseW $syntheticContractPath -DataFolderOverride $treeW.Root
    Check 'exit 2' ($resultW.Code -eq 2)
    Check 'controlled failure recorded' ($resultW.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case X: AccountStopOut with a non-terminal outcome shape is refused'
    $caseX = New-RunCase 'case-x' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    New-Outcome $caseX 0 0 $true 0 $runtimeRoot $runtimeHashes
    $resultX = Invoke-Classifier $caseX $syntheticContractPath
    Check 'exit 2' ($resultX.Code -eq 2)
    Check 'controlled failure recorded' ($resultX.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case Y: AccountStopOut with an unrelated engine error is refused'
    $caseY = New-RunCase 'case-y' $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
    New-Outcome $caseY 1 1 $true 1 $runtimeRoot $runtimeHashes -TerminalLines 1
    $resultY = Invoke-Classifier $caseY $syntheticContractPath
    Check 'exit 2' ($resultY.Code -eq 2)
    Check 'controlled failure recorded' ($resultY.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case P1: preflight pass (contract identity + qualified tree), no run needed'
    $resultP1 = Invoke-Classifier $runRoot $syntheticContractPath -Preflight
    Check 'exit 0' ($resultP1.Code -eq 0)
    Check 'qualification PREFLIGHT-PASS' ($resultP1.Record.qualification -eq 'PREFLIGHT-PASS')
    Check 'tree partition hashes verified' ($resultP1.Record.verifiedPartitionCount -eq 2)
    Check 'contract identity recorded' ($resultP1.Record.baselineContractSha256 -eq $script:syntheticContractSha)

    Write-Host 'Case P2: preflight catches tree drift before any run'
    $resultP2 = Invoke-Classifier $runRoot $syntheticContractPath -Preflight -DataFolderOverride $treeK.Root
    Check 'exit 2' ($resultP2.Code -eq 2)
    Check 'controlled failure recorded' ($resultP2.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Case P3: preflight refuses an unpinned contract'
    $resultP3 = Invoke-Classifier $runRoot $unpinnedContractPath -Preflight -NoOverride
    Check 'exit 2' ($resultP3.Code -eq 2)
    Check 'controlled failure recorded' ($resultP3.Record.qualification -eq 'CONTROLLED_FAILURE')

    Write-Host 'Coherent local manifest and qualification record tampering cannot replace the tracked anchor'
    $recordWPath = Join-Path $treeW.Root 'marketlab-qualification\continuous-qualification-record.json'
    $recordW = [IO.File]::ReadAllText($recordWPath) | ConvertFrom-Json
    $recordW.continuous.composition_sha256 = Get-RawSha256 (Join-Path $treeW.Root 'marketlab-qualification\continuous-composition.json')
    Write-JsonFile $recordWPath $recordW
    $coherent = Invoke-Classifier $caseW $syntheticContractPath -DataFolderOverride $treeW.Root
    Check 'coherent local tamper refused' ($coherent.Code -eq 2)
    Check 'tracked replay anchor is the refusal reason' ($coherent.Record.failure -match 'tracked.*record_sha256|tracked replay')

    $mutations = [ordered]@{
        incomplete = { param($r) $r.completed = $false }
        missingCompleted = { param($r) $r.PSObject.Properties.Remove('completed') }
        shiftedWindow = { param($r) $r.endUtc = '2019-01-04T03:59:59.9999999Z' }
        wrongClock = { param($r) $r.algorithmTimeZone = 'America/New_York' }
        counterMismatch = { param($r) $r.quoteTicksProcessed = 1 }
        omittedPresentDay = { param($r) $r.delivered.per_partition.PSObject.Properties.Remove('2019-01-03') }
        alteredPartition = { param($r) $r.delivered.per_partition.'2019-01-03'.semantic_digest = 'sha256:' + ('0' * 64) }
        alteredGlobal = { param($r) $r.delivered.semantic_digest = 'sha256:' + ('0' * 64) }
        earlyLastQuote = { param($r) $r.delivered.last_canonical_utc = '2019-01-03T12:00:00.000Z' }
        missingDelivery = { param($r) $r.PSObject.Properties.Remove('delivered') }
    }
    foreach ($mutation in $mutations.GetEnumerator()) {
        $case = New-RunCase ('delivery-' + $mutation.Key) $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 $null $null $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
        $path = Join-Path $case 'storage\single-anchor\results.json'
        $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        & $mutation.Value $r
        Write-JsonFile $path $r
        $checked = Invoke-Classifier $case $syntheticContractPath
        Check ("delivery mutation refused: " + $mutation.Key) ($checked.Code -eq 2 -and $checked.Record.failure -match 'delivery')
    }

    $terminalMutations = [ordered]@{
        forgedPrefix = { param($r) $r.delivered.per_partition.'2019-01-01'.semantic_digest = 'sha256:' + ('0' * 64) }
        wrongPrice = { param($r) $r.delivered.last_quote.Ask = 999; $r.lastProcessedQuote.Ask = 999; $r.failure.Quote.Ask = 999 }
        wrongTerminal = { param($r) $r.researchMargin.StopOut.Time = '2019-01-01T13:00:00Z' }
        noStopOut = { param($r) $r.researchMargin.StopOut = $null }
        impossibleSurvival = { param($r) $r.researchMargin.StopOut.MarginLevelPercent = 50 }
        contradictoryCompletion = { param($r) $r.completed = $true }
    }
    foreach ($mutation in $terminalMutations.GetEnumerator()) {
        $case = New-RunCase ('terminal-' + $mutation.Key) $contract $dataRoot @('\cfd\dukascopy\hour\xauusd.zip') 1 'AccountStopOut' '2019-01-01T12:00:00Z' $null $algorithmFilePath $algorithmFileHash $runtimeRoot $runtimeHashes
        $path = Join-Path $case 'storage\single-anchor\results.json'
        $r = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        & $mutation.Value $r
        Write-JsonFile $path $r
        $checked = Invoke-Classifier $case $syntheticContractPath
        Check ("terminal mutation refused: " + $mutation.Key) ($checked.Code -eq 2 -and $checked.Record.failure -match 'delivery')
    }
}
finally {
    if (Test-Path -LiteralPath $root) {
        $fullRoot = [IO.Path]::GetFullPath($root)
        if (-not $fullRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\marketlab-baseline-classifier-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Write-Host "baseline classifier tests: $($script:Checks - $script:Failures)/$($script:Checks) passed"
if ($script:Failures -gt 0) {
    [Console]::Error.WriteLine("ERROR: $($script:Failures) check(s) failed.")
    exit 1
}
exit 0
