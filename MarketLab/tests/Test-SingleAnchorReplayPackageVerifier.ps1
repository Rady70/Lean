#requires -Version 5.1
<#
.SYNOPSIS
Mutation test for MarketLab\scripts\Test-SingleAnchorReplayPackage.ps1, the Phase E replay
package verifier.

.DESCRIPTION
Builds a synthetic SingleAnchor replay package (events.jsonl, telemetry-2019.jsonl, manifest.json)
next to a synthetic storage\single-anchor\results.json that is a possible engine execution: three
strictly sequential baskets (a trailing basket with a skipped-first-entry trace, a MarginLevel
Stop Out basket with an active Margin Call, and a hard-BE basket whose first tail attempt is
rejected and a later attempt of the same trade fills), monotone live/telemetry quote sequences and
coherent account identities. It asserts that the strengthened verifier returns PASS on it, then
applies each mutation in a copy of the tree:

  * entry_executed tradeNumber / fillPrice / snapshot quoteSequence / post-entry inventory /
    hard-BE sizingOutcome
  * forced_liquidation ordinal / closePrice / commission / snapshot time+trigger quote /
    event afterBalance
  * stop_out_triggered time and an impossible MarginLevel state
  * swap the two same-quote forced liquidations          (payload parity D order)
  * manifest modelRevision / payload sha256 / outcome / parameter representation / securityType /
    delivered presence / shard year / fake eventCounts key
  * delete one event / one telemetry snapshot            (coverage)
  * extra periodic row inside the 300-second interval    (periodic bound)
  * hard-BE activation snapshot replaced by the following entry snapshot (derived pre-attempt state)
  * hard-BE activation moved after its enabling attempt  (same-timestamp lifecycle order)
  * hard-BE activation timed at the later fill           (earliest-attempt selection)
  * trailing_activated threshold / snapshot quote / duplicate activation (lifecycle + threshold)
  * margin_call balance-only change, joint event+snapshot balance corruption, moved after the
    Stop Out, and a consistent event+snapshot impossible state (parity, lifecycle, margin condition)
  * backward event+snapshot quote sequence                (live sequence monotonicity)
  * run_started time moved with its snapshot               (authoritative start time)
  * first_entry_skipped attempts / spread / counter changes (emission semantics)
  * entry_rejected maximumVolume / sizingOutcome changes
  * entry_rejected / forced_liquidation / basket_liquidated / manifest parameter decimals changed
    from exact strings to JSON numbers                     (exact-string serialization)
  * spurious first_entry_skipped / extra run_started / unknown event type (stream contract)
  * swapped rejection recaps                              (authoritative rejection order)

After each mutation the package's own derived integrity (the changed payload's sha256/bytes/lines,
the event counts, the telemetry counts and the package fingerprint) is recomputed automatically,
so a failure can only come from the mutation the case is about. Every case must make the verifier
return a non-zero exit code.

The test also builds four positive fixtures the verifier must accept: a forward-time failed run
(faulting quote later than the last accepted quote), an out-of-order failed run (faulting quote
earlier), a NegativeEquity Stop Out with no defined margin level or Margin Call, and a terminal
hard-BE violation with exactly one diagnostic event bound to the failure quote. It rejects a
tampered failure identity, a run-end time that ignores the max rule, a numeric failureBid, a
missing violation event behind a violation failure and a duplicate violation event.

The test is self-contained, uses only Windows PowerShell 5.1 syntax and invokes the verifier with
the current machine's pwsh (falling back to Windows PowerShell). Exit 0 only when the base package
passes, all positive fixtures verify and every mutation is detected.
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

# Removes every event of the given types, renumbers the kept ids 1..N and remaps (or removes) the
# matching telemetry event snapshots.
function Remove-EventsByType([string]$directory, [string[]]$types) {
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $rows = Read-JsonLinesArray $eventsPath
    $removedOldIds = @{}
    $keptRows = New-Object System.Collections.Generic.List[object]
    $keptOldIds = New-Object System.Collections.Generic.List[long]
    foreach ($row in $rows) {
        if ($types -contains [string]$row.type) {
            $removedOldIds[[long]$row.id] = $true
            continue
        }
        [void]$keptRows.Add($row)
        [void]$keptOldIds.Add([long]$row.id)
    }
    for ($i = 0; $i -lt $keptRows.Count; $i++) { $keptRows[$i].id = $i + 1 }
    Write-JsonLinesFile $eventsPath $keptRows
    $idMap = @{}
    for ($i = 0; $i -lt $keptOldIds.Count; $i++) { $idMap[$keptOldIds[$i]] = $i + 1 }
    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    $keptTelemetry = New-Object System.Collections.Generic.List[object]
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event') {
            $oldId = [long]$row.eventId
            if ($removedOldIds.ContainsKey($oldId)) { continue }
            $row.eventId = $idMap[$oldId]
        }
        [void]$keptTelemetry.Add($row)
    }
    Write-JsonLinesFile $telemetryPath $keptTelemetry
}

