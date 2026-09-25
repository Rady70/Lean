<#
.SYNOPSIS
Measures the throughput overhead of the SingleAnchor research account on the shipped fixture.

.DESCRIPTION
Runs the same representative C# tick fixture through the MarketLab helper in three
configurations, in one session and in a rotated round-robin order:

  pre-change  the DLL built from the base revision, no research-account code at all
  disabled    the current DLL with `single-anchor-research-account:false`
  enabled     the current DLL with the research account attached (the default)

Each configuration gets one warm-up run and -Rounds measured runs (default 5, the roadmap's
3-5). Wall-clock seconds and the derived ticks/second are reported, as is the paired
per-quote cost of the analytics.

The acceptance threshold is set after the measurement from the pre-change baseline runs only
(the roadmap's requirement): the enabled median must not exceed the pre-change mean plus two
pre-change sample standard deviations. The account-disabled configuration is measured and
reported as a diagnostic (it isolates the attributable account cost), but it is not mixed into
the baseline variance, because it is a different binary and its systematic difference is not
run-to-run noise.

If the pre-change relative standard deviation is large (more than 3%), the session is too noisy
to distinguish the candidate effect: the script reports INCONCLUSIVE regardless of how the
enabled median compares with the bound, and asks for a rerun under cleaner conditions, rather
than letting a wide bound, or a wide band, certify the result. Exit codes: 0 PASS, 1 FAIL,
2 INCONCLUSIVE; a run that itself fails aborts the script with an error.

The absolute times depend on the host (start-up, caches, other applications). Compare the
three configurations within one session; the rotated order removes ordering bias.

.PARAMETER PreChangeDll
Path to the MarketLab.SingleAnchor.dll built from the base revision (before the research
account). Build it from a worktree at the base commit if necessary.

.PARAMETER CurrentDll
Path to the current MarketLab.SingleAnchor.dll.

.EXAMPLE
pwsh -File MarketLab\scripts\Measure-SingleAnchorResearchOverhead.ps1 `
    -PreChangeDll C:\worktrees\base\MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll `
    -CurrentDll MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PreChangeDll,
    [Parameter(Mandatory = $true)][string]$CurrentDll,
    [string]$Parameters = 'single-anchor-step-percent:0.2,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.5',
    [int]$Rounds = 5,
    [long]$ExpectedQuoteTicks = 1688736,
    [string]$OutputRoot = (Join-Path $env:TEMP ('marketlab-research-overhead-' + [Guid]::NewGuid().ToString('N'))),
    [string]$Helper = (Join-Path $PSScriptRoot 'run-backtest.ps1')
)

$ErrorActionPreference = 'Stop'
if ($Rounds -lt 3) { throw 'Rounds must be at least 3 (the roadmap asks for 3-5 measured runs).' }
foreach ($dll in @($PreChangeDll, $CurrentDll)) {
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { throw "algorithm DLL not found: $dll" }
}
if (-not (Test-Path -LiteralPath $Helper -PathType Leaf)) { throw "helper not found: $Helper" }

$shell = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Write-Host "shell: $shell"
Write-Host "output root: $OutputRoot"

