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
  * every significant event's snapshot is the account state at that event's exact time and quote,
    and every event that carries account values (Stop Out, Margin Call, forced liquidation) is
    compared field by field to its own snapshot;
  * the hard-BE activation snapshot is proven to be the pre-attempt state derived from the
    parity-verified entry/liquidation events, and trailing activation thresholds are re-derived
    from the parity-verified anchor step, surviving inventory and parameters;
  * the causal lifecycle order is asserted: hard-BE activation before its enabling attempt,
    Margin Call entry/exit alternation, Stop Out before its episode's first forced liquidation and
    after the previous episode's last one, basket_liquidated after the last forced close, trailing
    activation before the close, ascending same-quote liquidation ordinals;
  * telemetry times are non-decreasing in manifest shard order and consecutive periodic samples are
    at least manifest.telemetryIntervalSeconds apart while positions stay open;
  * every authoritative payload structure is compared, field by field, against the event stream:
    anchors, entries, strategy exits, forced liquidations, Stop Out episodes, rejection episodes,
    hard-BE activations, trailing activations, Margin Call transitions, the manifest identity,
    outcome and payload order, the run-end identity/counters/delivery/failure and the run-end
    account snapshot. A failed run's run-end time follows the documented
    max(lastProcessedQuote, failureQuote) rule and its failure identity is compared completely.

The payload parity comparison is tolerant about representation (JSON number vs exact decimal
string, result timestamps with or without the trailing 'Z') but exact about value, case and
ordering. It compares at most 200 accumulated failures and appends a truncation note afterwards.

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

$script:failures = New-Object System.Collections.Generic.List[string]
$script:checks = 0
$script:parityChecks = 0
$script:maxFailures = 200
$script:failuresTruncated = $false

function Add-Failure([string]$message) {
    if ($script:failures.Count -lt $script:maxFailures) {
        [void]$script:failures.Add($message)
    }
    elseif (-not $script:failuresTruncated) {
        $script:failuresTruncated = $true
        [void]$script:failures.Add("additional failures were truncated after the $($script:maxFailures)-failure cap")
    }
}

function Test-Check([bool]$condition, [string]$message) {
    $script:checks++
    if (-not $condition) { Add-Failure $message }
}

