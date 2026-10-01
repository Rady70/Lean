#requires -Version 5.1
<#
.SYNOPSIS
Verifies one SingleAnchor Phase E replay package against its own manifest and against the
authoritative strategy result of the same run.

.DESCRIPTION
This verifier is the Phase E evidence gate. It proves that the deterministic replay package
emitted by SingleAnchorVNextAlgorithm is complete, internally consistent and bound to the
authoritative persisted result of the run:

  * the manifest contract, run identity and counters agree with storage\single-anchor\results.json;
  * every payload file re-hashes to its manifest SHA-256, byte size and line count;
  * the package fingerprint (name\nsha256\nbytes\n over the payload files, in manifest order)
    re-computes exactly;
  * every event line parses, event ids are strictly monotonic 1..N, the event-type counts match
    the manifest, run_started is first and run_ended is last, and the engine-event counts match
    the authoritative result counters;
  * every significant event has exactly one telemetry snapshot (the run-end entry_rejection_summary
    recaps deliberately have none), periodic samples exist only while positions are open and every
    account decimal is an exact JSON string (never a JSON number);
  * telemetry times are non-decreasing in shard order.

With -ExpectedResultsSha256 the verifier also enforces the Phase D binding: the run's persisted
results.json must hash to the finalized Phase D artifact. A mismatch fails the gate and is
recorded; the verifier never changes the run or the package.

Exit codes: 0 = PASS, 1 = verification failure, 2 = usage or missing input.
Output: <RunDirectory>\replay-package-verification.json by default, or -OutputPath.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [string]$ExpectedResultsSha256,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$failures = New-Object System.Collections.Generic.List[string]
$checks = 0

function Add-Failure([string]$message) {
    [void]$script:failures.Add($message)
}

function Test-Check([bool]$condition, [string]$message) {
    $script:checks++
    if (-not $condition) { Add-Failure $message }
}

