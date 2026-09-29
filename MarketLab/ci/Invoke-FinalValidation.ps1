<#
.SYNOPSIS
Final-validation gate for one exact reviewed MarketLab/LEAN candidate commit.

.DESCRIPTION
Manual, Windows-only final regression gate. It binds itself to the candidate
SHA, checks the effective .NET SDK, builds through the production build wrapper
(fail-fast), runs the agreed MarketLab regression matrix, verifies the final
source state and the production build receipt, and writes a small JSON summary.

It is not a hermetic-build or supply-chain policy tool: it runs the reviewed
repository's own build and tests on a clean machine and records what happened.

Exit code 0 = gate passed; 1 = gate failed. The summary is written for every
completed execution so the workflow can require it as evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidateSha,
    [string]$BaseSha,
    [string]$SummaryPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrEmpty($SummaryPath)) { $SummaryPath = Join-Path $repo 'MarketLab\output\gate-summary.json' }
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SummaryPath))

$expectedSdk = '10.0.401'
$receiptPath = Join-Path $repo 'MarketLab\output\baseline-build.json'

$steps = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList
$initialHead = $null
$finalHead = $null
$finalTreeClean = $null
$receiptVerified = $false
$receiptSha256 = $null
$dotnet = $null
$sdkVersion = $null

function Add-Failure([string]$Name) {
    if (-not $script:failures.Contains($Name)) { [void]$script:failures.Add($Name) }
}

function Invoke-GateStep {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments)
    Write-Host ''
    Write-Host "=== $Name ==="
    Write-Host ("> " + $FilePath + ' ' + ($Arguments -join ' '))
    $started = [DateTime]::UtcNow
    & $FilePath @Arguments *>&1 | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
    $ended = [DateTime]::UtcNow
    [void]$script:steps.Add([ordered]@{
        name            = $Name
        command         = $FilePath + ' ' + ($Arguments -join ' ')
        exitCode        = $code
        startedUtc      = $started.ToString('o')
        endedUtc        = $ended.ToString('o')
        durationSeconds = [Math]::Round(($ended - $started).TotalSeconds, 1)
    })
    if ($code -ne 0) { Add-Failure $Name }
    return $code
}

