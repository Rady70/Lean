# Shared checks for the one frozen SingleAnchor baseline. Dot-sourcing starts nothing.
Set-StrictMode -Version 2.0

function Get-BaselineHash([string]$Path, [switch]$LfNormalized) {
    if (-not $LfNormalized) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-BaselineSourceState([string]$RepoRoot) {
    $head = @(& git --no-optional-locks -C $RepoRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1) { throw 'Cannot establish the build source HEAD.' }
    $tree = @(& git --no-optional-locks -C $RepoRoot rev-parse 'HEAD^{tree}')
    if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1) { throw 'Cannot establish the build source tree.' }
    $status = @(& git --no-optional-locks -C $RepoRoot status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot establish whether the build source is clean.' }
    return [pscustomobject]@{ head = $head[0].Trim(); tree = $tree[0].Trim(); dirty = $status.Count -ne 0 }
}

function Assert-BaselineReviewedSource($Source, [string]$ReviewedCommit) {
    if ($ReviewedCommit -cnotmatch '^[0-9a-f]{40}$') { throw '-ReviewedCommit must be the explicitly approved full Git commit SHA.' }
    if ($Source.head -cne $ReviewedCommit -or $Source.dirty -ne $false) {
        throw "The baseline requires clean reviewed commit $ReviewedCommit; current HEAD is $($Source.head), dirty=$($Source.dirty)."
    }
}

function Get-BaselineRuntimeSelection([string]$Dotnet) {
    $lines = @(& $Dotnet --list-runtimes)
    if ($LASTEXITCODE -ne 0) { throw 'dotnet --list-runtimes failed.' }
    $choices = @($lines | ForEach-Object {
        if ($_ -match '^Microsoft.NETCore.App (10\.\d+\.\d+) \[(.+)\]$') {
            [pscustomobject]@{ version = $Matches[1]; directory = [IO.Path]::GetFullPath((Join-Path $Matches[2] $Matches[1])) }
        }
    } | Sort-Object { [version]$_.version } -Descending)
    if ($choices.Count -eq 0) { throw 'A stable Microsoft.NETCore.App 10.x runtime is required.' }
    return $choices[0]
}

function Get-BaselineArtifacts([string]$RepoRoot, [string]$Dotnet, $Runtime) {
    $roots = [ordered]@{
        launcher = Join-Path $RepoRoot 'Launcher\bin\Release'
        algorithm = Join-Path $RepoRoot 'MarketLab\src\SingleAnchor\bin\Release'
        framework = $Runtime.directory
        hostfxr = Join-Path (Split-Path -Parent $Dotnet) 'host\fxr'
    }
    $files = [ordered]@{}
    $files['dotnet'] = Get-BaselineHash $Dotnet
    foreach ($entry in $roots.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Container)) { throw "Runtime directory is missing: $($entry.Value)" }
        foreach ($file in Get-ChildItem -LiteralPath $entry.Value -Recurse -File | Sort-Object FullName) {
            # Managed/native dependencies and host resolution files; PDBs and logs do not select code.
            if ($file.Name -notmatch '(?i)\.(dll|exe|json|config|pyd|so|dylib)$') { continue }
            $relative = $file.FullName.Substring($entry.Value.TrimEnd('\', '/').Length + 1).Replace('\', '/')
            $files[$entry.Key + '/' + $relative] = Get-BaselineHash $file.FullName
        }
    }
    foreach ($required in @('launcher/QuantConnect.Lean.Launcher.dll', 'launcher/QuantConnect.Queues.dll',
            'launcher/NodaTime.dll', 'algorithm/MarketLab.SingleAnchor.dll', 'framework/System.Private.CoreLib.dll')) {
        if (-not $files.Contains($required)) { throw "Build output is incomplete: $required" }
    }
    return $files
}

function Assert-BaselineArtifactEquality($Expected, $Actual) {
    $expectedNames = @($Expected.PSObject.Properties.Name | Sort-Object)
    $actualNames = @($Actual.Keys | Sort-Object)
    if (($expectedNames -join "`n") -cne ($actualNames -join "`n")) { throw 'The build/runtime dependency file set changed.' }
    foreach ($name in $actualNames) {
        if ([string]$Expected.$name -cne [string]$Actual[$name]) { throw "Build/runtime artifact changed: $name" }
    }
}

function Assert-BaselineBuild([string]$ReceiptPath, [string]$RepoRoot, [string]$ReviewedCommit,
        [string]$Dotnet, [string]$ContractSha256) {
    $source = Get-BaselineSourceState $RepoRoot
    Assert-BaselineReviewedSource $source $ReviewedCommit
    $receipt = [IO.File]::ReadAllText($ReceiptPath) | ConvertFrom-Json
    if ($receipt.contract -ne 'marketlab-single-anchor-build-v1' -or $receipt.buildSucceeded -ne $true) {
        throw 'A successful SingleAnchor baseline build receipt is required.'
    }
    Assert-BaselineReviewedSource $receipt.source $ReviewedCommit
    if ($receipt.source.tree -cne $source.tree -or $receipt.baselineContractSha256 -cne $ContractSha256) {
        throw 'The build receipt does not bind the current source tree and baseline contract.'
    }
    if ([IO.Path]::GetFullPath($receipt.repoRoot) -ne [IO.Path]::GetFullPath($RepoRoot) -or
        [IO.Path]::GetFullPath($receipt.dotnet) -ne [IO.Path]::GetFullPath($Dotnet)) {
        throw 'The build receipt names a different checkout or dotnet executable.'
    }
    if ($receipt.runtime.version -notmatch '^10\.\d+\.\d+$') { throw 'The build receipt has no exact .NET 10 runtime version.' }
    $expectedRuntimeRoot = Join-Path (Split-Path -Parent $Dotnet) ('shared\Microsoft.NETCore.App\' + $receipt.runtime.version)
    if ([IO.Path]::GetFullPath($receipt.runtime.directory) -ne [IO.Path]::GetFullPath($expectedRuntimeRoot)) {
        throw 'The runtime directory is not the pinned framework under the selected dotnet installation.'
    }
    foreach ($name in @('DOTNET_STARTUP_HOOKS', 'DOTNET_ADDITIONAL_DEPS', 'DOTNET_SHARED_STORE')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {
            throw "Baseline runtime dependency injection is not supported: $name is set."
        }
    }
    Assert-BaselineArtifactEquality $receipt.artifacts (Get-BaselineArtifacts $RepoRoot $Dotnet $receipt.runtime)
    return $receipt
}

function Assert-BaselineLaunch($Contract, [string]$RepoRoot, [string]$Configuration,
        [string]$Config, [string]$AlgorithmTypeName, [string]$AlgorithmLanguage,
        [string]$AlgorithmLocation, [string]$DataFolder, [string]$Parameters,
        [bool]$AllowMissingData, [bool]$AllowEngineErrors, [string]$ExpectedTerminalException) {
    $hostContract = $Contract.runHost
    $pairs = @($Contract.parameters | ForEach-Object { $_.name + ':' + $_.value }) -join ','
    $checks = [ordered]@{
        configuration = $Configuration -ceq $hostContract.buildConfiguration
        algorithmTypeName = $AlgorithmTypeName -ceq $hostContract.algorithmTypeName
        algorithmLanguage = $AlgorithmLanguage -ceq $hostContract.algorithmLanguage
        algorithmLocation = [IO.Path]::GetFullPath($AlgorithmLocation) -eq [IO.Path]::GetFullPath((Join-Path $RepoRoot $hostContract.algorithmLocation))
        configPath = [IO.Path]::GetFullPath($Config) -eq [IO.Path]::GetFullPath((Join-Path $RepoRoot $hostContract.leanConfig))
        configHash = (Get-BaselineHash $Config -LfNormalized) -ceq $hostContract.leanConfigSha256LfNormalized
        dataFolder = [IO.Path]::GetFullPath($DataFolder) -eq [IO.Path]::GetFullPath($Contract.qualifiedDataIdentity.dataFolder)
        parameters = $Parameters -ceq $pairs
        allowMissingData = $AllowMissingData -eq $true
        allowEngineErrors = $AllowEngineErrors -eq $false
        terminalException = $ExpectedTerminalException -ceq 'MarketLab.SingleAnchor.AccountStopOutException'
    }
    $problems = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
    if ($problems.Count -ne 0) { throw ('Frozen baseline invocation mismatch: ' + ($problems -join ', ')) }
}
