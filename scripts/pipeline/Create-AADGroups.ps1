<#
.SYNOPSIS
Create or Update Azure AD security Groups.

.DESCRIPTION
Uses Microsoft Graph to create or update AD groups based on a JSON manifest.

.PARAMETER AADGroupsJsonManifestPath
Mandatory. Path to the JSON manifest defining groups.

.PARAMETER WorkingDirectory
Optional. Working directory. Default is $PWD.

.PARAMETER ClientId
Mandatory. SPN Client ID.

.PARAMETER TenantId
Mandatory. Tenant ID.

.PARAMETER ClientSecret
Mandatory. SPN Client Secret (from pipeline variable).
#>

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
Write-Debug "${functionName}:WorkingDirectory=$WorkingDirectory"

try {
    # ------------------------------------------------------------
    # Load AD-groups module
    # ------------------------------------------------------------
    $adGroupsModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "../Powershell/aad-groups"
    Write-Debug "${functionName}:moduleDir=$adGroupsModuleDir"
    Import-Module $adGroupsModuleDir -Force

    # ------------------------------------------------------------
    # Ensure Microsoft.Graph module installed
    # ------------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph')) {
        Write-Host "Installing Microsoft.Graph module..."
        Install-Module Microsoft.Graph -Force
    }

    Write-Host "======================================================"
    Write-Host "Authenticating to Microsoft Graph using SPN credentials..."

    # ------------------------------------------------------------
    # CONNECT TO MICROSOFT GRAPH (Linux-compatible)
    # ------------------------------------------------------------
    Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -ClientSecret $ClientSecret

    $context = Get-MgContext
    Write-Host "Connected to Microsoft Graph as: $($context.ClientId)"
    Write-Host "======================================================"

    # ------------------------------------------------------------
    # Load AAD Groups Manifest
    # ------------------------------------------------------------
    $aadGroups = Get-Content -Raw -Path $AADGroupsJsonManifestPath | ConvertFrom-Json

    # ------------------------------------------------------------
    # Setup User AD Groups
    # ------------------------------------------------------------
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
    } else {
        Write-Host "No 'userADGroups' defined in group manifest file. Skipped"
    }

    # ------------------------------------------------------------
    # Setup Access AD Groups
    # ------------------------------------------------------------
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
    } else {
        Write-Host "No 'accessADGroups' defined in group manifest file. Skipped"
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
