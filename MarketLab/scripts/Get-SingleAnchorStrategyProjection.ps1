<#
.SYNOPSIS
Computes the SingleAnchor strategy-projection hash of one or more results.json files.

.DESCRIPTION
The projection is the strategy-facing part of `storage\single-anchor\results.json` only: the
strategy parameter block, the quote counters, entries, skipped first-entry quotes, rejected
entries and attempts, baskets closed, realized profit, the last processed quote, the
closed-basket records and the open-basket snapshot. The research blocks (`researchAccount`,
`researchBaskets`, `researchOpenBasket`) and the envelope fields are deliberately excluded, so
a run with the research account enabled and the same run with it disabled must print the same
hash: that is the PR 2 strategy-path parity check. The strategy parameter block is included
because it is part of the configuration that produced the path; the
`single-anchor-research-account` toggle is a separate host field and is not part of it.

The values are re-serialized as compact canonical JSON in a fixed key order
(ConvertTo-Json -Depth 100 -Compress) and hashed with SHA-256. Run every compared file through
the same shell, because hosts may format JSON numbers slightly differently.

When more than one file is given, the script also compares the hashes and exits 1 with an
error that prints each differing projection and the result files that belong to it, so the
mismatching inputs can be identified directly.

.EXAMPLE
pwsh -File MarketLab\scripts\Get-SingleAnchorStrategyProjection.ps1 `
    C:\runs\baseline\storage\single-anchor\results.json `
    C:\runs\enabled\storage\single-anchor\results.json `
    C:\runs\disabled\storage\single-anchor\results.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Results
)

$ErrorActionPreference = 'Stop'
$hashes = @()
foreach ($path in $Results) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [Console]::Error.WriteLine("ERROR: results file not found: $path")
        exit 2
    }
    $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $projection = [ordered]@{
        parameters               = $j.parameters
        quoteTicksProcessed      = $j.quoteTicksProcessed
        quoteOnlyQuotes          = $j.quoteOnlyQuotes
        strategyEligibleQuotes   = $j.strategyEligibleQuotes
        legsOpened               = $j.legsOpened
        skippedFirstEntryQuotes  = $j.skippedFirstEntryQuotes
        distinctRejectedEntries  = $j.distinctRejectedEntries
        rejectedEntryAttempts    = $j.rejectedEntryAttempts
        basketsClosed            = $j.basketsClosed
        realizedProfit           = $j.realizedProfit
        lastProcessedQuote       = $j.lastProcessedQuote
        closedBaskets            = $j.closedBaskets
        openBasket               = $j.openBasket
    }
    $json = $projection | ConvertTo-Json -Depth 100 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant()
    $hashes += [pscustomobject]@{ Hash = $hash; Path = $path }
    Write-Output ("{0}  {1}" -f $hash, $path)
}

if ($hashes.Count -gt 1) {
    $distinct = @($hashes | Group-Object Hash)
    if ($distinct.Count -gt 1) {
        [Console]::Error.WriteLine("ERROR: strategy projections differ; each projection below lists the files that produced it:")
        foreach ($group in $distinct) {
            $header = "  {0} ({1} file(s)):" -f $group.Name, $group.Count
            [Console]::Error.WriteLine($header)
            foreach ($entry in $group.Group) {
                $file = "    {0}" -f $entry.Path
                [Console]::Error.WriteLine($file)
            }
        }
        exit 1
    }
}
