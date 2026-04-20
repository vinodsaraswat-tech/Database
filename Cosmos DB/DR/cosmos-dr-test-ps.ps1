#!/usr/bin/env pwsh
#requires -Version 7.0
<#
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
#>
<#
Cosmos DB DR test for UK South <-> East US 2
Works for multi-region write accounts too (tests routing/failover priority behavior).

Usage:
  ./cosmos-dr-test.ps1 -ResourceGroup <rg> -AccountName <acct> [-Primary uksouth|ukwest] [-Rollback]

Examples:
  ./cosmos-dr-test.ps1 -ResourceGroup rg-prod -AccountName cosacct01 -Primary uksouth -Rollback
  ./cosmos-dr-test.ps1 -ResourceGroup rg-prod -AccountName cosacct01 -Primary ukwest

Notes:
- Requires: az CLI installed, logged in, and authorized.
- Region policy names must be Azure display names: "UK South", "East US 2".
#>

param(
    [Parameter(Mandatory = $true)]
    [Alias('g','rg')]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $true)]
    [Alias('n','account')]
    [string] $AccountName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('uksouth', 'ukwest')]
    [string] $Primary = 'uksouth',

    [Parameter(Mandatory = $false)]
    [switch] $Rollback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Args
    )

    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az command failed (exit=$LASTEXITCODE): az $($Args -join ' ')`n$out"
    }
    return ($out | Out-String).Trim()
}

function Get-CosmosProvisioningState {
    param(
        [Parameter(Mandatory = $true)][string] $rg,
        [Parameter(Mandatory = $true)][string] $name
    )

    return Invoke-AzCli @(
        'cosmosdb','show',
        '-g', $rg,
        '-n', $name,
        '--query', 'provisioningState',
        '-o', 'tsv'
    )
}

function Wait-CosmosProvisioning {
    param(
        [Parameter(Mandatory = $true)][string] $rg,
        [Parameter(Mandatory = $true)][string] $name,
        [int] $MaxTries = 60,
        [int] $SleepSeconds = 10
    )

    for ($i = 1; $i -le $MaxTries; $i++) {
        $state = Get-CosmosProvisioningState -rg $rg -name $name
        Write-Host ("  [{0}/{1}] provisioningState={2}" -f $i, $MaxTries, $state)

        if ($state -eq 'Succeeded') { return $true }
        Start-Sleep -Seconds $SleepSeconds
    }

    return $false
}

# Build failover policy arrays based on requested primary
[string[]] $NewPolicies = @()
[string[]] $RollbackPolicies = @()

if ($Primary -eq 'uksouth') {
    $NewPolicies      = @('UK South=0', 'UK West=1')
    $RollbackPolicies = @('UK West=0', 'UK South=1')
} else {
    $NewPolicies      = @('UK West=0', 'UK South=1')
    $RollbackPolicies = @('UK South=0', 'UK West=1')
}

Write-Host "==> Checking Azure login context"
Invoke-AzCli @('account','show') | Out-Null

Write-Host "==> Validating Cosmos account exists"
Invoke-AzCli @('cosmosdb','show','-g', $ResourceGroup,'-n', $AccountName) | Out-Null

Write-Host "==> Pre-check: account mode and regions"
$multiWrite = Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', 'enableMultipleWriteLocations',
    '-o', 'tsv'
)

$ukExists = Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', "length(locations[?locationName=='UK South'])",
    '-o', 'tsv'
)

$eus2Exists = Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', "length(locations[?locationName=='UK West'])",
    '-o', 'tsv'
)

Write-Host "enableMultipleWriteLocations = $multiWrite"
Write-Host "UK South present             = $ukExists"
Write-Host "UK West present            = $eus2Exists"

if ($ukExists -ne '1' -or $eus2Exists -ne '1') {
    throw "ERROR: Account must include both UK South and UK West."
}

Write-Host "==> Current failover priorities"
Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', "locations[].{region:locationName,priority:failoverPriority}",
    '-o', 'table'
) | Write-Host

Write-Host "==> Applying failover-priority change: $($NewPolicies -join ' ')"

# Passing array values so each policy is a separate argument (equivalent to bash "${NEW_POLICIES[@]}")
$cmdArgs = @(
    'cosmosdb','failover-priority-change',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--failover-policies'
) + $NewPolicies

Invoke-AzCli $cmdArgs | Out-Null

Write-Host "==> Waiting for provisioning to complete..."
$ok = Wait-CosmosProvisioning -rg $ResourceGroup -name $AccountName
if (-not $ok) {
    throw "ERROR: failover change did not complete in expected time."
}

Write-Host "==> Post-change validation"
Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', "locations[].{region:locationName,priority:failoverPriority,isZoneRedundant:isZoneRedundant}",
    '-o', 'table'
) | Write-Host

Write-Host "==> Read/Write region view"
Invoke-AzCli @(
    'cosmosdb','show',
    '-g', $ResourceGroup,
    '-n', $AccountName,
    '--query', '{readLocations:readLocations[].locationName, writeLocations:writeLocations[].locationName, multiWrite:enableMultipleWriteLocations}',
    '-o', 'json'
) | Write-Host

# StrictMode-safe switch check:
if ($PSBoundParameters.ContainsKey('Rollback')) {

    Write-Host "==> Rolling back priorities: $($RollbackPolicies -join ' ')"

    $rbArgs = @(
        'cosmosdb','failover-priority-change',
        '-g', $ResourceGroup,
        '-n', $AccountName,
        '--failover-policies'
    ) + $RollbackPolicies

    Invoke-AzCli $rbArgs | Out-Null

    Write-Host "==> Waiting for rollback to complete..."
    $ok2 = Wait-CosmosProvisioning -rg $ResourceGroup -name $AccountName
    if (-not $ok2) {
        throw "ERROR: rollback did not complete in expected time."
    }

    Write-Host "==> Final priorities after rollback"
    Invoke-AzCli @(
        'cosmosdb','show',
        '-g', $ResourceGroup,
        '-n', $AccountName,
        '--query', "locations[].{region:locationName,priority:failoverPriority}",
        '-o', 'table'
    ) | Write-Host
}

Write-Host "DR test completed."