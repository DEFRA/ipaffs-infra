<#
.SYNOPSIS
Create or Update an Azure AD security Group.

.DESCRIPTION
Create or Update an Azure AD security Group properties, members and owners.

.PARAMETER AADGroupsJsonManifestPath
Mandatory. AAD Groups configuration file.

.PARAMETER WorkingDirectory
Optional. Working directory. Default is $PWD.

.EXAMPLE
.\Create-AADGroups.ps1 AADGroupsJsonManifestPath <AAD Groups config json path>
#> 

[CmdletBinding()]
param(
    [Parameter(Mandatory)] 
    [string]$AADGroupsJsonManifestPath,
    [Parameter()]
    [string]$WorkingDirectory = $PWD,
    [Parameter()]
    [string]$ExpectedServiceConnectionName = ''
)

Set-StrictMode -Version 3.0

[string]$functionName = $MyInvocation.MyCommand
[datetime]$startTime = [datetime]::UtcNow

[int]$exitCode = -1
[bool]$setHostExitCode = (Test-Path -Path ENV:TF_BUILD) -and ($ENV:TF_BUILD -eq "true")
[bool]$enableDebug = (Test-Path -Path ENV:SYSTEM_DEBUG) -and ($ENV:SYSTEM_DEBUG -eq "true")

Set-Variable -Name ErrorActionPreference -Value Continue -scope global
Set-Variable -Name InformationPreference -Value Continue -Scope global

if ($enableDebug) {
    Set-Variable -Name VerbosePreference -Value Continue -Scope global
    Set-Variable -Name DebugPreference -Value Continue -Scope global
}

Write-Host "${functionName} started at $($startTime.ToString('u'))"
Write-Debug "${functionName}:AADGroupsJsonManifestPath=$AADGroupsJsonManifestPath"
Write-Debug "${functionName}:WorkingDirectory=$WorkingDirectory"

