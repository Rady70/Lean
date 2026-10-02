#requires -Version 5.1
<#
.SYNOPSIS
Mutation test for MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1, the Phase E replay
package verifier.

.DESCRIPTION
Builds a minimal but complete synthetic SingleAnchor replay package (events.jsonl,
telemetry-2019.jsonl, manifest.json) next to a synthetic storage\single-anchor\results.json with
three baskets: a trailing basket, a stop-out/margin-call basket and a hard-BE basket whose first
tail attempt is rejected and a later attempt of the same trade fills. It asserts that the
strengthened verifier returns PASS on it, then applies each payload mutation in a copy of the tree:

  * entry_executed tradeNumber / fillPrice / snapshot quoteSequence / post-entry inventory
  * forced_liquidation ordinal / closePrice / commission / snapshot time+trigger quote /
    event afterBalance
  * stop_out_triggered time                              (payload parity E)
  * swap the two same-quote forced liquidations          (payload parity D order)
  * manifest.modelRevision / payload sha256 / outcome / numeric parameter representation
  * delete one event / one telemetry snapshot            (coverage)
  * extra periodic row inside the 300-second interval    (periodic bound)
  * hard-BE activation snapshot replaced by the following entry snapshot (derived pre-attempt state)
  * hard-BE activation moved after its enabling attempt  (same-timestamp lifecycle order)
  * hard-BE activation timed at the later fill           (earliest-attempt selection)
  * trailing_activated threshold / snapshot quote / duplicate activation (lifecycle + threshold)
  * margin_call_entered balance-only change, moved after the Stop Out, and a consistent
    event+snapshot impossible state                        (parity, lifecycle, margin condition)
  * entry_rejected / forced_liquidation / basket_liquidated / manifest parameter decimals changed
    from exact strings to JSON numbers                     (exact-string serialization)
  * spurious first_entry_skipped / extra run_started / unknown event type (stream contract)
  * swapped rejection recaps                              (authoritative rejection order)

After each mutation the package's own derived integrity (the changed payload's sha256/bytes/lines,
the event counts, the telemetry counts and the package fingerprint) is recomputed automatically,
so a failure can only come from the mutation the case is about. Every case must make the verifier
return a non-zero exit code.

The test also builds two positive failed-run fixtures (a forward-time fault whose quote is later
than the last accepted quote and an out-of-order fault whose quote precedes it) and asserts the
verifier PASSES them under the documented max(lastProcessedQuote, failureQuote) rule, then rejects
a tampered failure identity, a run-end time that ignores the rule and a numeric failureBid.

The test is self-contained, uses only Windows PowerShell 5.1 syntax and invokes the verifier with
the current machine's pwsh (falling back to Windows PowerShell). Exit 0 only when the base package
passes, both positive fixtures verify and every mutation is detected.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:caseFailures = New-Object System.Collections.Generic.List[string]
$script:lastVerifierOutput = ''

# ---- Small helpers ---------------------------------------------------------

