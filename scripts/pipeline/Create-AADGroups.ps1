[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AADGroupsJsonManifestPath,

    [Parameter()]
    [string]$WorkingDirectory = $PWD,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientSecret
)

Set-StrictMode -Version 3.0
[string]$functionName = $MyInvocation.MyCommand
[datetime]$startTime = [datetime]::UtcNow
[int]$exitCode = -1

$ErrorActionPreference = "Continue"
$InformationPreference = "Continue"

Write-Host "${functionName} started at $($startTime.ToString('u'))"
Write-Debug "${functionName}:AADGroupsJsonManifestPath=$AADGroupsJsonManifestPath"

try {
    # Load module
    $adGroupsModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "../Powershell/aad-groups"
    Import-Module $adGroupsModuleDir.FullName -Force

    # Ensure Microsoft.Graph module installed
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph')) {
        Install-Module Microsoft.Graph -Force
    }

    Write-Host "======================================================"
    Write-Host "Authenticating to Microsoft Graph using SPN credentials..."

    # Correct authentication for Linux
    Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -ClientSecret $ClientSecret

    $context = Get-MgContext
    Write-Host "Connected to Microsoft Graph as: $($context.ClientId)"
    Write-Host "======================================================"

    # Load AAD Groups Manifest
    $aadGroups = Get-Content -Raw -Path $AADGroupsJsonManifestPath | ConvertFrom-Json

    # Process user AD groups
    if ($aadGroups.userADGroups) {
        foreach ($g in $aadGroups.userADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($g.displayName)'"
            if ($result) {
                Write-Host "User AD Group '$($g.displayName)' exists. Group Id: $($result.Id)"
                Update-ADGroup -AADGroupObject $g -GroupId $result.Id
            } else {
                Write-Host "User AD Group '$($g.displayName)' does not exist."
                New-ADGroup -AADGroupObject $g
            }
        }
    }

    # Process access AD groups
    if ($aadGroups.accessADGroups) {
        foreach ($g in $aadGroups.accessADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($g.displayName)'"
            if ($result) {
                Write-Host "Access AD Group '$($g.displayName)' exists. Group Id: $($result.Id)"
                Update-ADGroup -AADGroupObject $g -GroupId $result.Id
            } else {
                Write-Host "Access AD Group '$($g.displayName)' does not exist."
                New-ADGroup -AADGroupObject $g
            }
        }
    }

    $exitCode = 0
}
catch {
    $exitCode = -2
    Write-Error $_.Exception.ToString()
    throw
}
finally {
    $endTime = [DateTime]::UtcNow
    $duration = $endTime - $startTime
    Write-Host "${functionName} finished at $($endTime.ToString('u')) (duration $($duration -f 'g')) with exit code $exitCode"
    exit $exitCode
}