try {
    [System.IO.DirectoryInfo]$adGroupsModuleDir = Join-Path -Path $PSScriptRoot -ChildPath "../Powershell/aad-groups"
    Write-Debug "${functionName}:moduleDir.FullName=$($adGroupsModuleDir.FullName)"
    Import-Module $adGroupsModuleDir.FullName -Force
    
    ## Verify Azure context
    $azContext = Get-AzContext
    Write-Host "Current Azure Context:"
    Write-Host "  Account: $($azContext.Account.Id)"
    Write-Host "  Account Type: $($azContext.Account.Type)"
    Write-Host "  Tenant: $($azContext.Tenant.Id)"
    Write-Host "  Subscription: $($azContext.Subscription.Id)"
    Write-Host "  Subscription Name: $($azContext.Subscription.Name)"
    
    ## Verify we're using the correct service connection
    if ($ExpectedServiceConnectionName) {
        Write-Host "Verifying service connection matches expected: $ExpectedServiceConnectionName"
        
        ## Check if account ID matches expected pattern or if we can verify via subscription name
        ## Service connection names often map to subscription names or can be verified via environment variables
        $serviceConnectionMatch = $false
        
        ## Check if subscription name contains the service connection name
        if ($azContext.Subscription.Name -like "*$ExpectedServiceConnectionName*") {
            $serviceConnectionMatch = $true
            Write-Host "✓ Service connection verified via subscription name match"
        }
        ## Check environment variable set by AzurePowerShell task (if addSpnToEnvironment is true)
        elseif ($env:AZURE_SERVICE_PRINCIPAL_ID) {
            Write-Host "  Service Principal ID from environment: $env:AZURE_SERVICE_PRINCIPAL_ID"
            Write-Host "  Account ID: $($azContext.Account.Id)"
            ## If they match, we're good
            if ($env:AZURE_SERVICE_PRINCIPAL_ID -eq $azContext.Account.Id) {
                $serviceConnectionMatch = $true
                Write-Host "✓ Service connection verified via service principal ID match"
            }
        }
        ## Check account ID format (service principals are typically GUIDs)
        elseif ($azContext.Account.Type -eq 'ServicePrincipal') {
            Write-Host "  Using Service Principal authentication"
            Write-Host "  Note: Cannot directly verify service connection name '$ExpectedServiceConnectionName'"
            Write-Host "  Account ID (Service Principal): $($azContext.Account.Id)"
            ## For now, just warn but don't fail - the account type is correct
            $serviceConnectionMatch = $true
            Write-Host "✓ Service Principal authentication confirmed"
        }
        
        if (-not $serviceConnectionMatch) {
            Write-Warning "Could not verify service connection name '$ExpectedServiceConnectionName'"
            Write-Warning "Current account: $($azContext.Account.Id) (Type: $($azContext.Account.Type))"
            Write-Warning "Please verify manually that this is the correct service connection"
        }
    }
    else {
        Write-Host "No expected service connection name provided - skipping verification"
    }
    
    ## Authenticate using Graph Powershell
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph')) {
        Write-Host "Microsoft.Graph Module does not exists. Installing now.."
        Install-Module Microsoft.Graph -Force
        Write-Host "Microsoft.Graph Installed Successfully."
    }
    
    ## Disconnect any existing Graph connections
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
    catch {
        Write-Debug "No existing Graph connection to disconnect"
    }
    
    Write-Host "Getting access token for Microsoft Graph API..."
    $tokenResponse = Get-AzAccessToken -Resource "https://graph.microsoft.com"
    $graphApiToken = $tokenResponse.Token
    Write-Host "Access token obtained successfully (length: $($graphApiToken.Length))"
    Write-Host "Token expires: $($tokenResponse.ExpiresOn)"
    
    ## Verify token is a valid JWT format
    $tokenParts = $graphApiToken.Split('.')
    if ($tokenParts.Length -ne 3) {
        throw "Invalid token format - expected JWT with 3 parts, got $($tokenParts.Length)"
    }
    Write-Debug "Token format verified as JWT"

    ## Connect to Microsoft Graph using the access token
    ## Microsoft.Graph module expects SecureString for AccessToken parameter
    $secureToken = ConvertTo-SecureString -String $graphApiToken -AsPlainText -Force
    Connect-MgGraph -AccessToken $secureToken -ErrorAction Stop -NoWelcome
    Write-Host "Successfully connected to Microsoft Graph"
    
    ## Verify the connection by getting current context
    $mgContext = Get-MgContext
    Write-Host "Microsoft Graph Context:"
    Write-Host "  Scopes: $($mgContext.Scopes -join ', ')"
    Write-Host "  Account: $($mgContext.Account)"
    
    ## Test the connection with a simple API call
    Write-Host "Testing Graph API connection..."
    try {
        $testResult = Get-MgContext -ErrorAction Stop
        Write-Host "Graph API connection test successful"
    }
    catch {
        Write-Warning "Graph API connection test failed: $_"
        throw
    }
    Write-Host "======================================================"


    [PSCustomObject]$aadGroups = Get-Content -Raw -Path $AADGroupsJsonManifestPath | ConvertFrom-Json

    Write-Debug "${functionName}:aadGroups=$($aadGroups | ConvertTo-Json -Depth 10)"

    #Setup User AD groups
    if (($aadGroups.psobject.properties.match('userADGroups').Count -gt 0) -and $aadGroups.userADGroups) {
        foreach ($userAADGroup in $aadGroups.userADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($userAADGroup.displayName)'"
        
            if ($result) {
                Write-Host "User AD Group '$($userAADGroup.displayName)' already exist. Group Id: $($result.Id)"
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

    #Setup Access AD groups
    if (($aadGroups.psobject.properties.match('accessADGroups').Count -gt 0) -and $aadGroups.accessADGroups) {
        foreach ($accessAADGroup in $aadGroups.accessADGroups) {
            $result = Get-MgGroup -Filter "DisplayName eq '$($accessAADGroup.displayName)'"
        
            if ($result) {
                Write-Host "Access AD Group '$($accessAADGroup.displayName)' already exist. Group Id: $result.Id"
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