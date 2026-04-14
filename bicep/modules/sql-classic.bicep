targetScope = 'resourceGroup'

param deploymentId string
param entraGroups object
param location string
param sqlParams object
param tags object
param tenantId string

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' existing = {
  name: sqlParams.serverName
}

resource sqlServerAdministrator 'Microsoft.Sql/servers/administrators@2023-05-01-preview' = {
  parent: sqlServer
  name: 'activeDirectory'
  location: location

  properties: {
    administratorType: 'ActiveDirectory'
    login: entraGroups.sqlAdmins.name
    sid: entraGroups.sqlAdmins.id
    tenantId: tenantId
  }
}

output sqlServerName string = sqlServer.name
output sqlServerManagedIdentityObjectId string = sqlServer.identity.principalId
output sqlServerResourceId string = sqlServer.id

// vim: set ts=2 sts=2 sw=2 et:
