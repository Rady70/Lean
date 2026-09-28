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
    if ($terminal -and $Results.failure.Kind -cne 'AccountStopOut') { throw "Only AccountStopOut is an approved terminal result for the frozen pre-liquidation baseline (got '$($Results.failure.Kind)')." }
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
        # The Phase B broker-liquidation model does not persist a terminal StopOut record; an
        # older pre-liquidation result carries one. Both shapes are accepted for a completed run,
        # but a record whose model says the run stopped must not be certified as a completion.
        $stopOut = $null
        if ($null -ne $Results.researchMargin -and $Results.researchMargin.PSObject.Properties.Name -contains 'StopOut') {
            $stopOut = $Results.researchMargin.StopOut
        }
        if ($count -ne [long]$Identity.continuousHistoryQuoteCount -or
            $delivered.semantic_digest -cne $Identity.continuousHistorySemanticDigest -or
            $last -ne (ConvertTo-BaselineUtc $Identity.continuousHistoryLastQuoteUtc) -or $null -ne $stopOut) {
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
