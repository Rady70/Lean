<#
.SYNOPSIS
Windows-local tests for scripts\Get-SingleAnchorBaselineInvocation.ps1.

.DESCRIPTION
Checks that the reporter renders the frozen invocation only when the contract file's
computed LF-normalized SHA-256 equals the authoritative register's
frozenBaselineContractSha256:

  happy path (real contract + real register)          -> exit 0, report carries the matching hash
  register pin tampered                               -> exit 2, refused
  contract file modified (hash no longer pinned)      -> exit 2, refused
  contract missing / unparsable                       -> exit 2, refused

No repository file is modified; the tampered copies live in a temporary directory.

Exit code: 0 when every case behaves as expected; 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Checks = 0

function Check([string]$Description, [bool]$Condition) {
    $script:Checks++
    if ($Condition) {
        Write-Host "  PASS: $Description"
    }
    else {
        $script:Failures++
        [Console]::Error.WriteLine("  FAIL: $Description")
    }
}

$reporter = Join-Path $PSScriptRoot '..\scripts\Get-SingleAnchorBaselineInvocation.ps1'
if (-not (Test-Path -LiteralPath $reporter -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: reporter script not found at '$reporter'.")
    exit 1
}
$marketLabRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$realContract = Join-Path $marketLabRoot 'config\baseline-contract.json'
$realRegister = Join-Path $marketLabRoot 'config\baseline-decision-audit.json'
$root = Join-Path $env:TEMP ("marketlab-baseline-invocation-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Invoke-Reporter([string]$Contract, [string]$Register) {
    $arguments = @('-NoProfile', '-File', $reporter, '-Json', '-Contract', $Contract)
    if ($Register) { $arguments += @('-Register', $Register) }
    # Windows PowerShell 5.1 wraps a native process's stderr as an error record; the
    # reporter's expected refusals write there, so relax the preference for the call.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell @arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    $report = $null
    if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace(($output -join ''))) {
        $report = ($output -join "`n") | ConvertFrom-Json
    }
    return [pscustomobject]@{ Code = $code; Report = $report }
}

try {
    Write-Host 'Happy path: the real contract pinned by the real register'
    $happy = Invoke-Reporter $realContract $realRegister
    Check 'exit 0' ($happy.Code -eq 0)
    Check 'report carries the pin' ($happy.Report.registerMatches -eq $true)
    Check 'contract hash equals the register pin' ($happy.Report.contractSha256 -eq $happy.Report.registerPin)
    Check 'run command carries -RunEvidence' ($happy.Report.runCommand -match '-RunEvidence')
    Check 'run command carries -AllowMissingData' ($happy.Report.runCommand -match '-AllowMissingData')
    Check 'run command does not carry -AllowEngineErrors' (-not ($happy.Report.runCommand -match '-AllowEngineErrors'))

    Write-Host 'Tampered register pin'
    $register = [System.IO.File]::ReadAllText($realRegister) | ConvertFrom-Json
    $register.frozenBaselineContractSha256 = ('0' * 64)
    $tamperedRegisterPath = Join-Path $root 'tampered-register.json'
    [System.IO.File]::WriteAllText($tamperedRegisterPath, ($register | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $tampered = Invoke-Reporter $realContract $tamperedRegisterPath
    Check 'exit 2' ($tampered.Code -eq 2)

    Write-Host 'Modified contract file'
    $contract = [System.IO.File]::ReadAllText($realContract) | ConvertFrom-Json
    $contract.parameters[0].value = 'NOT-XAUUSD'
    $modifiedContractPath = Join-Path $root 'modified-contract.json'
    [System.IO.File]::WriteAllText($modifiedContractPath, ($contract | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $modified = Invoke-Reporter $modifiedContractPath $realRegister
    Check 'exit 2' ($modified.Code -eq 2)

    Write-Host 'Unparsable contract'
    $badContractPath = Join-Path $root 'bad-contract.json'
    [System.IO.File]::WriteAllText($badContractPath, '{ not json', (New-Object System.Text.UTF8Encoding($false)))
    $bad = Invoke-Reporter $badContractPath $realRegister
    Check 'exit 2' ($bad.Code -eq 2)
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Write-Host "baseline invocation tests: $($script:Checks - $script:Failures)/$($script:Checks) passed"
if ($script:Failures -gt 0) {
    [Console]::Error.WriteLine("ERROR: $($script:Failures) check(s) failed.")
    exit 1
}
exit 0