# Removes every event for which the filter returns true, renumbers the kept ids 1..N and remaps
# (or removes) the matching telemetry event snapshots.
function Remove-EventsByFilter([string]$directory, [scriptblock]$shouldRemove) {
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $rows = Read-JsonLinesArray $eventsPath
    $removedOldIds = @{}
    $keptRows = New-Object System.Collections.Generic.List[object]
    $keptOldIds = New-Object System.Collections.Generic.List[long]
    foreach ($row in $rows) {
        if (& $shouldRemove $row) {
            $removedOldIds[[long]$row.id] = $true
            continue
        }
        [void]$keptRows.Add($row)
        [void]$keptOldIds.Add([long]$row.id)
    }
    for ($i = 0; $i -lt $keptRows.Count; $i++) { $keptRows[$i].id = $i + 1 }
    Write-JsonLinesFile $eventsPath $keptRows
    $idMap = @{}
    for ($i = 0; $i -lt $keptOldIds.Count; $i++) { $idMap[$keptOldIds[$i]] = $i + 1 }
    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    $keptTelemetry = New-Object System.Collections.Generic.List[object]
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event') {
            $oldId = [long]$row.eventId
            if ($removedOldIds.ContainsKey($oldId)) { continue }
            $row.eventId = $idMap[$oldId]
        }
        [void]$keptTelemetry.Add($row)
    }
    Write-JsonLinesFile $telemetryPath $keptTelemetry
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

    # Preserve the existing manifest key set (so a fake/extra key stays visible to the verifier
    # instead of being silently dropped) while updating every count from the actual stream.
    $counts = [ordered]@{}
    foreach ($existingProperty in $manifest.eventCounts.PSObject.Properties) {
        $counts[$existingProperty.Name] = 0
    }
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

    # A contract-consistent synthetic verifier fixture: the ledger, parity and account
    # identities are internally coherent and follow the producer's contracts, but the quote
    # path is constructed to exercise the verifier rules and is not a full strategy replay.
    $modelRevision = 'marketlab-single-anchor-synthetic-v1'
    $stopOutModel = 'BrokerLiquidation'
    $symbol = 'XAUUSD'
    $market = 'dukascopy'
    $startDate = '2019-01-02'
    $endDate = '2019-01-02'

    $runStart = New-UtcTime '2019-01-02T00:00:00.000'
    $anchorOneTime = New-UtcTime '2019-01-02T02:00:00.000'
    $skipOneTime = New-UtcTime '2019-01-02T02:00:30.000'
    $entryOneTime = New-UtcTime '2019-01-02T02:01:00.000'
    $periodicOneTime = $entryOneTime
    $trailingOneTime = New-UtcTime '2019-01-02T02:02:00.000'
    $rejectionOneTime = New-UtcTime '2019-01-02T02:03:00.000'
    $exitOneTime = New-UtcTime '2019-01-02T02:04:00.000'
    $anchorTwoTime = New-UtcTime '2019-01-02T02:05:00.000'
    $entryTwoTime = New-UtcTime '2019-01-02T02:06:00.000'
    $entryThreeTime = New-UtcTime '2019-01-02T02:07:00.000'
    $periodicTwoTime = New-UtcTime '2019-01-02T02:07:30.000'
    $marginEnterTime = New-UtcTime '2019-01-02T02:08:00.000'
    $stopOutTime = New-UtcTime '2019-01-02T02:09:00.000'
    $marginLeaveTime = New-UtcTime '2019-01-02T02:09:30.000'
    $anchorFourTime = New-UtcTime '2019-01-02T02:10:00.000'
    $entryFourOneTime = New-UtcTime '2019-01-02T02:10:10.000'
    $entryFourTwoTime = New-UtcTime '2019-01-02T02:10:20.000'
    $entryFourThreeTime = New-UtcTime '2019-01-02T02:10:30.000'
    $entryFourFourTime = New-UtcTime '2019-01-02T02:10:40.000'
    $activationFourTime = New-UtcTime '2019-01-02T02:11:00.000'
    $entryFourFiveTime = New-UtcTime '2019-01-02T02:12:00.000'
    $exitFourTime = New-UtcTime '2019-01-02T02:13:00.000'
    $runEndTime = New-UtcTime '2019-01-02T02:14:00.000'
    $quoteTicksProcessed = 400

    # Valid frozen-model account states. Every state satisfies equity = balance + floatingProfit,
    # freeMargin = equity - usedMargin and the exact margin-level ratio. The Stop Out state is a
    # legitimate MarginLevel stop out: level 20% at the configured Stop Out level and already below
    # the 50% Margin Call level, so Margin Call is active at the trigger.
    $beforeOne = [ordered]@{
        Balance = [decimal]10000.5; FloatingProfit = [decimal]-9960.5; Equity = [decimal]40.0
        UsedMargin = [decimal]200.0; FreeMargin = [decimal]-160.0; MarginLevelPercent = [decimal]20.0; OpenPositions = 2
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
    $skippedOne = [ordered]@{
        Basket = 1; FirstQuoteSequence = 101; FirstTime = Format-UtcZ $skipOneTime
        FirstBid = [decimal]997.5; FirstAsk = [decimal]1002.7; Attempts = 3
    }
    $legOne = [ordered]@{
        Basket = 1; TradeNumber = 1; QuoteSequence = 102; Time = Format-UtcZ $entryOneTime
        DecisionBid = [decimal]1002.6; DecisionAsk = [decimal]1003.0; Side = 'Buy'
        PlacedLot = [decimal]0.1; FillPrice = [decimal]1003.0; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.1; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $rejectionOne = [ordered]@{
        Basket = 1; FirstQuoteSequence = 111; FirstTime = Format-UtcZ $rejectionOneTime
        FirstBid = [decimal]1004.0; FirstAsk = [decimal]1004.2; TradeNumber = 2; Side = 'Sell'
        Reason = 'VolumeExceedsMaximum'; RawRequestedLots = [decimal]0.2; ExactRequiredLots = $null
        NormalizedRequiredLots = [decimal]0.2; PlacedLots = $null; NormalizedLot = $null; Outcome = $null
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
        AccountUsedMargin = [decimal]100.0; AccountFreeMargin = [decimal]9900.0; AccountMarginLevelPercent = [decimal]9990.5
        MaximumVolume = [decimal]50.0
        ProjectedUsedMargin = $null; ProjectedFreeMargin = $null
        Message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        Attempts = 1; LastQuoteSequence = 111; LastTime = Format-UtcZ $rejectionOneTime
        LastBid = [decimal]1004.0; LastAsk = [decimal]1004.2
        ParityAlgorithm = 'synthetic parity algorithm'; ParityHash = 'fedcba9876543210'
        MinNormalizedRequiredLots = [decimal]0.2; MaxNormalizedRequiredLots = [decimal]0.2
        MinProjectedFreeMargin = $null; MaxProjectedFreeMargin = $null
    }
    $basketOne = [ordered]@{
        Sequence = 1; AnchorEvent = $anchorOne; CreatedTime = Format-UtcZ $anchorOneTime; ClosedTime = Format-UtcZ $exitOneTime
        CloseQuoteSequence = 112; CloseBid = [decimal]1005.0; CloseAsk = [decimal]1005.2; Anchor = [decimal]1000.1
        Reason = 'Trailing'; Legs = 1; BuyLots = [decimal]0.1; SellLots = [decimal]0.0
        GrossLots = [decimal]0.1; NetLots = [decimal]0.1; HardBreakevenModeActive = $false
        RawProfit = [decimal]0.5; ExitProfit = [decimal]0.5; Threshold = [decimal]0.4
        BuyClosePrice = [decimal]1005.0; SellClosePrice = [decimal]1005.2; Commission = [decimal]0.0
        RealizedProfit = [decimal]0.5; LiquidatedRealizedProfit = [decimal]0.0; LiquidatedPositions = 0
        HistoricalEntries = 1; LiquidationTrace = @(); LegTrace = @($legOne); RejectionTrace = @($rejectionOne)
        SkippedFirstEntryTrace = $skippedOne
    }

    $anchorTwo = [ordered]@{
        Basket = 2; QuoteSequence = 200; Time = Format-UtcZ $anchorTwoTime
        Bid = [decimal]1010.0; Ask = [decimal]1010.4; Anchor = [decimal]1010.2
        Step = [decimal]4.0; Upper = [decimal]1014.2; Lower = [decimal]1006.2
        LowerTarget = [decimal]1000.0; UpperTarget = [decimal]1020.0
    }
    $liquidationLegOne = [ordered]@{
        Basket = 2; TradeNumber = 1; Side = 'Buy'; PlacedLot = [decimal]0.1; EntryPrice = [decimal]1014.6
        EntryTime = Format-UtcZ $entryTwoTime; Regime = 'Arithmetic'; RawRequestedLot = [decimal]0.1
        ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        LiquidationTime = Format-UtcZ $stopOutTime; TriggerTime = Format-UtcZ $stopOutTime
        TriggerQuoteSequence = 211; TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4
        ClosePrice = [decimal]990.0; Commission = [decimal]0.0; RealizedProfit = [decimal]-1.02
        Reason = 'MarginLevel'; Ordinal = 1
    }
    $liquidationLegTwo = [ordered]@{
        Basket = 2; TradeNumber = 2; Side = 'Sell'; PlacedLot = [decimal]0.2; EntryPrice = [decimal]1005.8
        EntryTime = Format-UtcZ $entryThreeTime; Regime = 'Arithmetic'; RawRequestedLot = [decimal]0.2
        ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.2
        LiquidationTime = Format-UtcZ $stopOutTime; TriggerTime = Format-UtcZ $stopOutTime
        TriggerQuoteSequence = 211; TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4
        ClosePrice = [decimal]990.4; Commission = [decimal]0.0; RealizedProfit = [decimal]4.0
        Reason = 'MarginLevel'; Ordinal = 2
    }
    $basketTwo = [ordered]@{
        Sequence = 2; AnchorEvent = $anchorTwo; CreatedTime = Format-UtcZ $anchorTwoTime; ClosedTime = Format-UtcZ $stopOutTime
        CloseQuoteSequence = 211; CloseBid = [decimal]990.0; CloseAsk = [decimal]990.4; Anchor = [decimal]1010.2
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
        Basket = 3; QuoteSequence = 300; Time = Format-UtcZ $anchorFourTime
        Bid = [decimal]1010.0; Ask = [decimal]1010.4; Anchor = [decimal]1010.2
        Step = [decimal]2.5; Upper = [decimal]1012.6; Lower = [decimal]1007.6
        LowerTarget = [decimal]1000.0; UpperTarget = [decimal]1020.0
    }
    $legFourOne = [ordered]@{
        Basket = 3; TradeNumber = 1; QuoteSequence = 301; Time = Format-UtcZ $entryFourOneTime
        DecisionBid = [decimal]1013.0; DecisionAsk = [decimal]1013.4; Side = 'Buy'
        PlacedLot = [decimal]0.1; FillPrice = [decimal]1013.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.1; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.1
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourTwo = [ordered]@{
        Basket = 3; TradeNumber = 2; QuoteSequence = 302; Time = Format-UtcZ $entryFourTwoTime
        DecisionBid = [decimal]1006.6; DecisionAsk = [decimal]1007.0; Side = 'Sell'
        PlacedLot = [decimal]0.2; FillPrice = [decimal]1006.6; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.2; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.2
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourThree = [ordered]@{
        Basket = 3; TradeNumber = 3; QuoteSequence = 303; Time = Format-UtcZ $entryFourThreeTime
        DecisionBid = [decimal]1013.0; DecisionAsk = [decimal]1013.4; Side = 'Buy'
        PlacedLot = [decimal]0.3; FillPrice = [decimal]1013.4; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.3; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.3
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourFour = [ordered]@{
        Basket = 3; TradeNumber = 4; QuoteSequence = 304; Time = Format-UtcZ $entryFourFourTime
        DecisionBid = [decimal]1006.6; DecisionAsk = [decimal]1007.0; Side = 'Sell'
        PlacedLot = [decimal]0.4; FillPrice = [decimal]1006.6; Regime = 'Arithmetic'
        RawRequestedLot = [decimal]0.4; ExactRequiredLot = $null; NormalizedRequiredLot = [decimal]0.4
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
    }
    $legFourFive = [ordered]@{
        Basket = 3; TradeNumber = 5; QuoteSequence = 306; Time = Format-UtcZ $entryFourFiveTime
        DecisionBid = [decimal]1013.0; DecisionAsk = [decimal]1013.4; Side = 'Buy'
        PlacedLot = [decimal]0.5; FillPrice = [decimal]1013.4; Regime = 'HardBreakeven'
        RawRequestedLot = [decimal]0.5; ExactRequiredLot = [decimal]0.5; NormalizedRequiredLot = [decimal]0.5
        HardBreakevenTarget = [decimal]1000.0; TargetSpread = [decimal]0.5; TargetBid = [decimal]1000.0
        TargetAsk = [decimal]1000.5; ExistingProfitAtTarget = [decimal]10.0
        MarginalProfitPerLot = [decimal]5.0; ProjectedProfitAfter = [decimal]15.0
    }
    $rejectionFour = [ordered]@{
        Basket = 3; FirstQuoteSequence = 305; FirstTime = Format-UtcZ $activationFourTime
        FirstBid = [decimal]1012.0; FirstAsk = [decimal]1012.4; TradeNumber = 5; Side = 'Buy'
        Reason = 'InsufficientMargin'; RawRequestedLots = [decimal]0.5; ExactRequiredLots = $null
        NormalizedRequiredLots = [decimal]0.5; PlacedLots = $null; NormalizedLot = $null; Outcome = $null
        HardBreakevenTarget = $null; TargetSpread = $null; TargetBid = $null; TargetAsk = $null
        ExistingProfitAtTarget = $null; MarginalProfitPerLot = $null; ProjectedProfitAfter = $null
        AccountUsedMargin = [decimal]0.0; AccountFreeMargin = [decimal]-50.0; AccountMarginLevelPercent = $null
        MaximumVolume = [decimal]50.0
        ProjectedUsedMargin = [decimal]100.0; ProjectedFreeMargin = [decimal]-150.0
        Message = 'Synthetic tail attempt rejected; hard-BE mode stays active and the trade may be retried.'
        Attempts = 1; LastQuoteSequence = 305; LastTime = Format-UtcZ $activationFourTime
        LastBid = [decimal]1013.0; LastAsk = [decimal]1013.4
        ParityAlgorithm = 'synthetic parity algorithm'; ParityHash = '0123456789abcdef'
        MinNormalizedRequiredLots = [decimal]0.5; MaxNormalizedRequiredLots = [decimal]0.5
        MinProjectedFreeMargin = [decimal]-150.0; MaxProjectedFreeMargin = [decimal]-150.0
    }
    $basketFour = [ordered]@{
        Sequence = 3; AnchorEvent = $anchorFour; CreatedTime = Format-UtcZ $anchorFourTime; ClosedTime = Format-UtcZ $exitFourTime
        CloseQuoteSequence = 307; CloseBid = [decimal]1015.0; CloseAsk = [decimal]1015.4; Anchor = [decimal]1010.2
        Reason = 'Escape'; Legs = 5; BuyLots = [decimal]0.9; SellLots = [decimal]0.6
        GrossLots = [decimal]1.5; NetLots = [decimal]0.3; HardBreakevenModeActive = $true
        RawProfit = [decimal]5.0; ExitProfit = [decimal]5.0; Threshold = [decimal]4.0
        BuyClosePrice = [decimal]1015.0; SellClosePrice = [decimal]1015.4; Commission = [decimal]0.0
        RealizedProfit = [decimal]5.0; LiquidatedRealizedProfit = [decimal]0.0; LiquidatedPositions = 0
        HistoricalEntries = 5; LiquidationTrace = @()
        LegTrace = @($legFourOne, $legFourTwo, $legFourThree, $legFourFour, $legFourFive)
        RejectionTrace = @($rejectionFour); SkippedFirstEntryTrace = $null
    }

    $stopOutEpisode = [ordered]@{
        Basket = 2; Reason = 'MarginLevel'; TriggerQuoteSequence = 211; TriggerTime = Format-UtcZ $stopOutTime
        TriggerBid = [decimal]990.0; TriggerAsk = [decimal]990.4; AtTrigger = $beforeOne
        Liquidations = @(
            [ordered]@{ Leg = $liquidationLegOne; Before = $beforeOne; After = $afterOne },
            [ordered]@{ Leg = $liquidationLegTwo; Before = $afterOne; After = $afterTwo }
        )
        Outcome = 'AllPositionsLiquidated'; ResolvedTime = Format-UtcZ $stopOutTime; AfterLiquidation = $afterTwo
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
        first_canonical_utc = Format-UtcZ $anchorOneTime
        last_canonical_utc = Format-UtcZ $runEndTime
    }
    $researchAccount = [ordered]@{
        InitialBalance = [decimal]10000.0; Balance = [decimal]10008.48; Equity = [decimal]10008.48
        FloatingProfit = [decimal]0.0; FloatingObservable = $true; FloatingObservationsSkipped = 0
        RealizedProfit = [decimal]8.48; PeakBalance = [decimal]10008.48; MaxBalanceDrawdown = [decimal]1.02
        PeakEquity = [decimal]10008.48; MaxEquityDrawdown = [decimal]10.0; CurrentOpenPositions = 0
        MaxOpenPositions = 2; CurrentGrossLots = [decimal]0.0; MaxGrossLots = [decimal]0.3
        CurrentAbsoluteNetLots = [decimal]0.0; MaxAbsoluteNetLots = [decimal]0.1
        MaxExecutableFloatingProfit = [decimal]10.0; MaxExecutableFloatingLoss = [decimal]-10.0
        ClosedBasketsObserved = 2
    }
    $researchMargin = [ordered]@{
        Parameters = $marginParameters; CurrentUsedMargin = [decimal]0.0; CurrentFreeMargin = [decimal]10008.48
        CurrentMarginLevelPercent = $null; MaxUsedMargin = [decimal]200.0; MinFreeMargin = [decimal]-160.0
        MinMarginLevelPercent = [decimal]20.0; MarginCallActive = $false; MarginCallObservations = 2
        MarginCallEpisodes = 1; MarginCallBlockedAttempts = 0; MarginCallBlockedEpisodes = 0
        InsufficientMarginAttempts = 1; InsufficientMarginEpisodes = 1; ForcedLiquidations = 2
        StopOutEpisodes = @($stopOutEpisode)
    }
    $results = [ordered]@{
        completed = $true; modelRevision = $modelRevision; stopOutModel = $stopOutModel
        algorithmTimeZone = 'UTC'; startUtc = Format-UtcZ $runStart; endUtc = Format-UtcZ $runEndTime
        delivered = $delivered; failure = $null; symbol = $symbol; market = $market; quoteTimeZone = 'UTC'
        startDate = $startDate; endDate = $endDate; parameters = $parameters
        quoteTicksProcessed = $quoteTicksProcessed; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; sessionMap = $sessionMap
        nonQuoteTicksUnused = 0
        lastProcessedQuote = [ordered]@{
            Time = Format-UtcZ $runEndTime; Bid = [decimal]990.0; Ask = [decimal]990.4
            Mid = [decimal]990.2; Spread = [decimal]0.4; IsValid = $true
        }
        legsOpened = 8; skippedFirstEntryQuotes = 3; distinctRejectedEntries = 2; rejectedEntryAttempts = 2
        basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; realizedProfit = [decimal]8.48
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
            type = 'first_entry_skipped'; basket = 1; quoteSequence = 101; time = Format-UtcZ $skipOneTime
            bid = Format-Decimal 997.5; ask = Format-Decimal 1002.7; spread = Format-Decimal 5.2; attempts = 1
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 1; tradeNumber = 1; quoteSequence = 102; time = Format-UtcZ $entryOneTime
            decisionBid = Format-Decimal 1002.6; decisionAsk = Format-Decimal 1003.0; side = 'Buy'
            placedLot = Format-Decimal 0.1; fillPrice = Format-Decimal 1003.0; regime = 'Arithmetic'
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
            quoteSequence = 111; time = Format-UtcZ $rejectionOneTime
            bid = Format-Decimal 1004.0; ask = Format-Decimal 1004.2
            rawRequestedLots = Format-Decimal 0.2; exactRequiredLots = $null; normalizedRequiredLots = Format-Decimal 0.2
            maximumVolume = Format-Decimal 50.0; hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null
            targetAsk = $null; existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null; accountUsedMargin = Format-Decimal 100.0; accountFreeMargin = Format-Decimal 9900.0
            accountMarginLevelPercent = Format-Decimal 9990.5; projectedUsedMargin = $null; projectedFreeMargin = $null
            message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'strategy_exit'; basket = 1; reason = 'Trailing'; quoteSequence = 112; time = Format-UtcZ $exitOneTime
            bid = Format-Decimal 1005.0; ask = Format-Decimal 1005.2; anchor = Format-Decimal 1000.1; legs = 1
            buyLots = Format-Decimal 0.1; sellLots = Format-Decimal 0.0; grossLots = Format-Decimal 0.1
            netLots = Format-Decimal 0.1; hardBreakevenModeActive = $false; rawProfit = Format-Decimal 0.5
            exitProfit = Format-Decimal 0.5; threshold = Format-Decimal 0.4; buyClosePrice = Format-Decimal 1005.0
            sellClosePrice = Format-Decimal 1005.2; commission = Format-Decimal 0.0; realizedProfit = Format-Decimal 0.5
            liquidatedRealizedProfit = Format-Decimal 0.0; liquidatedPositions = 0; historicalEntries = 1
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_anchored'; basket = 2; quoteSequence = 200; time = Format-UtcZ $anchorTwoTime
            bid = Format-Decimal 1010.0; ask = Format-Decimal 1010.4; anchor = Format-Decimal 1010.2
            step = Format-Decimal 4.0; upper = Format-Decimal 1014.2; lower = Format-Decimal 1006.2
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 2; tradeNumber = 1; quoteSequence = 201; time = Format-UtcZ $entryTwoTime
            decisionBid = Format-Decimal 1014.2; decisionAsk = Format-Decimal 1014.6; side = 'Buy'
            placedLot = Format-Decimal 0.1; fillPrice = Format-Decimal 1014.6; regime = 'Arithmetic'
            rawRequestedLot = Format-Decimal 0.1; exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.1
            hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
            existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_executed'; basket = 2; tradeNumber = 2; quoteSequence = 202; time = Format-UtcZ $entryThreeTime
            decisionBid = Format-Decimal 1005.8; decisionAsk = Format-Decimal 1006.2; side = 'Sell'
            placedLot = Format-Decimal 0.2; fillPrice = Format-Decimal 1005.8; regime = 'Arithmetic'
            rawRequestedLot = Format-Decimal 0.2; exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.2
            hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
            existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
            sizingOutcome = $null
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'margin_call_entered'; quoteSequence = 210; time = Format-UtcZ $marginEnterTime
            bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal 10000.5; equity = Format-Decimal 80.0
            usedMargin = Format-Decimal 200.0; freeMargin = Format-Decimal -120.0
            marginLevelPercent = Format-Decimal 40.0; openPositions = 2
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'stop_out_triggered'; basket = 2; reason = 'MarginLevel'; quoteSequence = 211
            time = Format-UtcZ $stopOutTime; bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal $beforeOne.Balance; floatingProfit = Format-Decimal $beforeOne.FloatingProfit
            equity = Format-Decimal $beforeOne.Equity; usedMargin = Format-Decimal $beforeOne.UsedMargin
            freeMargin = Format-Decimal $beforeOne.FreeMargin; marginLevelPercent = Format-Decimal $beforeOne.MarginLevelPercent
            openPositions = $beforeOne.OpenPositions
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'forced_liquidation'; time = Format-UtcZ $stopOutTime; basket = 2; ordinal = 1; tradeNumber = 1
            side = 'Buy'; placedLot = Format-Decimal 0.1; entryPrice = Format-Decimal 1014.6
            entryTime = Format-UtcZ $entryTwoTime; regime = 'Arithmetic'; rawRequestedLot = Format-Decimal 0.1
            exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.1; liquidationTime = Format-UtcZ $stopOutTime
            triggerTime = Format-UtcZ $stopOutTime; triggerQuoteSequence = 211; triggerBid = Format-Decimal 990.0
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
            side = 'Sell'; placedLot = Format-Decimal 0.2; entryPrice = Format-Decimal 1005.8
            entryTime = Format-UtcZ $entryThreeTime; regime = 'Arithmetic'; rawRequestedLot = Format-Decimal 0.2
            exactRequiredLot = $null; normalizedRequiredLot = Format-Decimal 0.2; liquidationTime = Format-UtcZ $stopOutTime
            triggerTime = Format-UtcZ $stopOutTime; triggerQuoteSequence = 211; triggerBid = Format-Decimal 990.0
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
            type = 'margin_call_left'; quoteSequence = 211; time = Format-UtcZ $stopOutTime
            bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            balance = Format-Decimal 10003.48; equity = Format-Decimal 10003.48
            usedMargin = Format-Decimal 0.0; freeMargin = Format-Decimal 10003.48
            marginLevelPercent = $null; openPositions = 0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_liquidated'; basket = 2; reason = 'BrokerLiquidation'; quoteSequence = 211
            time = Format-UtcZ $stopOutTime; bid = Format-Decimal 990.0; ask = Format-Decimal 990.4
            anchor = Format-Decimal 1010.2; legs = 0; buyLots = Format-Decimal 0.0; sellLots = Format-Decimal 0.0
            grossLots = Format-Decimal 0.0; netLots = Format-Decimal 0.0; hardBreakevenModeActive = $false
            rawProfit = Format-Decimal 0.0; exitProfit = Format-Decimal 0.0; threshold = Format-Decimal 0.0
            buyClosePrice = Format-Decimal 990.0; sellClosePrice = Format-Decimal 990.4; commission = Format-Decimal 0.0
            realizedProfit = Format-Decimal 2.98; liquidatedRealizedProfit = Format-Decimal 2.98
            liquidatedPositions = 2; historicalEntries = 2
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'basket_anchored'; basket = 3; quoteSequence = 300; time = Format-UtcZ $anchorFourTime
            bid = Format-Decimal 1010.0; ask = Format-Decimal 1010.4; anchor = Format-Decimal 1010.2
            step = Format-Decimal 2.5; upper = Format-Decimal 1012.6; lower = Format-Decimal 1007.6
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    foreach ($leg in @(
            [ordered]@{ tradeNumber = 1; quoteSequence = 301; time = $entryFourOneTime; placedLot = '0.1'; side = 'Buy'; decisionBid = '1013.0'; decisionAsk = '1013.4' },
            [ordered]@{ tradeNumber = 2; quoteSequence = 302; time = $entryFourTwoTime; placedLot = '0.2'; side = 'Sell'; decisionBid = '1006.6'; decisionAsk = '1007.0' },
            [ordered]@{ tradeNumber = 3; quoteSequence = 303; time = $entryFourThreeTime; placedLot = '0.3'; side = 'Buy'; decisionBid = '1013.0'; decisionAsk = '1013.4' },
            [ordered]@{ tradeNumber = 4; quoteSequence = 304; time = $entryFourFourTime; placedLot = '0.4'; side = 'Sell'; decisionBid = '1006.6'; decisionAsk = '1007.0' })) {
        Add-SyntheticEvent $events ([ordered]@{
                type = 'entry_executed'; basket = 3; tradeNumber = $leg.tradeNumber; quoteSequence = $leg.quoteSequence
                time = Format-UtcZ $leg.time
                decisionBid = Format-Decimal $leg.decisionBid; decisionAsk = Format-Decimal $leg.decisionAsk; side = $leg.side
                placedLot = $leg.placedLot; fillPrice = $(if ($leg.side -eq 'Buy') { Format-Decimal $leg.decisionAsk } else { Format-Decimal $leg.decisionBid }); regime = 'Arithmetic'
                rawRequestedLot = $leg.placedLot; exactRequiredLot = $null; normalizedRequiredLot = $leg.placedLot
                hardBreakevenTarget = $null; targetSpread = $null; targetBid = $null; targetAsk = $null
                existingProfitAtTarget = $null; marginalProfitPerLot = $null; projectedProfitAfter = $null
                sizingOutcome = $null
            })
    }
    Add-SyntheticEvent $events ([ordered]@{
            type = 'hard_breakeven_activated'; basket = 3; tradeNumber = 5; quoteSequence = 305
            time = Format-UtcZ $activationFourTime
            lowerTarget = Format-Decimal 1000.0; upperTarget = Format-Decimal 1020.0
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejected'; basket = 3; tradeNumber = 5; side = 'Buy'; reason = 'InsufficientMargin'
            quoteSequence = 305; time = Format-UtcZ $activationFourTime
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
            type = 'entry_executed'; basket = 3; tradeNumber = 5; quoteSequence = 306; time = Format-UtcZ $entryFourFiveTime
            decisionBid = Format-Decimal 1013.0; decisionAsk = Format-Decimal 1013.4; side = 'Buy'
            placedLot = Format-Decimal 0.5; fillPrice = Format-Decimal 1013.4; regime = 'HardBreakeven'
            rawRequestedLot = Format-Decimal 0.5; exactRequiredLot = Format-Decimal 0.5; normalizedRequiredLot = Format-Decimal 0.5
            hardBreakevenTarget = Format-Decimal 1000.0; targetSpread = Format-Decimal 0.5; targetBid = Format-Decimal 1000.0
            targetAsk = Format-Decimal 1000.5; existingProfitAtTarget = Format-Decimal 10.0
            marginalProfitPerLot = Format-Decimal 5.0; projectedProfitAfter = Format-Decimal 15.0
            sizingOutcome = 'Feasible'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'strategy_exit'; basket = 3; reason = 'Escape'; quoteSequence = 307; time = Format-UtcZ $exitFourTime
            bid = Format-Decimal 1015.0; ask = Format-Decimal 1015.4; anchor = Format-Decimal 1010.2; legs = 5
            buyLots = Format-Decimal 0.9; sellLots = Format-Decimal 0.6; grossLots = Format-Decimal 1.5
            netLots = Format-Decimal 0.3; hardBreakevenModeActive = $true; rawProfit = Format-Decimal 5.0
            exitProfit = Format-Decimal 5.0; threshold = Format-Decimal 4.0; buyClosePrice = Format-Decimal 1015.0
            sellClosePrice = Format-Decimal 1015.4; commission = Format-Decimal 0.0; realizedProfit = Format-Decimal 5.0
            liquidatedRealizedProfit = Format-Decimal 0.0; liquidatedPositions = 0; historicalEntries = 5
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejection_summary'; basket = 1; tradeNumber = 2; side = 'Sell'
            reason = 'VolumeExceedsMaximum'; outcome = $null; attempts = 1
            firstQuoteSequence = 111; firstTime = Format-UtcZ $rejectionOneTime
            firstBid = Format-Decimal 1004.0; firstAsk = Format-Decimal 1004.2
            lastQuoteSequence = 111; lastTime = Format-UtcZ $rejectionOneTime
            lastBid = Format-Decimal 1004.0; lastAsk = Format-Decimal 1004.2
            parityAlgorithm = 'synthetic parity algorithm'; parityHash = 'fedcba9876543210'
            minNormalizedRequiredLots = Format-Decimal 0.2; maxNormalizedRequiredLots = Format-Decimal 0.2
            minProjectedFreeMargin = $null; maxProjectedFreeMargin = $null
            message = 'Synthetic volume rejection; the trade may be retried on a later eligible quote.'
        })
    Add-SyntheticEvent $events ([ordered]@{
            type = 'entry_rejection_summary'; basket = 3; tradeNumber = 5; side = 'Buy'
            reason = 'InsufficientMargin'; outcome = $null; attempts = 1
            firstQuoteSequence = 305; firstTime = Format-UtcZ $activationFourTime
            firstBid = Format-Decimal 1012.0; firstAsk = Format-Decimal 1012.4
            lastQuoteSequence = 305; lastTime = Format-UtcZ $activationFourTime
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
            quoteTicksProcessed = $quoteTicksProcessed; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; legsOpened = 8
            basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; distinctRejectedEntries = 2
            rejectedEntryAttempts = 2; skippedFirstEntryQuotes = 3; engineRealizedProfit = Format-Decimal 8.48
            deliveryQuoteCount = 3; deliverySemanticDigest = $delivered.semantic_digest
            deliveryFirstUtc = $delivered.first_canonical_utc; deliveryLastUtc = $delivered.last_canonical_utc
        })

    # ---- Telemetry ---- (one event snapshot per significant event, in event order)
    $telemetry = New-Object System.Collections.Generic.List[object]
    Add-SyntheticTelemetry $telemetry 'event' $events[0]['id'] $runStart 0 10000.0 10000.0 0.0 $true 0.0 0.0 10000.0 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[1]['id'] $anchorOneTime 100 10000.0 10000.0 0.0 $true 0.0 0.0 10000.0 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[2]['id'] $skipOneTime 101 10000.0 10000.0 0.0 $true 0.0 0.0 10000.0 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[3]['id'] $entryOneTime 102 10000.0 9999.5 -0.5 $true 0.0 100.0 9899.5 9999.5 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'periodic' $null $periodicOneTime 102 10000.0 9999.5 -0.5 $true 0.0 100.0 9899.5 9999.5 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[4]['id'] $trailingOneTime 110 10000.0 9999.5 -0.5 $true 0.0 100.0 9899.5 9999.5 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[5]['id'] $rejectionOneTime 111 10000.0 9999.5 -0.5 $true 0.0 100.0 9899.5 9999.5 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[6]['id'] $exitOneTime 112 10000.5 10000.5 0.0 $true 0.5 0.0 10000.5 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[7]['id'] $anchorTwoTime 200 10000.5 10000.5 0.0 $true 0.5 0.0 10000.5 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[8]['id'] $entryTwoTime 201 10000.5 10000.48 -0.02 $true 0.5 100.0 9900.48 10000.48 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[9]['id'] $entryThreeTime 202 10000.5 10000.46 -0.04 $true 0.5 200.0 9800.46 5000.23 $false 2 0.3 0.1 -0.1
    Add-SyntheticTelemetry $telemetry 'periodic' $null $periodicTwoTime 205 10000.5 10000.46 -0.04 $true 0.5 200.0 9800.46 5000.23 $false 2 0.3 0.1 -0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[10]['id'] $marginEnterTime 210 10000.5 80.0 -9920.5 $true 0.5 200.0 -120.0 40.0 $true 2 0.3 0.1 -0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[11]['id'] $stopOutTime 211 10000.5 40.0 -9960.5 $true 0.5 200.0 -160.0 20.0 $true 2 0.3 0.1 -0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[12]['id'] $stopOutTime 211 9999.48 9990.5 -8.98 $true 2.98 100.0 9890.5 9990.5 $false 1 0.2 0.2 -0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[13]['id'] $stopOutTime 211 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[14]['id'] $stopOutTime 211 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[15]['id'] $stopOutTime 211 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[16]['id'] $anchorFourTime 300 10003.48 10003.48 0.0 $true 3.48 0.0 10003.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[17]['id'] $entryFourOneTime 301 10003.48 10003.38 -0.1 $true 3.48 100.0 9903.38 10003.38 $false 1 0.1 0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[18]['id'] $entryFourTwoTime 302 10003.48 10003.33 -0.15 $true 3.48 150.0 9853.33 10003.33 $false 2 0.3 0.1 -0.1
    Add-SyntheticTelemetry $telemetry 'event' $events[19]['id'] $entryFourThreeTime 303 10003.48 10003.28 -0.2 $true 3.48 200.0 9803.28 10003.28 $false 3 0.6 0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[20]['id'] $entryFourFourTime 304 10003.48 10003.23 -0.25 $true 3.48 250.0 9753.23 10003.23 $false 4 1.0 0.2 -0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[21]['id'] $activationFourTime 305 10003.48 10003.23 -0.25 $true 3.48 250.0 9753.23 10003.23 $false 4 1.0 0.2 -0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[22]['id'] $activationFourTime 305 10003.48 10003.23 -0.25 $true 3.48 250.0 9753.23 10003.23 $false 4 1.0 0.2 -0.2
    Add-SyntheticTelemetry $telemetry 'event' $events[23]['id'] $entryFourFiveTime 306 10003.48 10003.18 -0.3 $true 3.48 300.0 9703.18 10003.18 $false 5 1.5 0.3
    Add-SyntheticTelemetry $telemetry 'event' $events[24]['id'] $exitFourTime 307 10008.48 10008.48 0.0 $true 8.48 0.0 10008.48 $null $false 0 0.0 0.0
    Add-SyntheticTelemetry $telemetry 'event' $events[27]['id'] $runEndTime $quoteTicksProcessed 10008.48 10008.48 0.0 $true 8.48 0.0 10008.48 $null $false 0 0.0 0.0
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
        stopOutModel = $stopOutModel; symbol = $symbol; market = $market; securityType = 'Cfd'
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
            quoteTicksProcessed = 400; quoteOnlyQuotes = 1; strategyEligibleQuotes = 4; legsOpened = 8
            basketsClosed = 2; basketsLiquidated = 1; forcedLiquidations = 2; distinctRejectedEntries = 2
            rejectedEntryAttempts = 2; skippedFirstEntryQuotes = 3; engineRealizedProfit = Format-Decimal 8.48
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

# Turns a copy of the synthetic base package into a valid NegativeEquity Stop Out run: no Margin
# Call is defined (used margin 0, null margin level), equity is negative and two positions are
# liquidated. The verifier must accept it (only the MarginLevel branch requires Margin Call).
# Turns a copy of the synthetic base package into a valid NegativeEquity Stop Out run: no Margin
# Call is defined (the defined margin level does not exist for the negative-equity branch), equity
# is negative, the used margin follows the frozen uncovered-volume model and the balance moves by
# exactly the recorded forced-liquidation realized results.
function New-NegativeEquityStopOutFixture([string]$directory) {
    Remove-EventsByType $directory @('margin_call_entered', 'margin_call_left')

    # Frozen used margin: uncovered lots * contract size * weighted average entry price / leverage.
    $neUsedBefore = [decimal]0.0
    $neUsedAfterOne = [decimal]0.1 * [decimal]100.0 * [decimal]1005.8 / [decimal]500.0
    $neEquityBefore = [decimal]-50.0
    $neEquityAfterOne = [decimal]-130.0
    $neBefore = @{
        balance = '100.0'; floatingProfit = '-150.0'; equity = (Format-Decimal $neEquityBefore)
        usedMargin = '0.0'; freeMargin = (Format-Decimal $neEquityBefore)
        marginLevelPercent = $null; openPositions = 2
    }
    $neAfterOne = @{
        balance = '-50.0'; floatingProfit = '-80.0'; equity = (Format-Decimal $neEquityAfterOne)
        usedMargin = (Format-Decimal $neUsedAfterOne); freeMargin = (Format-Decimal ($neEquityAfterOne - $neUsedAfterOne))
        marginLevelPercent = (Format-Decimal ($neEquityAfterOne / $neUsedAfterOne * 100)); openPositions = 1
    }
    $neAfterTwo = @{
        balance = '-150.0'; floatingProfit = '0.0'; equity = '-150.0'
        usedMargin = '0.0'; freeMargin = '-150.0'; marginLevelPercent = $null; openPositions = 0
    }

    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $events = Read-JsonLinesArray $eventsPath
    $stopOutId = $null
    foreach ($row in $events) {
        if ([string]$row.type -eq 'stop_out_triggered') {
            $stopOutId = [long]$row.id
            $row.reason = 'NegativeEquity'
            foreach ($key in $neBefore.Keys) { $row.$key = $neBefore[$key] }
        }
        elseif ([string]$row.type -eq 'forced_liquidation') {
            if ([long]$row.ordinal -eq 1) {
                foreach ($key in $neBefore.Keys) { $row.('before' + $key.Substring(0, 1).ToUpper() + $key.Substring(1)) = $neBefore[$key] }
                foreach ($key in $neAfterOne.Keys) { $row.('after' + $key.Substring(0, 1).ToUpper() + $key.Substring(1)) = $neAfterOne[$key] }
                $row.realizedProfit = '-150.0'
                $row.reason = 'NegativeEquity'
            }
            else {
                foreach ($key in $neAfterOne.Keys) { $row.('before' + $key.Substring(0, 1).ToUpper() + $key.Substring(1)) = $neAfterOne[$key] }
                foreach ($key in $neAfterTwo.Keys) { $row.('after' + $key.Substring(0, 1).ToUpper() + $key.Substring(1)) = $neAfterTwo[$key] }
                $row.realizedProfit = '-100.0'
                # The surviving leg is unmatched now, so the re-evaluated reason is MarginLevel.
                $row.reason = 'MarginLevel'
                $row.placedLot = '0.1'
                $row.rawRequestedLot = '0.1'
                $row.exactRequiredLot = $null
                $row.normalizedRequiredLot = '0.1'
            }
        }
        elseif ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 2 -and [long]$row.tradeNumber -eq 2) {
            $row.placedLot = '0.1'; $row.rawRequestedLot = '0.1'; $row.exactRequiredLot = $null
            $row.normalizedRequiredLot = '0.1'
        }
        elseif ([string]$row.type -eq 'basket_liquidated') {
            $row.buyLots = '0.1'; $row.sellLots = '0.1'; $row.grossLots = '0.2'; $row.netLots = '0.0'
            $row.realizedProfit = '-250.0'; $row.liquidatedRealizedProfit = '-250.0'
        }
        elseif ([string]$row.type -eq 'run_ended') { $row.engineRealizedProfit = '-10150.00' }
    }
    Write-JsonLinesFile $eventsPath $events

    $events = Read-JsonLinesArray $eventsPath
    $liquidationIds = New-Object System.Collections.Generic.List[long]
    $runEndedId = $null
    $entryTwoId = $null
    foreach ($row in $events) {
        if ([string]$row.type -eq 'forced_liquidation') { [void]$liquidationIds.Add([long]$row.id) }
        if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 2 -and [long]$row.tradeNumber -eq 2) { $entryTwoId = [long]$row.id }
        if ([string]$row.type -eq 'run_ended') { $runEndedId = [long]$row.id }
    }
    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $stopOutId) {
            foreach ($key in $neBefore.Keys) { $row.$key = $neBefore[$key] }
            $row.grossLots = '0.2'; $row.netLots = '0.0'; $row.absoluteNetLots = '0.0'
        }
        elseif ($null -ne $entryTwoId -and [long]$row.eventId -eq $entryTwoId) {
            $row.grossLots = '0.2'; $row.netLots = '0.0'; $row.absoluteNetLots = '0.0'
        }
        elseif ([string]$row.kind -eq 'periodic' -and [int]$row.openPositions -eq 2) {
            $row.grossLots = '0.2'; $row.netLots = '0.0'; $row.absoluteNetLots = '0.0'
        }
        elseif ($liquidationIds.Count -ge 1 -and [long]$row.eventId -eq $liquidationIds[0]) {
            foreach ($key in $neAfterOne.Keys) { $row.$key = $neAfterOne[$key] }
            $row.grossLots = '0.1'; $row.netLots = '-0.1'; $row.absoluteNetLots = '0.1'
        }
        elseif ($liquidationIds.Count -ge 2 -and [long]$row.eventId -eq $liquidationIds[1]) {
            foreach ($key in $neAfterTwo.Keys) { $row.$key = $neAfterTwo[$key] }
            $row.grossLots = '0.0'; $row.netLots = '0.0'; $row.absoluteNetLots = '0.0'
        }
        elseif ($null -ne $runEndedId -and [long]$row.eventId -eq $runEndedId) {
            foreach ($key in $neAfterTwo.Keys) { $row.$key = $neAfterTwo[$key] }
            $row.realizedProfit = '-10150.00'
        }
    }
    Write-JsonLinesFile $telemetryPath $telemetry

    $resultsPath = Join-Path $directory 'storage\single-anchor\results.json'
    $results = Read-JsonFile $resultsPath
    $results.realizedProfit = [decimal]-10150.0
    $results.researchAccount.Balance = [decimal]-150.0
    $results.researchAccount.Equity = [decimal]-150.0
    $results.researchAccount.FloatingProfit = [decimal]0.0
    $results.researchAccount.RealizedProfit = [decimal]-10150.0
    $episode = $results.researchMargin.StopOutEpisodes[0]
    $episode.Reason = 'NegativeEquity'
    foreach ($key in @('Balance', 'FloatingProfit', 'Equity', 'UsedMargin', 'FreeMargin', 'MarginLevelPercent', 'OpenPositions')) {
        $property = $key.Substring(0, 1).ToLower() + $key.Substring(1)
        $episode.AtTrigger.$key = $neBefore[$property]
    }
    $episode.Liquidations[0].Before.Balance = [decimal]100.0
    $episode.Liquidations[0].Before.FloatingProfit = [decimal]-150.0
    $episode.Liquidations[0].Before.Equity = [decimal]-50.0
    $episode.Liquidations[0].Before.UsedMargin = [decimal]0.0
    $episode.Liquidations[0].Before.FreeMargin = [decimal]-50.0
    $episode.Liquidations[0].Before.MarginLevelPercent = $null
    $episode.Liquidations[0].Leg.RealizedProfit = [decimal]-150.0
    $episode.Liquidations[0].After.Balance = [decimal]-50.0
    $episode.Liquidations[0].After.FloatingProfit = [decimal]-80.0
    $episode.Liquidations[0].After.Equity = [decimal]-130.0
    $episode.Liquidations[0].After.UsedMargin = $neUsedAfterOne
    $episode.Liquidations[0].After.FreeMargin = $neEquityAfterOne - $neUsedAfterOne
    $episode.Liquidations[0].After.MarginLevelPercent = $neEquityAfterOne / $neUsedAfterOne * 100
    $episode.Liquidations[1].Before = $episode.Liquidations[0].After
    $episode.Liquidations[1].Leg.RealizedProfit = [decimal]-100.0
    $episode.Liquidations[1].After.Balance = [decimal]-150.0
    $episode.Liquidations[1].After.FloatingProfit = [decimal]0.0
    $episode.Liquidations[1].After.Equity = [decimal]-150.0
    $episode.Liquidations[1].After.UsedMargin = [decimal]0.0
    $episode.Liquidations[1].After.FreeMargin = [decimal]-150.0
    $episode.Liquidations[1].After.MarginLevelPercent = $null
    $episode.AfterLiquidation = $episode.Liquidations[1].After
    $episode.Liquidations[0].Leg.Reason = 'NegativeEquity'
    $episode.Liquidations[1].Leg.Reason = 'MarginLevel'
    $results.researchMargin.CurrentUsedMargin = [decimal]0.0
    $results.researchMargin.CurrentFreeMargin = [decimal]-150.0
    $results.researchMargin.CurrentMarginLevelPercent = $null
    $results.researchMargin.MarginCallActive = $false
    $results.researchMargin.MarginCallEpisodes = 0
    $results.researchMargin.MarginCallObservations = 0
    $basketTwoRecord = @($results.closedBaskets | Where-Object { [long]$_.Sequence -eq 2 })[0]
    $basketTwoRecord.BuyLots = [decimal]0.1
    $basketTwoRecord.SellLots = [decimal]0.1
    $basketTwoRecord.GrossLots = [decimal]0.2
    $basketTwoRecord.NetLots = [decimal]0.0
    $basketTwoRecord.RealizedProfit = [decimal]-250.0
    $basketTwoRecord.LiquidatedRealizedProfit = [decimal]-250.0
    $episode.Liquidations[1].Leg.PlacedLot = [decimal]0.1
    $episode.Liquidations[1].Leg.RawRequestedLot = [decimal]0.1
    $episode.Liquidations[1].Leg.NormalizedRequiredLot = [decimal]0.1
    $basketTwoRecord.LiquidationTrace[1].PlacedLot = [decimal]0.1
    $basketTwoRecord.LiquidationTrace[1].RawRequestedLot = [decimal]0.1
    $basketTwoRecord.LiquidationTrace[1].NormalizedRequiredLot = [decimal]0.1
    $basketTwoRecord.LiquidationTrace[1].Reason = 'MarginLevel'
    Write-JsonFile $resultsPath $results

    $manifestPath = Get-ArtifactPath $directory 'manifest.json'
    $manifest = Read-JsonFile $manifestPath
    $manifest.counters.engineRealizedProfit = '-10150.00'
    # A producer never retains a zero-count key for a type it did not emit.
    foreach ($removedType in @('margin_call_entered', 'margin_call_left')) {
        $manifest.eventCounts.PSObject.Properties.Remove($removedType)
    }
    Write-JsonFile $manifestPath $manifest
    Repair-PackageIntegrity $directory @('events.jsonl', 'telemetry-2019.jsonl')
}

# Turns a copy of the synthetic base package into a valid terminal hard-BE violation run: one
# hard_breakeven_violated event at the faulting quote and the documented failure identity.
# Turns a copy of the synthetic base package into a terminal hard-BE violation run that matches the
# real engine: the tail order filled and entered the basket ledger, then the engine threw before
# EntriesOpened/EntryOpened and before any strategy continuation. The faulting leg is therefore in
# the final open basket state without a normal entry_executed event, and no later close occurs.
function New-HardBreakevenViolationFixture([string]$directory) {
    $failureTime = '2019-01-02T02:12:00.000Z'
    # Capture the faulting trade-5 post-fill snapshot before its normal entry event is removed:
    # the engine observes the fill before it re-verifies hard-BE and raises the diagnostic.
    $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
    $events = Read-JsonLinesArray $eventsPath
    $faultingEntryId = $null
    foreach ($row in $events) {
        if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 3 -and [long]$row.tradeNumber -eq 5) { $faultingEntryId = [long]$row.id }
    }
    if ($null -eq $faultingEntryId) { throw 'the faulting trade-5 entry event is missing' }
    $telemetry = Read-JsonLinesArray (Get-ArtifactPath $directory 'telemetry-2019.jsonl')
    $postFillSnapshot = $null
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $faultingEntryId) { $postFillSnapshot = $row }
    }
    if ($null -eq $postFillSnapshot) { throw 'the faulting trade-5 post-fill snapshot is missing' }
    Remove-EventsByFilter $directory {
        param($row)
        $type = [string]$row.type
        if ($type -eq 'strategy_exit' -and [long]$row.basket -eq 3) { return $true }
        if ($type -eq 'entry_executed' -and [long]$row.basket -eq 3 -and [long]$row.tradeNumber -eq 5) { return $true }
        return $false
    }
    $events = Read-JsonLinesArray $eventsPath
    $rejectionIndex = -1
    for ($i = 0; $i -lt $events.Count; $i++) {
        if ([string]$events[$i].type -eq 'entry_rejected' -and [long]$events[$i].basket -eq 3) { $rejectionIndex = $i }
    }
    if ($rejectionIndex -lt 0) { throw 'the rejected tail attempt is missing' }
    $snapshotBase = $postFillSnapshot
    $payload = [ordered]@{
        type = 'hard_breakeven_violated'; basket = 3; tradeNumber = 5; side = 'Buy'; quoteSequence = 306
        time = $failureTime; bid = '1013.0'; ask = '1013.4'; placedLot = '0.5'; fillPrice = '1013.4'
        hardBreakevenTarget = '1000.0'; projectedProfitAfterFill = '-0.5'; sizingProjectedProfitAfter = '15.0'
        message = 'Synthetic hard-BE violation.'
    }
    # The diagnostic snapshot is the exact post-fill account state (the ledger and the account
    # both already reflect the faulting fill).
    Insert-EventAndSnapshot $directory ($rejectionIndex + 1) $payload $snapshotBase @{
        time = $failureTime; quoteSequence = 306
    }

    $resultsPath = Join-Path $directory 'storage\single-anchor\results.json'
    $results = Read-JsonFile $resultsPath
    $results.completed = $false
    $results.failure = [pscustomobject][ordered]@{
        Kind = 'StrategyInvariant'; Condition = 'HardBreakevenViolatedByFill'
        Message = 'Synthetic hard-BE violation.'
        Quote = [ordered]@{
            Time = $failureTime; Bid = [decimal]1013.0; Ask = [decimal]1013.4
            Mid = [decimal]1013.2; Spread = [decimal]0.4; IsValid = $true
        }
    }
    $results | Add-Member -NotePropertyName 'hardBreakevenVerification' -NotePropertyValue ([pscustomobject][ordered]@{
            StrategyDefinitionResolved = $true; HardBEVerifiedUnderConfiguredExecutionModel = $false
            Scope = 'synthetic'; Assumptions = @(); NotCovered = @()
        }) -Force
    $basketThreeRecord = @($results.closedBaskets | Where-Object { [long]$_.Sequence -eq 3 })[0]
    $results.closedBaskets = @($results.closedBaskets | Where-Object { [long]$_.Sequence -ne 3 })
    $results | Add-Member -NotePropertyName 'openBasket' -NotePropertyValue ([pscustomobject][ordered]@{
            Sequence = 3; AnchorEvent = $basketThreeRecord.AnchorEvent; CreatedTime = $basketThreeRecord.CreatedTime
            Anchor = $basketThreeRecord.Anchor; Step = [decimal]2.5; Upper = [decimal]1012.6; Lower = [decimal]1007.6
            LowerTarget = [decimal]1000.0; UpperTarget = [decimal]1020.0
            HardBreakevenModeActive = $true; TrailingActive = $false
            LegTrace = $basketThreeRecord.LegTrace; LiquidationTrace = @()
            RejectionTrace = $basketThreeRecord.RejectionTrace
            OpenPositions = 5; GrossLots = [decimal]1.5; NetLots = [decimal]0.3; AbsoluteNetLots = [decimal]0.3
            BuyLots = [decimal]0.9; SellLots = [decimal]0.6; HistoricalEntries = 5
        }) -Force
    $results.legsOpened = 7
    $results.basketsClosed = 1
    $results.quoteTicksProcessed = 306
    $results.realizedProfit = [decimal]3.48
    $results.lastProcessedQuote = [pscustomobject][ordered]@{
        Time = $failureTime; Bid = [decimal]1013.0; Ask = [decimal]1013.4
        Mid = [decimal]1013.2; Spread = [decimal]0.4; IsValid = $true
    }
    $results.researchAccount.Balance = [decimal]10003.48
    $results.researchAccount.Equity = [decimal]10003.18
    $results.researchAccount.FloatingProfit = [decimal]-0.3
    $results.researchAccount.RealizedProfit = [decimal]3.48
    $results.researchAccount.CurrentOpenPositions = 5
    $results.researchAccount.CurrentGrossLots = [decimal]1.5
    $results.researchAccount.CurrentAbsoluteNetLots = [decimal]0.3
    $results.researchMargin.CurrentUsedMargin = [decimal]300.0
    $results.researchMargin.CurrentFreeMargin = [decimal]9703.18
    $results.researchMargin.CurrentMarginLevelPercent = [decimal]10003.18 / [decimal]300.0 * 100
    $results.researchMargin.MarginCallActive = $false
    Write-JsonFile $resultsPath $results

    $events = Read-JsonLinesArray $eventsPath
    foreach ($row in $events) {
        if ([string]$row.type -eq 'run_ended') {
            $row.completed = $false
            $row.failureKind = 'StrategyInvariant'
            $row.failureCondition = 'HardBreakevenViolatedByFill'
            $row.failureMessage = 'Synthetic hard-BE violation.'
            $row.failureQuoteTime = $failureTime
            $row.failureBid = '1013.0'
            $row.failureAsk = '1013.4'
            $row.time = $failureTime
            $row.quoteTicksProcessed = 306
            $row.legsOpened = 7
            $row.basketsClosed = 1
            $row.engineRealizedProfit = '3.48'
        }
    }
    Write-JsonLinesFile $eventsPath $events

    $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
    $telemetry = Read-JsonLinesArray $telemetryPath
    $runEndedId = $null
    foreach ($row in $events) { if ([string]$row.type -eq 'run_ended') { $runEndedId = [long]$row.id } }
    foreach ($row in $telemetry) {
        if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $runEndedId) {
            $row.time = $failureTime; $row.quoteSequence = 306
            $row.balance = '10003.48'; $row.equity = '10003.18'; $row.floatingProfit = '-0.3'
            $row.realizedProfit = '3.48'; $row.usedMargin = '300.0'; $row.freeMargin = '9703.18'
            $row.marginLevelPercent = (Format-Decimal ([decimal]10003.18 / [decimal]300.0 * 100))
            $row.marginCallActive = $false; $row.openPositions = 5; $row.grossLots = '1.5'; $row.netLots = '0.3'; $row.absoluteNetLots = '0.3'
        }
    }
    Write-JsonLinesFile $telemetryPath $telemetry

    $manifestPath = Get-ArtifactPath $directory 'manifest.json'
    $manifest = Read-JsonFile $manifestPath
    $manifest.outcome.completed = $false
    $manifest.outcome.failureKind = 'StrategyInvariant'
    $manifest.outcome.failureCondition = 'HardBreakevenViolatedByFill'
    $manifest.counters.quoteTicksProcessed = 306
    $manifest.counters.legsOpened = 7
    $manifest.counters.basketsClosed = 1
    $manifest.counters.engineRealizedProfit = '3.48'
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
    [decimal]$grossLots, [decimal]$absoluteNetLots, $netLots = $null) {
    if ($null -eq $netLots) { $netLots = $absoluteNetLots }
    $freeMarginText = Format-Decimal $freeMargin
    $marginLevelText = Format-Decimal $marginLevelPercent
    $row = [ordered]@{
        kind = $kind; eventId = $eventId; time = Format-UtcZ $time; quoteSequence = $quoteSequence
        balance = Format-Decimal $balance; equity = Format-Decimal $equity; floatingProfit = Format-Decimal $floatingProfit
        floatingObservable = $floatingObservable; realizedProfit = Format-Decimal $realizedProfit
        usedMargin = Format-Decimal $usedMargin; freeMargin = $freeMarginText; marginLevelPercent = $marginLevelText
        marginCallActive = $marginCallActive; openPositions = $openPositions; grossLots = Format-Decimal $grossLots
        netLots = Format-Decimal $netLots
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
    (New-Case 'telemetry netLots sign flipped on an entry snapshot' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $entryId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'entry_executed' -and [long]$row.basket -eq 2 -and [long]$row.tradeNumber -eq 2) { $entryId = [long]$row.id }
            }
            if ($null -eq $entryId) { throw 'the entry snapshot target is missing' }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $entryId) { $row.netLots = '0.1' }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'telemetry periodic netLots sign flipped' @('telemetry-2019.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'periodic') { $row.netLots = '-0.10'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'telemetry margin_call_entered netLots sign flipped' @('telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $marginId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'margin_call_entered') { $marginId = [long]$row.id; break }
            }
            if ($null -eq $marginId) { throw 'the margin-call snapshot target is missing' }
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $marginId) { $row.netLots = '0.10' }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'telemetry netLots/absoluteNetLots mismatch on a periodic row' @('telemetry-2019.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'periodic') { $row.netLots = '0.2'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'telemetry netLots removed from an event snapshot' @('telemetry-2019.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.kind -eq 'event') { $row.PSObject.Properties.Remove('netLots'); break }
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
            foreach ($field in @('balance', 'equity', 'floatingProfit', 'realizedProfit', 'usedMargin', 'freeMargin', 'marginLevelPercent', 'marginCallActive', 'openPositions', 'grossLots', 'netLots', 'absoluteNetLots')) {
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
                    $row.netLots = '9.0'
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
                openPositions = 0; grossLots = '0.0'; netLots = '0.0'; absoluteNetLots = '0.0'
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
        }),
    (New-Case 'margin_call balance corrupted in event and snapshot together' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $enteredId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'margin_call_entered') { $enteredId = [long]$row.id; break }
            }
            foreach ($row in $events) {
                if ([long]$row.id -eq $enteredId) { $row.balance = '1.0' }
            }
            Write-JsonLinesFile $eventsPath $events
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $enteredId) { $row.balance = '1.0' }
            }
            Write-JsonLinesFile $telemetryPath $telemetry
        }),
    (New-Case 'event and snapshot quote sequence moved backwards together' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $trailingId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'trailing_activated') { $trailingId = [long]$row.id; $row.quoteSequence = 1 }
            }
            Write-JsonLinesFile $eventsPath $events
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $trailingId) { $row.quoteSequence = 1 }
            }
            Write-JsonLinesFile $telemetryPath $telemetry
        }),
    (New-Case 'first_entry_skipped event attempts changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'first_entry_skipped') { $row.attempts = 3; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'first_entry_skipped spread changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'first_entry_skipped') { $row.spread = '0.9'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'skippedFirstEntryQuotes counter changed' @() {
            param($directory)
            $path = Join-Path $directory 'storage\single-anchor\results.json'
            $results = Read-JsonFile $path
            $results.skippedFirstEntryQuotes = 4
            Write-JsonFile $path $results
        }),
    (New-Case 'run_started time moved with its snapshot' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $movedTime = '2019-01-02T00:05:00.000Z'
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $runStartedId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'run_started') { $runStartedId = [long]$row.id; $row.time = $movedTime }
            }
            Write-JsonLinesFile $eventsPath $events
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $runStartedId) { $row.time = $movedTime }
            }
            Write-JsonLinesFile $telemetryPath $telemetry
        }),
    (New-Case 'manifest.securityType' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.securityType = 'Forex'
            Write-JsonFile $path $manifest
        }),
    (New-Case 'manifest.delivered removed' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.delivered = $null
            Write-JsonFile $path $manifest
        }),
    (New-Case 'manifest telemetry shard year' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.files[1].year = 2024
            Write-JsonFile $path $manifest
        }),
    (New-Case 'manifest eventCounts fake zero key' @() {
            param($directory)
            $path = Get-ArtifactPath $directory 'manifest.json'
            $manifest = Read-JsonFile $path
            $manifest.eventCounts | Add-Member -NotePropertyName 'totally_fake_event' -NotePropertyValue 0 -Force
            Write-JsonFile $path $manifest
        }),
    (New-Case 'hard-BE entry sizingOutcome changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_executed' -and [string]$row.regime -eq 'HardBreakeven') {
                    $row.sizingOutcome = 'MadeUpOutcome'
                    break
                }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'entry_rejected maximumVolume changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_rejected') { $row.maximumVolume = '99.0'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'entry_rejected sizingOutcome changed' @('events.jsonl') {
            param($directory)
            $path = Get-ArtifactPath $directory 'events.jsonl'
            $rows = Read-JsonLinesArray $path
            foreach ($row in $rows) {
                if ([string]$row.type -eq 'entry_rejected') { $row.sizingOutcome = 'MadeUpOutcome'; break }
            }
            Write-JsonLinesFile $path $rows
        }),
    (New-Case 'stop_out MarginLevel state above the Stop Out level' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            # A consistent state (identities hold, Margin Call threshold holds) that is impossible
            # for a MarginLevel Stop Out: level 25% is above the frozen 20% Stop Out level.
            $state = @{ balance = '10000.5'; floatingProfit = '-9950.5'; equity = '50.0'; usedMargin = '200.0'; freeMargin = '-150.0'; marginLevelPercent = '25.0' }
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $stopOutId = $null
            foreach ($row in $events) {
                if ([string]$row.type -eq 'stop_out_triggered') {
                    $stopOutId = [long]$row.id
                    foreach ($key in $state.Keys) { $row.$key = $state[$key] }
                    break
                }
            }
            Write-JsonLinesFile $eventsPath $events
            $telemetryPath = Get-ArtifactPath $directory 'telemetry-2019.jsonl'
            $telemetry = Read-JsonLinesArray $telemetryPath
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq $stopOutId) {
                    foreach ($key in $state.Keys) { $row.$key = $state[$key] }
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

# Specialized valid fixtures for the account-model branches the frozen run does not contain.
$violationFixture = Join-Path $testRoot 'fixture-hard-BE-violation'
$specializedFixtures = @(
    @{ name = 'negative-equity stop-out'; directory = (Join-Path $testRoot 'fixture-negative-equity'); build = { param($d) New-NegativeEquityStopOutFixture $d } },
    @{ name = 'hard-BE violation'; directory = $violationFixture; build = { param($d) New-HardBreakevenViolationFixture $d } }
)
foreach ($fixture in $specializedFixtures) {
    $positiveTotal++
    Copy-BasePackage $baseDirectory $fixture.directory
    try {
        & $fixture.build $fixture.directory
    }
    catch {
        $script:caseFailures.Add(("the '{0}' fixture threw while preparing: {1}" -f $fixture.name, $_.Exception.Message))
        Write-Output ("ERROR:    fixture {0} ({1})" -f $fixture.name, $_.Exception.Message)
        continue
    }
    $exitCode = Invoke-PackageVerifier $fixture.directory
    if ($exitCode -eq 0) {
        $positivePassed++
        Write-Output ("VERIFIED: {0} fixture (positive)" -f $fixture.name)
    }
    else {
        $script:caseFailures.Add(("the '{0}' fixture did not verify (exit {1}): {2}" -f $fixture.name, $exitCode, $script:lastVerifierOutput))
        Write-Output ("FAILED:   {0} fixture (verifier exit {1})" -f $fixture.name, $exitCode)
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

$violationCases = @(
    (New-Case 'hard-BE violation event missing behind the failure' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            Remove-EventsByType $directory @('hard_breakeven_violated')
        }),
    (New-Case 'hard-BE violation event duplicated' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $events = Read-JsonLinesArray (Get-ArtifactPath $directory 'events.jsonl')
            $violationIndex = -1
            for ($i = 0; $i -lt $events.Count; $i++) {
                if ([string]$events[$i].type -eq 'hard_breakeven_violated') { $violationIndex = $i; break }
            }
            if ($violationIndex -lt 0) { throw 'no hard_breakeven_violated event' }
            Insert-DuplicateEvent $directory $violationIndex
        }),
    (New-Case 'terminal violation with a normal entry restored for the faulting leg' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $violationIndex = -1
            $violation = $null
            for ($i = 0; $i -lt $events.Count; $i++) {
                if ([string]$events[$i].type -eq 'hard_breakeven_violated') { $violationIndex = $i; $violation = $events[$i]; break }
            }
            if ($violationIndex -lt 0) { throw 'no hard_breakeven_violated event' }
            $payload = [ordered]@{
                type = 'entry_executed'; basket = [long]$violation.basket; tradeNumber = [long]$violation.tradeNumber
                quoteSequence = [long]$violation.quoteSequence; time = [string]$violation.time
                decisionBid = '1013.0'; decisionAsk = '1013.4'; side = [string]$violation.side
                placedLot = [string]$violation.placedLot; fillPrice = [string]$violation.fillPrice; regime = 'HardBreakeven'
                rawRequestedLot = '0.5'; exactRequiredLot = '0.5'; normalizedRequiredLot = '0.5'
                hardBreakevenTarget = '1000.0'; targetSpread = '0.5'; targetBid = '1000.0'; targetAsk = '1000.5'
                existingProfitAtTarget = '10.0'; marginalProfitPerLot = '5.0'; projectedProfitAfter = '15.0'
                sizingOutcome = 'Feasible'
            }
            $telemetry = Read-JsonLinesArray (Get-ArtifactPath $directory 'telemetry-2019.jsonl')
            $snapshotBase = $null
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq [long]$violation.id) { $snapshotBase = $row }
            }
            if ($null -eq $snapshotBase) { throw 'the violation snapshot is missing' }
            Insert-EventAndSnapshot $directory $violationIndex $payload $snapshotBase @{
                time = [string]$violation.time; quoteSequence = [long]$violation.quoteSequence
                openPositions = 5; grossLots = '1.5'; netLots = '0.3'; absoluteNetLots = '0.3'
            }
        }),
    (New-Case 'strategy continuation after the terminal violation' @('events.jsonl', 'telemetry-2019.jsonl') {
            param($directory)
            $eventsPath = Get-ArtifactPath $directory 'events.jsonl'
            $events = Read-JsonLinesArray $eventsPath
            $violationIndex = -1
            $violation = $null
            for ($i = 0; $i -lt $events.Count; $i++) {
                if ([string]$events[$i].type -eq 'hard_breakeven_violated') { $violationIndex = $i; $violation = $events[$i]; break }
            }
            if ($violationIndex -lt 0) { throw 'no hard_breakeven_violated event' }
            $payload = [ordered]@{
                type = 'basket_close_failed'; basket = [long]$violation.basket; reason = 'ExecutorFailed'
                quoteSequence = [long]$violation.quoteSequence; time = [string]$violation.time
                bid = '1013.0'; ask = '1013.4'; message = 'Synthetic continuation after the terminal violation.'
            }
            $telemetry = Read-JsonLinesArray (Get-ArtifactPath $directory 'telemetry-2019.jsonl')
            $snapshotBase = $null
            foreach ($row in $telemetry) {
                if ([string]$row.kind -eq 'event' -and [long]$row.eventId -eq [long]$violation.id) { $snapshotBase = $row }
            }
            if ($null -eq $snapshotBase) { throw 'the violation snapshot is missing' }
            Insert-EventAndSnapshot $directory ($violationIndex + 1) $payload $snapshotBase @{
                time = [string]$violation.time; quoteSequence = [long]$violation.quoteSequence
                openPositions = 5; grossLots = '1.5'; netLots = '0.3'; absoluteNetLots = '0.3'
            }
        })
)
foreach ($case in $violationCases) {
    $caseIndex++
    $caseDirectory = Join-Path $testRoot (('violation-case-{0:D2}-' -f $caseIndex) + ($case.name -replace '[^A-Za-z0-9]+', '-'))
    Copy-BasePackage $violationFixture $caseDirectory
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
$totalCases = $cases.Count + $failedCases.Count + $violationCases.Count

if ($script:caseFailures.Count -eq 0) {
    Write-Output ("PASS: {0}/{1} verifier mutation cases behaved as expected; {2}/{3} positive failed-run fixtures verified" -f $passed, $totalCases, $positivePassed, $positiveTotal)
    exit 0
}
Write-Output ("FAIL: {0}/{1} verifier mutation cases behaved as expected; {2}/{3} positive failed-run fixtures verified; {4} case(s) failed:" -f $passed, $totalCases, $positivePassed, $positiveTotal, $script:caseFailures.Count)
foreach ($failure in $script:caseFailures) { Write-Output ("  - " + $failure) }
exit 1
