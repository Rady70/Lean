<#
.SYNOPSIS
Computes the SingleAnchor strategy-projection hash of one or more results.json files.

.DESCRIPTION
The projection is the strategy-facing part of `storage\single-anchor\results.json` only: the
strategy parameter block, the quote counters, entries, skipped first-entry quotes, rejected
entries and attempts, baskets closed, realized profit, the last processed quote, the
closed-basket records and the open-basket snapshot. The research blocks (`researchAccount`,
`researchBaskets`, `researchOpenBasket`, `researchMargin`) and the envelope fields are
deliberately excluded, so a run with the research account (and PR 3 margin) enabled and the
same run with them disabled must print the same hash: that is the PR 2/PR 3 strategy-path
parity check. The strategy parameter block is included because it is part of the configuration
that produced the path; the `single-anchor-research-account` and
`single-anchor-margin-enabled` toggles are separate host fields and are not part of it.

PR 3 adds account-only fields to every rejection trace row inside the closed-basket and
open-basket objects (account used/free/level and the projected post-fill margins). They are
removed from the parsed rows before hashing, so the projection is genuinely strategy-only and
a pre-PR-3 result and a margin-disabled PR 3 result of the same strategy path hash identically
even when rejection episodes exist.

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

# PR 3 account-only fields on rejection trace rows; excluded so the projection stays
# strategy-only across the pre-PR-3 and PR 3 result shapes.
$pr3RejectionAccountFields = @(
    'accountUsedMargin',
    'accountFreeMargin',
    'accountMarginLevelPercent',
    'projectedUsedMargin',
    'projectedFreeMargin',
    'minProjectedFreeMargin',
    'maxProjectedFreeMargin'
)

function Remove-Pr3RejectionAccountFields($Basket) {
    if ($null -eq $Basket -or $null -eq $Basket.rejectionTrace) { return }
    foreach ($row in @($Basket.rejectionTrace)) {
        foreach ($field in $script:pr3RejectionAccountFields) {
            if ($row.PSObject.Properties[$field]) {
                $row.PSObject.Properties.Remove($field)
            }
        }
    }
}

$hashes = @()
foreach ($path in $Results) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [Console]::Error.WriteLine("ERROR: results file not found: $path")
        exit 2
    }
    $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Remove-Pr3RejectionAccountFields $j.openBasket
    if ($null -ne $j.closedBaskets) {
        foreach ($basket in @($j.closedBaskets)) {
            Remove-Pr3RejectionAccountFields $basket
        }
    }
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
