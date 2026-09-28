<# Runs the production algorithm on three synthetic UTC quotes, with normal and stop-out outcomes.
   No historical data, build receipt or authoritative baseline run is created. #>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\SingleAnchorDelivery.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('marketlab-delivery-e2e-' + [guid]::NewGuid().ToString('N'))
$checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
try {
    $data = Join-Path $scratch 'data'
    foreach ($part in @('market-hours', 'symbol-properties', 'cfd\dukascopy\tick\xauusd')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $data $part))
    }
    $hours = [IO.File]::ReadAllText((Join-Path $repo 'Data\market-hours\market-hours-database.json')) | ConvertFrom-Json
    $entry = [ordered]@{ dataTimeZone = 'UTC'; exchangeTimeZone = 'UTC' }
    foreach ($day in @('sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday')) {
        $entry[$day] = @([ordered]@{ start = '00:00:00'; end = '1.00:00:00'; state = 'market' })
    }
    $hours.entries | Add-Member -NotePropertyName 'Cfd-dukascopy-XAUUSD' -NotePropertyValue $entry -Force
    [IO.File]::WriteAllText((Join-Path $data 'market-hours\market-hours-database.json'), ($hours | ConvertTo-Json -Depth 30))
    $properties = [IO.File]::ReadAllText((Join-Path $repo 'Data\symbol-properties\symbol-properties-database.csv'))
    [IO.File]::WriteAllText((Join-Path $data 'symbol-properties\symbol-properties-database.csv'), $properties.TrimEnd() + "`n" + 'dukascopy,XAUUSD,cfd,Gold,USD,1,0.001,1' + "`n")
    # LEAN's final statistics also consult the shipped SPY auxiliary fixture.
    foreach ($relative in @('equity\usa\map_files\spy.csv', 'equity\usa\factor_files\spy.csv', 'equity\usa\daily\spy.zip')) {
        $target = Join-Path $data $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-Item -LiteralPath (Join-Path (Join-Path $repo 'Data') $relative) -Destination $target
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $data 'cfd\dukascopy\tick\xauusd\20260630_quote.zip'
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('20260630_xauusd_tick_quote.csv').Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write("1,1999.9,2000.1`n43200000,2010,2020`n86399999,2010,2020`n") } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    $native = Get-BaselineNativePrefix $zipPath '2026-06-30' 3
    $identity = [pscustomobject]@{
        startDate = '2026-06-30'; endDate = '2026-06-30'; continuousHistoryQuoteCount = 3
        continuousHistoryFirstQuoteUtc = '2026-06-30T00:00:00.001Z'; continuousHistoryLastQuoteUtc = '2026-06-30T23:59:59.999Z'
        continuousHistorySemanticDigest = $native.digest
    }
    $manifest = [pscustomobject]@{
        native = [pscustomobject]@{ partitions = @([pscustomobject]@{ zip_relative_path = 'cfd/dukascopy/tick/xauusd/20260630_quote.zip' }) }
        semantic = [pscustomobject]@{ per_partition = [pscustomobject]@{ '2026-06-30' = [pscustomobject]@{ accepted_row_count = 3; semantic_digest = $native.digest } } }
    }
    # The former "terminal" fixture (cash 4.05) now exercises the Phase B broker-liquidation model:
    # the same post-fill Stop Out force-closes the only position and the run continues to the third
    # quote instead of stopping with the intact basket left open.
    foreach ($terminal in @($false, $true)) {
        $cash = if ($terminal) { '4.05' } else { '20000' }
        $out = Join-Path $scratch ('output-' + $cash)
        $parameters = 'single-anchor-market:dukascopy,single-anchor-start-date:2026-06-30,single-anchor-end-date:2026-06-30,single-anchor-step-percent:1,single-anchor-base-lot:0.01,single-anchor-projected-spread:0.50,single-anchor-margin-enabled:true,single-anchor-cash:' + $cash
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $log = @(& pwsh -NoProfile -File (Join-Path $repo 'MarketLab\scripts\run-backtest.ps1') `
                -Configuration Release -AlgorithmTypeName SingleAnchorVNextAlgorithm `
                -AlgorithmLocation (Join-Path $repo 'MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll') `
                -DataFolder $data -OutputRoot $out -Parameters $parameters -AllowMissingData 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        Check ($code -eq 0) ("Unexpected native helper exit $code : " + (($log | Where-Object { [string]$_ -match 'ERROR|Exception' }) -join "`n"))
        $run = @(Get-ChildItem -LiteralPath $out -Directory)
        Check ($run.Count -eq 1) 'Exactly one synthetic run directory is required'
        $result = [IO.File]::ReadAllText((Join-Path $run[0].FullName 'storage\single-anchor\results.json')) | ConvertFrom-Json
        $verified = Assert-BaselineDelivery $result $manifest $identity $data
        Check ($result.algorithmTimeZone -ceq 'UTC') 'Production Initialize must use UTC'
        Check ($result.completed -eq $true) 'The broker-liquidation model completes both fixtures'
        Check ($null -eq $result.failure) 'A Stop Out trigger is not a run failure under the Phase B model'
        Check ($result.runtimeVersion -match '^10\.\d+\.\d+$') 'Production host must report its runtime'
        Check ($verified.mode -eq 'qualified-full-stream' -and $verified.quoteCount -eq 3) 'Both fixtures deliver the full three-quote stream'
        if ($terminal) {
            Check ($result.forcedLiquidations -eq 1) 'The post-fill Stop Out force-closes one position'
            Check ($result.basketsLiquidated -eq 1) 'The only position ends through broker liquidation'
            Check ($result.basketsClosed -eq 0) 'No strategy exit is fabricated for a forced close'
            Check ($result.realizedProfit -eq -10) '(2010 - 2020) * 0.01 * 100 on the force-closed BUY'
            Check ($result.researchAccount.Balance -eq -5.95 -and $result.researchAccount.Equity -eq -5.95) 'The realized loss reaches the flat account'
            Check ($result.researchMargin.StopOutEpisodes.Count -eq 1) 'The Stop Out episode is recorded'
            Check ($result.researchMargin.StopOutEpisodes[0].Outcome -ceq 'AllPositionsLiquidated') 'The episode outcome is recorded'
            Check ($result.researchMargin.StopOutEpisodes[0].Liquidations[0].Leg.ClosePrice -eq 2010) 'A BUY closes at the executable Bid'
            Check ($result.closedBaskets[0].Reason -ceq 'BrokerLiquidation') 'The basket outcome is a broker liquidation'
            Check ($result.closedBaskets[0].HistoricalEntries -eq 1 -and $result.closedBaskets[0].LiquidatedPositions -eq 1) 'The immutable trade identity survives the forced close'
        } else {
            Check ($result.forcedLiquidations -eq 0 -and $result.basketsLiquidated -eq 0) 'A healthy account liquidates nothing'
            $failed = @(Get-ChildItem -LiteralPath $run[0].FullName -Filter 'failed-data-requests-*.txt' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
            Check ($failed -notmatch '20260701_quote.zip') 'UTC end window must not request a July 1 partition'
        }
    }
}
finally {
    $full = [IO.Path]::GetFullPath($scratch)
    if (-not $full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\marketlab-delivery-e2e-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
Write-Host "Production delivery end-to-end: $checks checks passed on two three-quote fixtures."
