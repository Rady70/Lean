<# Synthetic tests of the production launch/build guards. No LEAN process is started. #>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\SingleAnchorBaseline.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$contract = [IO.File]::ReadAllText((Join-Path $repo 'MarketLab\config\baseline-contract.json')) | ConvertFrom-Json
$checks = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Refused([scriptblock]$Action, [string]$Reason) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Reason) ("Wrong refusal: " + $_.Exception.Message)
        return
    }
    throw "Expected refusal: $Reason"
}
$launch = @{
    Contract = $contract; RepoRoot = $repo; Configuration = 'Release'
    Config = Join-Path $repo $contract.runHost.leanConfig
    AlgorithmTypeName = 'SingleAnchorVNextAlgorithm'; AlgorithmLanguage = 'CSharp'
    AlgorithmLocation = Join-Path $repo $contract.runHost.algorithmLocation
    DataFolder = $contract.qualifiedDataIdentity.dataFolder
    Parameters = @($contract.parameters | ForEach-Object { $_.name + ':' + $_.value }) -join ','
    AllowMissingData = $true; AllowEngineErrors = $false
    ExpectedTerminalException = 'MarketLab.SingleAnchor.AccountStopOutException'
}
Assert-BaselineLaunch @launch
Check $true 'Canonical launch'
$mutations = @{
    Parameters = $launch.Parameters.Replace('single-anchor-step-percent:0.25', 'single-anchor-step-percent:0.30')
    Configuration = 'Debug'; AlgorithmTypeName = 'OtherAlgorithm'; AlgorithmLanguage = 'Python'
    AlgorithmLocation = Join-Path $repo 'Launcher\bin\Release\QuantConnect.Algorithm.CSharp.dll'
    DataFolder = Join-Path $repo 'Data'; AllowMissingData = $false; AllowEngineErrors = $true
    ExpectedTerminalException = 'System.Exception'
}
foreach ($key in $mutations.Keys) {
    $copy = $launch.Clone()
    $copy[$key] = $mutations[$key]
    Refused { Assert-BaselineLaunch @copy } 'invocation mismatch'
}
# Exercise the actual helper entry point as well: a changed StepPercent with the
# same pinned contract must be rejected specifically as an invocation mismatch.
$previousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $output = @(& pwsh -NoProfile -File (Join-Path $repo 'MarketLab\scripts\run-backtest.ps1') `
        -Configuration Release -Config $launch.Config -AlgorithmTypeName $launch.AlgorithmTypeName `
        -AlgorithmLocation $launch.AlgorithmLocation -DataFolder $launch.DataFolder `
        -Parameters $mutations.Parameters -AllowMissingData -RunEvidence -DryRun `
        -BaselineContract (Join-Path $repo 'MarketLab\config\baseline-contract.json') `
        -BaselineRegister (Join-Path $repo 'MarketLab\config\baseline-decision-audit.json') `
        -ExpectedTerminalException $launch.ExpectedTerminalException -ReviewedCommit ('a' * 40) 2>&1)
    Check ($LASTEXITCODE -eq 2) 'Actual helper must reject changed baseline inputs'
    Check (($output -join ' ') -match 'Frozen baseline invocation mismatch: parameters') 'The helper must validate actual parameters, independently of source/build failures'
} finally { $ErrorActionPreference = $previousPreference }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('marketlab-baseline-guards-' + [guid]::NewGuid().ToString('N'))
try {
    $testRepo = Join-Path $temp 'repo'
    $dotnet = Join-Path $temp 'dotnet\dotnet.exe'
    $runtime = [pscustomobject]@{ version = '10.0.5'; directory = Join-Path $temp 'dotnet\shared\Microsoft.NETCore.App\10.0.5' }
    $paths = @($dotnet, (Join-Path $runtime.directory 'System.Private.CoreLib.dll'),
        (Join-Path $temp 'dotnet\host\fxr\10.0.5\hostfxr.dll'),
        (Join-Path $testRepo 'MarketLab\src\SingleAnchor\bin\Release\MarketLab.SingleAnchor.dll'))
    foreach ($name in @('QuantConnect.Lean.Launcher.dll', 'QuantConnect.Queues.dll', 'NodaTime.dll', 'QuantConnect.Lean.Launcher.deps.json')) {
        $paths += Join-Path $testRepo ('Launcher\bin\Release\' + $name)
    }
    foreach ($path in $paths) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'synthetic dependency')
    }
    $script:source = [pscustomobject]@{ head = 'a' * 40; tree = 'b' * 40; dirty = $false }
    # Inject only Git identity for a synthetic build fixture; production artifact checks run unchanged.
    function Get-BaselineSourceState([string]$RepoRoot) { return $script:source }
    $receiptPath = Join-Path $temp 'build.json'
    $receipt = [ordered]@{
        contract = 'marketlab-single-anchor-build-v1'; buildSucceeded = $true; repoRoot = $testRepo
        source = $script:source; baselineContractSha256 = 'c' * 64; dotnet = $dotnet; runtime = $runtime
        artifacts = Get-BaselineArtifacts $testRepo $dotnet $runtime
    }
    function Save-Receipt { [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 8)) }
    function Validate-Build { Assert-BaselineBuild $receiptPath $testRepo ('a' * 40) $dotnet ('c' * 64) }
    Save-Receipt
    $verified = Validate-Build
    Check ($verified.buildSucceeded -eq $true) 'Successful receipt must validate'
    foreach ($path in @((Join-Path $testRepo 'Launcher\bin\Release\QuantConnect.Queues.dll'),
        (Join-Path $testRepo 'Launcher\bin\Release\NodaTime.dll'), (Join-Path $runtime.directory 'System.Private.CoreLib.dll'))) {
        [IO.File]::WriteAllText($path, 'changed dependency')
        Refused { Validate-Build } 'artifact changed'
        [IO.File]::WriteAllText($path, 'synthetic dependency')
    }
    $added = Join-Path $runtime.directory 'unexpected.dll'
    [IO.File]::WriteAllText($added, 'extra dependency')
    Refused { Validate-Build } 'file set changed'
    [IO.File]::Delete($added)
    $script:source.dirty = $true
    Refused { Validate-Build } 'requires clean reviewed commit'
    $script:source.dirty = $false
    $script:source.head = 'd' * 40
    Refused { Validate-Build } 'requires clean reviewed commit'
    $script:source.head = 'a' * 40
    $receipt.buildSucceeded = $false
    Save-Receipt
    Refused { Validate-Build } 'successful.*build receipt'
    $receipt.buildSucceeded = $true
    $receipt.baselineContractSha256 = 'e' * 64
    Save-Receipt
    Refused { Validate-Build } 'source tree and baseline contract'
    Refused { Assert-BaselineReviewedSource $script:source '' } 'explicitly approved full Git commit'

    # The actual rebuild wrapper is tested with injected native Git/dotnet processes.
    # A failed first build must invalidate an old receipt and never start the second build.
    $scripts = Join-Path $testRepo 'MarketLab\scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    foreach ($name in @('SingleAnchorBaseline.ps1', 'Build-SingleAnchorBaseline.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('..\scripts\' + $name)) -Destination (Join-Path $scripts $name)
    }
    $bin = Join-Path $temp 'injected'
    [void][IO.Directory]::CreateDirectory($bin)
    [IO.File]::WriteAllText((Join-Path $bin 'git.cmd'), "@echo off`r`nif `"%4`"==`"status`" exit /b 0`r`nif `"%5`"==`"HEAD`" (`r`necho $('a' * 40)`r`n) else (`r`necho $('b' * 40)`r`n)`r`nexit /b 0`r`n")
    [IO.File]::WriteAllText((Join-Path $bin 'dotnet.cmd'), "@echo off`r`nif `"%1`"==`"--list-runtimes`" (`r`necho Microsoft.NETCore.App 10.0.5 [$temp\dotnet\shared\Microsoft.NETCore.App]`r`nexit /b 0`r`n)`r`nif `"%1`"==`"--version`" (`r`necho 10.0.100`r`nexit /b 0`r`n)`r`necho build>>`"$temp\build-attempts.txt`"`r`nexit /b 9`r`n")
    Save-Receipt
    $savedPath = $env:PATH
    try {
        $env:PATH = $bin + ';' + $savedPath
        $injectedOutput = @(& pwsh -NoProfile -File (Join-Path $scripts 'Build-SingleAnchorBaseline.ps1') -ReviewedCommit ('a' * 40) -OutputPath $receiptPath 2>&1)
        Check ($LASTEXITCODE -eq 2) 'Failed rebuild must exit 2'
    } finally { $env:PATH = $savedPath }
    Check (([IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json).buildSucceeded -eq $false) ('Failed rebuild must invalidate the previous receipt: ' + ($injectedOutput -join ' '))
    Check (Test-Path -LiteralPath (Join-Path $temp 'build-attempts.txt')) ('Injected build must be attempted: ' + ($injectedOutput -join ' '))
    Check (([IO.File]::ReadAllLines((Join-Path $temp 'build-attempts.txt'))).Count -eq 1) 'Failed launcher build must stop before the strategy build'
}
finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\marketlab-baseline-guards-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "Baseline launch/build guards: $checks passed."
