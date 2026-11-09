targetScope = 'resourceGroup'

param entraGroups object
param sqlParams object
param tenantId string

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' existing = {
  name: sqlParams.serverName
}

resource sqlServerAdministrator 'Microsoft.Sql/servers/administrators@2023-05-01-preview' = {
  parent: sqlServer
  name: 'activeDirectory'

  properties: {
    administratorType: 'ActiveDirectory'
    login: entraGroups.sqlAdmins.name
    sid: entraGroups.sqlAdmins.id
    tenantId: tenantId
  }
}

output sqlServerName string = sqlServer.name
output sqlServerResourceId string = sqlServer.id