# A payload-parity comparison: it is a regular check plus it is counted as a parity comparison so
# the verification record proves that payload parity was actually evaluated.
function Test-ParityCheck([bool]$condition, [string]$message) {
    $script:parityChecks++
    Test-Check $condition $message
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

# The authoritative results.json writes DateTime values without the trailing 'Z'. Depending on the
# host, ConvertFrom-Json reads such a value as a DateTime (Windows PowerShell 5.1) or keeps the raw
# text (the exact reader below on PowerShell 7). Both forms are the same UTC instant.
function Convert-ResultTime([object]$value, [string]$field) {
    if ($null -eq $value) { throw "the field '$field' is null" }
    if ($value -is [datetime]) {
        $time = [datetime]$value
        if ($time.Kind -eq [System.DateTimeKind]::Utc) { return $time }
        if ($time.Kind -eq [System.DateTimeKind]::Local) { return $time.ToUniversalTime() }
        return [datetime]::SpecifyKind($time, [System.DateTimeKind]::Utc)
    }
    if ($value -isnot [string]) { throw "the field '$field' is not a timestamp" }
    $text = [string]$value
    if ($text.EndsWith('Z')) {
        # The authoritative writer emits optional fractional digits; the tolerant parser accepts
        # both the canonical three-digit package form and the result form without them.
        try {
            return [datetime]::Parse(
                $text,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        catch {
            throw "the authoritative field '$field' is not a timestamp: '$value'"
        }
    }
    try {
        return [datetime]::Parse(
            $text,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    catch {
        throw "the authoritative field '$field' is not a timestamp: '$value'"
    }
}

function Get-Property([object]$object, [string]$name) {
    if ($null -eq $object) { return $null }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Has-Property([object]$object, [string]$name) {
    if ($null -eq $object) { return $false }
    return ($null -ne $object.PSObject.Properties[$name])
}

# Returns the events of one type in stream order. Kept as a function (not a scriptblock) because
# PowerShell refuses to wrap a hashtable-indexed List in @() inside a scriptblock.
function Get-EventsOfType([string]$name) {
    if ($script:eventsByType.ContainsKey($name)) { return $script:eventsByType[$name] }
    return @()
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

# ---- Exact JSON reader -----------------------------------------------------
# Windows PowerShell 5.1's ConvertFrom-Json reads JSON fractional numbers as System.Decimal and
# keeps every emitted digit. PowerShell 7's ConvertFrom-Json reads them as System.Double and loses
# precision beyond ~15 significant digits, which would make the exact-decimal parity comparison
# impossible. On PowerShell 7 the reader below uses System.Text.Json and converts every JSON number
# from its raw text with [decimal]::Parse, so both hosts expose the same authoritative values.

$script:systemTextJson = $false
try {
    Add-Type -AssemblyName 'System.Text.Json' -ErrorAction Stop
    $script:systemTextJson = ($null -ne ('System.Text.Json.JsonDocument' -as [type]))
}
catch {
    $script:systemTextJson = $false
}

function ConvertFrom-ExactJsonElement([object]$element) {
    $kind = [string]$element.ValueKind
    if ($kind -eq 'Object') {
        $properties = [ordered]@{}
        foreach ($property in $element.EnumerateObject()) {
            $properties[$property.Name] = ConvertFrom-ExactJsonElement $property.Value
        }
        return [pscustomobject]$properties
    }
    if ($kind -eq 'Array') {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $element.EnumerateArray()) {
            [void]$items.Add((ConvertFrom-ExactJsonElement $item))
        }
        return ,$items.ToArray()
    }
    if ($kind -eq 'String') { return $element.GetString() }
    if ($kind -eq 'Number') {
        $raw = $element.GetRawText()
        try {
            return [decimal]::Parse(
                $raw,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            return [double]::Parse(
                $raw,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ($kind -eq 'True') { return $true }
    if ($kind -eq 'False') { return $false }
    return $null
}

function Read-ExactJson([string]$path) {
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($script:systemTextJson) {
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { return ConvertFrom-ExactJsonElement $document.RootElement }
        finally { $document.Dispose() }
    }
    return ($text | ConvertFrom-Json)
}

# ---- Tolerant value comparison ---------------------------------------------

function Convert-JsonDecimal([object]$value, [string]$where) {
    if ($null -eq $value) { return $null }
    if ($value -is [decimal]) { return [decimal]$value }
    if ($value -is [double] -or $value -is [single]) { return [decimal]$value }
    if ($value -is [int] -or $value -is [long] -or $value -is [int16] -or $value -is [int64] -or $value -is [byte]) {
        return [decimal]$value
    }
    if ($value -is [string]) {
        $text = ([string]$value).Trim()
        try {
            return [decimal]::Parse(
                $text,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            Add-Failure "$where is not a canonical decimal: '$value'"
            return $null
        }
    }
    Add-Failure "$where has an unsupported numeric type $($value.GetType().Name)"
    return $null
}

function Test-TextParity([object]$actual, [object]$expected, [string]$where) {
    $script:parityChecks++
    $script:checks++
    if ($null -eq $actual -and $null -eq $expected) { return }
    $left = if ($null -eq $actual) { '<null>' } else { [string]$actual }
    $right = if ($null -eq $expected) { '<null>' } else { [string]$expected }
    if ($left -cne $right) {
        Add-Failure "$where parity: package '$left' does not equal authoritative '$right'"
    }
}

function Test-NumberParity([object]$actual, [object]$expected, [string]$where) {
    $script:parityChecks++
    $script:checks++
    if ($null -eq $actual -and $null -eq $expected) { return }
    if ($null -eq $actual -or $null -eq $expected) {
        Add-Failure "$where parity: null mismatch (package '$actual', authoritative '$expected')"
        return
    }
    $left = Convert-JsonDecimal $actual $where
    $right = Convert-JsonDecimal $expected $where
    if ($null -eq $left -or $null -eq $right) { return }
    if ($left -ne $right) {
        Add-Failure "$where parity: package '$([string]$actual)' does not equal authoritative '$([string]$expected)'"
    }
}

# Account-arithmetic identities (free margin, margin level) are exact decimal combinations in
# ResearchAccount; the comparison allows only a numeric-scale tolerance (the frozen run contains
# last-digit decimal scale artifacts of order 1e-25, far below any meaningful corruption).
function Test-NumberApproxParity([object]$actual, [object]$expected, [string]$where, [decimal]$absoluteTolerance = [decimal]'1e-20') {
    $script:parityChecks++
    $script:checks++
    if ($null -eq $actual -and $null -eq $expected) { return }
    if ($null -eq $actual -or $null -eq $expected) {
        Add-Failure "${where}: null mismatch (actual '$actual', derived '$expected')"
        return
    }
    $left = Convert-JsonDecimal $actual $where
    $right = Convert-JsonDecimal $expected $where
    if ($null -eq $left -or $null -eq $right) { return }
    if ([math]::Abs($left - $right) -gt $absoluteTolerance) {
        Add-Failure "${where}: actual '$([string]$actual)' differs from the derived '$([string]$expected)' by more than $absoluteTolerance"
    }
}

function Test-BoolParity([object]$actual, [object]$expected, [string]$where) {
    $script:parityChecks++
    $script:checks++
    if ($null -eq $actual -and $null -eq $expected) { return }
    if ($null -eq $actual -or $null -eq $expected) {
        Add-Failure "$where parity: null mismatch (package '$actual', authoritative '$expected')"
        return
    }
    $left = [System.Convert]::ToBoolean($actual)
    $right = [System.Convert]::ToBoolean($expected)
    if ($left -ne $right) {
        Add-Failure "$where parity: package '$left' does not equal authoritative '$right'"
    }
}

function Test-TimeParity([object]$actual, [object]$expected, [string]$where) {
    $script:parityChecks++
    $script:checks++
    if ($null -eq $actual -and $null -eq $expected) { return }
    if ($null -eq $actual -or $null -eq $expected) {
        Add-Failure "$where parity: null time mismatch (package '$actual', authoritative '$expected')"
        return
    }
    $left = $null
    $right = $null
    try { $left = Convert-UtcTime $actual "$where (package)" } catch { Add-Failure $_.Exception.Message; return }
    try { $right = Convert-ResultTime $expected "$where (authoritative)" } catch { Add-Failure $_.Exception.Message; return }
    if ($left -ne $right) {
        Add-Failure "$where parity: package time '$($left.ToString('o'))' does not equal authoritative time '$($right.ToString('o'))'"
    }
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

    $results = Read-ExactJson $resultsPath
    $manifestPath = Join-Path $replayDirectory 'manifest.json'
    $eventsPath = Join-Path $replayDirectory 'events.jsonl'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Write-Error "manifest.json is missing"; exit 1 }
    if (-not (Test-Path -LiteralPath $eventsPath -PathType Leaf)) { Write-Error "events.jsonl is missing"; exit 1 }
    $manifest = Read-ExactJson $manifestPath

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

    # ---- Manifest parameter and session provenance parity ----
    $manifestParameters = Get-Property $manifest 'parameters'
    $resultParameters = Get-Property $results 'parameters'
    if ($null -eq $manifestParameters -or $null -eq $resultParameters) {
        Add-Failure "manifest.parameters or results.parameters is missing"
    }
    else {
        $parameterNames = @($manifestParameters.PSObject.Properties | ForEach-Object { $_.Name })
        Test-ParityCheck ($parameterNames.Count -eq 21) "manifest.parameters has $($parameterNames.Count) fields, expected 21"
        foreach ($property in $manifestParameters.PSObject.Properties) {
            $resultValue = Get-Property $resultParameters $property.Name
            if ($null -eq $resultValue) { Add-Failure "results.parameters.$($property.Name) is missing"; continue }
            if ($property.Value -is [bool] -or $resultValue -is [bool]) {
                Test-BoolParity $property.Value $resultValue "manifest.parameters.$($property.Name)"
            }
            else {
                # The exact-decimal contract: a numeric parameter is a JSON string in the
                # manifest, so it cannot be re-read as an IEEE double.
                if ($property.Value -isnot [string]) {
                    Add-Failure "manifest.parameters.$($property.Name) is a JSON $($property.Value.GetType().Name), not an exact string"
                }
                Test-NumberParity $property.Value $resultValue "manifest.parameters.$($property.Name)"
            }
        }
        foreach ($property in $resultParameters.PSObject.Properties) {
            if ($null -eq (Get-Property $manifestParameters $property.Name)) {
                Add-Failure "manifest.parameters.$($property.Name) is missing"
            }
        }
    }

    $manifestMarginParameters = Get-Property $manifest 'marginParameters'
    $resultMarginParameters = Get-Property (Get-Property $results 'researchMargin') 'Parameters'
    if ($null -eq $manifestMarginParameters -or $null -eq $resultMarginParameters) {
        Add-Failure "manifest.marginParameters or researchMargin.Parameters is missing"
    }
    else {
        $marginParameterNames = @($manifestMarginParameters.PSObject.Properties | ForEach-Object { $_.Name })
        Test-ParityCheck ($marginParameterNames.Count -eq 4) "manifest.marginParameters has $($marginParameterNames.Count) fields, expected 4"
        foreach ($property in $manifestMarginParameters.PSObject.Properties) {
            $resultValue = Get-Property $resultMarginParameters $property.Name
            if ($null -eq $resultValue) { Add-Failure "researchMargin.Parameters.$($property.Name) is missing"; continue }
            if ($property.Value -isnot [string]) {
                Add-Failure "manifest.marginParameters.$($property.Name) is a JSON $($property.Value.GetType().Name), not an exact string"
            }
            Test-NumberParity $property.Value $resultValue "manifest.marginParameters.$($property.Name)"
        }
        foreach ($property in $resultMarginParameters.PSObject.Properties) {
            if ($null -eq (Get-Property $manifestMarginParameters $property.Name)) {
                Add-Failure "manifest.marginParameters.$($property.Name) is missing"
            }
        }
    }

    $manifestSession = Get-Property $manifest 'sessionMap'
    $resultSession = Get-Property $results 'sessionMap'
    if ($null -ne $manifestSession -and $null -ne $resultSession) {
        Test-TextParity (Get-Property $manifestSession 'Map') (Get-Property $resultSession 'Map') "manifest.sessionMap.Map"
        Test-TextParity (Get-Property $manifestSession 'Sha256') (Get-Property $resultSession 'Sha256') "manifest.sessionMap.Sha256"
        Test-TextParity (Get-Property $manifestSession 'Symbol') (Get-Property $resultSession 'Symbol') "manifest.sessionMap.Symbol"
        Test-TextParity (Get-Property $manifestSession 'JunctionTimeZone') (Get-Property $resultSession 'JunctionTimeZone') "manifest.sessionMap.JunctionTimeZone"
        Test-NumberParity (Get-Property $manifestSession 'Sessions') (Get-Property $resultSession 'Sessions') "manifest.sessionMap.Sessions"
        Test-NumberParity (Get-Property $manifestSession 'SourceFileCount') (Get-Property $resultSession 'SourceFileCount') "manifest.sessionMap.SourceFileCount"
        Test-NumberParity (Get-Property $manifestSession 'SourceRowCount') (Get-Property $resultSession 'SourceRowCount') "manifest.sessionMap.SourceRowCount"
        Test-BoolParity (Get-Property $manifestSession 'FinalSessionEndObservable') (Get-Property $resultSession 'FinalSessionEndObservable') "manifest.sessionMap.FinalSessionEndObservable"
        Test-TextParity (Get-Property $manifestSession 'SourceSha256Aggregate') (Get-Property $resultSession 'SourceSha256Aggregate') "manifest.sessionMap.SourceSha256Aggregate"
        Test-TextParity (Get-Property $manifestSession 'FirstSessionStartUtc') (Get-Property $resultSession 'FirstSessionStartUtc') "manifest.sessionMap.FirstSessionStartUtc"
        Test-TextParity (Get-Property $manifestSession 'SourceFirstQuoteUtc') (Get-Property $resultSession 'SourceFirstQuoteUtc') "manifest.sessionMap.SourceFirstQuoteUtc"
        # The manifest names the coverage end "SourceLastQuoteUtc"; the result names it
        # "SourceCoverageEndUtc". The recorder writes the same instant under both names.
        Test-TimeParity (Get-Property $manifestSession 'SourceLastQuoteUtc') (Get-Property $resultSession 'SourceCoverageEndUtc') "manifest.sessionMap.SourceLastQuoteUtc"
    }
    elseif ($null -ne $manifestSession -or $null -ne $resultSession) {
        Add-Failure "manifest.sessionMap and results.sessionMap are not both present"
    }

    $manifestDelivered = Get-Property $manifest 'delivered'
    $resultDelivered = Get-Property $results 'delivered'
    if ($null -ne $manifestDelivered -and $null -ne $resultDelivered) {
        Test-NumberParity (Get-Property $manifestDelivered 'quoteCount') (Get-Property $resultDelivered 'quote_count') `
            "manifest.delivered.quoteCount"
        Test-TextParity (Get-Property $manifestDelivered 'semanticDigest') (Get-Property $resultDelivered 'semantic_digest') `
            "manifest.delivered.semanticDigest"
        Test-TimeParity (Get-Property $manifestDelivered 'firstCanonicalUtc') (Get-Property $resultDelivered 'first_canonical_utc') `
            "manifest.delivered.firstCanonicalUtc"
        Test-TimeParity (Get-Property $manifestDelivered 'lastCanonicalUtc') (Get-Property $resultDelivered 'last_canonical_utc') `
            "manifest.delivered.lastCanonicalUtc"
    }
    elseif ($null -ne $manifestDelivered -or $null -ne $resultDelivered) {
        Add-Failure "manifest.delivered and results.delivered are not both present"
    }

    # Manifest run-identity, time zone and outcome parity. The manifest is part of the committed
    # package, so its identity fields must equal the authoritative result, not just each other.
    # securityType is the frozen contract identity of this finalized path (a Dukascopy CFD), and
    # the package only exists for the research-account + margin path, so both flags are true.
    Test-TextParity (Get-Property $manifest 'securityType') 'Cfd' "manifest.securityType (frozen contract)"
    Test-BoolParity (Get-Property $manifest 'researchAccountEnabled') $true "manifest.researchAccountEnabled"
    Test-BoolParity (Get-Property $manifest 'marginEnabled') $true "manifest.marginEnabled"
    Test-TextParity (Get-Property $manifest 'algorithmTimeZone') (Get-Property $results 'algorithmTimeZone') "manifest.algorithmTimeZone"
    Test-TextParity (Get-Property $manifest 'quoteTimeZone') (Get-Property $results 'quoteTimeZone') "manifest.quoteTimeZone"
    # The manifest serializes the run bounds at the canonical millisecond precision, while the
    # authoritative result keeps the full tick precision; compare the truncated instants.
    $resultStartTime = Convert-ResultTime (Get-Property $results 'startUtc') "results.startUtc"
    $resultEndTime = Convert-ResultTime (Get-Property $results 'endUtc') "results.endUtc"
    Test-TimeParity (Get-Property $manifest 'startUtc') ($resultStartTime.AddTicks(-($resultStartTime.Ticks % [System.TimeSpan]::TicksPerMillisecond))) "manifest.startUtc"
    Test-TimeParity (Get-Property $manifest 'endUtc') ($resultEndTime.AddTicks(-($resultEndTime.Ticks % [System.TimeSpan]::TicksPerMillisecond))) "manifest.endUtc"
    $manifestOutcome = Get-Property $manifest 'outcome'
    $resultFailure = Get-Property $results 'failure'
    if ($null -eq $manifestOutcome) { Add-Failure "manifest.outcome is missing" }
    else {
        Test-BoolParity (Get-Property $manifestOutcome 'completed') (Get-Property $results 'completed') "manifest.outcome.completed"
        if ($null -eq $resultFailure) {
            Test-TextParity (Get-Property $manifestOutcome 'failureKind') $null "manifest.outcome.failureKind"
            Test-TextParity (Get-Property $manifestOutcome 'failureCondition') $null "manifest.outcome.failureCondition"
        }
        else {
            Test-TextParity (Get-Property $manifestOutcome 'failureKind') (Get-Property $resultFailure 'Kind') "manifest.outcome.failureKind"
            Test-TextParity (Get-Property $manifestOutcome 'failureCondition') (Get-Property $resultFailure 'Condition') "manifest.outcome.failureCondition"
        }
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
    $manifestEngineRealized = Get-Property $manifestCounters 'engineRealizedProfit'
    if ($null -eq $manifestEngineRealized) { Add-Failure "manifest.counters.engineRealizedProfit is missing" }
    elseif ($manifestEngineRealized -isnot [string]) { Add-Failure "manifest.counters.engineRealizedProfit is not an exact string" }
    else {
        Test-NumberParity $manifestEngineRealized (Get-Property $results 'realizedProfit') "manifest.counters.engineRealizedProfit"
    }

    # Manifest file identities and payload fingerprint.
    $fileRows = @(Get-Property $manifest 'files')
    Test-Check ($fileRows.Count -ge 2) "the manifest lists fewer than two payload files"
    # The documented payload order: events.jsonl first, then the telemetry shards in strictly
    # ascending year order, with no other file interleaved after the first telemetry shard.
    if ($fileRows.Count -ge 1) {
        Test-ParityCheck (([string](Get-Property $fileRows[0] 'name')) -ceq 'events.jsonl') `
            "the manifest payload order must begin with events.jsonl"
        $telemetryYears = New-Object System.Collections.Generic.List[int]
        $orderViolation = $false
        for ($i = 1; $i -lt $fileRows.Count; $i++) {
            $rowName = [string](Get-Property $fileRows[$i] 'name')
            if (-not $rowName.StartsWith('telemetry-') -or -not $rowName.EndsWith('.jsonl') -or $rowName.Length -lt 18) {
                $orderViolation = $true
                continue
            }
            $yearText = $rowName.Substring(10, 4)
            $yearValue = 0
            if (-not [int]::TryParse($yearText, [ref]$yearValue)) { $orderViolation = $true; continue }
            [void]$telemetryYears.Add($yearValue)
        }
        Test-ParityCheck (-not $orderViolation) "the manifest lists a payload after the first telemetry shard that is not a year-named telemetry shard"
        $ascendingYears = $true
        for ($i = 1; $i -lt $telemetryYears.Count; $i++) {
            if ($telemetryYears[$i] -le $telemetryYears[$i - 1]) { $ascendingYears = $false }
        }
        Test-ParityCheck $ascendingYears "the manifest telemetry shard order is not strictly ascending by year"
    }
    # The manifest file `year` identity: events.jsonl carries null, each telemetry shard carries
    # exactly its filename year. The shard year is also enforced on every telemetry row below.
    $shardYearByName = @{}
    foreach ($row in $fileRows) {
        $name = [string](Get-Property $row 'name')
        $yearValue = Get-Property $row 'year'
        if ($name -ceq 'events.jsonl') {
            Test-ParityCheck ($null -eq $yearValue) "manifest file events.jsonl must declare year null"
        }
        elseif ($name -match '^telemetry-(\d{4})\.jsonl$') {
            $shardYear = [int]$Matches[1]
            $shardYearByName[$name] = $shardYear
            Test-ParityCheck ($null -ne $yearValue -and [int]$yearValue -eq $shardYear) "manifest file $name must declare year $shardYear"
        }
    }
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
    $eventsByType = @{}
    $significantIds = New-Object System.Collections.Generic.List[long]
    $previousEventTime = $null
    $previousLiveSequence = $null
    $quoteTicksProcessed = [long](Get-Property $results 'quoteTicksProcessed')
    for ($i = 0; $i -lt $events.Count; $i++) {
        $event = $events[$i]
        $id = Get-Property $event 'id'
        $type = Get-Property $event 'type'
        Test-Check ([long]$id -eq ($i + 1)) "event $i has a non-monotonic id '$id'"
        if ([string]::IsNullOrWhiteSpace([string]$type)) { Add-Failure "event $($i + 1) has no type"; continue }
        if ($eventCounts.ContainsKey([string]$type)) { $eventCounts[[string]$type] = $eventCounts[[string]$type] + 1 }
        else { $eventCounts[[string]$type] = 1 }
        if (-not $eventsByType.ContainsKey([string]$type)) {
            $eventsByType[[string]$type] = New-Object System.Collections.Generic.List[object]
        }
        [void]$eventsByType[[string]$type].Add($event)
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
        # The live quote sequence is the monotonically non-decreasing processed-quote counter:
        # run_started is 0, forced liquidation exposes it as triggerQuoteSequence, repeats are
        # allowed (several events on one quote) and it can never exceed the processed count.
        $liveSequence = $null
        if ([string]$type -eq 'run_started') { $liveSequence = [long]0 }
        elseif (Has-Property $event 'quoteSequence') { $liveSequence = [long](Get-Property $event 'quoteSequence') }
        elseif ([string]$type -eq 'forced_liquidation') { $liveSequence = [long](Get-Property $event 'triggerQuoteSequence') }
        if ($null -ne $liveSequence) {
            if ($liveSequence -gt $quoteTicksProcessed) {
                Add-Failure "event $($i + 1) quote sequence $liveSequence exceeds results.quoteTicksProcessed $quoteTicksProcessed"
            }
            if ($null -ne $previousLiveSequence -and $liveSequence -lt $previousLiveSequence) {
                Add-Failure "event $($i + 1) goes backwards in quote sequence ($liveSequence after $previousLiveSequence)"
            }
            $previousLiveSequence = $liveSequence
        }
    }
    Test-Check ((Get-Property $events[0] 'type') -eq 'run_started') "the first event is not run_started"
    Test-Check ((Get-Property $events[-1] 'type') -eq 'run_ended') "the last event is not run_ended"
    $manifestEventCounts = Get-Property $manifest 'eventCounts'
    $allowedEventTypes = @('run_started', 'basket_anchored', 'first_entry_skipped', 'entry_executed',
        'entry_rejected', 'entry_rejection_summary', 'hard_breakeven_activated', 'hard_breakeven_violated',
        'trailing_activated', 'basket_close_failed', 'strategy_exit', 'basket_liquidated',
        'stop_out_triggered', 'forced_liquidation', 'margin_call_entered', 'margin_call_left', 'run_ended')
    foreach ($property in $manifestEventCounts.PSObject.Properties) {
        $expected = [int]$property.Value
        Test-ParityCheck ($allowedEventTypes -contains $property.Name) `
            "manifest eventCounts carries a type outside the published contract: '$($property.Name)'"
        Test-ParityCheck ($expected -gt 0) `
            "manifest eventCounts carries a non-positive count for '$($property.Name)' (the producer omits absent types)"
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
    $episodes = @()
    if ($null -ne $margin) {
        $episodes = @(Get-Property $margin 'StopOutEpisodes')
        Test-Check ((& $countOf 'stop_out_triggered') -eq $episodes.Count) "stop_out_triggered count does not match the recorded Stop Out episodes"
        $enters = & $countOf 'margin_call_entered'
        $leaves = & $countOf 'margin_call_left'
        Test-Check ($enters -eq [int](Get-Property $margin 'MarginCallEpisodes')) "margin_call_entered count $enters does not match MarginCallEpisodes"
        $expectedLeaves = $enters - $(if ([bool](Get-Property $margin 'MarginCallActive')) { 1 } else { 0 })
        Test-Check ($leaves -eq $expectedLeaves) "margin_call_left count $leaves does not match the entered/active state ($expectedLeaves)"
    }

    # Event-stream contract: only published event types, exactly one run boundary pair, and the
    # rare terminal diagnostic classes are impossible on this successful run.
    foreach ($streamType in $eventCounts.Keys) {
        Test-Check ($allowedEventTypes -contains $streamType) "the event stream contains an event type outside the published contract: '$streamType'"
    }
    Test-ParityCheck ((& $countOf 'run_started') -eq 1) "the event stream must contain exactly one run_started"
    Test-ParityCheck ((& $countOf 'run_ended') -eq 1) "the event stream must contain exactly one run_ended"
    # A hard-BE violation is terminal by construction and maps one-to-one onto the documented
    # StrategyInvariant/HardBreakevenViolatedByFill failure; any other outcome must have none.
    $hardViolationCount = & $countOf 'hard_breakeven_violated'
    $violationFailure = Get-Property $results 'failure'
    $violationCondition = if ($null -eq $violationFailure) { $null } else { [string](Get-Property $violationFailure 'Condition') }
    if ($violationCondition -ceq 'HardBreakevenViolatedByFill') {
        Test-ParityCheck ($hardViolationCount -eq 1) "a HardBreakevenViolatedByFill failure requires exactly one hard_breakeven_violated event, found $hardViolationCount"
        Test-TextParity (Get-Property $violationFailure 'Kind') 'StrategyInvariant' "results.failure.Kind (hard-BE violation)"
        $violationEvents = @(Get-EventsOfType 'hard_breakeven_violated')
        if ($violationEvents.Count -ge 1) {
            $violationQuote = Get-Property $violationFailure 'Quote'
            Test-TimeParity (Get-Property $violationEvents[0] 'time') (Get-Property $violationQuote 'Time') "hard_breakeven_violated.time"
            Test-NumberParity (Get-Property $violationEvents[0] 'bid') (Get-Property $violationQuote 'Bid') "hard_breakeven_violated.bid"
            Test-NumberParity (Get-Property $violationEvents[0] 'ask') (Get-Property $violationQuote 'Ask') "hard_breakeven_violated.ask"
        }
        $hardVerification = Get-Property $results 'hardBreakevenVerification'
        if ($null -ne $hardVerification) {
            Test-BoolParity (Get-Property $hardVerification 'HardBEVerifiedUnderConfiguredExecutionModel') $false "hardBreakevenVerification.HardBEVerifiedUnderConfiguredExecutionModel"
        }
    }
    else {
        Test-ParityCheck ($hardViolationCount -eq 0) "a hard_breakeven_violated event requires the HardBreakevenViolatedByFill failure"
    }
    $runEnded = $events[-1]
    Test-Check ($null -ne (Get-Property $runEnded 'completed')) "run_ended has no completed flag"

    # Event-level exact decimals: a B1-style regression must not be able to hide outside the
    # telemetry stream. Every event type's decimal identity is written as a JSON string.
    $eventDecimalFields = @{
        'basket_anchored'          = @('bid', 'ask', 'anchor', 'step', 'upper', 'lower', 'lowerTarget', 'upperTarget')
        'entry_executed'           = @('decisionBid', 'decisionAsk', 'placedLot', 'fillPrice', 'normalizedRequiredLot')
        'trailing_activated'       = @('bid', 'ask', 'profit', 'activationThreshold')
        'hard_breakeven_activated' = @('lowerTarget', 'upperTarget')
        'strategy_exit'            = @('bid', 'ask', 'anchor', 'buyLots', 'sellLots', 'grossLots', 'netLots', 'rawProfit', 'exitProfit', 'threshold', 'buyClosePrice', 'sellClosePrice', 'commission', 'realizedProfit', 'liquidatedRealizedProfit')
        'basket_liquidated'        = @('bid', 'ask', 'anchor', 'buyLots', 'sellLots', 'grossLots', 'netLots', 'rawProfit', 'exitProfit', 'threshold', 'buyClosePrice', 'sellClosePrice', 'commission', 'realizedProfit', 'liquidatedRealizedProfit')
        'forced_liquidation'       = @('closePrice', 'realizedProfit', 'triggerBid', 'triggerAsk', 'placedLot', 'entryPrice', 'normalizedRequiredLot', 'commission', 'beforeBalance', 'beforeFloatingProfit', 'beforeEquity', 'beforeUsedMargin', 'afterBalance', 'afterFloatingProfit', 'afterEquity', 'afterUsedMargin')
        'stop_out_triggered'       = @('bid', 'ask', 'balance', 'floatingProfit', 'equity', 'usedMargin', 'freeMargin')
        'entry_rejected'           = @('bid', 'ask', 'normalizedRequiredLots')
        'entry_rejection_summary'  = @('firstBid', 'firstAsk', 'lastBid', 'lastAsk')
        'first_entry_skipped'      = @('bid', 'ask', 'spread')
        'basket_close_failed'      = @('bid', 'ask')
        'hard_breakeven_violated'  = @('bid', 'ask', 'placedLot', 'fillPrice', 'hardBreakevenTarget', 'projectedProfitAfterFill', 'sizingProjectedProfitAfter')
        'run_ended'                = @('engineRealizedProfit')
        'margin_call_entered'      = @('bid', 'ask', 'balance', 'equity', 'usedMargin')
        'margin_call_left'         = @('bid', 'ask', 'balance', 'equity', 'usedMargin')
    }
    $eventNullableDecimalFields = @{
        'entry_executed'          = @('rawRequestedLot', 'exactRequiredLot', 'hardBreakevenTarget', 'targetSpread', 'targetBid', 'targetAsk', 'existingProfitAtTarget', 'marginalProfitPerLot', 'projectedProfitAfter')
        'stop_out_triggered'      = @('marginLevelPercent')
        'forced_liquidation'      = @('rawRequestedLot', 'exactRequiredLot', 'beforeFreeMargin', 'beforeMarginLevelPercent', 'afterFreeMargin', 'afterMarginLevelPercent')
        'entry_rejected'          = @('rawRequestedLots', 'exactRequiredLots', 'maximumVolume', 'hardBreakevenTarget', 'targetSpread', 'targetBid', 'targetAsk', 'existingProfitAtTarget', 'marginalProfitPerLot', 'projectedProfitAfter', 'accountUsedMargin', 'accountFreeMargin', 'accountMarginLevelPercent', 'projectedUsedMargin', 'projectedFreeMargin')
        'entry_rejection_summary' = @('minNormalizedRequiredLots', 'maxNormalizedRequiredLots', 'minProjectedFreeMargin', 'maxProjectedFreeMargin')
        'run_ended'               = @('failureBid', 'failureAsk')
        'margin_call_entered'     = @('freeMargin', 'marginLevelPercent')
        'margin_call_left'        = @('freeMargin', 'marginLevelPercent')
    }
    foreach ($event in $events) {
        $type = [string](Get-Property $event 'type')
        if ($eventDecimalFields.ContainsKey($type)) {
            foreach ($field in $eventDecimalFields[$type]) {
                Assert-ExactString $event $field "event[$type]" $true
            }
        }
        if ($eventNullableDecimalFields.ContainsKey($type)) {
            foreach ($field in $eventNullableDecimalFields[$type]) {
                Assert-ExactString $event $field "event[$type]" $false
            }
        }
    }

    # run_ended must carry the same outcome counters, delivery identity and time as the
    # authoritative result.
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
    if ($null -ne $resultDelivered) {
        Test-NumberParity (Get-Property $runEnded 'deliveryQuoteCount') (Get-Property $resultDelivered 'quote_count') "run_ended.deliveryQuoteCount"
        Test-TextParity (Get-Property $runEnded 'deliverySemanticDigest') (Get-Property $resultDelivered 'semantic_digest') "run_ended.deliverySemanticDigest"
        Test-TimeParity (Get-Property $runEnded 'deliveryFirstUtc') (Get-Property $resultDelivered 'first_canonical_utc') "run_ended.deliveryFirstUtc"
        Test-TimeParity (Get-Property $runEnded 'deliveryLastUtc') (Get-Property $resultDelivered 'last_canonical_utc') "run_ended.deliveryLastUtc"
    }
    Test-BoolParity (Get-Property $runEnded 'completed') (Get-Property $results 'completed') "run_ended.completed"
    # The complete failure identity: kind, condition, message and faulting quote.
    $failure = Get-Property $results 'failure'
    if ($null -eq $failure) {
        foreach ($field in @('failureKind', 'failureCondition', 'failureMessage', 'failureQuoteTime', 'failureBid', 'failureAsk')) {
            Test-TextParity (Get-Property $runEnded $field) $null "run_ended.$field (no authoritative failure)"
        }
    }
    else {
        Test-TextParity (Get-Property $runEnded 'failureKind') (Get-Property $failure 'Kind') "run_ended.failureKind"
        Test-TextParity (Get-Property $runEnded 'failureCondition') (Get-Property $failure 'Condition') "run_ended.failureCondition"
        Test-TextParity (Get-Property $runEnded 'failureMessage') (Get-Property $failure 'Message') "run_ended.failureMessage"
        $failureQuote = Get-Property $failure 'Quote'
        if ($null -eq $failureQuote) { Add-Failure "results.failure.Quote is missing" }
        else {
            Test-TimeParity (Get-Property $runEnded 'failureQuoteTime') (Get-Property $failureQuote 'Time') "run_ended.failureQuoteTime"
            Test-NumberParity (Get-Property $runEnded 'failureBid') (Get-Property $failureQuote 'Bid') "run_ended.failureBid"
            Test-NumberParity (Get-Property $runEnded 'failureAsk') (Get-Property $failureQuote 'Ask') "run_ended.failureAsk"
        }
    }
    # The documented end-time rule: the run-end time is the later of the last accepted quote and
    # the rejected faulting quote (a forward-time invalid quote may be later); with no accepted
    # quote at all it is the declared end of the run.
    $lastProcessed = Get-Property $results 'lastProcessedQuote'
    $expectedEndValue = $null
    if ($null -ne $lastProcessed -and $null -ne (Get-Property $lastProcessed 'Time')) {
        $expectedEndValue = Get-Property $lastProcessed 'Time'
    }
    else {
        $expectedEndValue = Get-Property $results 'endUtc'
        if ($null -eq $expectedEndValue) { $expectedEndValue = Get-Property $manifest 'endUtc' }
    }
    if ($null -ne $failure) {
        $failureQuoteTime = Get-Property (Get-Property $failure 'Quote') 'Time'
        if ($null -ne $failureQuoteTime) {
            $baseTime = Convert-ResultTime $expectedEndValue "the run-end time base"
            $faultTime = Convert-ResultTime $failureQuoteTime "results.failure.Quote.Time"
            if ($faultTime -gt $baseTime) { $expectedEndValue = $failureQuoteTime }
        }
    }
    Test-TimeParity (Get-Property $runEnded 'time') $expectedEndValue "run_ended.time"

    # ---- Authoritative payload parity ----
    # Every comparison below is a check and is counted in parityChecks. Numeric values compare via
    # [decimal] (the exact JSON reader above keeps every authoritative digit on both hosts), text
    # compares case-sensitively and timestamps compare via the UTC parser.

    # run_started identity.
    $runStarted = $events[0]
    foreach ($field in @('modelRevision', 'stopOutModel', 'symbol', 'market', 'startDate', 'endDate', 'quoteTimeZone')) {
        Test-TextParity (Get-Property $runStarted $field) (Get-Property $results $field) "run_started.$field"
    }
    # The producer defines the run-start time from the metadata start instant, which is persisted
    # as the manifest startUtc (canonical millisecond precision).
    Test-TimeParity (Get-Property $runStarted 'time') (Get-Property $manifest 'startUtc') "run_started.time"

    # A terminal hard-BE violation is raised after the faulting tail order filled and was added to
    # the basket ledger but before EntriesOpened/EntryOpened, so the faulting leg exists in the
    # final authoritative basket state without a normal entry_executed event.
    $violationLegKey = $null
    if ($violationCondition -ceq 'HardBreakevenViolatedByFill') {
        $violationEventsForLeg = @(Get-EventsOfType 'hard_breakeven_violated')
        if ($violationEventsForLeg.Count -eq 1) {
            $violationLegKey = "$([long](Get-Property $violationEventsForLeg[0] 'basket'))/$([long](Get-Property $violationEventsForLeg[0] 'tradeNumber'))"
        }
    }

    # A. Anchors: one basket_anchored event per closed basket plus the open basket, in strictly
    # ascending basket order, with every anchor field equal to the authoritative AnchorEvent.
    $anchoredEvents = @(Get-EventsOfType 'basket_anchored')
    $expectedBasketRecords = New-Object System.Collections.Generic.List[object]
    foreach ($basketRecord in @(Get-Property $results 'closedBaskets')) { [void]$expectedBasketRecords.Add($basketRecord) }
    $openBasket = Get-Property $results 'openBasket'
    if ($null -ne $openBasket) { [void]$expectedBasketRecords.Add($openBasket) }

    Test-ParityCheck ($anchoredEvents.Count -eq $expectedBasketRecords.Count) `
        "basket_anchored parity: the package has $($anchoredEvents.Count) anchors but the result has $($expectedBasketRecords.Count) closed/open baskets"
    $actualAnchorOrder = @($anchoredEvents | ForEach-Object { [string]([long](Get-Property $_ 'basket')) })
    $expectedAnchorOrder = @($expectedBasketRecords | ForEach-Object { [string]([long](Get-Property $_ 'Sequence')) })
    Test-ParityCheck (($actualAnchorOrder -join ',') -eq ($expectedAnchorOrder -join ',')) `
        "basket_anchored parity: the anchored basket sequence $($actualAnchorOrder -join ',') does not equal the closed plus open sequence $($expectedAnchorOrder -join ',')"
    $ascending = $true
    for ($i = 1; $i -lt $anchoredEvents.Count; $i++) {
        if ([long](Get-Property $anchoredEvents[$i] 'basket') -le [long](Get-Property $anchoredEvents[$i - 1] 'basket')) { $ascending = $false }
    }
    Test-Check $ascending "the anchored basket-number sequence is not strictly ascending"
    for ($i = 0; $i -lt [Math]::Min($anchoredEvents.Count, $expectedBasketRecords.Count); $i++) {
        $event = $anchoredEvents[$i]
        $basketRecord = $expectedBasketRecords[$i]
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        $anchor = Get-Property $basketRecord 'AnchorEvent'
        Test-NumberParity (Get-Property $event 'basket') $sequence "basket_anchored[$sequence].basket"
        Test-NumberParity (Get-Property $event 'quoteSequence') (Get-Property $anchor 'QuoteSequence') "basket_anchored[$sequence].quoteSequence"
        Test-TimeParity (Get-Property $event 'time') (Get-Property $anchor 'Time') "basket_anchored[$sequence].time"
        foreach ($pair in @(@('bid', 'Bid'), @('ask', 'Ask'), @('anchor', 'Anchor'), @('step', 'Step'),
                @('upper', 'Upper'), @('lower', 'Lower'), @('lowerTarget', 'LowerTarget'), @('upperTarget', 'UpperTarget'))) {
            Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $anchor $pair[1]) "basket_anchored[$sequence].$($pair[0])"
        }
    }

    # B. Entries: every LegTrace row of every closed basket and of the open basket must have a
    # matching entry_executed event with equal decision/fill/sizing fields, and the events of one
    # basket must appear in the same order as that basket's LegTrace. Liquidated legs stay in the
    # authoritative LiquidationTrace (the engine removes them from LegTrace when they are closed
    # with the basket); their entry events are compared on the identity fields the trace carries,
    # and the forced-close fields are compared by parity D. The total entry-event count must equal
    # the full authoritative entry population (LegTrace plus LiquidationTrace rows).
    $entryEvents = @(Get-EventsOfType 'entry_executed')
    $entryEventByKey = @{}
    foreach ($event in $entryEvents) {
        $key = ([string]([long](Get-Property $event 'basket'))) + '/' + ([string]([long](Get-Property $event 'tradeNumber')))
        if ($entryEventByKey.ContainsKey($key)) { Add-Failure "duplicate entry_executed event for basket/trade $key" }
        else { $entryEventByKey[$key] = $event }
    }
    $entryTraceRows = 0
    $legTraceRows = 0
    foreach ($basketRecord in $expectedBasketRecords) {
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        $legRows = @(Get-Property $basketRecord 'LegTrace')
        $liquidationRows = @(Get-Property $basketRecord 'LiquidationTrace')
        $entryTraceRows += $legRows.Count + $liquidationRows.Count
        $legTraceRows += $legRows.Count

        $legTradeNumbers = @{}
        foreach ($legRow in $legRows) { $legTradeNumbers[[long](Get-Property $legRow 'TradeNumber')] = $true }
        $basketEntryEvents = @($entryEvents | Where-Object {
                [long](Get-Property $_ 'basket') -eq $sequence -and $legTradeNumbers.ContainsKey([long](Get-Property $_ 'tradeNumber'))
            })
        $actualEntryOrder = @($basketEntryEvents | ForEach-Object { [string]([long](Get-Property $_ 'tradeNumber')) })
        $expectedOrderRows = @($legRows | Where-Object { "$sequence/$([long](Get-Property $_ 'TradeNumber'))" -cne $violationLegKey })
        $expectedEntryOrder = @($expectedOrderRows | ForEach-Object { [string]([long](Get-Property $_ 'TradeNumber')) })
        Test-ParityCheck (($actualEntryOrder -join ',') -eq ($expectedEntryOrder -join ',')) `
            "entry_executed parity: basket $sequence entries appear as $($actualEntryOrder -join ',') but its LegTrace order is $($expectedEntryOrder -join ',')"

        foreach ($legRow in $legRows) {
            $tradeNumber = [long](Get-Property $legRow 'TradeNumber')
            $key = "$sequence/$tradeNumber"
            if (-not $entryEventByKey.ContainsKey($key)) {
                # The terminal hard-BE faulting leg is in the basket ledger but never produced an
                # EntryOpened event (the engine throws first); it is exempt by construction.
                if ($key -cne $violationLegKey) {
                    Add-Failure "entry_executed parity: no event for basket $sequence leg $tradeNumber"
                }
                continue
            }
            $event = $entryEventByKey[$key]
            Test-NumberParity (Get-Property $event 'quoteSequence') (Get-Property $legRow 'QuoteSequence') "entry_executed[$key].quoteSequence"
            Test-TimeParity (Get-Property $event 'time') (Get-Property $legRow 'Time') "entry_executed[$key].time"
            Test-TextParity (Get-Property $event 'side') (Get-Property $legRow 'Side') "entry_executed[$key].side"
            Test-TextParity (Get-Property $event 'regime') (Get-Property $legRow 'Regime') "entry_executed[$key].regime"
            foreach ($pair in @(@('decisionBid', 'DecisionBid'), @('decisionAsk', 'DecisionAsk'), @('placedLot', 'PlacedLot'),
                    @('fillPrice', 'FillPrice'), @('rawRequestedLot', 'RawRequestedLot'), @('exactRequiredLot', 'ExactRequiredLot'),
                    @('normalizedRequiredLot', 'NormalizedRequiredLot'), @('hardBreakevenTarget', 'HardBreakevenTarget'),
                    @('targetSpread', 'TargetSpread'), @('targetBid', 'TargetBid'), @('targetAsk', 'TargetAsk'),
                    @('existingProfitAtTarget', 'ExistingProfitAtTarget'), @('marginalProfitPerLot', 'MarginalProfitPerLot'),
                    @('projectedProfitAfter', 'ProjectedProfitAfter'))) {
                Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $legRow $pair[1]) "entry_executed[$key].$($pair[0])"
            }
            # sizingOutcome is the sizing semantics of the verified regime: an arithmetic fill
            # carries none, a hard-BE fill carries the Feasible sizing outcome.
            if (([string](Get-Property $legRow 'Regime')) -ceq 'HardBreakeven') {
                Test-TextParity (Get-Property $event 'sizingOutcome') 'Feasible' "entry_executed[$key].sizingOutcome"
            }
            else {
                Test-TextParity (Get-Property $event 'sizingOutcome') $null "entry_executed[$key].sizingOutcome"
            }
        }
        foreach ($liquidationRow in $liquidationRows) {
            $tradeNumber = [long](Get-Property $liquidationRow 'TradeNumber')
            $key = "$sequence/$tradeNumber"
            if (-not $entryEventByKey.ContainsKey($key)) { Add-Failure "entry_executed parity: no event for liquidated basket $sequence leg $tradeNumber"; continue }
            $event = $entryEventByKey[$key]
            Test-TimeParity (Get-Property $event 'time') (Get-Property $liquidationRow 'EntryTime') "entry_executed[liquidation $key].time"
            Test-TextParity (Get-Property $event 'side') (Get-Property $liquidationRow 'Side') "entry_executed[liquidation $key].side"
            Test-TextParity (Get-Property $event 'regime') (Get-Property $liquidationRow 'Regime') "entry_executed[liquidation $key].regime"
            foreach ($pair in @(@('placedLot', 'PlacedLot'), @('fillPrice', 'EntryPrice'), @('rawRequestedLot', 'RawRequestedLot'),
                    @('exactRequiredLot', 'ExactRequiredLot'), @('normalizedRequiredLot', 'NormalizedRequiredLot'))) {
                Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $liquidationRow $pair[1]) "entry_executed[liquidation $key].$($pair[0])"
            }
            if (([string](Get-Property $liquidationRow 'Regime')) -ceq 'HardBreakeven') {
                Test-TextParity (Get-Property $event 'sizingOutcome') 'Feasible' "entry_executed[liquidation $key].sizingOutcome"
            }
            else {
                Test-TextParity (Get-Property $event 'sizingOutcome') $null "entry_executed[liquidation $key].sizingOutcome"
            }
        }
    }
    $exemptEntryRows = 0
    if ($null -ne $violationLegKey) {
        foreach ($basketRecord in $expectedBasketRecords) {
            foreach ($legRow in @(Get-Property $basketRecord 'LegTrace')) {
                if ("$([long](Get-Property $basketRecord 'Sequence'))/$([long](Get-Property $legRow 'TradeNumber'))" -ceq $violationLegKey) {
                    $exemptEntryRows = 1
                }
            }
        }
    }
    Test-ParityCheck ($entryEvents.Count -eq ($entryTraceRows - $exemptEntryRows)) `
        "entry_executed parity: the package has $($entryEvents.Count) entries but the authoritative LegTrace plus LiquidationTrace population is $entryTraceRows minus $exemptEntryRows terminal-fault exemption(s)"

    # Terminal hard-BE violation semantics: the single diagnostic key must be exactly one leg of
    # the final open basket with no normal entry event, bound field by field to that leg, and no
    # live event may follow it other than the run-end recaps and run_ended.
    if ($violationCondition -ceq 'HardBreakevenViolatedByFill') {
        $openViolationMatches = 0
        $openViolationLeg = $null
        if ($null -ne $openBasket -and $null -ne $violationLegKey) {
            foreach ($legRow in @(Get-Property $openBasket 'LegTrace')) {
                if ("$([long](Get-Property $openBasket 'Sequence'))/$([long](Get-Property $legRow 'TradeNumber'))" -ceq $violationLegKey) {
                    $openViolationLeg = $legRow
                    $openViolationMatches++
                }
            }
        }
        Test-ParityCheck ($openViolationMatches -eq 1) `
            "the hard-BE faulting leg must appear exactly once in the final open basket LegTrace, found $openViolationMatches"
        if ($null -ne $violationLegKey) {
            Test-ParityCheck (-not $entryEventByKey.ContainsKey($violationLegKey)) `
                "the hard-BE faulting leg must not have a normal entry_executed event"
        }
        if ($null -ne $openViolationLeg) {
            $violationEventsForBinding = @(Get-EventsOfType 'hard_breakeven_violated')
            if ($violationEventsForBinding.Count -eq 1) {
                $violationEvent = $violationEventsForBinding[0]
                Test-NumberParity (Get-Property $violationEvent 'tradeNumber') (Get-Property $openViolationLeg 'TradeNumber') "hard_breakeven_violated.tradeNumber vs the faulting leg"
                Test-TextParity (Get-Property $violationEvent 'side') (Get-Property $openViolationLeg 'Side') "hard_breakeven_violated.side vs the faulting leg"
                Test-NumberParity (Get-Property $violationEvent 'placedLot') (Get-Property $openViolationLeg 'PlacedLot') "hard_breakeven_violated.placedLot vs the faulting leg"
                Test-NumberParity (Get-Property $violationEvent 'fillPrice') (Get-Property $openViolationLeg 'FillPrice') "hard_breakeven_violated.fillPrice vs the faulting leg"
                Test-TimeParity (Get-Property $violationEvent 'time') (Get-Property $openViolationLeg 'Time') "hard_breakeven_violated.time vs the faulting leg"
                Test-NumberParity (Get-Property $violationEvent 'quoteSequence') (Get-Property $openViolationLeg 'QuoteSequence') "hard_breakeven_violated.quoteSequence vs the faulting leg"
            }
        }
        $terminalIndex = -1
        for ($i = 0; $i -lt $events.Count; $i++) {
            if ([string](Get-Property $events[$i] 'type') -ceq 'hard_breakeven_violated') { $terminalIndex = $i; break }
        }
        if ($terminalIndex -ge 0) {
            for ($i = $terminalIndex + 1; $i -lt $events.Count; $i++) {
                $laterType = [string](Get-Property $events[$i] 'type')
                if ($laterType -cne 'entry_rejection_summary' -and $laterType -cne 'run_ended') {
                    Add-Failure "a $laterType event follows the terminal hard_breakeven_violated diagnostic"
                }
            }
        }
    }

    # C. Strategy exits: the closed baskets that were not broker-liquidated, in closing order,
    # each with a strategy_exit event whose close fields, realized figures and lots all agree.
    $closedBasketRecords = @(Get-Property $results 'closedBaskets')
    $nonLiquidatedClosed = @($closedBasketRecords | Where-Object { ([string](Get-Property $_ 'Reason')) -cne 'BrokerLiquidation' })
    $previousClosedTime = $null
    foreach ($basketRecord in $nonLiquidatedClosed) {
        $closedTime = Convert-ResultTime (Get-Property $basketRecord 'ClosedTime') "closedBaskets[$([long](Get-Property $basketRecord 'Sequence'))].ClosedTime"
        if ($null -ne $previousClosedTime -and $closedTime -lt $previousClosedTime) {
            Add-Failure "the authoritative closed baskets are not in closing order at basket $([long](Get-Property $basketRecord 'Sequence'))"
        }
        $previousClosedTime = $closedTime
    }
    $strategyExitEvents = @(Get-EventsOfType 'strategy_exit')
    Test-ParityCheck ($strategyExitEvents.Count -eq $nonLiquidatedClosed.Count) `
        "strategy_exit parity: the package has $($strategyExitEvents.Count) strategy exits but the authoritative non-liquidated closed-basket count is $($nonLiquidatedClosed.Count)"
    $actualExitOrder = @($strategyExitEvents | ForEach-Object { [string]([long](Get-Property $_ 'basket')) })
    $expectedExitOrder = @($nonLiquidatedClosed | ForEach-Object { [string]([long](Get-Property $_ 'Sequence')) })
    Test-ParityCheck (($actualExitOrder -join ',') -eq ($expectedExitOrder -join ',')) `
        "strategy_exit parity: the package close order $($actualExitOrder -join ',') does not equal the authoritative closing order $($expectedExitOrder -join ',')"
    for ($i = 0; $i -lt [Math]::Min($strategyExitEvents.Count, $nonLiquidatedClosed.Count); $i++) {
        $event = $strategyExitEvents[$i]
        $basketRecord = $nonLiquidatedClosed[$i]
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        Test-TextParity (Get-Property $event 'reason') (Get-Property $basketRecord 'Reason') "strategy_exit[$sequence].reason"
        Test-TimeParity (Get-Property $event 'time') (Get-Property $basketRecord 'ClosedTime') "strategy_exit[$sequence].time"
        Test-BoolParity (Get-Property $event 'hardBreakevenModeActive') (Get-Property $basketRecord 'HardBreakevenModeActive') "strategy_exit[$sequence].hardBreakevenModeActive"
        foreach ($pair in @(@('quoteSequence', 'CloseQuoteSequence'), @('bid', 'CloseBid'), @('ask', 'CloseAsk'), @('anchor', 'Anchor'),
                @('legs', 'Legs'), @('buyLots', 'BuyLots'), @('sellLots', 'SellLots'), @('grossLots', 'GrossLots'), @('netLots', 'NetLots'),
                @('rawProfit', 'RawProfit'), @('exitProfit', 'ExitProfit'), @('threshold', 'Threshold'),
                @('buyClosePrice', 'BuyClosePrice'), @('sellClosePrice', 'SellClosePrice'), @('commission', 'Commission'),
                @('realizedProfit', 'RealizedProfit'), @('liquidatedRealizedProfit', 'LiquidatedRealizedProfit'),
                @('liquidatedPositions', 'LiquidatedPositions'), @('historicalEntries', 'HistoricalEntries'))) {
            Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $basketRecord $pair[1]) "strategy_exit[$sequence].$($pair[0])"
        }
    }

    # The fully broker-liquidated baskets close with the same BasketCloseRecord shape.
    $liquidatedClosed = @($closedBasketRecords | Where-Object { ([string](Get-Property $_ 'Reason')) -ceq 'BrokerLiquidation' })
    $basketLiquidatedEvents = @(Get-EventsOfType 'basket_liquidated')
    Test-ParityCheck ($basketLiquidatedEvents.Count -eq $liquidatedClosed.Count) `
        "basket_liquidated parity: the package has $($basketLiquidatedEvents.Count) liquidated closes but the authoritative count is $($liquidatedClosed.Count)"
    $actualLiquidatedOrder = @($basketLiquidatedEvents | ForEach-Object { [string]([long](Get-Property $_ 'basket')) })
    $expectedLiquidatedOrder = @($liquidatedClosed | ForEach-Object { [string]([long](Get-Property $_ 'Sequence')) })
    Test-ParityCheck (($actualLiquidatedOrder -join ',') -eq ($expectedLiquidatedOrder -join ',')) `
        "basket_liquidated parity: $($actualLiquidatedOrder -join ',') does not equal $($expectedLiquidatedOrder -join ',')"
    for ($i = 0; $i -lt [Math]::Min($basketLiquidatedEvents.Count, $liquidatedClosed.Count); $i++) {
        $event = $basketLiquidatedEvents[$i]
        $basketRecord = $liquidatedClosed[$i]
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        Test-TextParity (Get-Property $event 'reason') (Get-Property $basketRecord 'Reason') "basket_liquidated[$sequence].reason"
        Test-TimeParity (Get-Property $event 'time') (Get-Property $basketRecord 'ClosedTime') "basket_liquidated[$sequence].time"
        Test-BoolParity (Get-Property $event 'hardBreakevenModeActive') (Get-Property $basketRecord 'HardBreakevenModeActive') "basket_liquidated[$sequence].hardBreakevenModeActive"
        foreach ($pair in @(@('quoteSequence', 'CloseQuoteSequence'), @('bid', 'CloseBid'), @('ask', 'CloseAsk'), @('anchor', 'Anchor'),
                @('legs', 'Legs'), @('buyLots', 'BuyLots'), @('sellLots', 'SellLots'), @('grossLots', 'GrossLots'), @('netLots', 'NetLots'),
                @('rawProfit', 'RawProfit'), @('exitProfit', 'ExitProfit'), @('threshold', 'Threshold'),
                @('buyClosePrice', 'BuyClosePrice'), @('sellClosePrice', 'SellClosePrice'), @('commission', 'Commission'),
                @('realizedProfit', 'RealizedProfit'), @('liquidatedRealizedProfit', 'LiquidatedRealizedProfit'),
                @('liquidatedPositions', 'LiquidatedPositions'), @('historicalEntries', 'HistoricalEntries'))) {
            Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $basketRecord $pair[1]) "basket_liquidated[$sequence].$($pair[0])"
        }
    }

    # D. Forced liquidations: the Stop Out episodes' liquidations, flattened in episode and
    # liquidation order, must match the forced_liquidation events one for one and in stream order.
    # This includes the same-quote liquidation order and the exact before/after account state.
    $liquidationRecords = New-Object System.Collections.Generic.List[object]
    foreach ($episodeRecord in @($episodes)) {
        foreach ($liquidationRecord in @(Get-Property $episodeRecord 'Liquidations')) {
            [void]$liquidationRecords.Add($liquidationRecord)
        }
    }
    $forcedLiquidationEvents = @(Get-EventsOfType 'forced_liquidation')
    Test-ParityCheck ($forcedLiquidationEvents.Count -eq $liquidationRecords.Count) `
        "forced_liquidation parity: the package has $($forcedLiquidationEvents.Count) events but the authoritative flattened liquidation count is $($liquidationRecords.Count)"
    for ($i = 0; $i -lt [Math]::Min($forcedLiquidationEvents.Count, $liquidationRecords.Count); $i++) {
        $event = $forcedLiquidationEvents[$i]
        $liquidationRecord = $liquidationRecords[$i]
        $leg = Get-Property $liquidationRecord 'Leg'
        $identity = "$([long](Get-Property $leg 'Basket'))/$([long](Get-Property $leg 'Ordinal'))"
        Test-TimeParity (Get-Property $event 'time') (Get-Property $leg 'LiquidationTime') "forced_liquidation[$identity].time"
        foreach ($pair in @(@('basket', 'Basket', 'number'), @('ordinal', 'Ordinal', 'number'), @('tradeNumber', 'TradeNumber', 'number'),
                @('side', 'Side', 'text'), @('placedLot', 'PlacedLot', 'number'), @('entryPrice', 'EntryPrice', 'number'),
                @('entryTime', 'EntryTime', 'time'), @('regime', 'Regime', 'text'), @('rawRequestedLot', 'RawRequestedLot', 'number'),
                @('exactRequiredLot', 'ExactRequiredLot', 'number'), @('normalizedRequiredLot', 'NormalizedRequiredLot', 'number'),
                @('liquidationTime', 'LiquidationTime', 'time'), @('triggerTime', 'TriggerTime', 'time'),
                @('triggerQuoteSequence', 'TriggerQuoteSequence', 'number'), @('triggerBid', 'TriggerBid', 'number'),
                @('triggerAsk', 'TriggerAsk', 'number'), @('closePrice', 'ClosePrice', 'number'), @('commission', 'Commission', 'number'),
                @('realizedProfit', 'RealizedProfit', 'number'), @('reason', 'Reason', 'text'))) {
            $where = "forced_liquidation[$identity].$($pair[1])"
            if ($pair[2] -eq 'time') { Test-TimeParity (Get-Property $event $pair[0]) (Get-Property $leg $pair[1]) $where }
            elseif ($pair[2] -eq 'text') { Test-TextParity (Get-Property $event $pair[0]) (Get-Property $leg $pair[1]) $where }
            else { Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $leg $pair[1]) $where }
        }
        foreach ($sideName in @('before', 'after')) {
            if ($sideName -eq 'before') { $snapshot = Get-Property $liquidationRecord 'Before' } else { $snapshot = Get-Property $liquidationRecord 'After' }
            foreach ($field in @('Balance', 'FloatingProfit', 'Equity', 'UsedMargin', 'FreeMargin', 'MarginLevelPercent', 'OpenPositions')) {
                Test-NumberParity (Get-Property $event ($sideName + $field)) (Get-Property $snapshot $field) "forced_liquidation[$identity].$($sideName + $field)"
            }
        }
    }

    # E. Stop Out: the stop_out_triggered events in order against the authoritative episodes:
    # basket, reason, trigger quote and the exact AtTrigger account state. The committed
    # stop_out_triggered payload (REPLAY_PACKAGE.md section 3, ReplayRecorder.AddStopOutEvent)
    # carries those fields; if a package extends the payload with the episode's Outcome,
    # ResolvedTime and AfterLiquidation, those are compared as well.
    $stopOutEvents = @(Get-EventsOfType 'stop_out_triggered')
    Test-ParityCheck ($stopOutEvents.Count -eq $episodes.Count) `
        "stop_out_triggered parity: the package has $($stopOutEvents.Count) events but the authoritative episode count is $($episodes.Count)"
    $stopOutExtendedFields = @('outcome', 'resolvedTime', 'afterBalance', 'afterFloatingProfit', 'afterEquity',
        'afterUsedMargin', 'afterFreeMargin', 'afterMarginLevelPercent', 'afterOpenPositions')
    for ($i = 0; $i -lt [Math]::Min($stopOutEvents.Count, $episodes.Count); $i++) {
        $event = $stopOutEvents[$i]
        $episodeRecord = $episodes[$i]
        $sequence = [long](Get-Property $episodeRecord 'Basket')
        $atTrigger = Get-Property $episodeRecord 'AtTrigger'
        Test-NumberParity (Get-Property $event 'basket') $sequence "stop_out_triggered[$sequence].basket"
        Test-TextParity (Get-Property $event 'reason') (Get-Property $episodeRecord 'Reason') "stop_out_triggered[$sequence].reason"
        Test-NumberParity (Get-Property $event 'quoteSequence') (Get-Property $episodeRecord 'TriggerQuoteSequence') "stop_out_triggered[$sequence].quoteSequence"
        Test-TimeParity (Get-Property $event 'time') (Get-Property $episodeRecord 'TriggerTime') "stop_out_triggered[$sequence].time"
        Test-NumberParity (Get-Property $event 'bid') (Get-Property $episodeRecord 'TriggerBid') "stop_out_triggered[$sequence].bid"
        Test-NumberParity (Get-Property $event 'ask') (Get-Property $episodeRecord 'TriggerAsk') "stop_out_triggered[$sequence].ask"
        foreach ($pair in @(@('balance', 'Balance'), @('floatingProfit', 'FloatingProfit'), @('equity', 'Equity'),
                @('usedMargin', 'UsedMargin'), @('freeMargin', 'FreeMargin'), @('marginLevelPercent', 'MarginLevelPercent'),
                @('openPositions', 'OpenPositions'))) {
            Test-NumberParity (Get-Property $event $pair[0]) (Get-Property $atTrigger $pair[1]) "stop_out_triggered[$sequence].AtTrigger.$($pair[1])"
        }
        $hasExtendedPayload = $false
        foreach ($field in $stopOutExtendedFields) { if (Has-Property $event $field) { $hasExtendedPayload = $true } }
        if ($hasExtendedPayload) {
            Test-TextParity (Get-Property $event 'outcome') (Get-Property $episodeRecord 'Outcome') "stop_out_triggered[$sequence].outcome"
            Test-TimeParity (Get-Property $event 'resolvedTime') (Get-Property $episodeRecord 'ResolvedTime') "stop_out_triggered[$sequence].resolvedTime"
            $afterLiquidation = Get-Property $episodeRecord 'AfterLiquidation'
            foreach ($field in @('Balance', 'FloatingProfit', 'Equity', 'UsedMargin', 'FreeMargin', 'MarginLevelPercent', 'OpenPositions')) {
                Test-NumberParity (Get-Property $event ('after' + $field)) (Get-Property $afterLiquidation $field) "stop_out_triggered[$sequence].AfterLiquidation.$field"
            }
        }
    }

    # F. Rejections: every RejectionTrace row of every closed basket and of the open basket must
    # have exactly one live entry_rejected event (the first attempt) and exactly one run-end
    # entry_rejection_summary recap. The live event carries the attempt requirement and margin
    # assessment; the summary carries the episode identity and aggregates.
    $rejectionTraceRows = New-Object System.Collections.Generic.List[object]
    foreach ($basketRecord in $expectedBasketRecords) {
        foreach ($rejectionRow in @(Get-Property $basketRecord 'RejectionTrace')) {
            [void]$rejectionTraceRows.Add($rejectionRow)
        }
    }
    $rejectionSummaryEvents = @(Get-EventsOfType 'entry_rejection_summary')
    $entryRejectedEvents = @(Get-EventsOfType 'entry_rejected')
    Test-ParityCheck ($rejectionSummaryEvents.Count -eq $rejectionTraceRows.Count) `
        "entry_rejection_summary parity: the package has $($rejectionSummaryEvents.Count) summaries but the authoritative RejectionTrace row count is $($rejectionTraceRows.Count)"
    Test-ParityCheck ($entryRejectedEvents.Count -eq $rejectionTraceRows.Count) `
        "entry_rejected parity: the package has $($entryRejectedEvents.Count) live rejections but the authoritative RejectionTrace row count is $($rejectionTraceRows.Count)"
    foreach ($rejectionRow in $rejectionTraceRows) {
        $sequence = [long](Get-Property $rejectionRow 'Basket')
        $tradeNumber = [long](Get-Property $rejectionRow 'TradeNumber')
        $side = [string](Get-Property $rejectionRow 'Side')
        $identity = "$sequence/$tradeNumber/$side"
        $summaryMatches = @($rejectionSummaryEvents | Where-Object {
                [long](Get-Property $_ 'basket') -eq $sequence -and
                [long](Get-Property $_ 'tradeNumber') -eq $tradeNumber -and
                ([string](Get-Property $_ 'side')) -ceq $side
            })
        Test-ParityCheck ($summaryMatches.Count -eq 1) "entry_rejection_summary parity: $($summaryMatches.Count) summaries match rejection row $identity, expected exactly one"
        if ($summaryMatches.Count -ge 1) {
            $summary = $summaryMatches[0]
            Test-NumberParity (Get-Property $summary 'basket') $sequence "entry_rejection_summary[$identity].basket"
            Test-NumberParity (Get-Property $summary 'tradeNumber') $tradeNumber "entry_rejection_summary[$identity].tradeNumber"
            Test-TextParity (Get-Property $summary 'side') $side "entry_rejection_summary[$identity].side"
            Test-TextParity (Get-Property $summary 'reason') (Get-Property $rejectionRow 'Reason') "entry_rejection_summary[$identity].reason"
            Test-TextParity (Get-Property $summary 'outcome') (Get-Property $rejectionRow 'Outcome') "entry_rejection_summary[$identity].outcome"
            Test-NumberParity (Get-Property $summary 'attempts') (Get-Property $rejectionRow 'Attempts') "entry_rejection_summary[$identity].attempts"
            Test-NumberParity (Get-Property $summary 'firstQuoteSequence') (Get-Property $rejectionRow 'FirstQuoteSequence') "entry_rejection_summary[$identity].firstQuoteSequence"
            Test-TimeParity (Get-Property $summary 'firstTime') (Get-Property $rejectionRow 'FirstTime') "entry_rejection_summary[$identity].firstTime"
            Test-NumberParity (Get-Property $summary 'firstBid') (Get-Property $rejectionRow 'FirstBid') "entry_rejection_summary[$identity].firstBid"
            Test-NumberParity (Get-Property $summary 'firstAsk') (Get-Property $rejectionRow 'FirstAsk') "entry_rejection_summary[$identity].firstAsk"
            Test-NumberParity (Get-Property $summary 'lastQuoteSequence') (Get-Property $rejectionRow 'LastQuoteSequence') "entry_rejection_summary[$identity].lastQuoteSequence"
            Test-TimeParity (Get-Property $summary 'lastTime') (Get-Property $rejectionRow 'LastTime') "entry_rejection_summary[$identity].lastTime"
            Test-NumberParity (Get-Property $summary 'lastBid') (Get-Property $rejectionRow 'LastBid') "entry_rejection_summary[$identity].lastBid"
            Test-NumberParity (Get-Property $summary 'lastAsk') (Get-Property $rejectionRow 'LastAsk') "entry_rejection_summary[$identity].lastAsk"
            Test-TextParity (Get-Property $summary 'parityHash') (Get-Property $rejectionRow 'ParityHash') "entry_rejection_summary[$identity].parityHash"
            Test-TextParity (Get-Property $summary 'parityAlgorithm') (Get-Property $rejectionRow 'ParityAlgorithm') "entry_rejection_summary[$identity].parityAlgorithm"
            Test-TextParity (Get-Property $summary 'message') (Get-Property $rejectionRow 'Message') "entry_rejection_summary[$identity].message"
            Test-NumberParity (Get-Property $summary 'minNormalizedRequiredLots') (Get-Property $rejectionRow 'MinNormalizedRequiredLots') "entry_rejection_summary[$identity].minNormalizedRequiredLots"
            Test-NumberParity (Get-Property $summary 'maxNormalizedRequiredLots') (Get-Property $rejectionRow 'MaxNormalizedRequiredLots') "entry_rejection_summary[$identity].maxNormalizedRequiredLots"
            Test-NumberParity (Get-Property $summary 'minProjectedFreeMargin') (Get-Property $rejectionRow 'MinProjectedFreeMargin') "entry_rejection_summary[$identity].minProjectedFreeMargin"
            Test-NumberParity (Get-Property $summary 'maxProjectedFreeMargin') (Get-Property $rejectionRow 'MaxProjectedFreeMargin') "entry_rejection_summary[$identity].maxProjectedFreeMargin"
            # If a package ever carries the attempt requirement/margin fields on the summary too,
            # they are compared as well (the committed recorder puts them on the live event only).
            foreach ($pair in @(@('rawRequestedLots', 'RawRequestedLots'), @('exactRequiredLots', 'ExactRequiredLots'),
                    @('normalizedRequiredLots', 'NormalizedRequiredLots'), @('hardBreakevenTarget', 'HardBreakevenTarget'),
                    @('targetSpread', 'TargetSpread'), @('targetBid', 'TargetBid'), @('targetAsk', 'TargetAsk'),
                    @('existingProfitAtTarget', 'ExistingProfitAtTarget'), @('marginalProfitPerLot', 'MarginalProfitPerLot'),
                    @('projectedProfitAfter', 'ProjectedProfitAfter'), @('accountUsedMargin', 'AccountUsedMargin'),
                    @('accountFreeMargin', 'AccountFreeMargin'), @('accountMarginLevelPercent', 'AccountMarginLevelPercent'),
                    @('projectedUsedMargin', 'ProjectedUsedMargin'), @('projectedFreeMargin', 'ProjectedFreeMargin'))) {
                if (Has-Property $summary $pair[0]) {
                    Test-NumberParity (Get-Property $summary $pair[0]) (Get-Property $rejectionRow $pair[1]) "entry_rejection_summary[$identity].$($pair[0])"
                }
            }
        }
        $liveMatches = @($entryRejectedEvents | Where-Object {
                [long](Get-Property $_ 'basket') -eq $sequence -and
                [long](Get-Property $_ 'tradeNumber') -eq $tradeNumber -and
                ([string](Get-Property $_ 'side')) -ceq $side
            })
        Test-ParityCheck ($liveMatches.Count -eq 1) "entry_rejected parity: $($liveMatches.Count) live rejections match rejection row $identity, expected exactly one"
        if ($liveMatches.Count -ge 1) {
            $live = $liveMatches[0]
            Test-NumberParity (Get-Property $live 'basket') $sequence "entry_rejected[$identity].basket"
            Test-NumberParity (Get-Property $live 'tradeNumber') $tradeNumber "entry_rejected[$identity].tradeNumber"
            Test-TextParity (Get-Property $live 'side') $side "entry_rejected[$identity].side"
            Test-TextParity (Get-Property $live 'reason') (Get-Property $rejectionRow 'Reason') "entry_rejected[$identity].reason"
            Test-NumberParity (Get-Property $live 'quoteSequence') (Get-Property $rejectionRow 'FirstQuoteSequence') "entry_rejected[$identity].quoteSequence"
            Test-TimeParity (Get-Property $live 'time') (Get-Property $rejectionRow 'FirstTime') "entry_rejected[$identity].time"
            Test-NumberParity (Get-Property $live 'bid') (Get-Property $rejectionRow 'FirstBid') "entry_rejected[$identity].bid"
            Test-NumberParity (Get-Property $live 'ask') (Get-Property $rejectionRow 'FirstAsk') "entry_rejected[$identity].ask"
            Test-TextParity (Get-Property $live 'message') (Get-Property $rejectionRow 'Message') "entry_rejected[$identity].message"
            # The sizing outcome of the rejected attempt and the frozen maximum volume.
            Test-TextParity (Get-Property $live 'sizingOutcome') (Get-Property $rejectionRow 'Outcome') "entry_rejected[$identity].sizingOutcome"
            Test-NumberParity (Get-Property $live 'maximumVolume') (Get-Property $resultParameters 'MaximumVolume') "entry_rejected[$identity].maximumVolume"
            foreach ($pair in @(@('rawRequestedLots', 'RawRequestedLots'), @('exactRequiredLots', 'ExactRequiredLots'),
                    @('normalizedRequiredLots', 'NormalizedRequiredLots'), @('hardBreakevenTarget', 'HardBreakevenTarget'),
                    @('targetSpread', 'TargetSpread'), @('targetBid', 'TargetBid'), @('targetAsk', 'TargetAsk'),
                    @('existingProfitAtTarget', 'ExistingProfitAtTarget'), @('marginalProfitPerLot', 'MarginalProfitPerLot'),
                    @('projectedProfitAfter', 'ProjectedProfitAfter'), @('accountUsedMargin', 'AccountUsedMargin'),
                    @('accountFreeMargin', 'AccountFreeMargin'), @('accountMarginLevelPercent', 'AccountMarginLevelPercent'),
                    @('projectedUsedMargin', 'ProjectedUsedMargin'), @('projectedFreeMargin', 'ProjectedFreeMargin'))) {
                Test-NumberParity (Get-Property $live $pair[0]) (Get-Property $rejectionRow $pair[1]) "entry_rejected[$identity].$($pair[0])"
            }
        }
    }

    # F2. The run-end recap order must match the authoritative RejectionTrace order.
    $summaryOrder = @($rejectionSummaryEvents | ForEach-Object {
            "$([long](Get-Property $_ 'basket'))/$([long](Get-Property $_ 'tradeNumber'))/$([string](Get-Property $_ 'side'))" })
    $authoritativeRejectionOrder = @($rejectionTraceRows | ForEach-Object {
            "$([long](Get-Property $_ 'Basket'))/$([long](Get-Property $_ 'TradeNumber'))/$([string](Get-Property $_ 'Side'))" })
    Test-ParityCheck (($summaryOrder -join ',') -eq ($authoritativeRejectionOrder -join ',')) `
        "entry_rejection_summary parity: the summary order does not match the authoritative RejectionTrace order"

    # F3. first_entry_skipped: every published event must match the basket's authoritative
    # SkippedFirstEntryTrace and the population must equal the trace population exactly.
    $skippedTraceRows = New-Object System.Collections.Generic.List[object]
    foreach ($basketRecord in $expectedBasketRecords) {
        $trace = Get-Property $basketRecord 'SkippedFirstEntryTrace'
        if ($null -eq $trace) { continue }
        if ($trace -is [System.Collections.IEnumerable] -and $trace -isnot [string]) {
            foreach ($row in $trace) { [void]$skippedTraceRows.Add($row) }
        }
        else { [void]$skippedTraceRows.Add($trace) }
    }
    $skippedEvents = @(Get-EventsOfType 'first_entry_skipped')
    Test-ParityCheck ($skippedEvents.Count -eq $skippedTraceRows.Count) `
        "first_entry_skipped parity: the package has $($skippedEvents.Count) events but the authoritative SkippedFirstEntryTrace population is $($skippedTraceRows.Count)"
    foreach ($skippedEvent in $skippedEvents) {
        $skippedBasket = [long](Get-Property $skippedEvent 'basket')
        $skippedMatches = @($skippedTraceRows | Where-Object { [long](Get-Property $_ 'Basket') -eq $skippedBasket })
        Test-ParityCheck ($skippedMatches.Count -eq 1) "first_entry_skipped parity: $($skippedMatches.Count) trace rows match basket $skippedBasket, expected exactly one"
        if ($skippedMatches.Count -ge 1) {
            $skippedRecord = $skippedMatches[0]
            Test-NumberParity (Get-Property $skippedEvent 'quoteSequence') (Get-Property $skippedRecord 'FirstQuoteSequence') "first_entry_skipped[$skippedBasket].quoteSequence"
            Test-TimeParity (Get-Property $skippedEvent 'time') (Get-Property $skippedRecord 'FirstTime') "first_entry_skipped[$skippedBasket].time"
            Test-NumberParity (Get-Property $skippedEvent 'bid') (Get-Property $skippedRecord 'FirstBid') "first_entry_skipped[$skippedBasket].bid"
            Test-NumberParity (Get-Property $skippedEvent 'ask') (Get-Property $skippedRecord 'FirstAsk') "first_entry_skipped[$skippedBasket].ask"
            # The live event is raised only on the first ambiguous quote, so its attempts is
            # exactly 1; the retained trace counts every repeat.
            Test-ParityCheck ([long](Get-Property $skippedEvent 'attempts') -eq 1) "first_entry_skipped[$skippedBasket].attempts must be 1 at emission"
            # The published spread is the authoritative first quote's spread.
            $expectedSpread = (Convert-JsonDecimal (Get-Property $skippedRecord 'FirstAsk') "first_entry_skipped[$skippedBasket].FirstAsk") -
                (Convert-JsonDecimal (Get-Property $skippedRecord 'FirstBid') "first_entry_skipped[$skippedBasket].FirstBid")
            Test-NumberParity (Get-Property $skippedEvent 'spread') $expectedSpread "first_entry_skipped[$skippedBasket].spread"
        }
    }
    # The authoritative skipped-first-entry population is the sum of the retained attempt counts.
    $skippedAttemptSum = 0
    foreach ($skippedRow in $skippedTraceRows) { $skippedAttemptSum += [long](Get-Property $skippedRow 'Attempts') }
    Test-ParityCheck ($skippedAttemptSum -eq [long](Get-Property $results 'skippedFirstEntryQuotes')) `
        "first_entry_skipped parity: the SkippedFirstEntryTrace attempts sum $skippedAttemptSum does not match results.skippedFirstEntryQuotes"

    # G. Hard-BE activation: every basket whose authoritative record activated hard-BE mode has
    # exactly one hard_breakeven_activated event, published at the first hard-BE-regime entry
    # (the engine removes liquidated legs from LegTrace, so the first hard-BE entry is the lowest
    # trade number across LegTrace and LiquidationTrace), or at the first rejected attempt when
    # the activation attempt was rejected, with both hard-BE boundaries equal to the anchor's.
    $hardBreakevenEvents = @(Get-EventsOfType 'hard_breakeven_activated')
    $hardBreakevenBaskets = @($expectedBasketRecords | Where-Object { [bool](Get-Property $_ 'HardBreakevenModeActive') })
    Test-ParityCheck ($hardBreakevenEvents.Count -eq $hardBreakevenBaskets.Count) `
        "hard_breakeven_activated parity: the package has $($hardBreakevenEvents.Count) activations but the authoritative HardBreakevenModeActive basket count is $($hardBreakevenBaskets.Count)"
    foreach ($basketRecord in $hardBreakevenBaskets) {
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        $matches = @($hardBreakevenEvents | Where-Object { [long](Get-Property $_ 'basket') -eq $sequence })
        Test-ParityCheck ($matches.Count -eq 1) "hard_breakeven_activated parity: $($matches.Count) events for hard-BE basket $sequence, expected exactly one"
        if ($matches.Count -lt 1) { continue }
        $event = $matches[0]
        # The activation belongs to the earliest hard-BE attempt, whichever authoritative record
        # carries it: a filled leg, a leg that was later liquidated, or a first rejected tail
        # attempt (a rejected-then-later-filled trade must bind to the rejection's first time).
        $candidates = New-Object System.Collections.Generic.List[object]
        foreach ($legRow in @(Get-Property $basketRecord 'LegTrace')) {
            if (([string](Get-Property $legRow 'Regime')) -cne 'HardBreakeven') { continue }
            [void]$candidates.Add([pscustomobject]@{
                    tradeNumber   = [long](Get-Property $legRow 'TradeNumber')
                    quoteSequence = [long](Get-Property $legRow 'QuoteSequence')
                    time          = Convert-ResultTime (Get-Property $legRow 'Time') "HardBreakeven LegTrace[$sequence].Time"
                    source        = 'LegTrace'
                })
        }
        foreach ($liquidationRow in @(Get-Property $basketRecord 'LiquidationTrace')) {
            if (([string](Get-Property $liquidationRow 'Regime')) -cne 'HardBreakeven') { continue }
            $tradeNumberCandidate = [long](Get-Property $liquidationRow 'TradeNumber')
            $quoteSequenceCandidate = [long]::MaxValue
            $entryKey = "$sequence/$tradeNumberCandidate"
            if ($entryEventByKey.ContainsKey($entryKey)) {
                $quoteSequenceCandidate = [long](Get-Property $entryEventByKey[$entryKey] 'quoteSequence')
            }
            [void]$candidates.Add([pscustomobject]@{
                    tradeNumber   = $tradeNumberCandidate
                    quoteSequence = $quoteSequenceCandidate
                    time          = Convert-ResultTime (Get-Property $liquidationRow 'EntryTime') "HardBreakeven LiquidationTrace[$sequence].EntryTime"
                    source        = 'LiquidationTrace'
                })
        }
        $normalTradeCount = [int](Get-Property $resultParameters 'NormalTradeCount')
        foreach ($rejectionRow in @(Get-Property $basketRecord 'RejectionTrace')) {
            $tradeNumberCandidate = [long](Get-Property $rejectionRow 'TradeNumber')
            $isTailAttempt = ($tradeNumberCandidate -gt $normalTradeCount) -or
                ($null -ne (Get-Property $rejectionRow 'HardBreakevenTarget')) -or
                ($null -ne (Get-Property $rejectionRow 'ExactRequiredLots'))
            if (-not $isTailAttempt) { continue }
            [void]$candidates.Add([pscustomobject]@{
                    tradeNumber   = $tradeNumberCandidate
                    quoteSequence = [long](Get-Property $rejectionRow 'FirstQuoteSequence')
                    time          = Convert-ResultTime (Get-Property $rejectionRow 'FirstTime') "HardBreakeven RejectionTrace[$sequence].FirstTime"
                    source        = 'RejectionTrace'
                })
        }
        $reference = $null
        foreach ($candidate in $candidates) {
            if ($null -eq $reference -or $candidate.time -lt $reference.time) { $reference = $candidate; continue }
            if ($candidate.time -eq $reference.time -and $candidate.quoteSequence -lt $reference.quoteSequence) { $reference = $candidate; continue }
            if ($candidate.time -eq $reference.time -and $candidate.quoteSequence -eq $reference.quoteSequence -and $candidate.tradeNumber -lt $reference.tradeNumber) { $reference = $candidate }
        }
        if ($null -eq $reference) {
            Add-Failure "hard_breakeven_activated parity: basket $sequence has no HardBreakeven entry, liquidation or tail rejection to locate its activation attempt"
            continue
        }
        Test-NumberParity (Get-Property $event 'tradeNumber') $reference.tradeNumber "hard_breakeven_activated[$sequence].tradeNumber"
        Test-TimeParity (Get-Property $event 'time') $reference.time "hard_breakeven_activated[$sequence].time (earliest authoritative hard-BE attempt: $($reference.source))"
        if ($reference.quoteSequence -ne [long]::MaxValue) {
            Test-NumberParity (Get-Property $event 'quoteSequence') $reference.quoteSequence "hard_breakeven_activated[$sequence].quoteSequence"
        }
        $anchor = Get-Property $basketRecord 'AnchorEvent'
        Test-NumberParity (Get-Property $event 'lowerTarget') (Get-Property $anchor 'LowerTarget') "hard_breakeven_activated[$sequence].lowerTarget"
        Test-NumberParity (Get-Property $event 'upperTarget') (Get-Property $anchor 'UpperTarget') "hard_breakeven_activated[$sequence].upperTarget"
    }

    # G2. Trailing activation lifecycle: at most one activation per basket, every activation maps
    # to an anchored basket, and the authoritative Trailing closes map one-to-one onto activations.
    $trailingLifecycleEvents = @(Get-EventsOfType 'trailing_activated')
    $trailingByBasket = @{}
    foreach ($trailingEvent in $trailingLifecycleEvents) {
        $basket = [long](Get-Property $trailingEvent 'basket')
        Test-ParityCheck (-not $trailingByBasket.ContainsKey($basket)) "trailing_activated parity: more than one activation for basket $basket"
        $trailingByBasket[$basket] = $trailingEvent
    }
    $anchoredBasketNumbers = @{}
    foreach ($anchorEvent in @(Get-EventsOfType 'basket_anchored')) {
        $anchoredBasketNumbers[[long](Get-Property $anchorEvent 'basket')] = $true
    }
    foreach ($trailingBasket in @($trailingByBasket.Keys)) {
        Test-ParityCheck ($anchoredBasketNumbers.ContainsKey([long]$trailingBasket)) "trailing_activated parity: basket $trailingBasket has no anchored basket"
    }
    $trailingCloseBaskets2 = @($closedBasketRecords | Where-Object { ([string](Get-Property $_ 'Reason')) -ceq 'Trailing' })
    Test-ParityCheck ($trailingLifecycleEvents.Count -eq $trailingCloseBaskets2.Count) `
        "trailing_activated parity: $($trailingLifecycleEvents.Count) activations but $($trailingCloseBaskets2.Count) authoritative Trailing closes"
    foreach ($basketRecord in $trailingCloseBaskets2) {
        $sequence = [long](Get-Property $basketRecord 'Sequence')
        Test-ParityCheck ($trailingByBasket.ContainsKey($sequence)) "the authoritative Trailing close of basket $sequence has no trailing_activated event"
    }

    # G3. One active basket at a time: an anchor starts the current basket, no other basket may
    # anchor until it closes, the sequence advances monotonically (no repeated anchors), and only
    # the last basket may remain unclosed.
    $activeBasket = $null
    $anchoredSeen = @{}
    foreach ($lifecycleEvent in $events) {
        $lifecycleType = [string](Get-Property $lifecycleEvent 'type')
        if ($lifecycleType -eq 'entry_rejection_summary') { continue }
        $lifecycleBasket = Get-Property $lifecycleEvent 'basket'
        if ($lifecycleType -eq 'basket_anchored') {
            $basketValue = [long]$lifecycleBasket
            Test-ParityCheck ($null -eq $activeBasket) "basket_anchored[$basketValue] while basket $activeBasket is still active"
            Test-ParityCheck (-not $anchoredSeen.ContainsKey($basketValue)) "basket_anchored[$basketValue] repeats an anchored basket"
            if ($null -eq $activeBasket) { $activeBasket = $basketValue }
            $anchoredSeen[$basketValue] = $true
        }
        elseif ($null -ne $lifecycleBasket) {
            $basketValue = [long]$lifecycleBasket
            if ($lifecycleType -eq 'strategy_exit' -or $lifecycleType -eq 'basket_liquidated') {
                $activeLabel = if ($null -eq $activeBasket) { 'none' } else { [string]$activeBasket }
                Test-ParityCheck ($activeBasket -eq $basketValue) "basket $basketValue closes while active basket is $activeLabel"
                if ($activeBasket -eq $basketValue) { $activeBasket = $null }
            }
            else {
                Test-ParityCheck ($activeBasket -eq $basketValue) "the $lifecycleType event for basket $basketValue does not belong to the active basket"
            }
        }
    }

    # H. run_ended account snapshot: the event's telemetry snapshot must be the final research
    # account and margin state. It is looked up after the telemetry scan below.

    # Telemetry: event coverage, periodic bound, exact decimal strings, time and quote order.
    $telemetryFileNames = @($fileRows | Where-Object { ([string](Get-Property $_ 'name')).StartsWith('telemetry-') } | ForEach-Object { [string](Get-Property $_ 'name') })
    $diskTelemetryFiles = @(Get-ChildItem -LiteralPath $replayDirectory -Filter 'telemetry-*.jsonl' | Sort-Object Name)
    $diskTelemetryNames = @($diskTelemetryFiles | ForEach-Object { $_.Name })
    Test-Check ($diskTelemetryNames.Count -ge 1) "no telemetry shard exists"
    Test-Check (($diskTelemetryNames -join ',') -eq ($telemetryFileNames -join ',')) `
        "the on-disk telemetry shards do not match the manifest file list"
    $telemetryInterval = Get-Property $manifest 'telemetryIntervalSeconds'
    Test-Check ([decimal]$telemetryInterval -eq 300) "manifest.telemetryIntervalSeconds is not the fixed 300"
    $snapshotIds = New-Object System.Collections.Generic.HashSet[long]
    $snapshotByEventId = @{}
    $periodic = 0
    $eventSnapshots = 0
    $previousTelemetryTime = $null
    $previousTelemetrySequence = $null
    $quoteTicksProcessedValue = [long](Get-Property $results 'quoteTicksProcessed')
    $lastPeriodicTime = $null
    foreach ($telemetryName in $telemetryFileNames) {
        $telemetryPath = Join-Path $replayDirectory $telemetryName
        if (-not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
            Add-Failure "the manifest lists a missing telemetry shard: $telemetryName"
            continue
        }
        foreach ($row in @(Read-JsonLines $telemetryPath)) {
            $kind = [string](Get-Property $row 'kind')
            if ($kind -ne 'event' -and $kind -ne 'periodic') { Add-Failure "unknown telemetry kind '$kind'"; continue }
            $openPositions = [int](Get-Property $row 'openPositions')
            if ($openPositions -eq 0) { $lastPeriodicTime = $null }
            foreach ($field in $requiredDecimalFields) { Assert-ExactString $row $field "telemetry[$telemetryName] kind=$kind" $true }
            foreach ($field in $nullableDecimalFields) { Assert-ExactString $row $field "telemetry[$telemetryName] kind=$kind" $false }
            try {
                $time = Convert-UtcTime (Get-Property $row 'time') "telemetry.time"
                if ($null -ne $previousTelemetryTime -and $time -lt $previousTelemetryTime) {
                    Add-Failure "telemetry goes backwards in time at $($time.ToString('o'))"
                }
                $previousTelemetryTime = $time
                if ($shardYearByName.ContainsKey($telemetryName) -and $time.Year -ne $shardYearByName[$telemetryName]) {
                    Add-Failure "telemetry[$telemetryName] row year $($time.Year) does not match the shard year $($shardYearByName[$telemetryName])"
                }
                $rowSequence = [long](Get-Property $row 'quoteSequence')
                if ($rowSequence -gt $quoteTicksProcessedValue) {
                    Add-Failure "telemetry[$telemetryName] quote sequence $rowSequence exceeds results.quoteTicksProcessed $quoteTicksProcessedValue"
                }
                if ($null -ne $previousTelemetrySequence -and $rowSequence -lt $previousTelemetrySequence) {
                    Add-Failure "telemetry[$telemetryName] goes backwards in quote sequence ($rowSequence after $previousTelemetrySequence)"
                }
                $previousTelemetrySequence = $rowSequence
                if ($kind -eq 'periodic') {
                    $periodic++
                    if ($openPositions -le 0) {
                        Add-Failure "a periodic telemetry sample was taken with no open position"
                    }
                    if ($null -ne (Get-Property $row 'eventId')) {
                        Add-Failure "a periodic telemetry sample carries an eventId"
                    }
                    if ($null -ne $lastPeriodicTime) {
                        $delta = ($time - $lastPeriodicTime).TotalSeconds
                        if ($delta -lt [double]$telemetryInterval) {
                            Add-Failure "periodic telemetry at $($time.ToString('o')) is only $delta simulated seconds after the previous periodic sample (minimum $telemetryInterval)"
                        }
                    }
                    $lastPeriodicTime = $time
                }
                else {
                    $eventSnapshots++
                    $eventId = Get-Property $row 'eventId'
                    if ($null -eq $eventId) { Add-Failure "an event telemetry snapshot has no eventId"; continue }
                    if (-not $snapshotIds.Add([long]$eventId)) { Add-Failure "duplicate eventId telemetry snapshot for event $eventId" }
                    if (-not $snapshotByEventId.ContainsKey([long]$eventId)) { $snapshotByEventId[[long]$eventId] = $row }
                }
            }
            catch { Add-Failure $_.Exception.Message }
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

    # ---- Event-snapshot binding, derived pre-attempt state and lifecycle ordering ----
    # Every significant event's telemetry snapshot must be the account state at the event's exact
    # time and quote; event classes that carry overlapping account values compare them to the
    # snapshot, so tampering one side alone cannot pass. The hard-BE activation snapshot is
    # additionally proven to be the pre-attempt state derived from the parity-verified
    # entry/liquidation events, and trailing activation thresholds are re-derived from the
    # parity-verified anchor step, the surviving inventory and the parity-verified parameters.
    $snapshotAccountFields = @{
        'stop_out_triggered'  = @('balance', 'floatingProfit', 'equity', 'usedMargin', 'freeMargin', 'marginLevelPercent', 'openPositions')
        'margin_call_entered' = @('balance', 'equity', 'usedMargin', 'freeMargin', 'marginLevelPercent', 'openPositions')
        'margin_call_left'    = @('balance', 'equity', 'usedMargin', 'freeMargin', 'marginLevelPercent', 'openPositions')
    }
    $anchorStepByBasket = @{}
    foreach ($basketRecord in $expectedBasketRecords) {
        $anchorStepByBasket[[long](Get-Property $basketRecord 'Sequence')] = Get-Property (Get-Property $basketRecord 'AnchorEvent') 'Step'
    }
    $trailingUnitsValue = [decimal](Get-Property $resultParameters 'TrailingActivationUnits')
    $pointValueValue = [decimal](Get-Property $resultParameters 'PointValuePerLot')
    $openLegs = @{}
    foreach ($event in $events) {
        $type = [string](Get-Property $event 'type')
        $eventId = [long](Get-Property $event 'id')
        if ($type -eq 'entry_rejection_summary') { continue }
        # Inventory transitions happen before the snapshot checks: an entry snapshot is the
        # post-entry state, a forced-liquidation snapshot is the post-close state, and a close
        # leaves the basket flat.
        if ($type -eq 'entry_executed') {
            $basket = [long](Get-Property $event 'basket')
            if (-not $openLegs.ContainsKey($basket)) { $openLegs[$basket] = @{} }
            $openLegs[$basket][[long](Get-Property $event 'tradeNumber')] = [pscustomobject]@{
                side = [string](Get-Property $event 'side')
                lot  = [decimal](Get-Property $event 'placedLot')
            }
        }
        elseif ($type -eq 'forced_liquidation') {
            $basket = [long](Get-Property $event 'basket')
            if ($openLegs.ContainsKey($basket)) { [void]$openLegs[$basket].Remove([long](Get-Property $event 'tradeNumber')) }
        }
        elseif ($type -eq 'strategy_exit' -or $type -eq 'basket_liquidated') {
            $basket = [long](Get-Property $event 'basket')
            if ($openLegs.ContainsKey($basket)) { $openLegs[$basket] = @{} }
        }
        if (-not $snapshotByEventId.ContainsKey($eventId)) { continue }
        $snapshot = $snapshotByEventId[$eventId]
        try {
            $eventTime = Convert-UtcTime (Get-Property $event 'time') "event[$eventId].time"
            Test-TimeParity (Get-Property $snapshot 'time') $eventTime "telemetry[$eventId].time"
        }
        catch { Add-Failure $_.Exception.Message }
        # The applicable quote identity: the generic quoteSequence, the liquidation trigger quote
        # for forced_liquidation (which does not expose the generic property), zero at run start
        # and the processed-quote counter at run end.
        if ($type -eq 'forced_liquidation') {
            Test-NumberParity (Get-Property $snapshot 'quoteSequence') (Get-Property $event 'triggerQuoteSequence') "telemetry[$eventId].quoteSequence (trigger)"
        }
        elseif (Has-Property $event 'quoteSequence') {
            Test-NumberParity (Get-Property $snapshot 'quoteSequence') (Get-Property $event 'quoteSequence') "telemetry[$eventId].quoteSequence"
        }
        if ($type -eq 'run_started') {
            Test-NumberParity (Get-Property $snapshot 'quoteSequence') 0 "telemetry[$eventId].quoteSequence (run start)"
        }
        if ($type -eq 'run_ended') {
            Test-NumberParity (Get-Property $snapshot 'quoteSequence') (Get-Property $results 'quoteTicksProcessed') "telemetry[$eventId].quoteSequence (run end)"
        }
        if ($snapshotAccountFields.ContainsKey($type)) {
            foreach ($field in $snapshotAccountFields[$type]) {
                Test-NumberParity (Get-Property $snapshot $field) (Get-Property $event $field) "telemetry[$eventId].$field"
            }
        }
        if ($type -eq 'forced_liquidation') {
            foreach ($pair in @(@('balance', 'afterBalance'), @('floatingProfit', 'afterFloatingProfit'), @('equity', 'afterEquity'),
                    @('usedMargin', 'afterUsedMargin'), @('freeMargin', 'afterFreeMargin'),
                    @('marginLevelPercent', 'afterMarginLevelPercent'), @('openPositions', 'afterOpenPositions'))) {
                Test-NumberParity (Get-Property $snapshot $pair[0]) (Get-Property $event $pair[1]) "telemetry[$eventId].$($pair[1])"
            }
        }
        # Margin Call state conditions and the account arithmetic identities, checked against the
        # already-authoritative margin contract (MarginModel.MarginLevelPercent and
        # ResearchAccount.ObserveMarginState), never by reconstructing strategy logic.
        if ($type -eq 'margin_call_entered' -or $type -eq 'margin_call_left') {
            $balanceValue = Convert-JsonDecimal (Get-Property $snapshot 'balance') "telemetry[$eventId].balance"
            $floatingValue = Convert-JsonDecimal (Get-Property $snapshot 'floatingProfit') "telemetry[$eventId].floatingProfit"
            $equityValue = Convert-JsonDecimal (Get-Property $snapshot 'equity') "telemetry[$eventId].equity"
            $usedValue = Convert-JsonDecimal (Get-Property $snapshot 'usedMargin') "telemetry[$eventId].usedMargin"
            $freeValue = Convert-JsonDecimal (Get-Property $snapshot 'freeMargin') "telemetry[$eventId].freeMargin"
            $levelValue = Convert-JsonDecimal (Get-Property $snapshot 'marginLevelPercent') "telemetry[$eventId].marginLevelPercent"
            if ($null -ne $balanceValue -and $null -ne $floatingValue -and $null -ne $equityValue) {
                Test-NumberParity $equityValue ($balanceValue + $floatingValue) "telemetry[$eventId].equity identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $freeValue) {
                Test-NumberApproxParity $freeValue ($equityValue - $usedValue) "telemetry[$eventId].freeMargin identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $levelValue -and $usedValue -gt 0) {
                Test-NumberApproxParity $levelValue ($equityValue / $usedValue * 100) "telemetry[$eventId].marginLevelPercent identity"
            }
            $marginCallLevel = [decimal](Get-Property $resultMarginParameters 'MarginCallLevelPercent')
            if ($type -eq 'margin_call_entered') {
                Test-BoolParity (Get-Property $snapshot 'marginCallActive') $true "telemetry[$eventId].marginCallActive (entered)"
                Test-ParityCheck ($null -ne $levelValue -and $levelValue -le $marginCallLevel) "margin_call_entered[$eventId] has a margin level above the configured Margin Call level"
            }
            else {
                Test-BoolParity (Get-Property $snapshot 'marginCallActive') $false "telemetry[$eventId].marginCallActive (left)"
                Test-ParityCheck ($null -eq $levelValue -or $levelValue -gt $marginCallLevel) "margin_call_left[$eventId] has a margin level inside the Margin Call condition"
            }
        }
        if ($type -eq 'stop_out_triggered') {
            $balanceValue = Convert-JsonDecimal (Get-Property $event 'balance') "stop_out_triggered[$eventId].balance"
            $floatingValue = Convert-JsonDecimal (Get-Property $event 'floatingProfit') "stop_out_triggered[$eventId].floatingProfit"
            $equityValue = Convert-JsonDecimal (Get-Property $event 'equity') "stop_out_triggered[$eventId].equity"
            $usedValue = Convert-JsonDecimal (Get-Property $event 'usedMargin') "stop_out_triggered[$eventId].usedMargin"
            $freeValue = Convert-JsonDecimal (Get-Property $event 'freeMargin') "stop_out_triggered[$eventId].freeMargin"
            $levelValue = Convert-JsonDecimal (Get-Property $event 'marginLevelPercent') "stop_out_triggered[$eventId].marginLevelPercent"
            if ($null -ne $balanceValue -and $null -ne $floatingValue -and $null -ne $equityValue) {
                Test-NumberParity $equityValue ($balanceValue + $floatingValue) "stop_out_triggered[$eventId].equity identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $freeValue) {
                Test-NumberApproxParity $freeValue ($equityValue - $usedValue) "stop_out_triggered[$eventId].freeMargin identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $levelValue -and $usedValue -gt 0) {
                Test-NumberApproxParity $levelValue ($equityValue / $usedValue * 100) "stop_out_triggered[$eventId].marginLevelPercent identity"
            }
            # The two EvaluateSurvival branches: a MarginLevel stop out requires a defined level at
            # or below the configured Stop Out level; a NegativeEquity stop out requires negative
            # equity with open positions (and no defined-level requirement).
            $stopOutReason = [string](Get-Property $event 'reason')
            $stopOutLevel = [decimal](Get-Property $resultMarginParameters 'StopOutLevelPercent')
            $openPositionsValue = [int](Get-Property $event 'openPositions')
            if ($stopOutReason -ceq 'MarginLevel') {
                Test-ParityCheck ([int](Get-Property $event 'openPositions') -gt 0) "stop_out_triggered[$eventId] has no open positions"
                Test-ParityCheck ($null -ne $levelValue -and $levelValue -le $stopOutLevel) "stop_out_triggered[$eventId] MarginLevel state is above the configured Stop Out level"
            }
            elseif ($stopOutReason -ceq 'NegativeEquity') {
                Test-ParityCheck $openPositionsValue -gt 0 "stop_out_triggered[$eventId] NegativeEquity state has no open positions"
                Test-ParityCheck ($null -ne $equityValue -and $equityValue -lt 0) "stop_out_triggered[$eventId] NegativeEquity state has non-negative equity"
            }
            else {
                Add-Failure "stop_out_triggered[$eventId] has an unknown reason '$stopOutReason'"
            }
        }
        if ($type -eq 'forced_liquidation') {
            foreach ($prefix in @('before', 'after')) {
                $balanceValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'Balance')) "forced_liquidation[$eventId].$($prefix)Balance"
                $floatingValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'FloatingProfit')) "forced_liquidation[$eventId].$($prefix)FloatingProfit"
                $equityValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'Equity')) "forced_liquidation[$eventId].$($prefix)Equity"
                $usedValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'UsedMargin')) "forced_liquidation[$eventId].$($prefix)UsedMargin"
                $freeValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'FreeMargin')) "forced_liquidation[$eventId].$($prefix)FreeMargin"
                $levelValue = Convert-JsonDecimal (Get-Property $event ($prefix + 'MarginLevelPercent')) "forced_liquidation[$eventId].$($prefix)MarginLevelPercent"
                if ($null -ne $balanceValue -and $null -ne $floatingValue -and $null -ne $equityValue) {
                    Test-NumberParity $equityValue ($balanceValue + $floatingValue) "forced_liquidation[$eventId].$($prefix) equity identity"
                }
                if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $freeValue) {
                    Test-NumberApproxParity $freeValue ($equityValue - $usedValue) "forced_liquidation[$eventId].$($prefix) freeMargin identity"
                }
                if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $levelValue -and $usedValue -gt 0) {
                    Test-NumberApproxParity $levelValue ($equityValue / $usedValue * 100) "forced_liquidation[$eventId].$($prefix) marginLevelPercent identity"
                }
            }
        }
        if ($type -eq 'run_ended') {
            $balanceValue = Convert-JsonDecimal (Get-Property $snapshot 'balance') "telemetry[$eventId].balance"
            $floatingValue = Convert-JsonDecimal (Get-Property $snapshot 'floatingProfit') "telemetry[$eventId].floatingProfit"
            $equityValue = Convert-JsonDecimal (Get-Property $snapshot 'equity') "telemetry[$eventId].equity"
            $usedValue = Convert-JsonDecimal (Get-Property $snapshot 'usedMargin') "telemetry[$eventId].usedMargin"
            $freeValue = Convert-JsonDecimal (Get-Property $snapshot 'freeMargin') "telemetry[$eventId].freeMargin"
            $levelValue = Convert-JsonDecimal (Get-Property $snapshot 'marginLevelPercent') "telemetry[$eventId].marginLevelPercent"
            if ($null -ne $balanceValue -and $null -ne $floatingValue -and $null -ne $equityValue) {
                Test-NumberParity $equityValue ($balanceValue + $floatingValue) "telemetry[$eventId].equity identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $freeValue) {
                Test-NumberApproxParity $freeValue ($equityValue - $usedValue) "telemetry[$eventId].freeMargin identity"
            }
            if ($null -ne $equityValue -and $null -ne $usedValue -and $null -ne $levelValue -and $usedValue -gt 0) {
                Test-NumberApproxParity $levelValue ($equityValue / $usedValue * 100) "telemetry[$eventId].marginLevelPercent identity"
            }
        }
        # The parity-verified inventory transition: the snapshot must be the derived post-entry
        # (entry) or post-close (forced liquidation) state of the surviving basket legs.
        if ($type -eq 'entry_executed' -or $type -eq 'forced_liquidation') {
            $basket = [long](Get-Property $event 'basket')
            $legs = if ($openLegs.ContainsKey($basket)) { $openLegs[$basket] } else { @{} }
            $count = 0
            $gross = [decimal]0
            $net = [decimal]0
            foreach ($leg in $legs.Values) {
                $count++
                $gross += $leg.lot
                if ($leg.side -ceq 'Buy') { $net += $leg.lot } else { $net -= $leg.lot }
            }
            $qualifier = if ($type -eq 'entry_executed') { 'post-entry' } else { 'post-close' }
            Test-NumberParity (Get-Property $snapshot 'openPositions') $count "telemetry[$eventId].openPositions (derived $qualifier)"
            Test-NumberParity (Get-Property $snapshot 'grossLots') $gross "telemetry[$eventId].grossLots (derived $qualifier)"
            Test-NumberParity (Get-Property $snapshot 'absoluteNetLots') ([math]::Abs($net)) "telemetry[$eventId].absoluteNetLots (derived $qualifier)"
        }
        if ($type -eq 'hard_breakeven_activated' -or $type -eq 'trailing_activated') {
            $basket = [long](Get-Property $event 'basket')
            $legs = if ($openLegs.ContainsKey($basket)) { $openLegs[$basket] } else { @{} }
            $count = 0
            $gross = [decimal]0
            $net = [decimal]0
            $smallest = $null
            foreach ($leg in $legs.Values) {
                $count++
                $gross += $leg.lot
                if ($leg.side -ceq 'Buy') { $net += $leg.lot } else { $net -= $leg.lot }
                if ($null -eq $smallest -or $leg.lot -lt $smallest) { $smallest = $leg.lot }
            }
            if ($type -eq 'hard_breakeven_activated') {
                # The activation is published before sizing/placing the first tail attempt, so the
                # snapshot must show the surviving pre-attempt inventory.
                Test-NumberParity (Get-Property $snapshot 'openPositions') $count "telemetry[$eventId].openPositions (derived pre-attempt)"
                Test-NumberParity (Get-Property $snapshot 'grossLots') $gross "telemetry[$eventId].grossLots (derived pre-attempt)"
                Test-NumberParity (Get-Property $snapshot 'absoluteNetLots') ([math]::Abs($net)) "telemetry[$eventId].absoluteNetLots (derived pre-attempt)"
            }
            else {
                # activationThreshold = TrailingActivationUnits * Step * ExitSensitivityLots *
                # PointValuePerLot, evaluated with the engine's exact decimal operations over the
                # surviving inventory.
                if ($count -eq 0) { Add-Failure "trailing_activated[$eventId] fired with no open legs on basket $basket" }
                else {
                    $sensitivity = if ($net -eq 0) { $smallest } else { [math]::Abs($net) }
                    $step = [decimal]$anchorStepByBasket[$basket]
                    $stepMoney = $step * $sensitivity * $pointValueValue
                    $expectedThreshold = $trailingUnitsValue * $stepMoney
                    Test-NumberParity (Get-Property $event 'activationThreshold') $expectedThreshold "trailing_activated[$eventId].activationThreshold (derived)"
                    Test-ParityCheck ([decimal](Get-Property $event 'profit') -ge $expectedThreshold) "trailing_activated[$eventId].profit is below the derived activation threshold"
                }
            }
        }
    }

    # Lifecycle ordering: same-timestamp causal order is part of the contract.
    $indexOfId = @{}
    for ($i = 0; $i -lt $events.Count; $i++) { $indexOfId[[long](Get-Property $events[$i] 'id')] = $i }
    # (a) hard-BE activation strictly before the attempt it enables, on the same quote. The
    # enabling attempt is whichever of the first rejection of that trade or its later fill
    # appears first in the stream (a rejected-then-later-filled trade activates on the rejection).
    foreach ($activationEvent in @(Get-EventsOfType 'hard_breakeven_activated')) {
        $basket = [long](Get-Property $activationEvent 'basket')
        $tradeNumber = [long](Get-Property $activationEvent 'tradeNumber')
        $key = "$basket/$tradeNumber"
        $attempt = $null
        $attemptIndex = [int]::MaxValue
        if ($entryEventByKey.ContainsKey($key)) {
            $attemptIndex = $indexOfId[[long](Get-Property $entryEventByKey[$key] 'id')]
            $attempt = $entryEventByKey[$key]
        }
        $rejected = @($entryRejectedEvents | Where-Object { [long](Get-Property $_ 'basket') -eq $basket -and [long](Get-Property $_ 'tradeNumber') -eq $tradeNumber })
        foreach ($rejectedEvent in $rejected) {
            $rejectedIndex = $indexOfId[[long](Get-Property $rejectedEvent 'id')]
            if ($rejectedIndex -lt $attemptIndex) { $attemptIndex = $rejectedIndex; $attempt = $rejectedEvent }
        }
        if ($null -eq $attempt) {
            Add-Failure "hard_breakeven_activated[$basket/$tradeNumber] has no enabling attempt event"
            continue
        }
        $activationIndex = $indexOfId[[long](Get-Property $activationEvent 'id')]
        Test-ParityCheck ($activationIndex -lt $attemptIndex) "hard_breakeven_activated[$basket/$tradeNumber] does not precede its enabling attempt"
        Test-TimeParity (Get-Property $activationEvent 'time') (Get-Property $attempt 'time') "hard_breakeven_activated[$basket/$tradeNumber].time vs enabling attempt"
    }
    # (b) Margin Call entry/exit alternation; stop-out requires an active Margin Call.
    $marginEnabledFlag = $false
    $marginCallState = $false
    foreach ($event in $events) {
        $type = [string](Get-Property $event 'type')
        if ($type -eq 'entry_rejection_summary') { continue }
        if ($type -eq 'margin_call_entered') {
            $marginEnabledFlag = $true
            Test-ParityCheck (-not $marginCallState) "margin_call_entered while already active (event id $([long](Get-Property $event 'id')))"
            $marginCallState = $true
        }
        elseif ($type -eq 'margin_call_left') {
            $marginEnabledFlag = $true
            Test-ParityCheck $marginCallState "margin_call_left while not active (event id $([long](Get-Property $event 'id')))"
            $marginCallState = $false
        }
        elseif ($type -eq 'stop_out_triggered') {
            # Only the MarginLevel branch implies a defined level at or below the Margin Call
            # level; the NegativeEquity branch occurs with no defined margin level.
            if (([string](Get-Property $event 'reason')) -ceq 'MarginLevel') {
                Test-ParityCheck $marginCallState "MarginLevel stop_out_triggered without an active Margin Call (event id $([long](Get-Property $event 'id')))"
            }
        }
    }
    if ($null -ne $margin) {
        Test-ParityCheck ($marginCallState -eq [bool](Get-Property $margin 'MarginCallActive')) "the Margin Call state at the end of the event stream does not match researchMargin.MarginCallActive"
    }
    # (c) Each Stop Out trigger precedes that episode's first forced liquidation and follows the
    # previous episode's last one; (d) each basket_liquidated follows the last forced close.
    $stopOutEventIndexes = @()
    foreach ($stopOutEvent in @(Get-EventsOfType 'stop_out_triggered')) { $stopOutEventIndexes += $indexOfId[[long](Get-Property $stopOutEvent 'id')] }
    $forcedEventIndexes = @()
    foreach ($forcedEvent in @(Get-EventsOfType 'forced_liquidation')) { $forcedEventIndexes += $indexOfId[[long](Get-Property $forcedEvent 'id')] }
    $flatIndex = 0
    for ($episodeIndex = 0; $episodeIndex -lt $episodes.Count; $episodeIndex++) {
        $liquidationCount = @(Get-Property $episodes[$episodeIndex] 'Liquidations').Count
        if ($episodeIndex -lt $stopOutEventIndexes.Count -and $liquidationCount -gt 0) {
            $triggerIndex = $stopOutEventIndexes[$episodeIndex]
            $firstForcedIndex = $forcedEventIndexes[$flatIndex]
            Test-ParityCheck ($triggerIndex -lt $firstForcedIndex) `
                "stop_out_triggered[$episodeIndex] does not precede the episode's first forced liquidation"
            if ($episodeIndex -gt 0) {
                Test-ParityCheck ($triggerIndex -gt $forcedEventIndexes[$flatIndex - 1]) `
                    "stop_out_triggered[$episodeIndex] precedes the previous episode's forced liquidations"
            }
        }
        $flatIndex += $liquidationCount
    }
    $lastForcedIndexByBasket = @{}
    foreach ($forcedEvent in @(Get-EventsOfType 'forced_liquidation')) {
        $lastForcedIndexByBasket[[long](Get-Property $forcedEvent 'basket')] = $indexOfId[[long](Get-Property $forcedEvent 'id')]
    }
    foreach ($liquidatedEvent in @(Get-EventsOfType 'basket_liquidated')) {
        $basket = [long](Get-Property $liquidatedEvent 'basket')
        if ($lastForcedIndexByBasket.ContainsKey($basket)) {
            Test-ParityCheck ($indexOfId[[long](Get-Property $liquidatedEvent 'id')] -gt $lastForcedIndexByBasket[$basket]) `
                "basket_liquidated[$basket] does not follow the basket's last forced liquidation"
        }
    }
    # (e) Trailing activation precedes the basket's close; same-quote forced liquidations keep
    # strictly ascending ordinals.
    $closeIndexByBasket = @{}
    foreach ($closeEvent in @(@(Get-EventsOfType 'strategy_exit') + @(Get-EventsOfType 'basket_liquidated'))) {
        $closeIndexByBasket[[long](Get-Property $closeEvent 'basket')] = $indexOfId[[long](Get-Property $closeEvent 'id')]
    }
    foreach ($trailingEvent in @(Get-EventsOfType 'trailing_activated')) {
        $basket = [long](Get-Property $trailingEvent 'basket')
        if ($closeIndexByBasket.ContainsKey($basket)) {
            Test-ParityCheck ($indexOfId[[long](Get-Property $trailingEvent 'id')] -lt $closeIndexByBasket[$basket]) `
                "trailing_activated[$basket] does not precede the basket close"
        }
    }
    $previousForcedOrdinal = $null
    $previousForcedQuote = $null
    foreach ($forcedEvent in @(Get-EventsOfType 'forced_liquidation')) {
        $ordinal = [long](Get-Property $forcedEvent 'ordinal')
        $triggerQuote = [long](Get-Property $forcedEvent 'triggerQuoteSequence')
        if ($null -ne $previousForcedOrdinal -and $triggerQuote -eq $previousForcedQuote -and $ordinal -le $previousForcedOrdinal) {
            Add-Failure "same-quote forced liquidations are not in ascending ordinal order at event id $([long](Get-Property $forcedEvent 'id'))"
        }
        $previousForcedOrdinal = $ordinal
        $previousForcedQuote = $triggerQuote
    }

    # H (continued). run_ended account snapshot against the final research account and margin state.
    $runEndedId = [long](Get-Property $runEnded 'id')
    if (-not $snapshotByEventId.ContainsKey($runEndedId)) {
        Add-Failure "run_ended parity: the run_ended event has no telemetry account snapshot"
    }
    else {
        $runEndedSnapshot = $snapshotByEventId[$runEndedId]
        $researchAccount = Get-Property $results 'researchAccount'
        if ($null -eq $researchAccount) { Add-Failure "run_ended parity: results.researchAccount is missing" }
        else {
            foreach ($pair in @(@('balance', 'Balance'), @('equity', 'Equity'), @('floatingProfit', 'FloatingProfit'),
                    @('realizedProfit', 'RealizedProfit'), @('openPositions', 'CurrentOpenPositions'),
                    @('grossLots', 'CurrentGrossLots'), @('absoluteNetLots', 'CurrentAbsoluteNetLots'))) {
                Test-NumberParity (Get-Property $runEndedSnapshot $pair[0]) (Get-Property $researchAccount $pair[1]) "run_ended snapshot.$($pair[0])"
            }
        }
        if ($null -eq $margin) { Add-Failure "run_ended parity: results.researchMargin is missing" }
        else {
            foreach ($pair in @(@('usedMargin', 'CurrentUsedMargin'), @('freeMargin', 'CurrentFreeMargin'),
                    @('marginLevelPercent', 'CurrentMarginLevelPercent'))) {
                Test-NumberParity (Get-Property $runEndedSnapshot $pair[0]) (Get-Property $margin $pair[1]) "run_ended snapshot.$($pair[0])"
            }
            Test-BoolParity (Get-Property $runEndedSnapshot 'marginCallActive') (Get-Property $margin 'MarginCallActive') "run_ended snapshot.marginCallActive"
        }
    }

    # A deterministic verification record: the event-type counts are emitted in sorted key order
    # (a raw hashtable's enumeration order is not stable across runs) and the run identity is the
    # directory name only, never its absolute path, so the record is byte-reproducible when the
    # same package is verified in another location.
    $eventTypesOrdered = [ordered]@{}
    foreach ($eventTypeKey in @($eventCounts.Keys | Sort-Object)) {
        $eventTypesOrdered[$eventTypeKey] = $eventCounts[$eventTypeKey]
    }
    $summary = [ordered]@{
        contract = 'marketlab-single-anchor-replay-package-verification-v1'
        runDirectory = [System.IO.Path]::GetFileName($run)
        pass = ($script:failures.Count -eq 0)
        checks = $script:checks
        parityChecks = $script:parityChecks
        failures = @($script:failures)
        failuresTruncated = $script:failuresTruncated
        resultsSha256 = $resultsSha256
        expectedResultsSha256 = if ($ExpectedResultsSha256) { $ExpectedResultsSha256.ToLowerInvariant() } else { $null }
        resultsBoundToPhaseD = if ($ExpectedResultsSha256) { $resultsSha256 -eq $ExpectedResultsSha256.ToLowerInvariant() } else { $null }
        packageSha256 = [string](Get-Property $manifest 'packageSha256')
        eventCount = $events.Count
        eventTypes = $eventTypesOrdered
        telemetryEventSnapshots = $eventSnapshots
        telemetryPeriodicSamples = $periodic
        telemetryShards = @($telemetryFileNames)
        packageFiles = @($fileRows | ForEach-Object { [ordered]@{ name = (Get-Property $_ 'name'); sha256 = (Get-Property $_ 'sha256'); bytes = (Get-Property $_ 'bytes') } })
    }
    $json = ($summary | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    if ($script:failures.Count -eq 0) {
        Write-Output "PASS: replay package verified ($($script:checks) checks, $($script:parityChecks) payload-parity comparisons); results $resultsSha256; package $($summary.packageSha256); $($events.Count) events; $eventSnapshots event snapshots; $periodic periodic samples."
        exit 0
    }
    Write-Output "FAIL: replay package verification found $($script:failures.Count) problem(s) in $($script:checks) checks ($($script:parityChecks) payload-parity comparisons):"
    foreach ($failure in $script:failures) { Write-Output "  - $failure" }
    exit 1
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