function Invoke-Run([string]$Name, [string]$Dll, [string]$ParameterList, [string]$Round) {
    $out = Join-Path $OutputRoot $Name
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    & $shell -NoProfile -File $Helper -AlgorithmTypeName SingleAnchorVNextAlgorithm `
        -AlgorithmLocation $Dll -Parameters $ParameterList -OutputRoot $out | Out-Null
    $code = $LASTEXITCODE
    $watch.Stop()
    if ($code -ne 0) { throw "run '$Name' (round $Round) exited with code $code" }
    [pscustomobject]@{ Config = $Name; Round = $Round; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3) }
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    if ($count % 2 -eq 1) { return [double]$sorted[[int](($count - 1) / 2)] }
    return ([double]$sorted[$count / 2 - 1] + [double]$sorted[$count / 2]) / 2
}

function Get-HalfSpread([double[]]$Values) {
    $median = Get-Median $Values
    $min = ($Values | Measure-Object -Minimum).Minimum
    $max = ($Values | Measure-Object -Maximum).Maximum
    return ($max - $min) / (2 * $median)
}

$configs = [ordered]@{
    pre      = @{ Dll = $PreChangeDll; Parameters = $Parameters }
    disabled = @{ Dll = $CurrentDll; Parameters = "$Parameters,single-anchor-research-account:false" }
    enabled  = @{ Dll = $CurrentDll; Parameters = $Parameters }
}
$order = @('pre', 'disabled', 'enabled')

Write-Host 'warm-up (one run per configuration)'
foreach ($name in $order) {
    Invoke-Run $name $configs[$name].Dll $configs[$name].Parameters 'warmup' | Out-Null
}

$rows = New-Object System.Collections.Generic.List[object]
for ($round = 0; $round -lt $Rounds; $round++) {
    $offset = $round % 3
    $rotated = @()
    for ($i = 0; $i -lt 3; $i++) { $rotated += $order[($i + $offset) % 3] }
    Write-Host ("round {0}: {1}" -f $round, ($rotated -join ', '))
    foreach ($name in $rotated) {
        $rows.Add((Invoke-Run $name $configs[$name].Dll $configs[$name].Parameters $round))
    }
}

$csvPath = Join-Path $OutputRoot 'benchmark.csv'
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation

$summary = [ordered]@{}
foreach ($name in $order) {
    $seconds = @($rows | Where-Object { $_.Config -eq $name } | ForEach-Object { [double]$_.Seconds })
    $median = Get-Median $seconds
    $summary[$name] = [pscustomobject]@{
        Median = $median
        Min = ($seconds | Measure-Object -Minimum).Minimum
        Max = ($seconds | Measure-Object -Maximum).Maximum
        HalfSpread = Get-HalfSpread $seconds
        TicksPerSecond = $ExpectedQuoteTicks / $median
    }
}

foreach ($name in $order) {
    $s = $summary[$name]
    Write-Host ("{0,-8} median {1,7:N3} s ({2:N3}-{3:N3}), half-spread {4:P1}, {5:N0} ticks/s" -f $name, $s.Median, $s.Min, $s.Max, $s.HalfSpread, $s.TicksPerSecond)
}
Write-Host "csv: $csvPath"

$preSeconds = @($rows | Where-Object { $_.Config -eq 'pre' } | ForEach-Object { [double]$_.Seconds })
$preMean = ($preSeconds | Measure-Object -Average).Average
$preSd = [Math]::Sqrt((($preSeconds | ForEach-Object { ($_ - $preMean) * ($_ - $preMean) } | Measure-Object -Sum).Sum) / ($preSeconds.Count - 1))
$preRelativeSd = $preSd / $preMean
$threshold = $preMean + 2 * $preSd
$preDelta = ($summary.enabled.Median - $summary.pre.Median) / $summary.pre.Median
$disabledDelta = ($summary.enabled.Median - $summary.disabled.Median) / $summary.disabled.Median
$perQuoteNanoseconds = ($summary.enabled.Median - $summary.disabled.Median) * 1e9 / $ExpectedQuoteTicks
$pass = $summary.enabled.Median -le $threshold

Write-Host ("baseline (pre-change only, n={0}): mean {1:N3} s, median {2:N3} s, sample sd {3:N4} s ({4:P2})" -f $preSeconds.Count, $preMean, $summary.pre.Median, $preSd, $preRelativeSd)
Write-Host ("acceptance: enabled median {0:N3} s must be <= pre-change mean + 2 sd = {1:N3} s" -f $summary.enabled.Median, $threshold)
Write-Host ("diagnostic: enabled delta {0:+0.0%;-0.0%} vs pre-change, {1:+0.0%;-0.0%} vs disabled; attributable {2:N0} ns/quote" -f $preDelta, $disabledDelta, $perQuoteNanoseconds)
if ($preRelativeSd -gt 0.03) {
    Write-Host ("RESULT: INCONCLUSIVE (the pre-change baseline relative sd {0:P2} exceeds the 3% quality limit; the session cannot distinguish the effect, rerun under cleaner conditions)" -f $preRelativeSd)
    exit 2
}
if ($pass) {
    Write-Host 'RESULT: PASS'
    exit 0
}
Write-Host 'RESULT: FAIL'
exit 1