function New-UtcTime([string]$text) {
    return [datetime]::ParseExact(
        $text,
        "yyyy-MM-dd'T'HH:mm:ss.fff",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Format-UtcZ([datetime]$time) {
    return $time.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Decimal([object]$value) {
    if ($null -eq $value) { return $null }
    return ([decimal]$value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

# ConvertFrom-Json turns package timestamp strings into [datetime]; ConvertTo-Json would then
# write them back without milliseconds. This walker restores the canonical UTC text so a repaired
# manifest or result keeps its byte-level timestamp form.
function Convert-DateTimesForJson([object]$value) {
    if ($value -is [datetime]) {
        $time = [datetime]$value
        if ($time.Kind -eq [System.DateTimeKind]::Local) { $time = $time.ToUniversalTime() }
        elseif ($time.Kind -eq [System.DateTimeKind]::Unspecified) { $time = [datetime]::SpecifyKind($time, [System.DateTimeKind]::Utc) }
        return $time.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($value -is [System.Collections.IDictionary]) {
        $dictionary = [ordered]@{}
        foreach ($key in $value.Keys) { $dictionary[$key] = Convert-DateTimesForJson $value[$key] }
        return $dictionary
    }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $object = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) { $object[$property.Name] = Convert-DateTimesForJson $property.Value }
        return $object
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = @()
        foreach ($item in $value) { $items += ,(Convert-DateTimesForJson $item) }
        return ,$items
    }
    return $value
}

function Write-JsonFile([string]$path, [object]$value) {
    $json = (Convert-DateTimesForJson $value) | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Write-JsonLinesFile([string]$path, [object]$rows) {
    $builder = New-Object System.Text.StringBuilder
    foreach ($row in $rows) {
        [void]$builder.Append(($row | ConvertTo-Json -Compress -Depth 30)).Append("`n")
    }
    [System.IO.File]::WriteAllText($path, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function Read-JsonFile([string]$path) {
    return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}

function Read-JsonLinesArray([string]$path) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ($line.Length -eq 0) { continue }
        $rows.Add(($line | ConvertFrom-Json))
    }
    # Return the List as one object (not enumerated) so mutation cases keep a mutable collection.
    return ,$rows
}

function Copy-ObjectWithUpdates([object]$source, [hashtable]$updates) {
    $copy = [ordered]@{}
    foreach ($property in $source.PSObject.Properties) {
        $copy[$property.Name] = $property.Value
    }
    foreach ($key in $updates.Keys) {
        $copy[$key] = $updates[$key]
    }
    return $copy
}

function New-EventWithId([object]$source, [long]$id) {
    $copy = [ordered]@{}
    foreach ($property in $source.PSObject.Properties) {
        if ($property.Name -eq 'id') { continue }
        $copy[$property.Name] = $property.Value
    }
    $copy['id'] = $id
    return $copy
}

# Duplicates the event at a 0-based index immediately after itself, renumbers every event id so
# the id sequence stays 1..N, and duplicates its telemetry snapshot. Because the ids were
# sequential, originals at or after the insertion keep a valid shifted identity.
function Insert-DuplicateEvent([string]$directory, [int]$sourceIndex) {
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $rows = Read-JsonLinesArray $eventsPath
    if ($sourceIndex -lt 0 -or $sourceIndex -ge $rows.Count) { throw "source index $sourceIndex is outside the event stream" }
    $sourceId = $sourceIndex + 1
    $insertIndex = $sourceIndex + 1
    $newId = $insertIndex + 1
    $duplicate = New-EventWithId $rows[$sourceIndex] $newId
    $rows.Insert($insertIndex, $duplicate)
    for ($i = $insertIndex + 1; $i -lt $rows.Count; $i++) { $rows[$i].id = $i + 1 }
    Write-JsonLinesFile $eventsPath $rows

    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    $snapshotCopy = $null
    $snapshotPosition = 0
    for ($i = 0; $i -lt $telemetry.Count; $i++) {
        $row = $telemetry[$i]
        if ([string]$row.kind -ne 'event') { continue }
        if ([long]$row.eventId -eq $sourceId) { $snapshotCopy = $row; $snapshotPosition = $i + 1 }
        elseif ([long]$row.eventId -gt $sourceId) { $row.eventId = [long]$row.eventId + 1 }
    }
    if ($null -eq $snapshotCopy) { throw "the source event has no telemetry snapshot" }
    $newSnapshot = Copy-ObjectWithUpdates $snapshotCopy @{ eventId = $newId }
    $telemetry.Insert($snapshotPosition, $newSnapshot)
    Write-JsonLinesFile $telemetryPath $telemetry
}

# Inserts a synthetic event and its telemetry snapshot at a 0-based index, renumbering ids.
function Insert-EventAndSnapshot(
    [string]$directory, [int]$index, [System.Collections.IDictionary]$payload,
    [object]$snapshotBase, [hashtable]$snapshotOverrides) {
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $rows = Read-JsonLinesArray $eventsPath
    $newId = $index + 1
    $event = [ordered]@{}
    foreach ($key in $payload.Keys) { $event[$key] = $payload[$key] }
    $event['id'] = $newId
    $rows.Insert($index, $event)
    for ($i = $index + 1; $i -lt $rows.Count; $i++) { $rows[$i].id = $i + 1 }
    Write-JsonLinesFile $eventsPath $rows

    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    $overrides = @{}
    foreach ($key in $snapshotOverrides.Keys) { $overrides[$key] = $snapshotOverrides[$key] }
    $overrides['kind'] = 'event'
    $overrides['eventId'] = $newId
    $snapshot = Copy-ObjectWithUpdates $snapshotBase $overrides
    $insertPosition = $telemetry.Count
    for ($i = 0; $i -lt $telemetry.Count; $i++) {
        $row = $telemetry[$i]
        if ([string]$row.kind -ne 'event') { continue }
        if ([long]$row.eventId -ge $newId) { $insertPosition = $i; break }
    }
    for ($i = 0; $i -lt $telemetry.Count; $i++) {
        $row = $telemetry[$i]
        if ([string]$row.kind -eq 'event' -and [long]$row.eventId -ge $newId) { $row.eventId = [long]$row.eventId + 1 }
    }
    $telemetry.Insert($insertPosition, $snapshot)
    Write-JsonLinesFile $telemetryPath $telemetry
}

function Add-SecondsToUtc([object]$value, [double]$seconds) {
    if ($value -is [datetime]) {
        $time = [datetime]$value
        if ($time.Kind -eq [System.DateTimeKind]::Local) { $time = $time.ToUniversalTime() }
        elseif ($time.Kind -eq [System.DateTimeKind]::Unspecified) { $time = [datetime]::SpecifyKind($time, [System.DateTimeKind]::Utc) }
        return $time.AddSeconds($seconds)
    }
    $text = [string]$value
    if ($text.EndsWith('Z')) { $text = $text.Substring(0, $text.Length - 1) }
    return (New-UtcTime $text).AddSeconds($seconds)
}

function Get-ArtifactPath([string]$directory, [string]$name) {
    return (Join-Path (Join-Path (Join-Path $directory 'storage\single-anchor') 'replay') $name)
}

# ---- Package integrity repair ----------------------------------------------

function Repair-PackageIntegrity([string]$directory, [string[]]$dirtyPayloads) {
    $manifestPath = Get-ArtifactPath $directory 'manifest.json'
    $manifest = Read-JsonFile $manifestPath
    foreach ($fileRow in @($manifest.files)) {
        $name = [string]$fileRow.name
        if ($dirtyPayloads -notcontains $name) { continue }
        $path = Get-ArtifactPath $directory $name
        $fileRow.sha256 = Get-FileSha256 $path
        $fileRow.bytes = (Get-Item -LiteralPath $path).Length
        if ($name.EndsWith('.jsonl')) {
            $fileRow.lines = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)).Count
        }
    }

    $counts = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines((Get-ArtifactPath $directory 'events.jsonl'), [System.Text.Encoding]::UTF8)) {
        if ($line.Length -eq 0) { continue }
        $type = [string](($line | ConvertFrom-Json).type)
        if ($counts.Contains($type)) { $counts[$type] = [int]$counts[$type] + 1 }
        else { $counts[$type] = 1 }
    }
    $manifest.eventCounts = [pscustomobject]$counts

    $eventSnapshots = 0
    $periodic = 0
    foreach ($fileRow in @($manifest.files)) {
        $name = [string]$fileRow.name
        if (-not $name.StartsWith('telemetry-')) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines((Get-ArtifactPath $directory $name), [System.Text.Encoding]::UTF8)) {
            if ($line.Length -eq 0) { continue }
            if ([string](($line | ConvertFrom-Json).kind) -eq 'periodic') { $periodic++ }
            else { $eventSnapshots++ }
        }
    }
    $manifest.telemetryCounts.event = $eventSnapshots
    $manifest.telemetryCounts.periodic = $periodic

    $fingerprint = New-Object System.Text.StringBuilder
    foreach ($fileRow in @($manifest.files)) {
        [void]$fingerprint.Append([string]$fileRow.name).Append("`n").Append([string]$fileRow.sha256).Append("`n").Append([string]$fileRow.bytes).Append("`n")
    }
    $manifest.packageSha256 = Get-TextSha256 $fingerprint.ToString()
    Write-JsonFile $manifestPath $manifest
}

# ---- Synthetic base package -------------------------------------------------

function New-SyntheticResultPackage([string]$directory) {
    $replayDirectory = Join-Path $directory 'storage\single-anchor\replay'
    New-Item -ItemType Directory -Path $replayDirectory -Force | Out-Null

    $modelRevision = 'marketlab-single-anchor-synthetic-v1'
    $stopOutModel = 'BrokerLiquidation'
    $symbol = 'XAUUSD'
    $market = 'dukascopy'
    $startDate = '2019-01-02'
    $endDate = '2019-01-02'

    $runStart = New-UtcTime '2019-01-02T00:00:00.000'
    $anchorOneTime = New-UtcTime '2019-01-02T01:00:00.000'
    $entryOneTime = New-UtcTime '2019-01-02T02:00:00.000'
    $periodicOneTime = $entryOneTime
    $periodicTwoTime = New-UtcTime '2019-01-02T02:05:00.000'
    $exitOneTime = New-UtcTime '2019-01-02T02:10:00.000'
    $anchorTwoTime = New-UtcTime '2019-01-02T02:11:00.000'
    $entryTwoTime = New-UtcTime '2019-01-02T02:12:00.000'
    $entryThreeTime = New-UtcTime '2019-01-02T02:13:00.000'
    $periodicThreeTime = $entryThreeTime
    $trailingOneTime = New-UtcTime '2019-01-02T02:05:00.000'
    $rejectionOneTime = New-UtcTime '2019-01-02T02:06:00.000'
    $anchorFourTime = New-UtcTime '2019-01-02T02:14:00.000'
    $entryFourOneTime = New-UtcTime '2019-01-02T02:14:10.000'
    $entryFourTwoTime = New-UtcTime '2019-01-02T02:14:20.000'
    $entryFourThreeTime = New-UtcTime '2019-01-02T02:14:30.000'
    $entryFourFourTime = New-UtcTime '2019-01-02T02:14:40.000'
    $activationFourTime = New-UtcTime '2019-01-02T02:15:00.000'
    $entryFourFiveTime = New-UtcTime '2019-01-02T02:16:00.000'
    $exitFourTime = New-UtcTime '2019-01-02T02:17:00.000'
    $marginEnterTime = New-UtcTime '2019-01-02T02:22:00.000'
    $marginLeaveTime = New-UtcTime '2019-01-02T02:23:30.000'
    $stopOutTime = New-UtcTime '2019-01-02T02:23:00.000'
    $runEndTime = New-UtcTime '2019-01-02T02:24:00.000'

    $beforeOne = [ordered]@{
        Balance = [decimal]10000.5; FloatingProfit = [decimal]-10.0; Equity = [decimal]9990.5
        UsedMargin = [decimal]200.0; FreeMargin = [decimal]9790.5; MarginLevelPercent = [decimal]4995.25; OpenPositions = 2
    }
    $afterOne = [ordered]@{
        Balance = [decimal]9999.48; FloatingProfit = [decimal]-8.98; Equity = [decimal]9990.5
        UsedMargin = [decimal]100.0; FreeMargin = [decimal]9890.5; MarginLevelPercent = [decimal]9990.5; OpenPositions = 1
    }
    $afterTwo = [ordered]@{
        Balance = [decimal]10003.48; FloatingProfit = [decimal]0.0; Equity = [decimal]10003.48
        UsedMargin = [decimal]0.0; FreeMargin = [decimal]10003.48; MarginLevelPercent = $null; OpenPositions = 0
    }

    # ---- Authoritative structures (results.json) ----
    $anchorOne = [ordered]@{
        Basket = 1; QuoteSequence = 100; Time = Format-UtcZ $anchorOneTime
        Bid = [decimal]1000.0; Ask = [decimal]1000.2; Anchor = [decimal]1000.1
        Step = [decimal]2.5; Upper = [decimal]1002.6; Lower = [decimal]997.6
        LowerTarget = [decimal]990.0; UpperTarget = [decimal]1010.0
    }
    $legOne = [ordered]@{
        Basket = 1; TradeNumber = 1; QuoteSequence = 101; Time = Format-UtcZ $entryOneTime
        DecisionBid = [decimal]1000.0; DecisionAsk = [decimal]1000.2; Side = 'Buy'
        PlacedLot = [decimal]0.1; FillPrice = [decimal]1000.2; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.1; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $rejectionOne = [ordered]@{
        Basket = 1; FirstQuoteSequence = 103; FirstTime = Format-UtcZ $rejectionOneTime
        FirstBid = [decimal]1004.0; FirstAsk = [decimal]1004.2; TradeNumber = 2; Side = 'Sell'
        Reason = 'VolumeExceedsMaximum'; RawRequestedLots = [decimal]0.2; ExactRequiredLots = $null
        NormalizedRequiredLots = [decimal]0.2; PlacedLots = $null; NormalizedLot = $null; Outcome = $null
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
        AccountUsedMargin = [decimal]100.0; AccountFreeMargin = [decimal]9900.0; AccountMarginLevelPercent = [decimal]9990.5
        ProjectedUsedMargin = $null; ProjectedFreeMargin = $null
        Message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        Attempts = 1; LastQuoteSequence = 103; LastTime = Format-UtcZ $rejectionOneTime
        LastBid = [decimal]1004.0; LastAsk = [decimal]1004.2
        ParityAlgorithm = 'synthetic parity algorithm'; ParityHash = 'fedcba9876543210'
        MinNormalizedRequiredLots = [decimal]0.2; MaxNormalizedRequiredLots = [decimal]0.2
        MinProjectedFreeMargin = $null; MaxProjectedFreeMargin = $null
    }
    $basketOne = [ordered]@{
        Sequence = 1; AnchorEvent = $anchorOne; CreatedTime = Format-UtcZ $anchorOneTime; ClosedTime = Format-UtcZ $exitOneTime
        CloseQuoteSequence = 102; CloseBid = [decimal]1005.0; CloseAsk = [decimal]1005.2; Anchor = [decimal]1000.1
        Reason = 'Trailing'; Legs = 1; BuyLots = [decimal]0.1; SellLots = [decimal]0.0
        GrossLots = [decimal]0.1; NetLots = [decimal]0.1; HardBreakevenModeActive = $false
        RawProfit = [decimal]0.5; ExitProfit = [decimal]0.5; Threshold = [decimal]0.4
        BuyClosePrice = [decimal]1005.0; SellClosePrice = [decimal]1005.2; Commission = [decimal]0.0
        RealizedProfit = [decimal]0.5; LiquidatedRealizedProfit = [decimal]0.0; LiquidatedPositions = 0
        HistoricalEntries = 1; LiquidationTrace = @(); LegTrace = @($legOne); RejectionTrace = @($rejectionOne)
        SkippedFirstEntryTrace = $null
    }

    $anchorTwo = [ordered]@{
        Basket = 2; QuoteSequence = 300; Time = Format-UtcZ $anchorTwoTime
        Bid = [decimal]1010.0; Ask = [decimal]1010.4; Anchor = [decimal]1010.2
        Step = [decimal]4.0; Upper = [decimal]1014.2; Lower = [decimal]1006.2
        LowerTarget = [decimal]1000.0; UpperTarget = [decimal]1020.0
    }
    $liquidationLegOne = [ordered]@{
        Basket = 2; TradeNumber = 1; Side = 'Buy'; PlacedLot = [decimal]0.1; EntryPrice = [decimal]1000.2
        EntryTime = Format-UtcZ $entryTwoTime; Regime = 'Arithmetic'; RawRequestedLot = [decimal]0.1
        ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        LiquidationTime = Format-UtcZ $stopOutTime; TriggerTime = Format-UtcZ $stopOutTime
        TriggerQuoteSequence = 400; TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4
        ClosePrice = [decimal]990.0; Commission = [decimal]0.0; RealizedProfit = [decimal]-1.02
        Reason = 'MarginLevel'; Ordinal = 1
    }
    $liquidationLegTwo = [ordered]@{
        Basket = 2; TradeNumber = 2; Side = 'Sell'; PlacedLot = [decimal]0.2; EntryPrice = [decimal]1010.4
        EntryTime = Format-UtcZ $entryThreeTime; Regime = 'Arithmetic'; RawRequestedLot = [decimal]0.2
        ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.2
        LiquidationTime = Format-UtcZ $stopOutTime; TriggerTime = Format-UtcZ $stopOutTime
        TriggerQuoteSequence = 400; TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4
        ClosePrice = [decimal]990.4; Commission = [decimal]0.0; RealizedProfit = [decimal]4.0
        Reason = 'MarginLevel'; Ordinal = 2
    }
    $basketTwo = [ordered]@{
        Sequence = 2; AnchorEvent = $anchorTwo; CreatedTime = Format-UtcZ $anchorTwoTime; ClosedTime = Format-UtcZ $stopOutTime
        CloseQuoteSequence = 400; CloseBid = [decimal]990.0; CloseAsk = [decimal]990.4; Anchor = [decimal]1010.2
        Reason = 'BrokerLiquidation'; Legs = 0; BuyLots = [decimal]0.0; SellLots = [decimal]0.0
        GrossLots = [decimal]0.0; NetLots = [decimal]0.0; HardBreakevenModeActive = $false
        RawProfit = [decimal]0.0; ExitProfit = [decimal]0.0; Threshold = [decimal]0.0
        BuyClosePrice = [decimal]990.0; SellClosePrice = [decimal]990.4; Commission = [decimal]0.0
        RealizedProfit = [decimal]2.98; LiquidatedRealizedProfit = [decimal]2.98; LiquidatedPositions = 2
        HistoricalEntries = 2; LiquidationTrace = @($liquidationLegOne, $liquidationLegTwo); LegTrace = @()
        RejectionTrace = @(); SkippedFirstEntryTrace = $null
    }

    # Basket 3: the hard-BE reject-then-later-fill case. Its first tail attempt (trade 5) is
    # rejected, which is where hard-BE mode activates; a later attempt of the same trade fills.
    $anchorFour = [ordered]@{
        Basket = 3; QuoteSequence = 500; Time = Format-UtcZ $anchorFourTime
        Bid = [decimal]1010.0; Ask = [decimal]1010.4; Anchor = [decimal]1010.2
        Step = [decimal]2.5; Upper = [decimal]1012.6; Lower = [decimal]1007.6
        LowerTarget = [decimal]1000.0; UpperTarget = [decimal]1020.0
    }
    $legFourOne = [ordered]@{
        Basket = 3; TradeNumber = 1; QuoteSequence = 501; Time = Format-UtcZ $entryFourOneTime
        DecisionBid = [decimal]1010.0; DecisionAsk = [decimal]1010.4; Side = 'Buy'
        PlacedLot = [decimal]0.1; FillPrice = [decimal]1010.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.1; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourTwo = [ordered]@{
        Basket = 3; TradeNumber = 2; QuoteSequence = 502; Time = Format-UtcZ $entryFourTwoTime
        DecisionBid = [decimal]1010.0; DecisionAsk = [decimal]1010.4; Side = 'Buy'
        PlacedLot = [decimal]0.2; FillPrice = [decimal]1010.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.2; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.2
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourThree = [ordered]@{
        Basket = 3; TradeNumber = 3; QuoteSequence = 503; Time = Format-UtcZ $entryFourThreeTime
        DecisionBid = [decimal]1010.0; DecisionAsk = [decimal]1010.4; Side = 'Buy'
        PlacedLot = [decimal]0.3; FillPrice = [decimal]1010.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.3; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.3
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourFour = [ordered]@{
        Basket = 3; TradeNumber = 4; QuoteSequence = 504; Time = Format-UtcZ $entryFourFourTime
        DecisionBid = [decimal]1010.0; DecisionAsk = [decimal]1010.4; Side = 'Buy'
        PlacedLot = [decimal]0.4; FillPrice = [decimal]1010.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.4; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.4
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourFive = [ordered]@{
        Basket = 3; TradeNumber = 5; QuoteSequence = 506; Time = Format-UtcZ $entryFourFiveTime
        DecisionBid = [decimal]1013.0; DecisionAsk = [decimal]1013.4; Side = 'Buy'
        PlacedLot = [decimal]0.5; FillPrice = [decimal]1013.4; Regime = 'HardBreakeven'
        RawRequestedLot = [decimal]0.5; ExactRequiredLot = [decimal]0.5; NormalizedRequiredLot = [decimal]0.5
        HardBreakevenTarget = [decimal]1000.0; TargetSpread = [decimal]0.5; TargetBid = [decimal]1000.0
        TargetAsk = [decimal]1000.5; ExistingProfitAtTarget = [decimal]10.0
        MarginalProfitPerLot = [decimal]5.0; ProjectedProfitAfter = [decimal]15.0
    }
    $rejectionFour = [ordered]@{
        Basket = 3; FirstQuoteSequence = 505; FirstTime = Format-UtcZ $activationFourTime
        FirstBid = [decimal]1012.0; FirstAsk = [decimal]1012.4; TradeNumber = 5; Side = 'Buy'
        Reason = 'InsufficientMargin'; RawRequestedLots = [decimal]0.5; ExactRequiredLots = $null
        NormalizedRequiredLots = [decimal]0.5; PlacedLots = $null; NormalizedLot = $null; Outcome = $null
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
        AccountUsedMargin = [decimal]0.0; AccountFreeMargin = [decimal]-50.0; AccountMarginLevelPercent = $null
        ProjectedUsedMargin = [decimal]100.0; ProjectedFreeMargin = [decimal]-150.0
        Message = 'Synthetic tail attempt rejected; hard-BE mode stays active and the trade may be retried.'
        Attempts = 2; LastQuoteSequence = 506; LastTime = Format-UtcZ $entryFourFiveTime
        LastBid = [decimal]1013.0; LastAsk = [decimal]1013.4
        ParityAlgorithm = 'synthetic parity algorithm'; ParityHash = '0123456789abcdef'
        MinNormalizedRequiredLots = [decimal]0.5; MaxNormalizedRequiredLots = [decimal]0.5
        MinProjectedFreeMargin = [decimal]-150.0; MaxProjectedFreeMargin = [decimal]-150.0
    }
    $basketFour = [ordered]@{
        Sequence = 3; AnchorEvent = $anchorFour; CreatedTime = Format-UtcZ $anchorFourTime; ClosedTime = Format-UtcZ $exitFourTime
        CloseQuoteSequence = 507; CloseBid = [decimal]1015.0; CloseAsk = [decimal]1015.4; Anchor = [decimal]1010.2
        Reason = 'Escape'; Legs = 5; BuyLots = [decimal]1.5; SellLots = [decimal]0.0
        GrossLots = [decimal]1.5; NetLots = [decimal]1.5; HardBreakevenModeActive = $true
        RawProfit = [decimal]5.0; ExitProfit = [decimal]5.0; Threshold = [decimal]4.0
        BuyClosePrice = [decimal]1015.0; SellClosePrice = [decimal]1015.4; Commission = [decimal]0.0
        RealizedProfit = [decimal]5.0; LiquidatedRealizedProfit = [decimal]0.0; LiquidatedPositions = 0
        HistoricalEntries = 5; LiquidationTrace = @()
        LegTrace = @($legFourOne, $legFourTwo, $legFourThree, $legFourFour, $legFourFive)
        RejectionTrace = @($rejectionFour); SkippedFirstEntryTrace = $null
    }

    $stopOutEpisode = [ordered]@{
        Basket = 2; Reason = 'MarginLevel'; TriggerQuoteSequence = 400; TriggerTime = Format-UtcZ $stopOutTime
        TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4; AtTrigger = $beforeOne
        Liquidations = @(
            [ordered]@{ Leg = $liquidationLegOne; Before = $beforeOne; After = $afterOne },
            [ordered]@{ Leg = $liquidationLegTwo; Before = $afterOne; After = $afterTwo }
        )
        Outcome = 'MarginRestored'; ResolvedTime = Format-UtcZ $stopOutTime; AfterLiquidation = $afterTwo
    }

    $parameters = [ordered]@{
        StepPercent = [decimal]0.25; BaseLot = [decimal]0.1; NormalTradeCount = 4; HardBreakevenCeilingPercent = [decimal]4.478
        EscapeEnabled = $true; EscapeProfitUnits = [decimal]0.05; EscapeMinimumOpenPositions = 2; FixedTakeProfitUnits = [decimal]0.0
        TrailingEnabled = $true; TrailingActivationUnits = [decimal]0.5; TrailingDropUnits = [decimal]0.25; CommissionBuffer = [decimal]0.0
        PointValuePerLot = [decimal]100.0; VolumeStep = [decimal]0.01; MinimumVolume = [decimal]0.01; MaximumVolume = [decimal]50.0
        CommissionPerLot = [decimal]0.0; Slippage = [decimal]0.0; ProjectedSpread = [decimal]0.5
        BuySwapPerLotPerDay = [decimal]0.0; SellSwapPerLotPerDay = [decimal]0.0
    }
    $marginParameters = [ordered]@{
        ContractSize = [decimal]100.0; Leverage = [decimal]500.0
        MarginCallLevelPercent = [decimal]50.0; StopOutLevelPercent = [decimal]20.0
    }
    $sessionMap = [ordered]@{
        Map = 'marketlab-sessions/xauusd-sessions.json'
        Sha256 = '33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949'
        Symbol = 'XAUUSD'; JunctionTimeZone = 'America/New_York'; Sessions = 1
        FirstSessionStartUtc = Format-UtcZ $anchorOneTime; FinalSessionEndObservable = $false
        SourceFileCount = 1; SourceRowCount = 5
        SourceSha256Aggregate = 'eafd8709f750f439af1faad6cdac79acbf8b20cd5a577253a145df788b73f885'
        SourceFirstQuoteUtc = Format-UtcZ $anchorOneTime; SourceCoverageEndUtc = Format-UtcZ $runEndTime
    }
    $delivered = [ordered]@{
        quote_count = 3
        semantic_digest = 'sha256:4b856a6aa4256251ad3232565dc2a42d1bdc64effb31e9a59bff61314783f85b'
        first_canonical_utc = Format-UtcZ $entryOneTime
        last_canonical_utc = Format-UtcZ $runEndTime
    }
    $researchAccount = [ordered]@{
        InitialBalance = [decimal]10000.0; Balance = [decimal]10003.48; Equity = [decimal]10003.48
        FloatingProfit = [decimal]0.0; FloatingObservable = $true; FloatingObservationsSkipped = 0
        RealizedProfit = [decimal]3.48; PeakBalance = [decimal]10003.48; MaxBalanceDrawdown = [decimal]1.02
        PeakEquity = [decimal]10003.48; MaxEquityDrawdown = [decimal]10.0; CurrentOpenPositions = 0
        MaxOpenPositions = 2; CurrentGrossLots = [decimal]0.0; MaxGrossLots = [decimal]0.3
        CurrentAbsoluteNetLots = [decimal]0.0; MaxAbsoluteNetLots = [decimal]0.1
        MaxExecutableFloatingProfit = [decimal]10.0; MaxExecutableFloatingLoss = [decimal]-10.0
        ClosedBasketsObserved = 2
    }
    $researchMargin = [ordered]@{
        Parameters = $marginParameters; CurrentUsedMargin = [decimal]0.0; CurrentFreeMargin = [decimal]10003.48
        CurrentMarginLevelPercent = $null; MaxUsedMargin = [decimal]200.0; MinFreeMargin = [decimal]9790.5
        MinMarginLevelPercent = [decimal]4995.25; MarginCallActive = $false; MarginCallObservations = 2
        MarginCallEpisodes = 1; MarginCallBlockedAttempts = 0; MarginCallBlockedEpisodes = 0
        InsufficientMarginAttempts = 1; InsufficientMarginEpisodes = 1; ForcedLiquidations = 2
        StopOutEpisodes = @($stopOutEpisode)
    }
    $results = [ordered]@{
        completed = $true; modelRevision = $modelRevision; stopOutModel = $stopOutModel
        algorithmTimeZone = 'UTC'; startUtc = Format-UtcZ $runStart; endUtc = Format-UtcZ $runEndTime
        delivered = $delivered; failure = $null; symbol = $symbol; market = $market; quoteTimeZone = 'UTC'
        startDate = $startDate; endDate = $endDate; parameters = $parameters
        quoteTicksProcessed = 5; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; sessionMap = $sessionMap
        nonQuoteTicksUnused = 0
        lastProcessedQuote = [ordered]@{
            Time = Format-UtcZ $runEndTime; Bid = [decimal]990.0; Ask = [decimal]990.4
            Mid = [decimal]990.2; Spread = [decimal]0.4; IsValid = $true
        }
        legsOpened = 8; skippedFirstEntryQuotes = 0; distinctRejectedEntries = 2; rejectedEntryAttempts = 3
        basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; realizedProfit = [decimal]3.48
        researchAccount = $researchAccount; researchMargin = $researchMargin
        closedBaskets = @($basketOne, $basketTwo, $basketFour)
    }

    # ---- Event stream ----
    $events = New-Object System.Collections.Generic.List[object]
    Add-SyntheticEvent $events ([ordered]@{
            type = 'run_started'; time = Format-UtcZ $runStart; modelRevision = $modelRevision
            stopOutModel = $stopOutModel; symbol = $symbol; market = $market; startDate = $startDate
            endDate = $endDate; quoteTimeZone = 'UTC'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_anchored'; basket = 1; quoteSequence = 100; time = Format-UtcZ $anchorOneTime
            bid = Format-Decimal 1000.0; ask = Format-Decimal 1000.2; anchor = Format-Decimal 1000.1
            step = Format-Decimal 2.5; upper = Format-Decimal 1002.6; lower = Format-Decimal 997.6
            lowerTarget = Format-Decimal 990.0; upperTarget = Format-Decimal 1010.0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 1; tradeNumber = 1; quoteSequence = 101; time = Format-UtcZ $entryOneTime
            decisionBid = Format-Decimal 1000.0; decisionAsk = Format-Decimal 1000.2; side = 'Buy'
            placedLot = Format-Decimal 0.1; fillPrice = Format-Decimal 1000.2; regime = 'Arithmetic'
            rawRequestedLot = Format-Decimal 0.1; exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.1
            hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
            existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'trailing_activated'; basket = 1; quoteSequence = 110; time = Format-UtcZ $trailingOneTime
            bid = Format-Decimal 1005.0; ask = Format-Decimal 1005.2
            profit = Format-Decimal 12.6; activationThreshold = Format-Decimal 12.5
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejected'; basket = 1; tradeNumber = 2; side = 'Sell'; reason = 'VolumeExceedsMaximum'
            quoteSequence = 103; time = Format-UtcZ $rejectionOneTime
            bid = Format-Decimal 1004.0; ask = Format-Decimal 1004.2
            rawRequestedLots = Format-Decimal 0.2; exactRequiredLots = $null; normalizedRequiredLots = Format-Decimal 0.2
            maximumVolume = Format-Decimal 50.0; hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null
            targetAsk = $null; existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null; accountUsedMargin = Format-Decimal 100.0; accountFreeMargin = Format-Decimal 9900.0
            accountMarginLevelPercent = Format-Decimal 9990.5; projectedUsedMargin = $null; projectedFreeMargin = $null
            message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'strategy_exit'; basket = 1; reason = 'Trailing'; quoteSequence = 102; time = Format-UtcZ $exitOneTime
            bid = Format-Decimal 1005.0; ask = Format-Decimal 1005.2; anchor = Format-Decimal 1000.1; legs = 1
            buyLots = Format-Decimal 0.1; sellLots = Format-Decimal 0.0; grossLots = Format-Decimal 0.1
            netLots = Format-Decimal 0.1; hardBreakevenModeActive = $false; rawProfit = Format-Decimal 0.5
            exitProfit = Format-Decimal 0.5; threshold = Format-Decimal 0.4; buyClosePrice = Format-Decimal 1005.0
            sellClosePrice = Format-Decimal 1005.2; commission = Format-Decimal 0.0; realizedProfit = Format-Decimal 0.5
            liquidatedRealizedProfit = Format-Decimal 0.0; liquidatedPositions = 0; historicalEntries = 1
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_anchored'; basket = 2; quoteSequence = 300; time = Format-UtcZ $anchorTwoTime
            bid = Format-Decimal 1010.0; ask = Format-Decimal 1010.4; anchor = Format-Decimal 1010.2
            step = Format-Decimal 4.0; upper = Format-Decimal 1014.2; lower = Format-Decimal 1006.2
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 2; tradeNumber = 1; quoteSequence = 301; time = Format-UtcZ $entryTwoTime
            decisionBid = Format-Decimal 1000.0; decisionAsk = Format-Decimal 1000.2; side = 'Buy'
            placedLot = Format-Decimal 0.1; fillPrice = Format-Decimal 1000.2; regime = 'Arithmetic'
            rawRequestedLot = Format-Decimal 0.1; exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.1
            hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
            existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 2; tradeNumber = 2; quoteSequence = 302; time = Format-UtcZ $entryThreeTime
            decisionBid = Format-Decimal 1010.2; decisionAsk = Format-Decimal 1010.4; side = 'Sell'
            placedLot = Format-Decimal 0.2; fillPrice = Format-Decimal 1010.4; regime = 'Arithmetic'
            rawRequestedLot = Format-Decimal 0.2; exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.2
            hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
            existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_anchored'; basket = 3; quoteSequence = 500; time = Format-UtcZ $anchorFourTime
            bid = Format-Decimal 1010.0; ask = Format-Decimal 1010.4; anchor = Format-Decimal 1010.2
            step = Format-Decimal 2.5; upper = Format-Decimal 1012.6; lower = Format-Decimal 1007.6
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    foreach ($leg in @(
            [ordered]@{ tradeNumber = 1; quoteSequence = 501; time = $entryFourOneTime; placedLot = '0.1' },
            [ordered]@{ tradeNumber = 2; quoteSequence = 502; time = $entryFourTwoTime; placedLot = '0.2' },
            [ordered]@{ tradeNumber = 3; quoteSequence = 503; time = $entryFourThreeTime; placedLot = '0.3' },
            [ordered]@{ tradeNumber = 4; quoteSequence = 504; time = $entryFourFourTime; placedLot = '0.4' })) {
        Add-SyntheticEvent $events ([ordered]@{
                type = 'entry_executed'; basket = 3; tradeNumber = $leg.tradeNumber; quoteSequence = $leg.quoteSequence
                time = Format-UtcZ $leg.time
                decisionBid = Format-Decimal 1010.0; decisionAsk = Format-Decimal 1010.4; side = 'Buy'
                placedLot = $leg.placedLot; fillPrice = Format-Decimal 1010.4; regime = 'Arithmetic'
                rawRequestedLot = $leg.placedLot; exactRequiredLot = $null; normalizedRequiredLot = $leg.placedLot
                hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
                existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
                sizingOutcome = $null
            })
    }
    Add-SyntheticEvent $events ([ordered]@{
            type = 'hard_breakeven_activated'; basket = 3; tradeNumber = 5; quoteSequence = 505
            time = Format-UtcZ $activationFourTime
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejected'; basket = 3; tradeNumber = 5; side = 'Buy'; reason = 'InsufficientMargin'
            quoteSequence = 505; time = Format-UtcZ $activationFourTime
            bid = Format-Decimal 1012.0; ask = Format-Decimal 1012.4
            rawRequestedLots = Format-Decimal 0.5; exactRequiredLots = $null; normalizedRequiredLots = Format-Decimal 0.5
            maximumVolume = Format-Decimal 50.0; hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null
            targetAsk = $null; existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null; accountUsedMargin = Format-Decimal 0.0; accountFreeMargin = Format-Decimal -50.0
            accountMarginLevelPercent = $null; projectedUsedMargin = Format-Decimal 100.0
            projectedFreeMargin = Format-Decimal -150.0
            message = 'Synthetic tail attempt rejected; hard-BE mode stays active and the trade may be retried.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 3; tradeNumber = 5; quoteSequence = 506; time = Format-UtcZ $entryFourFiveTime
            decisionBid = Format-Decimal 1013.0; decisionAsk = Format-Decimal 1013.4; side = 'Buy'
            placedLot = Format-Decimal 0.5; fillPrice = Format-Decimal 1013.4; regime = 'HardBreakeven'
            rawRequestedLot = Format-Decimal 0.5; exactRequiredLot = Format-Decimal 0.5; normalizedRequiredLot = Format-Decimal 0.5
            hardBreakevenTarget = Format-Decimal 1000.0; targetSpread = Format-Decimal 0.5; targetBid = Format-Decimal 1000.0
            targetAsk = Format-Decimal 1000.5; existingProfitAtTarget = Format-Decimal 10.0
            marginalProfitPerLot = Format-Decimal 5.0; projectedProfitAfter = Format-Decimal 15.0
            sizingOutcome = 'Feasible'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'strategy_exit'; basket = 3; reason = 'Escape'; quoteSequence = 507; time = Format-UtcZ $exitFourTime
            bid = Format-Decimal 1015.0; ask = Format-Decimal 1015.4; anchor = Format-Decimal 1010.2; legs = 5
            buyLots = Format-Decimal 1.5; sellLots = Format-Decimal 0.0; grossLots = Format-Decimal 1.5
            netLots = Format-Decimal 1.5; hardBreakevenModeActive = $true; rawProfit = Format-Decimal 5.0
            exitProfit = Format-Decimal 5.0; threshold = Format-Decimal 4.0; buyClosePrice = Format-Decimal 1015.0
            sellClosePrice = Format-Decimal 1015.4; commission = Format-Decimal 0.0; realizedProfit = Format-Decimal 5.0
            liquidatedRealizedProfit = Format-Decimal 0.0; liquidatedPositions = 0; historicalEntries = 5
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'margin_call_entered'; quoteSequence = 399; time = Format-UtcZ $marginEnterTime
            bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal 10000.5; equity = Format-Decimal 80.0
            usedMargin = Format-Decimal 200.0; freeMargin = Format-Decimal -120.0
            marginLevelPercent = Format-Decimal 40.0; openPositions = 2
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'stop_out_triggered'; basket = 2; reason = 'MarginLevel'; quoteSequence = 400
            time = Format-UtcZ $stopOutTime; bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal $beforeOne.Balance; floatingProfit = Format-Decimal $beforeOne.FloatingProfit
            equity = Format-Decimal $beforeOne.Equity; usedMargin = Format-Decimal $beforeOne.UsedMargin
            freeMargin = Format-Decimal $beforeOne.FreeMargin; marginLevelPercent = Format-Decimal $beforeOne.MarginLevelPercent
            openPositions = $beforeOne.OpenPositions
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'forced_liquidation'; time = Format-UtcZ $stopOutTime; basket = 2; ordinal = 1; tradeNumber = 1
            side = 'Buy'; placedLot = Format-Decimal 0.1; entryPrice = Format-Decimal 1000.2
            entryTime = Format-UtcZ $entryTwoTime; regime = 'Arithmetic'; rawRequestedLot = Format-Decimal 0.1
            exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.1; liquidationTime = Format-UtcZ $stopOutTime
            triggerTime = Format-UtcZ $stopOutTime; triggerQuoteSequence = 400; triggerBid = Format-Decimal 990.0
            triggerAsk = Format-Decimal 990.4; closePrice = Format-Decimal 990.0; commission = Format-Decimal 0.0
            realizedProfit = Format-Decimal -1.02; reason = 'MarginLevel'
            beforeBalance = Format-Decimal $beforeOne.Balance; beforeFloatingProfit = Format-Decimal $beforeOne.FloatingProfit
            beforeEquity = Format-Decimal $beforeOne.Equity; beforeUsedMargin = Format-Decimal $beforeOne.UsedMargin
            beforeFreeMargin = Format-Decimal $beforeOne.FreeMargin; beforeMarginLevelPercent = Format-Decimal $beforeOne.MarginLevelPercent
            beforeOpenPositions = $beforeOne.OpenPositions
            afterBalance = Format-Decimal $afterOne.Balance; afterFloatingProfit = Format-Decimal $afterOne.FloatingProfit
            afterEquity = Format-Decimal $afterOne.Equity; afterUsedMargin = Format-Decimal $afterOne.UsedMargin
            afterFreeMargin = Format-Decimal $afterOne.FreeMargin; afterMarginLevelPercent = Format-Decimal $afterOne.MarginLevelPercent
            afterOpenPositions = $afterOne.OpenPositions
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'forced_liquidation'; time = Format-UtcZ $stopOutTime; basket = 2; ordinal = 2; tradeNumber = 2
            side = 'Sell'; placedLot = Format-Decimal 0.2; entryPrice = Format-Decimal 1010.4
            entryTime = Format-UtcZ $entryThreeTime; regime = 'Arithmetic'; rawRequestedLot = Format-Decimal 0.2
            exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.2; liquidationTime = Format-UtcZ $stopOutTime
            triggerTime = Format-UtcZ $stopOutTime; triggerQuoteSequence = 400; triggerBid = Format-Decimal 990.0
            triggerAsk = Format-Decimal 990.4; closePrice = Format-Decimal 990.4; commission = Format-Decimal 0.0
            realizedProfit = Format-Decimal 4.0; reason = 'MarginLevel'
            beforeBalance = Format-Decimal $afterOne.Balance; beforeFloatingProfit = Format-Decimal $afterOne.FloatingProfit
            beforeEquity = Format-Decimal $afterOne.Equity; beforeUsedMargin = Format-Decimal $afterOne.UsedMargin
            beforeFreeMargin = Format-Decimal $afterOne.FreeMargin; beforeMarginLevelPercent = Format-Decimal $afterOne.MarginLevelPercent
            beforeOpenPositions = $afterOne.OpenPositions
            afterBalance = Format-Decimal $afterTwo.Balance; afterFloatingProfit = Format-Decimal $afterTwo.FloatingProfit
            afterEquity = Format-Decimal $afterTwo.Equity; afterUsedMargin = Format-Decimal $afterTwo.UsedMargin
            afterFreeMargin = Format-Decimal $afterTwo.FreeMargin; afterMarginLevelPercent = $null
            afterOpenPositions = $afterTwo.OpenPositions
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_liquidated'; basket = 2; reason = 'BrokerLiquidation'; quoteSequence = 400
            time = Format-UtcZ $stopOutTime; bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            anchor = Format-Decimal 1010.2; legs = 0; buyLots = Format-Decimal 0.0; sellLots = Format-Decimal 0.0
            grossLots = Format-Decimal 0.0; netLots = Format-Decimal 0.0; hardBreakevenModeActive = $false
            rawProfit = Format-Decimal 0.0; exitProfit = Format-Decimal 0.0; threshold = Format-Decimal 0.0
            buyClosePrice = Format-Decimal 990.0; sellClosePrice = Format-Decimal 990.4; commission = Format-Decimal 0.0
            realizedProfit = Format-Decimal 2.98; liquidatedRealizedProfit = Format-Decimal 2.98
            liquidatedPositions = 2; historicalEntries = 2
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'margin_call_left'; quoteSequence = 401; time = Format-UtcZ $marginLeaveTime
            bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal 10003.48; equity = Format-Decimal 10003.48
            usedMargin = Format-Decimal 0.0; freeMargin = Format-Decimal 10003.48
            marginLevelPercent = $null; openPositions = 0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejection_summary'; basket = 1; tradeNumber = 2; side = 'Sell'
            reason = 'VolumeExceedsMaximum'; outcome = $null; attempts = 1
            firstQuoteSequence = 103; firstTime = Format-UtcZ $rejectionOneTime
            firstBid = Format-Decimal 1004.0; firstAsk = Format-Decimal 1004.2
            lastQuoteSequence = 103; lastTime = Format-UtcZ $rejectionOneTime
            lastBid = Format-Decimal 1004.0; lastAsk = Format-Decimal 1004.2
            parityAlgorithm = 'synthetic parity algorithm'; parityHash = 'fedcba9876543210'
            minNormalizedRequiredLots = Format-Decimal 0.2; maxNormalizedRequiredLots = Format-Decimal 0.2
            minProjectedFreeMargin = $null; maxProjectedFreeMargin = $null
            message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejection_summary'; basket = 3; tradeNumber = 5; side = 'Buy'
            reason = 'InsufficientMargin'; outcome = $null; attempts = 2
            firstQuoteSequence = 505; firstTime = Format-UtcZ $activationFourTime
            firstBid = Format-Decimal 1012.0; firstAsk = Format-Decimal 1012.4
            lastQuoteSequence = 506; lastTime = Format-UtcZ $entryFourFiveTime
            lastBid = Format-Decimal 1013.0; lastAsk = Format-Decimal 1013.4
            parityAlgorithm = 'synthetic parity algorithm'; parityHash = '0123456789abcdef'
            minNormalizedRequiredLots = Format-Decimal 0.5; maxNormalizedRequiredLots = Format-Decimal 0.5
            minProjectedFreeMargin = Format-Decimal -150.0; maxProjectedFreeMargin = Format-Decimal -150.0
            message = 'Synthetic tail attempt rejected; hard-BE mode stays active and the trade may be retried.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'run_ended'; time = Format-UtcZ $runEndTime; completed = $true
            failureKind = $null; failureCondition = $null; failureMessage = $null
            failureQuoteTime = $null; failureBid = $null; failureAsk = $null
            quoteTicksProcessed = 5; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; legsOpened = 8
            basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; distinctRejectedEntries = 2
            rejectedEntryAttempts = 3; skippedFirstEntryQuotes = 0; engineRealizedProfit = Format-Decimal 3.48
            deliveryQuoteCount = 3; deliverySemanticDigest = $delivered.semantic_digest
            deliveryFirstUtc = $delivered.first_canonical_utc; deliveryLastUtc = $delivered.last_canonical_utc
        })

    # ---- Telemetry ---- (one event snapshot per significant event, in event order)
    $telemetry = New-Object System.Collections.Generic.List[object]
    Add-SyntheticTelemetry $telemetry 'event' $events[0]['id'] $runStart 0 10000.0 10000.0 0.0 $true 0.0 0.0 10000.0 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[1]['id'] $anchorOneTime 100 10000.0 10000.0 0.0 $true 0.0 0.0 10000.0 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[2]['id'] $entryOneTime 101 10000.0 9999.5 -0.5 $true 0.5 100.0 9900.0 9999.0 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'periodic' $null $periodicOneTime 101 10000.0 9999.5 -0.5 $true 0.5 100.0 9900.0 9999.0 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'periodic' $null $periodicTwoTime 110 10000.0 10000.5 0.5 $true 0.5 100.0 9900.5 10000.0 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[3]['id'] $trailingOneTime 110 10000.5 10000.5 0.5 $true 0.5 100.0 9900.5 10000.0 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[4]['id'] $rejectionOneTime 103 10000.5 10000.45 -0.05 $true 0.5 100.0 9900.5 10000.45 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[5]['id'] $exitOneTime 102 10000.5 10000.5 0.0 $true 0.5 0.0 10000.5 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[6]['id'] $anchorTwoTime 300 10000.5 10000.5 0.0 $true 0.5 0.0 10000.5 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[7]['id'] $entryTwoTime 301 10000.5 10000.48 -0.02 $true 0.5 100.0 9900.5 10000.5 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[8]['id'] $entryThreeTime 302 10000.5 10000.46 -0.04 $true 0.5 200.0 9800.5 10000.5 $false 2 0.3 0.1
    Add-SyntheticTelemetry $telemetry 'periodic' $null $periodicThreeTime 302 10000.5 10000.46 -0.04 $true 0.5 200.0 9800.5 10000.5 $false 2 0.3 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[9]['id'] $anchorFourTime 500 10000.5 10000.46 -0.04 $true 0.5 200.0 9800.5 10000.5 $false 2 0.3 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[10]['id'] $entryFourOneTime 501 10000.5 10000.4 -0.1 $true 0.5 100.0 9900.5 10000.4 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[11]['id'] $entryFourTwoTime 502 10000.5 10000.35 -0.15 $true 0.5 150.0 9850.5 10000.35 $false 2 0.3 0.3
    Add-SyntheticTelemetry $telemetry 'event' $events[12]['id'] $entryFourThreeTime 503 10000.5 10000.3 -0.2 $true 0.5 200.0 9800.5 10000.3 $false 3 0.6 0.6
    Add-SyntheticTelemetry $telemetry 'event' $events[13]['id'] $entryFourFourTime 504 10000.5 10000.25 -0.25 $true 0.5 250.0 9750.5 10000.25 $false 4 1.0 1.0
    Add-SyntheticTelemetry $telemetry 'event' $events[14]['id'] $activationFourTime 505 10000.5 10000.25 -0.25 $true 0.5 250.0 9750.5 10000.25 $false 4 1.0 1.0
    Add-SyntheticTelemetry $telemetry 'event' $events[15]['id'] $activationFourTime 505 10000.5 10000.25 -0.25 $true 0.5 250.0 9750.5 10000.25 $false 4 1.0 1.0
    Add-SyntheticTelemetry $telemetry 'event' $events[16]['id'] $entryFourFiveTime 506 10000.5 10000.2 -0.3 $true 0.5 300.0 9700.5 10000.2 $false 5 1.5 1.5
    Add-SyntheticTelemetry $telemetry 'event' $events[17]['id'] $exitFourTime 507 10005.5 10005.5 0.0 $true 5.5 0.0 10005.5 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[18]['id'] $marginEnterTime 399 10000.5 80.0 -9920.5 $true 0.5 200.0 -120.0 40.0 $true 2 0.3 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[19]['id'] $stopOutTime 400 10000.5 9990.5 -10.0 $true 0.5 200.0 9790.5 4995.25 $false 2 0.3 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[20]['id'] $stopOutTime 400 9999.48 9990.5 -8.98 $true 2.98 100.0 9890.5 9990.5 $false 1 0.2 0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[21]['id'] $stopOutTime 400 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[22]['id'] $stopOutTime 400 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[23]['id'] $marginLeaveTime 401 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[26]['id'] $runEndTime 5 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0

    # ---- Write payload files ----
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    Write-JsonLinesFile $eventsPath $events
    Write-JsonLinesFile $telemetryPath $telemetry
    Write-JsonFile (Join-Path (Join-Path $directory 'storage\single-anchor') 'results.json') $results

    # ---- Manifest ----
    $eventCounts = [ordered]@{}
    foreach ($event in $events) {
        $type = [string]$event.type
        if ($eventCounts.Contains($type)) { $eventCounts[$type] = [int]$eventCounts[$type] + 1 }
        else { $eventCounts[$type] = 1 }
    }
    $eventSnapshotCount = 0
    $periodicCount = 0
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'periodic') { $periodicCount++ } else { $eventSnapshotCount++ }
    }
    $manifestParameters = [ordered]@{}
    foreach ($name in $parameters.Keys) {
        if ($parameters[$name] -is [bool]) { $manifestParameters[$name] = $parameters[$name] }
        else { $manifestParameters[$name] = Format-Decimal $parameters[$name] }
    }
    $manifestMarginParameters = [ordered]@{}
    foreach ($name in $marginParameters.Keys) { $manifestMarginParameters[$name] = Format-Decimal $marginParameters[$name] }
    $manifestSessionMap = [ordered]@{}
    foreach ($name in $sessionMap.Keys) { $manifestSessionMap[$name] = $sessionMap[$name] }
    $manifestSessionMap.Remove('SourceCoverageEndUtc')
    $manifestSessionMap['SourceLastQuoteUtc'] = Format-UtcZ $runEndTime

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(
            [ordered]@{ name = 'events.jsonl'; year = $null },
            [ordered]@{ name = 'telemetry-2019.jsonl'; year = 2019 })) {
        $path = Get-ArtifactPath $directory ([string]$entry.name)
        $lines = @([System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)).Count
        $files.Add([ordered]@{
                name = [string]$entry.name; year = $entry.year; sha256 = Get-FileSha256 $path
                bytes = (Get-Item -LiteralPath $path).Length; lines = $lines
            })
    }
    $fingerprint = New-Object System.Text.StringBuilder
    foreach ($row in $files) {
        [void]$fingerprint.Append([string]$row.name).Append("`n").Append([string]$row.sha256).Append("`n").Append([string]$row.bytes).Append("`n")
    }
    $manifest = [ordered]@{
        contract = 'marketlab-single-anchor-replay-package-v1'; modelRevision = $modelRevision
        stopOutModel = $stopOutModel; symbol = $symbol; market = $market; securityType = 'Forex'
        algorithmTimeZone = 'UTC'; quoteTimeZone = 'UTC'; startDate = $startDate; endDate = $endDate
        startUtc = Format-UtcZ $runStart; endUtc = Format-UtcZ $runEndTime
        researchAccountEnabled = $true; marginEnabled = $true; telemetryIntervalSeconds = 300
        parameters = $manifestParameters; marginParameters = $manifestMarginParameters
        sessionMap = $manifestSessionMap
        delivered = [ordered]@{
            quoteCount = 3; semanticDigest = $delivered.semantic_digest
            firstCanonicalUtc = $delivered.first_canonical_utc; lastCanonicalUtc = $delivered.last_canonical_utc
        }
        outcome = [ordered]@{ completed = $true; failureKind = $null; failureCondition = $null }
        counters = [ordered]@{
            quoteTicksProcessed = 5; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; legsOpened = 8
            basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; distinctRejectedEntries = 2
            rejectedEntryAttempts = 3; skippedFirstEntryQuotes = 0; engineRealizedProfit = Format-Decimal 3.48
        }
        eventCounts = [pscustomobject]$eventCounts
        telemetryCounts = [ordered]@{ event = $eventSnapshotCount; periodic = $periodicCount }
        files = $files.ToArray()
        packageSha256 = Get-TextSha256 $fingerprint.ToString()
    }
    Write-JsonFile (Get-ArtifactPath $directory 'manifest.json') $manifest
}

# Turns a copy of the successful synthetic base package into a valid failed-run package:
# results.failure, results.completed, the run_ended failure identity, its telemetry snapshot time
# and the manifest outcome block are written consistently. In 'forward' mode the faulting quote
# is later than the last accepted quote (the run-end time is the faulting quote); in
# 'out-of-order' mode the faulting quote precedes the last accepted quote (the run-end time stays
# the last accepted quote). Both are positive verifier fixtures.
function New-FailedResultFixture([string]$directory, [string]$mode) {
    $failureQuoteTime = if ($mode -eq 'forward') { New-UtcTime '2019-01-02T02:24:00.000' } else { New-UtcTime '2019-01-02T02:22:00.000' }
    $resultsPath = Join-Path $directory 'storage\single-anchor\results.json'
    $results = Read-JsonFile $resultsPath
    if ($mode -eq 'forward') {
        $results.lastProcessedQuote.Time = Format-UtcZ (New-UtcTime '2019-01-02T02:23:30.000')
    }
    $results.completed = $false
    $results.failure = [ordered]@{
        Kind = 'DataQuality'; Condition = 'SyntheticFault'; Message = 'Synthetic failed-run fixture.'
        Quote = [ordered]@{
            Time = Format-UtcZ $failureQuoteTime; Bid = [decimal]990.0; Ask = [decimal]990.4
            Mid = [decimal]990.2; Spread = [decimal]0.4; IsValid = $false
        }
    }
    Write-JsonFile $resultsPath $results

    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $events = Read-JsonLinesArray $eventsPath
    $runEnded = $null
    foreach ($row in $events) { if ([string]$row.type -eq 'run_ended') { $runEnded = $row } }
    $lastAcceptedValue = $results.lastProcessedQuote.Time
    if ($lastAcceptedValue -is [datetime]) {
        $lastAccepted = [datetime]$lastAcceptedValue
        if ($lastAccepted.Kind -eq [System.DateTimeKind]::Local) { $lastAccepted = $lastAccepted.ToUniversalTime() }
        elseif ($lastAccepted.Kind -eq [System.DateTimeKind]::Unspecified) { $lastAccepted = [datetime]::SpecifyKind($lastAccepted, [System.DateTimeKind]::Utc) }
    }
    else {
        $lastAccepted = New-UtcTime (([string]$lastAcceptedValue).TrimEnd('Z'))
    }
    $runEndTime = if ($failureQuoteTime -gt $lastAccepted) { $failureQuoteTime } else { $lastAccepted }
    $runEnded.completed = $false
    $runEnded.failureKind = 'DataQuality'
    $runEnded.failureCondition = 'SyntheticFault'
    $runEnded.failureMessage = 'Synthetic failed-run fixture.'
    $runEnded.failureQuoteTime = Format-UtcZ $failureQuoteTime
    $runEnded.failureBid = Format-Decimal 990.0
    $runEnded.failureAsk = Format-Decimal 990.4
    $runEnded.time = Format-UtcZ $runEndTime
    Write-JsonLinesFile $eventsPath $events

    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq [long]$runEnded.id) { $row.time = $runEnded.time }
    }
    Write-JsonLinesFile $telemetryPath $telemetry

    $manifestPath = Get-ArtifactPath $directory 'manifest.json'
    $manifest = Read-JsonFile $manifestPath
    $manifest.outcome.completed = $false
    $manifest.outcome.failureKind = 'DataQuality'
    $manifest.outcome.failureCondition = 'SyntheticFault'
    Write-JsonFile $manifestPath $manifest
    Repair-PackageIntegrity $directory @('events.jsonl', 'telemetry-2019.jsonl')
}

function Add-SyntheticEvent([System.Collections.Generic.List[object]]$list, [System.Collections.IDictionary]$body) {
    $event = [ordered]@{}
    foreach ($key in $body.Keys) { $event[$key] = $body[$key] }
    $event['id'] = $list.Count + 1
    [void]$list.Add($event)
}

function Add-SyntheticTelemetry(
    [System.Collections.Generic.List[object]]$list, [string]$kind, $eventId, [datetime]$time, [long]$quoteSequence,
    [decimal]$balance, [decimal]$equity, [decimal]$floatingProfit, [bool]$floatingObservable, [decimal]$realizedProfit,
    [decimal]$usedMargin, [decimal]$freeMargin, $marginLevelPercent, [bool]$marginCallActive, [int]$openPositions,
    [decimal]$grossLots, [decimal]$absoluteNetLots) {
    $freeMarginText = Format-Decimal $freeMargin
    $marginLevelText = Format-Decimal $marginLevelPercent
    $row = [ordered]@{
        kind = $kind; eventId = $eventId; time = Format-UtcZ $time; quoteSequence = $quoteSequence
        balance = Format-Decimal $balance; equity = Format-Decimal $equity; floatingProfit = Format-Decimal $floatingProfit
        floatingObservable = $floatingObservable; realizedProfit = Format-Decimal $realizedProfit
        usedMargin = Format-Decimal $usedMargin; freeMargin = $freeMarginText; marginLevelPercent = $marginLevelText
        marginCallActive = $marginCallActive; openPositions = $openPositions; grossLots = Format-Decimal $grossLots
        absoluteNetLots = Format-Decimal $absoluteNetLots
    }
    [void]$list.Add($row)
}

# ---- Verifier invocation and mutation cases --------------------------------

function Get-VerifierHost {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $command = Get-Command powershell -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    return (Join-Path $PSHOME 'powershell.exe')
}

function Invoke-PackageVerifier([string]$directory) {
    $outputPath = Join-Path $directory 'replay-package-verification.json'
    $output = & $script:verifierHost -NoProfile -File $script:verifierPath -RunDirectory $directory -OutputPath $outputPath 2>&1
    $exitCode = $LASTEXITCODE
    $script:lastVerifierOutput = ($output | Out-String)
    return $exitCode
}

function Copy-BasePackage([string]$base, [string]$destination) {
    Copy-Item -LiteralPath $base -Destination $destination -Recurse -Force
}

function New-Case([string]$name, [string[]]$dirtyPayloads, [scriptblock]$mutate) {
    return [ordered]@{ name = $name; dirty = $dirtyPayloads; mutate = $mutate }
}

$script:verifierPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\scripts\Test-SingleAnchorReplayPackage.ps1')).Path
$script:verifierHost = Get-VerifierHost
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('marketlab-replay-verifier-' + [Guid]::NewGuid().ToString('N'))
$baseDirectory = Join-Path $testRoot 'base'
New-Item -ItemType Directory -Path $baseDirectory -Force | Out-Null
New-SyntheticResultPackage $baseDirectory

Write-Output "Synthetic base package: $baseDirectory"
Write-Output "Verifier host: $script:verifierHost"

$baseExit = Invoke-PackageVerifier $baseDirectory
if ($baseExit -ne 0) {
    Write-Output "FAIL: the synthetic base package did not verify (exit $baseExit). Verifier output:"
    Write-Output $script:lastVerifierOutput
    exit 1
}
$baseRecord = Read-JsonFile (Join-Path $baseDirectory 'replay-package-verification.json')
if (-not [bool]$baseRecord.pass) {
    Write-Output "FAIL: the synthetic base verification record does not report pass = true."
    exit 1
}
if ([int]$baseRecord.parityChecks -le 0) {
    Write-Output "FAIL: the synthetic base verification record reports no payload-parity comparisons."
    exit 1
}
Write-Output ("Base package PASS: {0} checks, {1} payload-parity comparisons." -f $baseRecord.checks, $baseRecord.parityChecks)

$cases = @(
    (New-Case 'entry_executed tradeNumber' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_executed') { $row.tradeNumber = 999; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'entry_executed fillPrice' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_executed') { $row.fillPrice = '4242.42'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'forced_liquidation ordinal' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'forced_liquidation') { $row.ordinal = 9; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'forced_liquidation closePrice' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'forced_liquidation') { $row.closePrice = '1.23'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'stop_out_triggered time' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'stop_out_triggered') {
                    # Keep the stream time-ordered so the failure is the payload parity, not the
                    # monotonic clock: reuse the previous entry's time.
                    $row.time = '2019-01-02T02:13:00.000Z'
                    break
                }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'same-quote forced liquidation order' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            $indexes = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].type -eq 'forced_liquidation') { $indexes.Add($i) }
            }
            if ($indexes.Count -ne 2) { throw "expected exactly two forced_liquidation events, found $($indexes.Count)" }
            $firstIndex = $indexes[0]
            $secondIndex = $indexes[1]
            $firstRow = $rows[$firstIndex]
            $secondRow = $rows[$secondIndex]
            $firstId = [long]$firstRow.id
            $secondId = [long]$secondRow.id
            # Exchange the two payloads but keep the per-position ids, so the id/clock checks stay
            # valid and only the authoritative liquidation order can detect the swap.
            $rows[$firstIndex] = New-EventWithId $secondRow $firstId
            $rows[$secondIndex] = New-EventWithId $firstRow $secondId
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'manifest.modelRevision' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.modelRevision = 'marketlab-single-anchor-mutated-v1'
            Write-JsonFile $path $manifest
        }),
    (New-Case 'manifest payload sha256 row' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.files[0].sha256 = ('0' * 64)
            Write-JsonFile $path $manifest
        }),
    (New-Case 'delete one event' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].type -eq 'entry_executed') { $rows.RemoveAt($i); break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'delete one telemetry event snapshot' @('telemetry-2019.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].kind -eq 'event') { $rows.RemoveAt($i); break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'extra periodic row inside the interval' @('telemetry-2019.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].kind -ne 'periodic') { continue }
                $newTime = Add-SecondsToUtc $rows[$i].time 10
                $copy = Copy-ObjectWithUpdates $rows[$i] @{ time = (Format-UtcZ $newTime) }
                $rows.Insert($i + 1, $copy)
                break
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'hard-BE activation snapshot replaced by the following entry snapshot' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $activationId = $null
            $entryId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'hard_breakeven_activated') { $activationId = [long]$row.id }
                if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 3 -and [long]$row.tradeNumber -eq 5) { $entryId = [long]$row.id }
            }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            $source = $null
            $target = $null
            foreach ($row in $rows) {
                if ([string]$row.kind -ne 'event') { continue }
                if ([long]$row.eventId -eq $entryId) { $source = $row }
                if ([long]$row.eventId -eq $activationId) { $target = $row }
            }
            foreach ($field in @('balance', 'equity', 'floatingProfit', 'realizedProfit', 'usedMargin', 'freeMargin', 'marginLevelPercent', 'marginCallActive', 'openPositions', 'grossLots', 'absoluteNetLots')) {
                $target.$field = $source.$field
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'hard-BE activation moved after its enabling attempt' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            $activationIndex = -1
            $rejectionIndex = -1
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].type -eq 'hard_breakeven_activated') { $activationIndex = $i }
                if ([string]$rows[$i].type -eq 'entry_rejected') { $rejectionIndex = $i }
            }
            if ($activationIndex -lt 0 -or $rejectionIndex -lt 0) { throw 'the activation or rejection event is missing' }
            $activationRow = $rows[$activationIndex]
            $rejectionRow = $rows[$rejectionIndex]
            $activationId = [long]$activationRow.id
            $rejectionId = [long]$rejectionRow.id
            $rows[$activationIndex] = New-EventWithId $rejectionRow $activationId
            $rows[$rejectionIndex] = New-EventWithId $activationRow $rejectionId
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'hard-BE activation time moved to the later fill' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $activationId = $null
            $entry = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'hard_breakeven_activated') { $activationId = [long]$row.id }
                if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 3 -and [long]$row.tradeNumber -eq 5) { $entry = $row }
            }
            for ($i = 0; $i -lt $events.Count; $i++) {
                if ([long]$events[$i].id -eq $activationId) {
                    $events[$i].time = $entry.time
                    $events[$i].quoteSequence = $entry.quoteSequence
                }
            }
            Write-JsonLinesFile (Get-ArtifactPath $directory 'events.jsonl') $events
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $activationId) {
                    $row.time = $entry.time
                    $row.quoteSequence = $entry.quoteSequence
                }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'trailing_activated threshold changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'trailing_activated') { $row.activationThreshold = '1.0'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'trailing_activated snapshot quoteSequence changed' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $trailingId = $null
            foreach ($row in $events) { if ([string]$row.type -eq 'trailing_activated') { $trailingId = [long]$row.id } }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $trailingId) { $row.quoteSequence = 999999 }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'margin_call_entered balance changed on the event only' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'margin_call_entered') { $row.balance = '1.0'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'margin_call_entered moved after the stop out' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            $enterIndex = -1
            $stopOutIndex = -1
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].type -eq 'margin_call_entered') { $enterIndex = $i }
                if ([string]$rows[$i].type -eq 'stop_out_triggered') { $stopOutIndex = $i }
            }
            if ($enterIndex -lt 0 -or $stopOutIndex -lt 0) { throw 'the margin-call or stop-out event is missing' }
            $enterRow = $rows[$enterIndex]
            $stopOutRow = $rows[$stopOutIndex]
            $enterId = [long]$enterRow.id
            $stopOutId = [long]$stopOutRow.id
            $rows[$enterIndex] = New-EventWithId $stopOutRow $enterId
            $rows[$stopOutIndex] = New-EventWithId $enterRow $stopOutId
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'manifest.outcome.completed' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.outcome.completed = $false
            Write-JsonFile $path $manifest
        }),
    (New-Case 'entry_rejected projectedFreeMargin as a JSON number' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_rejected') { $row.projectedFreeMargin = [decimal]-150.0; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'entry_executed snapshot quoteSequence' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $entryId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'entry_executed') { $entryId = [long]$row.id; break }
            }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $entryId) { $row.quoteSequence = 999999 }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'entry_executed snapshot post-entry inventory' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $entryId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 3 -and [long]$row.tradeNumber -eq 5) { $entryId = [long]$row.id; break }
            }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $entryId) {
                    $row.openPositions = 9
                    $row.grossLots = '9.0'
                    $row.absoluteNetLots = '9.0'
                }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'forced_liquidation snapshot time and trigger quote' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $liquidationId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'forced_liquidation') { $liquidationId = [long]$row.id; break }
            }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $liquidationId) {
                    $row.time = '2019-01-02T02:23:00.500Z'
                    $row.quoteSequence = 401
                }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'forced_liquidation event afterBalance' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'forced_liquidation') { $row.afterBalance = '1.0'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'forced_liquidation commission as a JSON number' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'forced_liquidation') { $row.commission = [decimal]0.0; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'duplicate trailing_activated' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $trailingIndex = -1
            for ($i = 0; $i -lt $events.Count; $i++) {
                if ([string]$events[$i].type -eq 'trailing_activated') { $trailingIndex = $i; break }
            }
            if ($trailingIndex -lt 0) { throw 'no trailing_activated event' }
            Insert-DuplicateEvent $directory $trailingIndex
        }),
    (New-Case 'extra run_started' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            Insert-DuplicateEvent $directory 0
        }),
    (New-Case 'spurious first_entry_skipped' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $anchorId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'basket_anchored' -and [long]$row.basket -eq 2) { $anchorId = [long]$row.id; break }
            }
            $telemetry = Read-JsonLinesArray (Get-ArtifactPath $directory 'telemetry-2019.jsonl')
            $snapshotBase = $null
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $anchorId) { $snapshotBase = $row }
            }
            if ($null -eq $snapshotBase) { throw 'no anchor snapshot to copy' }
            $payload = [ordered]@{
                type = 'first_entry_skipped'; basket = 2; quoteSequence = 299
                time = '2019-01-02T02:11:00.000Z'; bid = '1010.0'; ask = '1010.4'; spread = '0.4'; attempts = 1
            }
            Insert-EventAndSnapshot $directory 6 $payload $snapshotBase @{
                time = '2019-01-02T02:11:00.000Z'; quoteSequence = 299
                openPositions = 0; grossLots = '0.0'; absoluteNetLots = '0.0'
            }
        }),
    (New-Case 'unknown event type' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'margin_call_left') { $row.type = 'bogus_replay_event'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'swapped rejection summaries' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            $indexes = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ([string]$rows[$i].type -eq 'entry_rejection_summary') { $indexes.Add($i) }
            }
            if ($indexes.Count -ne 2) { throw "expected two rejection summaries, found $($indexes.Count)" }
            $first = $rows[$indexes[0]]
            $second = $rows[$indexes[1]]
            $firstId = [long]$first.id
            $secondId = [long]$second.id
            $rows[$indexes[0]] = New-EventWithId $second $firstId
            $rows[$indexes[1]] = New-EventWithId $first $secondId
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'manifest parameter as a JSON number' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.parameters.BaseLot = [decimal]0.1
            Write-JsonFile $path $manifest
        }),
    (New-Case 'basket_liquidated decimal as a JSON number' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'basket_liquidated') { $row.threshold = [decimal]0.0; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'margin_call_entered impossible state (event and snapshot together)' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $enteredId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'margin_call_entered') { $enteredId = [long]$row.id; break }
            }
            foreach ($row in $events) {
                if ([long]$row.id -eq $enteredId) {
                    $row.equity = '9000.0'; $row.usedMargin = '100.0'; $row.freeMargin = '8900.0'; $row.marginLevelPercent = '9000.0'
                }
            }
            Write-JsonLinesFile $eventsPath $events
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $enteredId) {
                    $row.equity = '9000.0'; $row.usedMargin = '100.0'; $row.freeMargin = '8900.0'; $row.marginLevelPercent = '9000.0'
                }
            }
            Write-JsonLinesFile $telemetryPath $telemetry
        })
)

