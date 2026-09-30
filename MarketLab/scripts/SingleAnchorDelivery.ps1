# Delivery verification for the frozen UTC/UTC native history. Never replays the history.
Set-StrictMode -Version 2.0

function ConvertTo-BaselineUtc($Value) {
    if ($null -eq $Value) { throw 'A UTC quote timestamp is missing.' }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { $date = $Value }
    else { $date = [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    if ($date.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc) }
    return $date.ToUniversalTime()
}

function Assert-BaselineQuoteEqual($Expected, $Actual) {
    if ((ConvertTo-BaselineUtc $Expected.Time) -ne (ConvertTo-BaselineUtc $Actual.Time) -or
        [decimal]$Expected.Bid -ne [decimal]$Actual.Bid -or [decimal]$Expected.Ask -ne [decimal]$Actual.Ask) {
        throw 'Terminal/delivered/engine quote evidence disagrees.'
    }
}

function Get-BaselineNativePrefix([string]$Path, [string]$Day, [long]$Count) {
    if ($Count -lt 1) { throw 'A terminal partition prefix must contain at least one quote.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $reader = $null
    try {
        $member = $Day.Replace('-', '') + '_xauusd_tick_quote.csv'
        if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -cne $member) {
            throw 'The terminal native partition has an unexpected member layout.'
        }
        $reader = [IO.StreamReader]::new($archive.Entries[0].Open())
        $midnight = [DateTime]::SpecifyKind([DateTime]::ParseExact($Day, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
        $last = $null
        for ([long]$ordinal = 1; $ordinal -le $Count; $ordinal++) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { throw 'The terminal prefix exceeds the qualified native partition.' }
            $cells = $line.Split(',')
            if ($cells.Length -ne 3) { throw 'Invalid native quote row in the terminal partition.' }
            $time = $midnight.AddTicks(([long]$cells[0]) * [TimeSpan]::TicksPerMillisecond)
            $canonicalTime = $time.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            # Native prices were already qualified as canonical exact-decimal text; the ZIP is
            # hash-anchored before this function is called. No rounding or price transformation.
            $bytes = [Text.Encoding]::UTF8.GetBytes("$ordinal|$canonicalTime|$($cells[1])|$($cells[2])`n")
            [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0)
            $last = [pscustomobject]@{ Time = $time; Bid = [decimal]::Parse($cells[1], [Globalization.CultureInfo]::InvariantCulture); Ask = [decimal]::Parse($cells[2], [Globalization.CultureInfo]::InvariantCulture) }
        }
        [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
        return [pscustomobject]@{ digest = 'sha256:' + ([BitConverter]::ToString($sha.Hash)).Replace('-', '').ToLowerInvariant(); lastQuote = $last }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $sha.Dispose()
        $archive.Dispose()
    }
}

function Assert-BaselineDelivery($Results, $Manifest, $Identity, [string]$DataFolder) {
    if ($Results.completed -isnot [bool]) { throw 'The strategy completed flag must be present and boolean.' }
    $terminal = $null -ne $Results.failure
    if ($Results.completed -eq $terminal) { throw 'The strategy completed flag contradicts its failure record.' }
    if ($terminal -and $Results.failure.Kind -cne 'AccountStopOut') { throw 'Only AccountStopOut is an approved terminal result.' }
    if ($Results.algorithmTimeZone -cne 'UTC' -or $Results.quoteTimeZone -cne 'UTC') { throw 'The baseline algorithm and quote clocks must both be UTC.' }
    $start = ConvertTo-BaselineUtc $Identity.startDate
    $end = (ConvertTo-BaselineUtc $Identity.endDate).AddDays(1).AddTicks(-1)
    if ((ConvertTo-BaselineUtc $Results.startUtc) -ne $start -or (ConvertTo-BaselineUtc $Results.endUtc) -ne $end) {
        throw 'The effective production UTC subscription window differs from the frozen window.'
    }
    $delivered = $Results.delivered
    foreach ($value in @($Results.quoteTicksProcessed, $Results.quoteOnlyQuotes, $Results.strategyEligibleQuotes, $Results.nonQuoteTicksUnused, $delivered.quote_count)) {
        if ([string]$value -cnotmatch '^\d+$') { throw 'Delivery counters must be non-negative integers.' }
    }
    $count = [long]$delivered.quote_count
    if ($count -lt 1 -or $count -ne [long]$Results.quoteTicksProcessed -or
        $count -ne ([long]$Results.quoteOnlyQuotes + [long]$Results.strategyEligibleQuotes) -or $Results.nonQuoteTicksUnused -ne 0) {
        throw 'The strategy/delivery/availability counters do not describe one complete quote stream.'
    }
    if ($delivered.semantic_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'The delivered stream has no valid semantic digest.' }
    if ((ConvertTo-BaselineUtc $delivered.first_canonical_utc) -ne (ConvertTo-BaselineUtc $Identity.continuousHistoryFirstQuoteUtc)) { throw 'The first processed quote differs from the qualified first quote.' }
    $last = ConvertTo-BaselineUtc $delivered.last_canonical_utc
    if ($last -lt (ConvertTo-BaselineUtc $delivered.first_canonical_utc) -or $last -gt (ConvertTo-BaselineUtc $Identity.continuousHistoryLastQuoteUtc)) {
        throw 'The last processed quote is outside qualified coverage.'
    }
    Assert-BaselineQuoteEqual $delivered.last_quote $Results.lastProcessedQuote
    if ((ConvertTo-BaselineUtc $delivered.last_quote.Time) -ne $last) { throw 'The delivered final timestamp contradicts its last quote.' }
    $lastDay = $last.ToString('yyyy-MM-dd')
    $expectedDays = @($Manifest.semantic.per_partition.PSObject.Properties.Name | Where-Object { -not $terminal -or $_ -cle $lastDay } | Sort-Object)
    $actualDays = @($delivered.per_partition.PSObject.Properties.Name | Sort-Object)
    if (($expectedDays -join ',') -cne ($actualDays -join ',')) { throw 'The delivered partition set is not the qualified full stream or terminal prefix.' }
    if ($actualDays -cnotcontains $lastDay) { throw 'The final processed quote has no delivered qualified partition.' }
    [long]$total = 0
    $partial = $false
    foreach ($day in $actualDays) {
        $expected = $Manifest.semantic.per_partition.$day
        $actual = $delivered.per_partition.$day
        if ([string]$actual.quote_count -cnotmatch '^[1-9]\d*$') { throw "Invalid delivered partition count: $day" }
        $total += [long]$actual.quote_count
        if ($terminal -and $day -ceq $lastDay -and [long]$actual.quote_count -lt [long]$expected.accepted_row_count) {
            $partial = $true
            $native = @($Manifest.native.partitions | Where-Object { [IO.Path]::GetFileName($_.zip_relative_path) -ceq ($day.Replace('-', '') + '_quote.zip') })
            if ($native.Count -ne 1) { throw 'Cannot resolve the terminal native partition.' }
            $prefix = Get-BaselineNativePrefix (Join-Path $DataFolder $native[0].zip_relative_path) $day ([long]$actual.quote_count)
            if ($prefix.digest -cne $actual.semantic_digest) { throw 'The terminal-day delivery is not the exact qualified quote prefix.' }
            Assert-BaselineQuoteEqual $prefix.lastQuote $delivered.last_quote
        } elseif ([long]$actual.quote_count -ne [long]$expected.accepted_row_count -or $actual.semantic_digest -cne $expected.semantic_digest) {
            throw "Delivered count/digest differs from the qualified partition: $day"
        }
    }
    if ($total -ne $count) { throw 'Partition quote counts do not sum to the processed count.' }
    if (-not $terminal) {
        if ($count -ne [long]$Identity.continuousHistoryQuoteCount -or
            $delivered.semantic_digest -cne $Identity.continuousHistorySemanticDigest -or
            $last -ne (ConvertTo-BaselineUtc $Identity.continuousHistoryLastQuoteUtc) -or $null -ne $Results.researchMargin.StopOut) {
            throw 'Normal completion does not match the qualified full population or has a stop-out record.'
        }
    } else {
        Assert-BaselineQuoteEqual $Results.failure.Quote $delivered.last_quote
        $stop = $Results.researchMargin.StopOut
        if ($null -eq $stop -or (ConvertTo-BaselineUtc $stop.Time) -ne $last -or $stop.Reason -cne $Results.failure.Condition -or
            $stop.OpenPositions -lt 1 -or $stop.OpenPositions -ne $Results.researchAccount.CurrentOpenPositions -or
            $stop.Equity -ne $Results.researchAccount.Equity -or $stop.UsedMargin -ne $Results.researchMargin.CurrentUsedMargin) {
            throw 'AccountStopOut does not match the final research account and failure quote.'
        }
        $validReason = ($stop.Reason -ceq 'MarginLevel' -and $stop.UsedMargin -gt 0 -and $null -ne $stop.MarginLevelPercent -and $stop.MarginLevelPercent -le 20) -or
            ($stop.Reason -ceq 'NegativeEquity' -and $stop.UsedMargin -eq 0 -and $null -eq $stop.MarginLevelPercent -and $stop.Equity -lt 0)
        if (-not $validReason) { throw 'The terminal state does not satisfy the frozen stop-out rule.' }
    }
    return [pscustomobject]@{ mode = $(if ($terminal) { 'qualified-prefix' } else { 'qualified-full-stream' }); quoteCount = $count; partitions = $actualDays.Count; terminalDayPrefixRead = $partial }
}

function Assert-BrokerLiquidationDelivery($Results, $Manifest, $Identity, [string]$DataFolder, [switch]$AllowTerminalFailure) {
    # Current-model (Phase B) delivery verification. Deliberately separate from the frozen
    # pre-liquidation Assert-BaselineDelivery above, so the historical verifier stays strictly
    # bound to the AccountStopOut result shape and the two model revisions are never conflated.
    # The identifier check is explicit: a result must name its broker model.
    # Without -AllowTerminalFailure the run must be a completed full qualified stream.
    # With -AllowTerminalFailure a run that carries completed=false and a recorded failure is
    # verified as the exact qualified prefix ending at its last processed quote; every preceding
    # partition must match and the partial terminal day is checked against its native ZIP prefix.
    if ($null -eq $Results.modelRevision -or $Results.modelRevision -cne 'marketlab-single-anchor-broker-liquidation-v1') {
        throw "Not a Phase B broker-liquidation result: modelRevision is '$($Results.modelRevision)'."
    }
    if ($Results.stopOutModel -cne 'BrokerLiquidation') {
        throw "Not a Phase B broker-liquidation result: stopOutModel is '$($Results.stopOutModel)'."
    }
    if ($Results.completed -isnot [bool]) { throw 'The strategy completed flag must be present and boolean.' }
    $hasFailure = $null -ne $Results.failure
    $terminal = $false
    if ($AllowTerminalFailure) {
        if ($Results.completed -eq $false -and $hasFailure) {
            if ([string]::IsNullOrWhiteSpace([string]$Results.failure.Kind)) { throw 'The terminal failure record carries no kind.' }
            $terminal = $true
        }
        elseif ($Results.completed -ne $true -or $hasFailure) {
            throw 'The completed flag and the failure record contradict each other.'
        }
    }
    elseif ($Results.completed -ne $true -or $hasFailure) {
        throw 'A Phase B qualification run must complete without a terminal failure.'
    }
    if ($Results.algorithmTimeZone -cne 'UTC' -or $Results.quoteTimeZone -cne 'UTC') { throw 'The qualification algorithm and quote clocks must both be UTC.' }
    $start = ConvertTo-BaselineUtc $Identity.startDate
    $end = (ConvertTo-BaselineUtc $Identity.endDate).AddDays(1).AddTicks(-1)
    if ((ConvertTo-BaselineUtc $Results.startUtc) -ne $start -or (ConvertTo-BaselineUtc $Results.endUtc) -ne $end) {
        throw 'The effective production UTC subscription window differs from the requested window.'
    }
    $delivered = $Results.delivered
    foreach ($value in @($Results.quoteTicksProcessed, $Results.quoteOnlyQuotes, $Results.strategyEligibleQuotes, $Results.nonQuoteTicksUnused, $delivered.quote_count)) {
        if ([string]$value -cnotmatch '^\d+$') { throw 'Delivery counters must be non-negative integers.' }
    }
    $count = [long]$delivered.quote_count
    if ($count -lt 1 -or $count -ne [long]$Results.quoteTicksProcessed -or
        $count -ne ([long]$Results.quoteOnlyQuotes + [long]$Results.strategyEligibleQuotes) -or $Results.nonQuoteTicksUnused -ne 0) {
        throw 'The strategy/delivery/availability counters do not describe one complete quote stream.'
    }
    if ($delivered.semantic_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'The delivered stream has no valid semantic digest.' }
    if ((ConvertTo-BaselineUtc $delivered.first_canonical_utc) -ne (ConvertTo-BaselineUtc $Identity.continuousHistoryFirstQuoteUtc)) { throw 'The first processed quote differs from the qualified first quote.' }
    $last = ConvertTo-BaselineUtc $delivered.last_canonical_utc
    if ($last -lt (ConvertTo-BaselineUtc $delivered.first_canonical_utc) -or $last -gt (ConvertTo-BaselineUtc $Identity.continuousHistoryLastQuoteUtc)) {
        throw 'The last processed quote is outside qualified coverage.'
    }
    Assert-BaselineQuoteEqual $delivered.last_quote $Results.lastProcessedQuote
    if ((ConvertTo-BaselineUtc $delivered.last_quote.Time) -ne $last) { throw 'The delivered final timestamp contradicts its last quote.' }
    $lastDay = $last.ToString('yyyy-MM-dd')
    if ($terminal) {
        $expectedDays = @($Manifest.semantic.per_partition.PSObject.Properties.Name | Where-Object { $_ -cle $lastDay } | Sort-Object)
    }
    else {
        $expectedDays = @($Manifest.semantic.per_partition.PSObject.Properties.Name | Sort-Object)
    }
    $actualDays = @($delivered.per_partition.PSObject.Properties.Name | Sort-Object)
    if (($expectedDays -join ',') -cne ($actualDays -join ',')) { throw 'The delivered partition set is not the qualified full stream or terminal prefix.' }
    if ($actualDays -cnotcontains $lastDay) { throw 'The final processed quote has no delivered qualified partition.' }
    [long]$total = 0
    $partial = $false
    foreach ($day in $actualDays) {
        $expected = $Manifest.semantic.per_partition.$day
        $actual = $delivered.per_partition.$day
        if ([string]$actual.quote_count -cnotmatch '^[1-9]\d*$') { throw "Invalid delivered partition count: $day" }
        $total += [long]$actual.quote_count
        if ($terminal -and $day -ceq $lastDay -and [long]$actual.quote_count -lt [long]$expected.accepted_row_count) {
            $partial = $true
            $native = @($Manifest.native.partitions | Where-Object { [IO.Path]::GetFileName($_.zip_relative_path) -ceq ($day.Replace('-', '') + '_quote.zip') })
            if ($native.Count -ne 1) { throw 'Cannot resolve the terminal native partition.' }
            $prefix = Get-BaselineNativePrefix (Join-Path $DataFolder $native[0].zip_relative_path) $day ([long]$actual.quote_count)
            if ($prefix.digest -cne $actual.semantic_digest) { throw 'The terminal-day delivery is not the exact qualified quote prefix.' }
            Assert-BaselineQuoteEqual $prefix.lastQuote $delivered.last_quote
        }
        elseif ([long]$actual.quote_count -ne [long]$expected.accepted_row_count -or $actual.semantic_digest -cne $expected.semantic_digest) {
            throw "Delivered count/digest differs from the qualified partition: $day"
        }
    }
    if ($total -ne $count) { throw 'Partition quote counts do not sum to the processed count.' }
    if ($terminal) {
        # The terminal prefix's global delivered semantic digest is recorded but deliberately not
        # independently recomputed here: the verified identity is the per-partition set and the
        # native terminal-day ZIP prefix, not a global ordinal digest that a prefix cannot reuse.
        return [pscustomobject]@{ mode = 'phase-b-terminal-prefix'; quoteCount = $count; partitions = $actualDays.Count; terminalDayPrefixRead = $partial; failureKind = [string]$Results.failure.Kind; globalSemanticDigestVerified = $false }
    }
    if ($count -ne [long]$Identity.continuousHistoryQuoteCount -or
        $delivered.semantic_digest -cne $Identity.continuousHistorySemanticDigest -or
        $last -ne (ConvertTo-BaselineUtc $Identity.continuousHistoryLastQuoteUtc)) {
        throw 'A Phase B qualification run must deliver the full qualified stream.'
    }
    return [pscustomobject]@{ mode = 'phase-b-full-stream'; quoteCount = $count; partitions = $actualDays.Count; terminalDayPrefixRead = $false; globalSemanticDigestVerified = $true }
}
