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
    [string]$WorkingDirectory = $PWD
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
    Write-Host "  Tenant: $($azContext.Tenant.Id)"
    Write-Host "  Subscription: $($azContext.Subscription.Id)"
    
    ## Authenticate using Graph Powershell
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph')) {
        Write-Host "Microsoft.Graph Module does not exists. Installing now.."
        Install-Module Microsoft.Graph -Force -AllowClobber
        Write-Host "Microsoft.Graph Installed Successfully."
    }
    
    ## Import required Graph modules
    Import-Module Microsoft.Graph.Authentication -Force -ErrorAction Stop
    Import-Module Microsoft.Graph.Groups -Force -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications -Force -ErrorAction Stop
    
    ## Disconnect any existing Graph connections
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
    catch {
        Write-Debug "No existing Graph connection to disconnect"
    }
    
    Write-Host "Getting access token for Microsoft Graph API..."
    
    ## Try to get token with explicit scopes
    try {
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
        # Ensure we have a plain string token (not SecureString)
        $graphApiTokenString = [string]$tokenResponse.Token
        Write-Host "Access token obtained successfully (length: $($graphApiTokenString.Length))"
        Write-Host "Token expires: $($tokenResponse.ExpiresOn)"
        
        ## Verify token format (should be a JWT with 3 parts)
        $tokenParts = $graphApiTokenString.Split('.')
        if ($tokenParts.Length -ne 3) {
            throw "Invalid token format - expected JWT with 3 parts, got $($tokenParts.Length)"
        }
        Write-Debug "Token format verified as JWT"
        
        ## Decode token payload to verify audience and scopes (for debugging)
        try {
            $payload = $tokenParts[1]
            # Add padding if needed for base64 decoding
            $mod = $payload.Length % 4
            if ($mod -gt 0) {
                $payload += '=' * (4 - $mod)
            }
            $decodedBytes = [System.Convert]::FromBase64String($payload)
            $decodedJson = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
            $tokenData = $decodedJson | ConvertFrom-Json
            Write-Debug "Token audience: $($tokenData.aud)"
            Write-Debug "Token scopes: $($tokenData.scp)"
            Write-Debug "Token appid: $($tokenData.appid)"
            
            if ($tokenData.aud -ne "https://graph.microsoft.com") {
                Write-Warning "Token audience is '$($tokenData.aud)', expected 'https://graph.microsoft.com'"
            }
        }
        catch {
            Write-Debug "Could not decode token payload for inspection: $_"
        }
        
        ## Connect to Microsoft Graph using the access token
        $targetParameter = (Get-Command Connect-MgGraph).Parameters['AccessToken']
        if ($targetParameter.ParameterType -eq [securestring]){
            $secureToken = ConvertTo-SecureString -String $graphApiTokenString -AsPlainText -Force
            Connect-MgGraph -AccessToken $secureToken -ErrorAction Stop -NoWelcome
        }
        else {
            Connect-MgGraph -AccessToken $graphApiTokenString -ErrorAction Stop -NoWelcome
        }
        Write-Host "Successfully connected to Microsoft Graph"
        
        ## Verify the connection by checking context and testing with a simple API call
        $mgContext = Get-MgContext -ErrorAction SilentlyContinue
        if ($mgContext) {
            Write-Host "Microsoft Graph Context verified"
            Write-Debug "Graph Scopes: $($mgContext.Scopes -join ', ')"
        }
        
        ## Test the connection with a simple API call to verify token works
        Write-Host "Testing Graph API connection..."
        try {
            $testResult = Get-MgContext -ErrorAction Stop
            Write-Host "Graph API connection test successful"
        }
        catch {
            Write-Warning "Graph API connection test failed: $_"
            throw "Graph API connection verification failed. Token may not have required permissions."
        }
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
        if ($graphApiTokenString) {
            Write-Error "Token length: $($graphApiTokenString.Length)"
        }
        Write-Error "Azure Context Account: $($azContext.Account.Id)"
        Write-Error "Azure Context Tenant: $($azContext.Tenant.Id)"
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