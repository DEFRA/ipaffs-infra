targetScope = 'resourceGroup'

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

  properties: {
    administratorType: 'ActiveDirectory'
    login: entraGroups.sqlAdmins.name
    sid: entraGroups.sqlAdmins.id
    tenantId: tenantId
  }
}

// Opt-in per environment. The pool was created by the DEFRA-EUX-IMP ARM template;
// once an environment sets sqlParams.elasticPool, this deployment owns its size and
// any scaling runbook or ARM redeploy will be reverted by the next deployment.
// Edition, storage and zone redundancy match the pool as originally deployed.
var elasticPool = sqlParams.?elasticPool

resource sqlElasticPool 'Microsoft.Sql/servers/elasticPools@2023-08-01' = if (elasticPool != null) {
  parent: sqlServer
  name: elasticPool.?name ?? ''
  location: location
  tags: union(tags, {
    Name: elasticPool.?name ?? ''
    Tier: 'Database'
  })
  sku: {
    name: 'PremiumPool'
    tier: 'Premium'
    capacity: elasticPool.?eDtu ?? 0
  }
  properties: {
    maxSizeBytes: elasticPool.?maxSizeBytes ?? 805306368000
    perDatabaseSettings: {
      minCapacity: 0
      maxCapacity: elasticPool.?databaseDtuMax ?? 0
    }
    zoneRedundant: true
  }
}

output sqlServerName string = sqlServer.name
output sqlServerResourceId string = sqlServer.id

