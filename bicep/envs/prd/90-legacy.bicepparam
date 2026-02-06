using '../../90-legacy.bicep'

param environment = 'PRD'

param dbwParams = {
  name: 'PRDIMPDBSDBW001'
  adminEntraGroup: 'AAG-Users-IPAFFS-Support-Admin'
  kustoName: 'PRDIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  sqlServerElasticPoolName: 'PRDIMPEDPSQA001'
  sqlServerResourceId: '/subscriptions/79ee8c9c-33d7-4074-9f4c-a13f07c62a33/resourceGroups/PRDIMPINFRGP001/providers/Microsoft.Sql/servers/PRDIMPDBSSQA001'
}

param sejParams = {
  databaseName: 'elasticjobs'
  databaseNames: ['notification-microservice']
  databaseMaxSizeGiB: 10
  jobAgentName: 'PRDIMPDBSJBA001'
  jobAgentSku: {
    name: 'JA100'
    capacity: 100
  }
  sqlServerName: 'PRDIMPDBSSQA001'
  userAssignedIdentityName: 'prd-imp-elasticjobs-sql'
}

// vim: set ts=2 sts=2 sw=2 et:
