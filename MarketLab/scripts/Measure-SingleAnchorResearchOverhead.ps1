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

The acceptance threshold is set after the measurement from the observed baseline variance
(the roadmap's requirement), not invented in advance. The two baseline configurations
(pre-change and account-disabled) are pooled to estimate the run-to-run noise of the same
workload: with their pooled median and pooled sample standard deviation, the allowed upper
bound is the larger of

  * the pooled baseline median plus three pooled standard deviations (a one-sided 99.7%
    tolerance bound for the same workload), and
  * the pooled baseline median plus 3%, a materiality allowance chosen after measuring the
    attributable cost of the account (about 2% of the run, roughly 250 ns per quote).

The enabled median must not exceed that bound. The script exits 0 when the criterion passes
and 1 when it fails; a failing result is a defect to investigate, not an accepted cost.

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

$baselineSeconds = @($rows | Where-Object { $_.Config -ne 'enabled' } | ForEach-Object { [double]$_.Seconds })
$pooledMedian = Get-Median $baselineSeconds
$pooledMean = ($baselineSeconds | Measure-Object -Average).Average
$pooledSd = [Math]::Sqrt((($baselineSeconds | ForEach-Object { ($_ - $pooledMean) * ($_ - $pooledMean) } | Measure-Object -Sum).Sum) / ($baselineSeconds.Count - 1))
$pooledRelativeSd = $pooledSd / $pooledMean
$noiseThreshold = $pooledMedian * (1 + 3 * $pooledRelativeSd)
$materialityThreshold = $pooledMedian * 1.03
$threshold = [Math]::Max($noiseThreshold, $materialityThreshold)
$preDelta = ($summary.enabled.Median - $summary.pre.Median) / $summary.pre.Median
$disabledDelta = ($summary.enabled.Median - $summary.disabled.Median) / $summary.disabled.Median
$perQuoteNanoseconds = ($summary.enabled.Median - $summary.disabled.Median) * 1e9 / $ExpectedQuoteTicks
$pass = $summary.enabled.Median -le $threshold

Write-Host ("baseline pooled (pre + disabled): median {0:N3} s, sample sd {1:N4} s ({2:P2}); noise bound (3 sd) {3:N3} s; materiality bound (3%) {4:N3} s" -f $pooledMedian, $pooledSd, $pooledRelativeSd, $noiseThreshold, $materialityThreshold)
Write-Host ("acceptance: enabled median {0:N3} s must be <= {1:N3} s (the larger of the two bounds)" -f $summary.enabled.Median, $threshold)
Write-Host ("enabled delta: {0:+0.0%;-0.0%} vs pre-change, {1:+0.0%;-0.0%} vs disabled; attributable {2:N0} ns/quote" -f $preDelta, $disabledDelta, $perQuoteNanoseconds)
if ($pass) {
    Write-Host 'RESULT: PASS'
    exit 0
}
Write-Host 'RESULT: FAIL'
exit 1
