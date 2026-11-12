targetScope = 'resourceGroup'

param location string
param sqlPoolParams object

// Set only when sqlPoolParams.keepLiveCapacity is true. TST is scaled up on weekday
// mornings by something outside this repo, so it keeps whatever SKU and per-database
// limits are live when the deployment runs instead of scaling the pool back down.
param liveSku object = {}
param livePerDatabaseSettings object = {}

var keepLiveCapacity = sqlPoolParams.?keepLiveCapacity ?? false

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlPoolParams.serverName
}

// The pool was created outside this repo by the original ARM templates. This module
// pins its current settings so later changes (such as a vCore move) go through review.
resource elasticPool 'Microsoft.Sql/servers/elasticPools@2023-08-01' = {
  parent: sqlServer
  name: sqlPoolParams.name
  location: location
  tags: sqlPoolParams.tags

  sku: keepLiveCapacity ? liveSku : sqlPoolParams.sku

  properties: {
    licenseType: sqlPoolParams.?licenseType
    maintenanceConfigurationId: subscriptionResourceId('Microsoft.Maintenance/publicMaintenanceConfigurations', sqlPoolParams.maintenanceConfigurationName)
    maxSizeBytes: sqlPoolParams.maxSizeGiB * 1024 * 1024 * 1024
    perDatabaseSettings: keepLiveCapacity ? livePerDatabaseSettings : sqlPoolParams.perDatabaseSettings
    zoneRedundant: sqlPoolParams.zoneRedundant
  }
}

output elasticPoolName string = elasticPool.name
output elasticPoolResourceId string = elasticPool.id