$passed = 0
$caseIndex = 0
foreach ($case in $cases) {
    $caseIndex++
    $caseDirectory = Join-Path $testRoot (('case-{0:D2}-' -f $caseIndex) + ($case.name -replace '[^A-Za-z0-9]+', '-'))
    Copy-BasePackage $baseDirectory $caseDirectory
    try {
        & $case.mutate $caseDirectory
        Repair-PackageIntegrity $caseDirectory $case.dirty
    }
    catch {
        $script:caseFailures.Add(("case '{0}' threw while preparing the mutation: {1} {2}" -f $case.name, $_.Exception.Message, $_.InvocationInfo.PositionMessage))
        Write-Output ("ERROR:    {0} ({1})" -f $case.name, $_.Exception.Message)
        continue
    }
    $exitCode = Invoke-PackageVerifier $caseDirectory
    if ($exitCode -ne 0) {
        $passed++
        Write-Output ("DETECTED: {0} (verifier exit {1})" -f $case.name, $exitCode)
    }
    else {
        $script:caseFailures.Add(("case '{0}' was NOT detected: the verifier returned 0. Output: {1}" -f $case.name, $script:lastVerifierOutput))
        Write-Output ("MISSED:   {0} (verifier returned 0)" -f $case.name)
    }
}

# Positive failed-run fixtures: a valid failed package must verify, including the documented
# run-end time rule for a forward-time fault and for an out-of-order fault.
$positiveTotal = 0
$positivePassed = 0
$forwardFixture = Join-Path $testRoot 'failed-forward'
foreach ($mode in @('forward', 'out-of-order')) {
    $positiveTotal++
    $fixtureDirectory = Join-Path $testRoot ("failed-$mode")
    Copy-BasePackage $baseDirectory $fixtureDirectory
    try {
        New-FailedResultFixture $fixtureDirectory $mode
    }
    catch {
        $script:caseFailures.Add(("the failed-run '$mode' fixture threw while preparing: {0}" -f $_.Exception.Message))
        Write-Output ("ERROR:    failed-run fixture $mode ({0})" -f $_.Exception.Message)
        continue
    }
    $exitCode = Invoke-PackageVerifier $fixtureDirectory
    if ($exitCode -eq 0) {
        $positivePassed++
        Write-Output ("VERIFIED: failed-run {0} fixture (positive)" -f $mode)
    }
    else {
        $script:caseFailures.Add(("the failed-run '{0}' fixture did not verify (exit {1}): {2}" -f $mode, $exitCode, $script:lastVerifierOutput))
        Write-Output ("FAILED:   failed-run {0} fixture (verifier exit {1})" -f $mode, $exitCode)
    }
}

