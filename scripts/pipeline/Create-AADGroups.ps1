<#
.SYNOPSIS
Create or Update an Azure AD security Group.

.DESCRIPTION
Create or Update an Azure AD security Group properties, members and owners.

.PARAMETER AADGroupsJsonManifestPath
Mandatory. AAD Groups configuration file.

.PARAMETER WorkingDirectory
Optional. Working directory. Default is $PWD.

.PARAMETER ClientId
Optional. Client ID for app registration (fallback authentication).

.PARAMETER TenantId
Optional. Tenant ID for app registration (fallback authentication).

.PARAMETER ClientSecret
Optional. Client secret for app registration (fallback authentication).

.EXAMPLE
Federated Identity (Azure DevOps/GitHub):
.\Create-AADGroups.ps1 -AADGroupsJsonManifestPath .\groups.json

.EXAMPLE
Client Secret fallback:
.\Create-AADGroups.ps1 -AADGroupsJsonManifestPath .\groups.json `
                       -ClientId xxxx -TenantId yyyy -ClientSecret zzzz
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AADGroupsJsonManifestPath,

    [Parameter()]
    [string]$WorkingDirectory = $PWD,

    # Fallback auth parameters
    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientSecret
)

Set-StrictMode -Version 3.0
[string]$functionName = $MyInvocation.MyCommand
[datetime]$startTime = [datetime]::UtcNow

[int]$exitCode = -1
[bool]$setHostExitCode = (Test-Path -Path ENV:TF_BUILD) -and ($ENV:TF_BUILD -eq "true")
[bool]$enableDebug = (Test-Path -Path ENV:SYSTEM_DEBUG) -and ($ENV:SYSTEM_DEBUG -eq "true")

$ErrorActionPreference = "Continue"
$InformationPreference = "Continue"

if ($enableDebug) {
    $VerbosePreference = "Continue"
    $DebugPreference = "Continue"
}

Write-Host "${functionName} started at $($startTime.ToString('u'))"
Write-Debug "${functionName}:AADGroupsJsonManifestPath=$AADGroupsJsonManifestPath"
Write-Debug "${functionName}:WorkingDirectory=$WorkingDirectory"

try {
    # Load AD-group module
    [System.IO.DirectoryInfo]$adGroupsModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "../Powershell/aad-groups"
    Write-Debug "${functionName}:moduleDir.FullName=$($adGroupsModuleDir.FullName)"
    Import-Module $adGroupsModuleDir.FullName -Force

    # Ensure Microsoft.Graph installed
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph')) {
        Write-Host "Installing Microsoft.Graph module..."
        Install-Module Microsoft.Graph -Force
    }

    Write-Host "======================================================"  
    Write-Host "Authenticating to Microsoft Graph..."

    # ---------------------------
    # MAIN AUTH LOGIC
    # ---------------------------

    if ($ClientId -and $TenantId -and $ClientSecret) {
        # Fallback authentication (client secret)
        Write-Host "Using client-secret authentication..."
        Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -ClientSecret $ClientSecret
    }
    else {
        # Primary authentication (Federated Credentials / Managed Identity)
        Write-Host "Using federated / managed identity authentication..."
        Connect-MgGraph -Identity
    }

    $context = Get-MgContext
    Write-Host "Connected to Microsoft Graph as: $($context.Account)"

    Write-Host "======================================================"

    # Load AAD Groups Manifest
    [PSCustomObject]$aadGroups = Get-Content -Raw -Path $AADGroupsJsonManifestPath | ConvertFrom-Json
    Write-Debug "${functionName}:aadGroups=$($aadGroups | ConvertTo-Json -Depth 10)"

    # ------------------------------------------------------------
    # Setup User AD Groups
    # ------------------------------------------------------------
    if (($aadGroups.psobject.properties.match('userADGroups').Count -gt 0) -and $aadGroups.userADGroups) {
        foreach ($userAADGroup in $aadGroups.userADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($userAADGroup.displayName)'"
        
            if ($result) {
                Write-Host "User AD Group '$($userAADGroup.displayName)' already exists. Group Id: $($result.Id)"
                Update-ADGroup -AADGroupObject $userAADGroup -GroupId $result.Id
            }
            else {
                Write-Host "User AD Group '$($userAADGroup.displayName)' does not exist."
                New-ADGroup -AADGroupObject $userAADGroup
            }
        }
    }
    else {
        Write-Host "No 'userADGroups' defined in group manifest file. Skipped"
    }

    # ------------------------------------------------------------
    # Setup Access AD Groups
    # ------------------------------------------------------------
    if (($aadGroups.psobject.properties.match('accessADGroups').Count -gt 0) -and $aadGroups.accessADGroups) {
        foreach ($accessAADGroup in $aadGroups.accessADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($accessAADGroup.displayName)'"
        
            if ($result) {
                Write-Host "Access AD Group '$($accessAADGroup.displayName)' already exists. Group Id: $($result.Id)"
                Update-ADGroup -AADGroupObject $accessAADGroup -GroupId $result.Id
            }
            else {
                Write-Host "Access AD Group '$($accessAADGroup.displayName)' does not exist."
                New-ADGroup -AADGroupObject $accessAADGroup
            }
        }
    }
    else {
        Write-Host "No 'accessADGroups' defined in group manifest file. Skipped"
    }

    $exitCode = 0    
}
catch {
    $exitCode = -2
    Write-Error $_.Exception.ToString()
    throw $_.Exception
}
finally {
    [DateTime]$endTime = [DateTime]::UtcNow
    [Timespan]$duration = $endTime.Subtract($startTime)

    Write-Host "${functionName} finished at $($endTime.ToString('u')) (duration $($duration -f 'g')) with exit code $exitCode"

    if ($setHostExitCode) {
        Write-Debug "${functionName}:Setting host exit code"
        $host.SetShouldExit($exitCode)
    }

    exit $exitCode
}