function Get-GitState {
    $headLines = @(& git -C $repo rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $headLines.Count -ne 1) { throw 'git rev-parse HEAD failed.' }
    $statusLines = @(& git -C $repo status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
    return [pscustomobject]@{ head = ([string]$headLines[0]).Trim(); clean = ($statusLines.Count -eq 0) }
}

Push-Location $repo
try {
    if ($CandidateSha -cnotmatch '^[0-9a-f]{40}$') {
        throw '-CandidateSha must be the explicitly reviewed full 40-character lowercase commit SHA.'
    }
    if (-not [string]::IsNullOrEmpty($BaseSha) -and $BaseSha -cnotmatch '^[0-9a-f]{40}$') {
        throw '-BaseSha must be a full 40-character lowercase commit SHA when supplied.'
    }

    $state = Get-GitState
    $initialHead = $state.head
    if ($initialHead -cne $CandidateSha) { throw "Checked-out HEAD $initialHead does not equal candidate $CandidateSha." }
    if (-not $state.clean) { throw 'The working tree is not clean; the gate requires the reviewed checkout as-is.' }

    $dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $sdkLines = @(& $dotnet --version)
    if ($LASTEXITCODE -ne 0 -or $sdkLines.Count -ne 1) { throw 'dotnet --version failed.' }
    $sdkVersion = ([string]$sdkLines[0]).Trim()
    if ($sdkVersion -cne $expectedSdk) { throw "The effective .NET SDK is $sdkVersion; expected $expectedSdk." }

    $buildExit = Invoke-GateStep -Name 'production-build' -FilePath 'pwsh' -Arguments @(
        '-NoProfile', '-File', (Join-Path $repo 'MarketLab\scripts\Build-SingleAnchorBaseline.ps1'),
        '-ReviewedCommit', $CandidateSha)

    if ($buildExit -eq 0) {
        $tests = @(
            @{ name = 'single-anchor-unit-tests'; file = 'dotnet'; args = @('test', (Join-Path $repo 'MarketLab\tests\SingleAnchor\MarketLab.SingleAnchor.Tests.csproj'), '--configuration', 'Release') },
            @{ name = 'marketlab-backtesting-smoke'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-MarketLabBacktesting.ps1'), '-IncludeSmoke') },
            @{ name = 'single-anchor-invocation'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-SingleAnchorBaselineInvocation.ps1')) },
            @{ name = 'single-anchor-failed-data'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-SingleAnchorBaselineFailedData.ps1')) },
            @{ name = 'single-anchor-guards'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-SingleAnchorBaselineGuards.ps1')) },
            @{ name = 'single-anchor-delivery-e2e'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-SingleAnchorDeliveryEndToEnd.ps1')) },
            @{ name = 'trading-availability-e2e'; file = 'pwsh'; args = @('-NoProfile', '-File', (Join-Path $repo 'MarketLab\tests\Test-TradingAvailabilityEndToEnd.ps1')) }
        )
        foreach ($test in $tests) {
            [void](Invoke-GateStep -Name $test.name -FilePath $test.file -Arguments $test.args)
        }
    }
    else {
        Write-Host 'Production build failed; skipping the engine-backed test matrix.'
    }

    $finalState = Get-GitState
    $finalHead = $finalState.head
    $finalTreeClean = $finalState.clean
    if ($finalHead -cne $CandidateSha) { Add-Failure 'final-head' }
    if (-not $finalTreeClean) { Add-Failure 'final-tree-clean' }

    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $receiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        try {
            . (Join-Path $repo 'MarketLab\scripts\SingleAnchorBaseline.ps1')
            $contractSha256 = Get-BaselineHash (Join-Path $repo 'MarketLab\config\baseline-contract.json') -LfNormalized
            [void](Assert-BaselineBuild -ReceiptPath $receiptPath -RepoRoot $repo -ReviewedCommit $CandidateSha `
                -Dotnet $dotnet -ContractSha256 $contractSha256)
            $receiptVerified = $true
        }
        catch {
            Add-Failure 'build-receipt'
            Write-Host "ERROR: build receipt verification failed: $($_.Exception.Message)"
        }
    }
    else {
        Add-Failure 'build-receipt-missing'
    }
}
catch {
    Add-Failure 'gate-setup'
    Write-Host "ERROR: $($_.Exception.Message)"
}
finally {
    Pop-Location

    $windowsPowerShell = $null
    try { $windowsPowerShell = ([string](& powershell -NoProfile -Command '[string]$PSVersionTable.PSVersion' 2>$null)).Trim() } catch { }
    $gitVersion = $null
    try { $gitVersion = ([string](& git --version 2>$null)).Trim() } catch { }
    $ghVersion = $null
    try { $ghVersion = ([string](& gh --version 2>$null | Select-Object -First 1)).Trim() } catch { }

    $runUrl = $null
    if (-not [string]::IsNullOrEmpty($env:GITHUB_SERVER_URL) -and -not [string]::IsNullOrEmpty($env:GITHUB_REPOSITORY) -and -not [string]::IsNullOrEmpty($env:GITHUB_RUN_ID)) {
        $runUrl = "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
    }

    $summary = [ordered]@{
        contract    = 'marketlab-final-validation-gate-v1'
        candidateSha = $CandidateSha
        baseSha     = if ($BaseSha) { $BaseSha } else { $null }
        checkoutSha = $initialHead
        run         = [ordered]@{
            repository   = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { $null }
            runId        = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { $null }
            runAttempt   = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { $null }
            runUrl       = $runUrl
            event        = if ($env:GITHUB_EVENT_NAME) { $env:GITHUB_EVENT_NAME } else { $null }
            ref          = if ($env:GITHUB_REF) { $env:GITHUB_REF } else { $null }
            githubSha    = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { $null }
            workflowRef  = if ($env:GITHUB_WORKFLOW_REF) { $env:GITHUB_WORKFLOW_REF } else { $null }
            workflowSha  = if ($env:GITHUB_WORKFLOW_SHA) { $env:GITHUB_WORKFLOW_SHA } else { $null }
        }
        environment = [ordered]@{
            runnerOs          = if ($env:RUNNER_OS) { $env:RUNNER_OS } else { $null }
            runnerArch        = if ($env:RUNNER_ARCH) { $env:RUNNER_ARCH } else { $null }
            imageOs           = if ($env:ImageOS) { $env:ImageOS } else { $null }
            imageVersion      = if ($env:ImageVersion) { $env:ImageVersion } else { $null }
            osVersion         = [Environment]::OSVersion.VersionString
            pwsh              = $PSVersionTable.PSVersion.ToString()
            windowsPowerShell = $windowsPowerShell
            dotnetSdk         = $sdkVersion
            dotnetExecutable  = $dotnet
            runtimes          = if ($dotnet) { @(& $dotnet --list-runtimes 2>$null) } else { @() }
            git               = $gitVersion
            gh                = $ghVersion
        }
        steps       = @($steps)
        finalState  = [ordered]@{
            finalHead     = $finalHead
            finalTreeClean = $finalTreeClean
        }
        buildReceipt = [ordered]@{
            path        = 'MarketLab/output/baseline-build.json'
            sha256      = $receiptSha256
            verified    = $receiptVerified
        }
        result      = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
        failures    = @($failures)
    }

    $json = $summary | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($SummaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Host "gate-summary.json: $SummaryPath"
    Write-Host ("Gate result: " + $summary.result)
}

if ($failures.Count -eq 0) { exit 0 }
exit 1
