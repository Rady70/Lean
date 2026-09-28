<#
.SYNOPSIS
Rebuilds the reviewed Release launcher and SingleAnchor, then records source/build/runtime provenance.
.DESCRIPTION
Requires a clean checkout at the explicitly supplied reviewed commit. Each build must succeed.
No LEAN run is launched. A receipt is published only after both rebuilds and unchanged-source checks.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ReviewedCommit,
    [string]$OutputPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
. (Join-Path $PSScriptRoot 'SingleAnchorBaseline.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $OutputPath) { $OutputPath = Join-Path $repo 'MarketLab\output\baseline-build.json' }
try {
    $before = Get-BaselineSourceState $repo
    Assert-BaselineReviewedSource $before $ReviewedCommit
    $output = [IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $output))
    # An interrupted or failed new build must not leave a prior successful receipt usable.
    [IO.File]::WriteAllText($output, '{"contract":"marketlab-single-anchor-build-v1","buildSucceeded":false}', [Text.UTF8Encoding]::new($false))
    $dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $runtime = Get-BaselineRuntimeSelection $dotnet
    $sdk = @(& $dotnet --version)
    if ($LASTEXITCODE -ne 0 -or $sdk.Count -ne 1) { throw 'Cannot establish the .NET SDK version.' }
    foreach ($project in @('Launcher\QuantConnect.Lean.Launcher.csproj', 'MarketLab\src\SingleAnchor\MarketLab.SingleAnchor.csproj')) {
        & $dotnet build (Join-Path $repo $project) --configuration Release --no-incremental
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $project (exit $LASTEXITCODE). No build receipt was published." }
    }
    $after = Get-BaselineSourceState $repo
    Assert-BaselineReviewedSource $after $ReviewedCommit
    if ($before.tree -cne $after.tree) { throw 'Source changed during the build.' }
    $receipt = [ordered]@{
        contract = 'marketlab-single-anchor-build-v1'
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        buildSucceeded = $true
        repoRoot = $repo
        source = $after
        baselineContractSha256 = Get-BaselineHash (Join-Path $repo 'MarketLab\config\baseline-contract.json') -LfNormalized
        dotnet = $dotnet
        sdkVersion = $sdk[0].Trim()
        runtime = $runtime
        commands = @('dotnet build Launcher/QuantConnect.Lean.Launcher.csproj --configuration Release --no-incremental',
            'dotnet build MarketLab/src/SingleAnchor/MarketLab.SingleAnchor.csproj --configuration Release --no-incremental')
        artifacts = Get-BaselineArtifacts $repo $dotnet $runtime
    }
    [IO.File]::WriteAllText($output, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Host "Baseline build receipt: $output"
    exit 0
} catch {
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    exit 2
}
