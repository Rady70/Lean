<#
.SYNOPSIS
Reports the frozen SingleAnchor baseline contract identity and renders its exact run invocation.

.DESCRIPTION
Reads the canonical baseline contract (MarketLab\config\baseline-contract.json), verifies
that it is the frozen, immutable contract, computes its baseline contract identity (the
SHA-256 of the file's UTF-8 text content with CRLF normalized to LF), renders the exact
`-Parameters` string and the exact `run-backtest.ps1` invocation, and prints them.

This script starts nothing: it does not launch LEAN, build anything, touch any data file
or call any external service. The future authoritative baseline run reports the identity
this script prints so the reviewed frozen contract that generated its results is provable.

Exit codes:
  0  contract verified; identity and invocation printed
  2  the contract file is missing, unparsable or not the frozen immutable contract, or
     the contract's recorded exact run command does not match the rendered one

.PARAMETER Contract
Path to the contract file. Default: <script root>\..\config\baseline-contract.json.

.PARAMETER Register
Path to the authoritative decision register that pins the frozen contract hash.
Default: <contract directory>\baseline-decision-audit.json. The script refuses
(exit 2) to render the frozen invocation when the contract file's computed hash
does not equal the register's frozenBaselineContractSha256.

.PARAMETER Json
Emit the identity, the parameters string and the run command as one JSON object instead
of the human-readable report.

.EXAMPLE
pwsh -File MarketLab\scripts\Get-SingleAnchorBaselineInvocation.ps1
Prints the baseline contract identity and the exact invocation.

.EXAMPLE
pwsh -File MarketLab\scripts\Get-SingleAnchorBaselineInvocation.ps1 -Json
Prints the same report as machine-readable JSON.
#>
[CmdletBinding()]
param(
    [string]$Contract,
    [string]$Register,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ExitPreflight = 2

function Write-ErrorLine([string]$Message) {
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Get-JsonProperty($Object, [string]$Name) {
    if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $Name)) {
        throw "the contract is missing property '$Name'"
    }
    return $Object.$Name
}

function Get-ContractSha256([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

if ([string]::IsNullOrWhiteSpace($Contract)) {
    $Contract = Join-Path $PSScriptRoot '..\config\baseline-contract.json'
}
$contractPath = [System.IO.Path]::GetFullPath($Contract)
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    Write-ErrorLine "the baseline contract '$contractPath' does not exist."
    exit $script:ExitPreflight
}

try {
    $contractData = [System.IO.File]::ReadAllText($contractPath) | ConvertFrom-Json
}
catch {
    Write-ErrorLine "the baseline contract '$contractPath' is not valid JSON: $($_.Exception.Message)"
    exit $script:ExitPreflight
}

# --- Contract self-consistency ------------------------------------------------
try {
    $contractId = Get-JsonProperty $contractData 'contract'
    $status = Get-JsonProperty $contractData 'status'
    $immutable = Get-JsonProperty $contractData 'immutable'
    $parameters = @(Get-JsonProperty $contractData 'parameters')
    $runHost = Get-JsonProperty $contractData 'runHost'
    $dataIdentity = Get-JsonProperty $contractData 'qualifiedDataIdentity'
    $runProcedure = Get-JsonProperty $contractData 'runProcedure'
}
catch {
    Write-ErrorLine $_.Exception.Message
    exit $script:ExitPreflight
}

if ($contractId -ne 'marketlab-single-anchor-baseline-contract-v1') {
    Write-ErrorLine "unexpected contract id '$contractId'; expected 'marketlab-single-anchor-baseline-contract-v1'."
    exit $script:ExitPreflight
}
if ($status -ne 'frozen' -or -not $immutable) {
    Write-ErrorLine "the contract is not the frozen immutable baseline contract (status '$status', immutable '$immutable')."
    exit $script:ExitPreflight
}
if ($parameters.Count -eq 0) {
    Write-ErrorLine 'the contract carries no parameters.'
    exit $script:ExitPreflight
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$pairs = New-Object 'System.Collections.Generic.List[string]'
foreach ($parameter in $parameters) {
    $name = [string]$parameter.name
    $value = [string]$parameter.value
    $authority = [string]$parameter.authority
    if ($name -notmatch '^single-anchor-[a-z0-9-]+$') {
        Write-ErrorLine "parameter name '$name' is not a single-anchor-* LEAN parameter name."
        exit $script:ExitPreflight
    }
    if (-not $seen.Add($name)) {
        Write-ErrorLine "parameter '$name' is declared more than once."
        exit $script:ExitPreflight
    }
    if ([string]::IsNullOrWhiteSpace($value) -or [string]::IsNullOrWhiteSpace($authority)) {
        Write-ErrorLine "parameter '$name' must carry both a value and an authority."
        exit $script:ExitPreflight
    }
    if ($name -match '[\s,:"]' -or $value -match '[\s,:"]') {
        Write-ErrorLine "parameter '$name' has a name or value the LEAN -Parameters channel cannot carry intact (whitespace, comma, colon or quote)."
        exit $script:ExitPreflight
    }
    $pairs.Add("${name}:${value}")
}
$parametersString = $pairs -join ','

$renderedCommand = "pwsh -File MarketLab\scripts\run-backtest.ps1" `
    + " -Configuration $($runHost.buildConfiguration)" `
    + " -Config $($runHost.leanConfig)" `
    + " -AlgorithmTypeName $($runHost.algorithmTypeName)" `
    + " -AlgorithmLanguage $($runHost.algorithmLanguage)" `
    + " -AlgorithmLocation $($runHost.algorithmLocation)" `
    + " -DataFolder $($dataIdentity.dataFolder)" `
    + " -Parameters `"$parametersString`"" `
    + " -AllowMissingData -RunEvidence" `
    + " -BaselineContract MarketLab\config\baseline-contract.json" `
    + " -BaselineRegister MarketLab\config\baseline-decision-audit.json"

$recordedCommand = Get-JsonProperty $runProcedure 'exactRunCommand'
if ($recordedCommand -ne $renderedCommand) {
    Write-ErrorLine "the contract's exactRunCommand does not match the invocation rendered from its own fields; the contract is internally inconsistent."
    exit $script:ExitPreflight
}
if (-not $runHost.allowMissingData -or $runHost.allowEngineErrors) {
    Write-ErrorLine 'the contract run policy must be -AllowMissingData present and -AllowEngineErrors absent.'
    exit $script:ExitPreflight
}
if ($renderedCommand -match '-AllowEngineErrors') {
    Write-ErrorLine 'the rendered invocation must not carry -AllowEngineErrors.'
    exit $script:ExitPreflight
}

$contractSha256 = Get-ContractSha256 $contractPath

# The contract file alone proves nothing: the authoritative decision register
# pins the frozen contract hash. Refuse to render (or advertise) the frozen
# invocation when the file's computed hash does not equal that pin, so an
# accidentally edited local contract cannot masquerade as the baseline.
if ([string]::IsNullOrWhiteSpace($Register)) {
    $Register = Join-Path (Split-Path -Parent $contractPath) 'baseline-decision-audit.json'
}
$registerPath = [System.IO.Path]::GetFullPath($Register)
if (-not (Test-Path -LiteralPath $registerPath -PathType Leaf)) {
    Write-ErrorLine "the authoritative decision register '$registerPath' does not exist; the contract hash cannot be checked against its pin."
    exit $script:ExitPreflight
}
try {
    $registerData = [System.IO.File]::ReadAllText($registerPath) | ConvertFrom-Json
    $registerPin = Get-JsonProperty $registerData 'frozenBaselineContractSha256'
    $registerContract = Get-JsonProperty $registerData 'frozenBaselineContract'
}
catch {
    Write-ErrorLine "the authoritative decision register '$registerPath' is unreadable: $($_.Exception.Message)"
    exit $script:ExitPreflight
}
if ($registerPin -ne $contractSha256) {
    Write-ErrorLine "the contract hash $contractSha256 does not match the authoritative register pin $registerPin in '$registerPath'; refusing to render the frozen invocation."
    exit $script:ExitPreflight
}

$postRunAudit = Get-JsonProperty $runProcedure 'postRunAuditCommand'

if ($Json) {
    $report = [ordered]@{
        contract = $contractId
        status = $status
        contractSha256 = $contractSha256
        register = $registerContract
        registerPin = $registerPin
        registerMatches = $true
        parameterCount = $parameters.Count
        parameters = $parametersString
        runCommand = $renderedCommand
        postRunAuditCommand = $postRunAudit
    }
    $report | ConvertTo-Json -Depth 3
    exit 0
}

Write-Host 'MarketLab SingleAnchor frozen baseline contract'
Write-Host "contract:                  $contractId"
Write-Host "status:                    $status"
Write-Host "contract SHA-256:          $contractSha256  (LF-normalized tracked file content)"
Write-Host "register pin:              $registerPin  (verified: $registerContract)"
Write-Host "explicit parameters:       $($parameters.Count) single-anchor-* values"
Write-Host ''
Write-Host 'Parameters string:'
Write-Host $parametersString
Write-Host ''
Write-Host 'Exact baseline run invocation (run after this contract is reviewed and merged):'
Write-Host $renderedCommand
Write-Host ''
Write-Host 'Post-run failed-data classification:'
Write-Host $postRunAudit
exit 0