$failedCases = @(
    (New-Case 'failed run: failureKind tamper' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'run_ended') { $row.failureKind = 'TamperedKind' }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'failed run: run-end time ignores the max rule' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $targetTime = '2019-01-02T02:23:30.000Z'
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $eventsPath
            $runEndId = $null
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'run_ended') { $row.time = $targetTime; $runEndId = [long]$row.id }
            }
            Write-JsonLinesFile $eventsPath $rows
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $runEndId) { $row.time = $targetTime }
            }
            Write-JsonLinesFile $telemetryPath $telemetry
        }),
    (New-Case 'failed run: failureBid as a JSON number' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'run_ended') { $row.failureBid = [decimal]990.0 }
            }
            Write-JsonLinesFile $path $rows
        })
)

foreach ($case in $failedCases) {
    $caseIndex++
    $caseDirectory = Join-Path $testRoot (('failed-case-{0:D2}-' -f $caseIndex) + ($case.name -replace '[^A-Za-z0-9]+', '-'))
    Copy-BasePackage $forwardFixture $caseDirectory
    try {
        & $case.mutate $caseDirectory
        Repair-PackageIntegrity $caseDirectory $case.dirty
    }
    catch {
        $script:caseFailures.Add(("case '{0}' threw while preparing the mutation: {1}" -f $case.name, $_.Exception.Message))
        Write-Output ("ERROR:    {0} ({1})" -f $case.name, $_.Exception.Message)
        continue
    }
    $exitCode = Invoke-PackageVerifier $caseDirectory
    if ($exitCode -ne 0) {
        $passed++
        Write-Output ("DETECTED: {0} (verifier exit {1})" -f $case.name, $exitCode)
    }
    else {
        $script:caseFailures.Add(("case '{0}' was NOT detected: the verifier returned 0." -f $case.name))
        Write-Output ("MISSED:   {0} (verifier returned 0)" -f $case.name)
    }
}
$totalCases = $cases.Count + $failedCases.Count

if ($script:caseFailures.Count -eq 0) {
    Write-Output ("PASS: {0}/{1} verifier mutation cases behaved as expected; {2}/{3} positive failed-run fixtures verified" -f $passed, $totalCases, $positivePassed, $positiveTotal)
    exit 0
}
Write-Output ("FAIL: {0}/{1} verifier mutation cases behaved as expected; {2}/{3} positive failed-run fixtures verified; {4} case(s) failed:" -f $passed, $totalCases, $positivePassed, $positiveTotal, $script:caseFailures.Count)
foreach ($failure in $script:caseFailures) { Write-Output ("  - " + $failure) }
exit 1
