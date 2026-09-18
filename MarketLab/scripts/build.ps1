<#
.SYNOPSIS
Builds the LEAN solution with the exact commands qualified in MarketLab Batch A.

.DESCRIPTION
Runs, from the LEAN checkout root and echoing each command verbatim:

    dotnet restore QuantConnect.Lean.sln
    dotnet build QuantConnect.Lean.sln --configuration <Configuration> --no-restore

No other flags are added (upstream CI's /v:quiet /p:WarningLevel=1 were
deliberately omitted in Batch A so every warning stays visible). The build's
exit code is propagated. On success the script checks that
Launcher\bin\<Configuration>\QuantConnect.Lean.Launcher.dll exists and prints
its path.

`dotnet build-server shutdown` is NOT run automatically: the build servers
(MSBuild node reuse, Roslyn VBCSCompiler) make consecutive builds faster and
stopping them is an operator choice, not part of the build. Pass
-ShutdownBuildServer to run it after the build, or run it yourself.

Requires the .NET 10 SDK (Batch A). `dotnet` is resolved from PATH, then
$env:DOTNET_ROOT, then "$env:ProgramFiles\dotnet". Restore needs network access
to the configured NuGet feed (api.nuget.org); nothing else in the MarketLab
workflow touches the network.

Exit codes: 0 build succeeded and the launcher DLL exists; 2 pre-flight failure
(dotnet or the solution not found) or launcher DLL missing after a successful
build; otherwise the exit code of the failing dotnet command.

.PARAMETER LeanRoot
Root of the LEAN checkout (contains QuantConnect.Lean.sln). Default: two levels
above this script.

.PARAMETER Configuration
Release (default, the Batch A baseline configuration) or Debug.

.PARAMETER NoRestore
Skip `dotnet restore` (use when packages are already restored).

.PARAMETER ShutdownBuildServer
Run `dotnet build-server shutdown` after the build (regardless of its result).

.EXAMPLE
pwsh -File MarketLab\scripts\build.ps1
Full restore and Release build.

.EXAMPLE
pwsh -File MarketLab\scripts\build.ps1 -NoRestore -ShutdownBuildServer
Incremental Release build, then stop the build servers.
#>
[CmdletBinding()]
param(
    [string]$LeanRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$NoRestore,
    [switch]$ShutdownBuildServer
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

function Write-ErrorLine([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Resolve-DotnetExecutable {
    $cmd = Get-Command -Name 'dotnet' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) {
        return $cmd.Source
    }
    $candidates = @()
    if (-not [string]::IsNullOrEmpty($env:DOTNET_ROOT)) {
        $candidates += (Join-Path $env:DOTNET_ROOT 'dotnet.exe')
    }
    if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) {
        $candidates += (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

# PowerShell-pasteable rendering: `& 'exe' arg ...`, quoting any argument that
# contains whitespace or a character PowerShell would parse.
function Format-CommandLine([string]$Executable, [string[]]$Arguments) {
    $parts = @()
    foreach ($item in (@($Executable) + $Arguments)) {
        if ($item -match '[\s''"|<>&;(){}$`,]') {
            $parts += ("'" + ($item -replace "'", "''") + "'")
        }
        else {
            $parts += $item
        }
    }
    return ('& ' + ($parts -join ' '))
}

if ([string]::IsNullOrEmpty($LeanRoot)) {
    $LeanRoot = Join-Path $PSScriptRoot '..\..'
}
$leanRootPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $LeanRoot)).TrimEnd([char]'\', [char]'/')
if ($leanRootPath -match '^[A-Za-z]:$') { $leanRootPath += '\' }

$solution = Join-Path $leanRootPath 'QuantConnect.Lean.sln'
$launcherDll = Join-Path $leanRootPath ("Launcher\bin\" + $Configuration + "\QuantConnect.Lean.Launcher.dll")

$dotnet = Resolve-DotnetExecutable
if ($null -eq $dotnet) {
    Write-ErrorLine "dotnet was not found on PATH, in `$env:DOTNET_ROOT, or at `"$env:ProgramFiles\dotnet\dotnet.exe`". Install the .NET 10 SDK (Batch A prerequisite) or add it to PATH."
    exit 2
}
if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) {
    Write-ErrorLine "Solution `"$solution`" does not exist. Pass -LeanRoot <path to the LEAN checkout>."
    exit 2
}

Write-Host "MarketLab LEAN build"
Write-Host "  LEAN root:      $leanRootPath"
Write-Host "  configuration:  $Configuration"
Write-Host "  dotnet:         $dotnet"

$exitCode = 0
$startedUtc = [DateTime]::UtcNow
# dotnet writes warnings and errors to stderr. Under Windows PowerShell 5.1,
# when a caller redirects this script's stderr inside PowerShell (`& build.ps1
# ... 2>&1`), each such line becomes a NativeCommandError record, and with
# $ErrorActionPreference = 'Stop' the first one would terminate the script
# mid-build. Native output is never an error for this script, so the
# preference is relaxed around the native calls only.
$previousErrorActionPreference = $ErrorActionPreference
Push-Location -LiteralPath $leanRootPath
try {
    $ErrorActionPreference = 'Continue'
    if (-not $NoRestore) {
        $restoreArgs = @('restore', 'QuantConnect.Lean.sln')
        Write-Host (">> " + (Format-CommandLine $dotnet $restoreArgs))
        & $dotnet @restoreArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-ErrorLine "dotnet restore failed with exit code $exitCode (see output above). Restore needs access to the NuGet feed."
        }
    }
    if ($exitCode -eq 0) {
        $buildArgs = @('build', 'QuantConnect.Lean.sln', '--configuration', $Configuration, '--no-restore')
        Write-Host (">> " + (Format-CommandLine $dotnet $buildArgs))
        & $dotnet @buildArgs
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-ErrorLine "dotnet build failed with exit code $exitCode (see the error lines above)."
        }
    }
}
finally {
    if ($ShutdownBuildServer) {
        Write-Host (">> " + (Format-CommandLine $dotnet @('build-server', 'shutdown')))
        & $dotnet build-server shutdown
    }
    $ErrorActionPreference = $previousErrorActionPreference
    Pop-Location
}
$elapsed = [DateTime]::UtcNow - $startedUtc

if ($exitCode -eq 0) {
    if (Test-Path -LiteralPath $launcherDll -PathType Leaf) {
        Write-Host ("Build succeeded in {0:N1} s. Launcher: {1}" -f $elapsed.TotalSeconds, $launcherDll)
        if (-not $ShutdownBuildServer) {
            Write-Host "Optional: run `"$dotnet build-server shutdown`" to stop the MSBuild/Roslyn build servers left running by the SDK."
        }
    }
    else {
        Write-ErrorLine "dotnet build reported success but `"$launcherDll`" does not exist. Check the build output above for the Launcher project."
        $exitCode = 2
    }
}
exit $exitCode