function Get-Sha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Sha256OfText([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Convert-UtcTime([object]$value, [string]$field) {
    if ($null -eq $value) { throw "the field '$field' is null" }
    if ($value -is [datetime]) {
        # ConvertFrom-Json re-reads ISO-8601 text as a DateTime; the canonical UTC text itself is
        # asserted by the C# unit tests and written by the recorder.
        return ([datetime]$value).ToUniversalTime()
    }
    if ($value -isnot [string]) { throw "the field '$field' is not a timestamp" }
    try {
        return [datetime]::ParseExact(
            [string]$value,
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    catch {
        throw "the field '$field' is not a canonical UTC timestamp: '$value'"
    }
}

function Get-Property([object]$object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-JsonLines([string]$path) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($line.Length -eq 0) { continue }
        try {
            $rows.Add(($line | ConvertFrom-Json))
        }
        catch {
            throw "line is not valid JSON in $([System.IO.Path]::GetFileName($path)): $($line.Substring(0, [Math]::Min(120, $line.Length)))"
        }
    }
    return $rows
}

function Assert-ExactString([object]$object, [string]$name, [string]$where, [bool]$required = $false) {
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { Add-Failure "$where is missing the decimal field '$name'"; return }
    if ($null -eq $property.Value) {
        if ($required) { Add-Failure "$where decimal field '$name' is null" }
        return
    }
    if ($property.Value -isnot [string]) {
        Add-Failure "$where field '$name' is a JSON $($property.Value.GetType().Name), not an exact string"
    }
}

$requiredDecimalFields = @('balance', 'equity', 'floatingProfit', 'realizedProfit', 'usedMargin', 'grossLots', 'absoluteNetLots')
$nullableDecimalFields = @('freeMargin', 'marginLevelPercent')

try {
    if (-not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
        Write-Error "RunDirectory does not exist: $RunDirectory"
        exit 2
    }
    $run = (Resolve-Path -LiteralPath $RunDirectory).Path
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path $run 'replay-package-verification.json'
    }
    if ($ExpectedResultsSha256 -and ($ExpectedResultsSha256 -notmatch '^[0-9a-fA-F]{64}$')) {
        Write-Error "ExpectedResultsSha256 must be a 64-character hex SHA-256"
        exit 2
    }

    $resultsPath = Join-Path $run 'storage\single-anchor\results.json'
    $replayDirectory = Join-Path $run 'storage\single-anchor\replay'
    if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) {
        Write-Error "the authoritative result is missing: $resultsPath"
        exit 2
    }
    if (-not (Test-Path -LiteralPath $replayDirectory -PathType Container)) {
        Write-Error "the replay package directory is missing: $replayDirectory"
        exit 2
    }

    $resultsSha256 = Get-Sha256 $resultsPath
    if ($ExpectedResultsSha256) {
        Test-Check ($resultsSha256 -eq $ExpectedResultsSha256.ToLowerInvariant()) `
            "the run's results.json hash $resultsSha256 does not match the expected Phase D artifact $($ExpectedResultsSha256.ToLowerInvariant())"
    }

    $results = [System.IO.File]::ReadAllText($resultsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $manifestPath = Join-Path $replayDirectory 'manifest.json'
    $eventsPath = Join-Path $replayDirectory 'events.jsonl'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Write-Error "manifest.json is missing"; exit 1 }
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { Write-Error "events.jsonl is missing"; exit 1 }
    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    Test-Check ((Get-Property $manifest 'contract') -eq 'marketlab-single-anchor-replay-package-v1') `
        "the manifest contract is not marketlab-single-anchor-replay-package-v1"
    Test-Check ((Get-Property $manifest 'modelRevision') -ceq (Get-Property $results 'modelRevision')) `
        "manifest.modelRevision does not match results.modelRevision"
    Test-Check ((Get-Property $manifest 'stopOutModel') -ceq (Get-Property $results 'stopOutModel')) `
        "manifest.stopOutModel does not match results.stopOutModel"
    Test-Check ((Get-Property $manifest 'symbol') -ceq (Get-Property $results 'symbol')) `
        "manifest.symbol does not match results.symbol"
    Test-Check ((Get-Property $manifest 'market') -ceq (Get-Property $results 'market')) `
        "manifest.market does not match results.market"
    Test-Check ((Get-Property $manifest 'startDate') -ceq (Get-Property $results 'startDate')) `
        "manifest.startDate does not match results.startDate"
    Test-Check ((Get-Property $manifest 'endDate') -ceq (Get-Property $results 'endDate')) `
        "manifest.endDate does not match results.endDate"

    $manifestSession = Get-Property $manifest 'sessionMap'
    $resultSession = Get-Property $results 'sessionMap'
    if ($null -ne $manifestSession -and $null -ne $resultSession) {
        Test-Check ((Get-Property $manifestSession 'Sha256') -ceq (Get-Property $resultSession 'Sha256')) `
            "manifest.sessionMap.Sha256 does not match results.sessionMap.Sha256"
    }

    $manifestDelivered = Get-Property $manifest 'delivered'
    $resultDelivered = Get-Property $results 'delivered'
    if ($null -ne $manifestDelivered -and $null -ne $resultDelivered) {
        Test-Check ((Get-Property $manifestDelivered 'quoteCount') -eq (Get-Property $resultDelivered 'quote_count')) `
            "manifest.delivered.quoteCount does not match results.delivered.quote_count"
        Test-Check ((Get-Property $manifestDelivered 'semanticDigest') -ceq (Get-Property $resultDelivered 'semantic_digest')) `
            "manifest.delivered.semanticDigest does not match results.delivered.semantic_digest"
    }

    $manifestCounters = Get-Property $manifest 'counters'
    foreach ($pair in @(
            @('quoteTicksProcessed', 'quoteTicksProcessed'),
            @('quoteOnlyQuotes', 'quoteOnlyQuotes'),
            @('strategyEligibleQuotes', 'strategyEligibleQuotes'),
            @('legsOpened', 'legsOpened'),
            @('basketsClosed', 'basketsClosed'),
            @('basketsLiquidated', 'basketsLiquidated'),
            @('forcedLiquidations', 'forcedLiquidations'),
            @('distinctRejectedEntries', 'distinctRejectedEntries'),
            @('rejectedEntryAttempts', 'rejectedEntryAttempts'),
            @('skippedFirstEntryQuotes', 'skippedFirstEntryQuotes'))) {
        $left = Get-Property $manifestCounters $pair[0]
        $right = Get-Property $results $pair[1]
        if ($null -eq $left -or $null -eq $right) {
            Add-Failure "manifest.counters.$($pair[0]) or results.$($pair[1]) is missing"
            continue
        }
        Test-Check ([decimal]$left -eq [decimal]$right) `
            "manifest.counters.$($pair[0]) ($left) does not match results.$($pair[1]) ($right)"
    }

    # Manifest file identities and payload fingerprint.
    $fileRows = @(Get-Property $manifest 'files')
    Test-Check ($fileRows.Count -ge 2) "the manifest lists fewer than two payload files"
    $fingerprint = New-Object System.Text.StringBuilder
    foreach ($row in $fileRows) {
        $name = [string](Get-Property $row 'name')
        $path = Join-Path $replayDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Failure "the manifest lists a missing payload file: $name"
            continue
        }
        $hash = Get-Sha256 $path
        $bytes = (Get-Item -LiteralPath $path).Length
        $lines = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)).Count
        if (-not $name.EndsWith('.jsonl')) { $lines = 0 }
        Test-Check ($hash -eq ([string](Get-Property $row 'sha256')).ToLowerInvariant()) "payload SHA-256 mismatch for $name"
        Test-Check ([long]$bytes -eq [long](Get-Property $row 'bytes')) "payload byte size mismatch for $name"
        if ($name.EndsWith('.jsonl')) {
            Test-Check ([int]$lines -eq [int](Get-Property $row 'lines')) "payload line count mismatch for $name"
        }
        [void]$fingerprint.Append($name).Append("`n").Append($hash).Append("`n").Append($bytes).Append("`n")
    }
    Test-Check ((Get-Sha256OfText $fingerprint.ToString()) -eq ([string](Get-Property $manifest 'packageSha256')).ToLowerInvariant()) `
        "the package fingerprint does not recompute from the payload files"

    # Events. The run-end entry_rejection_summary recaps carry historical first/last times and are
    # not part of the live event clock, so they are validated separately and excluded from the
    # monotonic sequence.
    $events = @(Read-JsonLines $eventsPath)
    Test-Check ($events.Count -gt 0) "events.jsonl is empty"
    $eventCounts = @{}
    $significantIds = New-Object System.Collections.Generic.List[long]
    $previousEventTime = $null
    for ($i = 0; $i -lt $events.Count; $i++) {
        $event = $events[$i]
        $id = Get-Property $event 'id'
        $type = Get-Property $event 'type'
        Test-Check ([long]$id -eq ($i + 1)) "event $i has a non-monotonic id '$id'"
        if ([string]::IsNullOrWhiteSpace([string]$type)) { Add-Failure "event $($i + 1) has no type"; continue }
        if ($eventCounts.ContainsKey([string]$type)) { $eventCounts[[string]$type] = $eventCounts[[string]$type] + 1 }
        else { $eventCounts[[string]$type] = 1 }
        if ([string]$type -eq 'entry_rejection_summary') {
            foreach ($field in @('firstTime', 'lastTime')) {
                try { [void](Convert-UtcTime (Get-Property $event $field) "events[$i].$field") }
                catch { Add-Failure $_.Exception.Message }
            }
            continue
        }
        [void]$significantIds.Add([long]$id)
        try {
            $time = Convert-UtcTime (Get-Property $event 'time') "events[$i].time"
            if ($null -ne $previousEventTime -and $time -lt $previousEventTime) {
                Add-Failure "event $($i + 1) goes backwards in time"
            }
            $previousEventTime = $time
        }
        catch { Add-Failure $_.Exception.Message }
    }
    Test-Check ((Get-Property $events[0] 'type') -eq 'run_started') "the first event is not run_started"
    Test-Check ((Get-Property $events[-1] 'type') -eq 'run_ended') "the last event is not run_ended"
    $manifestEventCounts = Get-Property $manifest 'eventCounts'
    foreach ($property in $manifestEventCounts.PSObject.Properties) {
        $expected = [int]$property.Value
        $actual = 0
        if ($eventCounts.ContainsKey($property.Name)) { $actual = $eventCounts[$property.Name] }
        Test-Check ($actual -eq $expected) "manifest event count for '$($property.Name)' is $expected but the event stream has $actual"
    }
    foreach ($type in $eventCounts.Keys) {
        if ($null -eq (Get-Property $manifestEventCounts $type)) {
            Add-Failure "the event stream has a '$type' event the manifest does not count"
        }
    }

    # Event counts against the authoritative result counters.
    $countOf = {
        param($name)
        if ($eventCounts.ContainsKey($name)) { return [int]$eventCounts[$name] }
        return 0
    }
    $anchors = & $countOf 'basket_anchored'
    $expectedAnchors = [int](Get-Property $results 'basketsClosed') + [int](Get-Property $results 'basketsLiquidated') + $(if ($null -ne (Get-Property $results 'openBasket')) { 1 } else { 0 })
    Test-Check ($anchors -eq $expectedAnchors) "basket_anchored count $anchors does not match the closed/liquidated/open baskets $expectedAnchors"
    Test-Check ((& $countOf 'entry_executed') -eq [int](Get-Property $results 'legsOpened')) "entry_executed count does not match results.legsOpened"
    Test-Check ((& $countOf 'strategy_exit') -eq [int](Get-Property $results 'basketsClosed')) "strategy_exit count does not match results.basketsClosed"
    Test-Check ((& $countOf 'basket_liquidated') -eq [int](Get-Property $results 'basketsLiquidated')) "basket_liquidated count does not match results.basketsLiquidated"
    Test-Check ((& $countOf 'forced_liquidation') -eq [int](Get-Property $results 'forcedLiquidations')) "forced_liquidation count does not match results.forcedLiquidations"
    Test-Check ((& $countOf 'entry_rejected') -eq [int](Get-Property $results 'distinctRejectedEntries')) "entry_rejected count does not match results.distinctRejectedEntries"

    $margin = Get-Property $results 'researchMargin'
    if ($null -ne $margin) {
        $episodes = @(Get-Property $margin 'StopOutEpisodes')
        Test-Check ((& $countOf 'stop_out_triggered') -eq $episodes.Count) "stop_out_triggered count does not match the recorded Stop Out episodes"
        $enters = & $countOf 'margin_call_entered'
        $leaves = & $countOf 'margin_call_left'
        Test-Check ($enters -eq [int](Get-Property $margin 'MarginCallEpisodes')) "margin_call_entered count $enters does not match MarginCallEpisodes"
        $expectedLeaves = $enters - $(if ([bool](Get-Property $margin 'MarginCallActive')) { 1 } else { 0 })
        Test-Check ($leaves -eq $expectedLeaves) "margin_call_left count $leaves does not match the entered/active state ($expectedLeaves)"
    }
    $runEnded = $events[-1]
    Test-Check ($null -ne (Get-Property $runEnded 'completed')) "run_ended has no completed flag"

    # Event-level exact decimals: a B1-style regression must not be able to hide outside the
    # telemetry stream. Every event type's decimal identity is written as a JSON string.
    $eventDecimalFields = @{
        'basket_anchored'     = @('bid', 'ask', 'anchor', 'step', 'upper', 'lower', 'lowerTarget', 'upperTarget')
        'entry_executed'      = @('decisionBid', 'decisionAsk', 'placedLot', 'fillPrice', 'normalizedRequiredLot')
        'trailing_activated'  = @('bid', 'ask', 'profit', 'activationThreshold')
        'strategy_exit'       = @('bid', 'ask', 'anchor', 'buyLots', 'sellLots', 'grossLots', 'netLots', 'rawProfit', 'exitProfit', 'threshold', 'buyClosePrice', 'sellClosePrice', 'commission', 'realizedProfit', 'liquidatedRealizedProfit')
        'basket_liquidated'   = @('bid', 'ask', 'anchor', 'buyLots', 'sellLots', 'grossLots', 'netLots', 'realizedProfit', 'liquidatedRealizedProfit')
        'forced_liquidation'  = @('closePrice', 'realizedProfit', 'triggerBid', 'triggerAsk', 'placedLot', 'entryPrice', 'beforeBalance', 'beforeFloatingProfit', 'beforeEquity', 'beforeUsedMargin', 'afterBalance', 'afterFloatingProfit', 'afterEquity', 'afterUsedMargin')
        'stop_out_triggered'  = @('bid', 'ask', 'balance', 'floatingProfit', 'equity', 'usedMargin', 'freeMargin')
        'margin_call_entered' = @('bid', 'ask', 'balance', 'equity', 'usedMargin')
        'margin_call_left'    = @('bid', 'ask', 'balance', 'equity', 'usedMargin')
    }
    foreach ($event in $events) {
        $type = [string](Get-Property $event 'type')
        if (-not $eventDecimalFields.ContainsKey($type)) { continue }
        foreach ($field in $eventDecimalFields[$type]) {
            Assert-ExactString $event $field "event[$type]" $true
        }
    }

    # run_ended must carry the same outcome counters as the authoritative result.
    foreach ($name in @('quoteTicksProcessed', 'quoteOnlyQuotes', 'strategyEligibleQuotes', 'legsOpened',
            'basketsClosed', 'basketsLiquidated', 'forcedLiquidations', 'distinctRejectedEntries',
            'rejectedEntryAttempts', 'skippedFirstEntryQuotes')) {
        $left = Get-Property $runEnded $name
        $right = Get-Property $results $name
        if ($null -eq $left -or $null -eq $right) { Add-Failure "run_ended.$name or results.$name is missing"; continue }
        Test-Check ([decimal]$left -eq [decimal]$right) "run_ended.$name ($left) does not match results.$name ($right)"
    }
    $runEndedRealized = Get-Property $runEnded 'engineRealizedProfit'
    if ($null -eq $runEndedRealized) { Add-Failure "run_ended.engineRealizedProfit is missing" }
    else { Test-Check ([decimal]$runEndedRealized -eq [decimal](Get-Property $results 'realizedProfit')) "run_ended.engineRealizedProfit does not match results.realizedProfit" }

    # Telemetry: event coverage, periodic bound, exact decimal strings, time order.
    $telemetryFiles = @(Get-ChildItem -LiteralPath $replayDirectory -Filter 'telemetry-*.jsonl' | Sort-Object Name)
    Test-Check ($telemetryFiles.Count -ge 1) "no telemetry shard exists"
    $manifestTelemetryNames = @($fileRows | Where-Object { ([string](Get-Property $_ 'name')).StartsWith('telemetry-') } | ForEach-Object { [string](Get-Property $_ 'name') })
    $diskTelemetryNames = @($telemetryFiles | ForEach-Object { $_.Name })
    Test-Check (($diskTelemetryNames -join ',') -eq ($manifestTelemetryNames -join ',')) `
        "the on-disk telemetry shards do not match the manifest file list"
    $snapshotIds = New-Object System.Collections.Generic.HashSet[long]
    $periodic = 0
    $eventSnapshots = 0
    $previousTelemetryTime = $null
    foreach ($file in $telemetryFiles) {
        foreach ($row in @(Read-JsonLines $file.FullName)) {
            $kind = [string](Get-Property $row 'kind')
            if ($kind -ne 'event' -and $kind -ne 'periodic') { Add-Failure "unknown telemetry kind '$kind'"; continue }
            foreach ($field in $requiredDecimalFields) { Assert-ExactString $row $field "telemetry[$($file.Name)] kind=$kind" $true }
            foreach ($field in $nullableDecimalFields) { Assert-ExactString $row $field "telemetry[$($file.Name)] kind=$kind" $false }
            try {
                $time = Convert-UtcTime (Get-Property $row 'time') "telemetry.time"
                if ($null -ne $previousTelemetryTime -and $time -lt $previousTelemetryTime) {
                    Add-Failure "telemetry goes backwards in time at $($time.ToString('o'))"
                }
                $previousTelemetryTime = $time
            }
            catch { Add-Failure $_.Exception.Message }
            if ($kind -eq 'periodic') {
                $periodic++
                if ([int](Get-Property $row 'openPositions') -le 0) {
                    Add-Failure "a periodic telemetry sample was taken with no open position"
                }
                if ($null -ne (Get-Property $row 'eventId')) {
                    Add-Failure "a periodic telemetry sample carries an eventId"
                }
            }
            else {
                $eventSnapshots++
                $eventId = Get-Property $row 'eventId'
                if ($null -eq $eventId) { Add-Failure "an event telemetry snapshot has no eventId"; continue }
                [void]$snapshotIds.Add([long]$eventId)
            }
        }
    }
    [int]$snapshotEvents = 0
    foreach ($key in $eventCounts.Keys) {
        if ($key -eq 'entry_rejection_summary') { continue }
        $snapshotEvents += [int]$eventCounts[$key]
    }
    Test-Check ($eventSnapshots -eq $snapshotEvents) "event telemetry snapshots ($eventSnapshots) do not match the significant events ($snapshotEvents)"
    Test-Check ($snapshotIds.Count -eq $eventSnapshots) "duplicate eventId telemetry snapshots"
    $sortedSnapshotIds = @($snapshotIds | Sort-Object)
    $sortedSignificantIds = @($significantIds | Sort-Object)
    Test-Check (($sortedSnapshotIds -join ',') -eq ($sortedSignificantIds -join ',')) `
        "the telemetry event snapshots are not exactly the significant event ids"
    $manifestTelemetry = Get-Property $manifest 'telemetryCounts'
    Test-Check ((Get-Property $manifestTelemetry 'event') -eq $eventSnapshots) "manifest telemetry event count does not match the telemetry file"
    Test-Check ((Get-Property $manifestTelemetry 'periodic') -eq $periodic) "manifest telemetry periodic count does not match the telemetry file"

    $summary = [ordered]@{
        contract = 'marketlab-single-anchor-replay-package-verification-v1'
        runDirectory = $run
        pass = ($failures.Count -eq 0)
        checks = $checks
        failures = @($failures)
        resultsSha256 = $resultsSha256
        expectedResultsSha256 = if ($ExpectedResultsSha256) { $ExpectedResultsSha256.ToLowerInvariant() } else { $null }
        resultsBoundToPhaseD = if ($ExpectedResultsSha256) { $resultsSha256 -eq $ExpectedResultsSha256.ToLowerInvariant() } else { $null }
        packageSha256 = [string](Get-Property $manifest 'packageSha256')
        eventCount = $events.Count
        eventTypes = $eventCounts
        telemetryEventSnapshots = $eventSnapshots
        telemetryPeriodicSamples = $periodic
        telemetryShards = @($telemetryFiles | ForEach-Object { $_.Name })
        packageFiles = @($fileRows | ForEach-Object { [ordered]@{ name = (Get-Property $_ 'name'); sha256 = (Get-Property $_ 'sha256'); bytes = (Get-Property $_ 'bytes') } })
    }
    $json = ($summary | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    if ($failures.Count -eq 0) {
        Write-Output "PASS: replay package verified ($checks checks); results $resultsSha256; package $($summary.packageSha256); $($events.Count) events; $eventSnapshots event snapshots; $periodic periodic samples."
        exit 0
    }
    Write-Output "FAIL: replay package verification found $($failures.Count) problem(s) in $checks checks:"
    foreach ($failure in $failures) { Write-Output "  - $failure" }
    exit 1
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
