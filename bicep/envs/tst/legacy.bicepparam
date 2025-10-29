using '../../legacy.bicep'

param environment = 'TST'

param dbwParams = {
  name: 'TSTIMPDBSDBW001'
  adminEntraGroup: 'AG-Azure-EUX-IPAFFS-Kainos-DevUsers'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  sqlServerElasticPoolName: 'TSTIMPEDPSQA001'
  sqlServerResourceId: '/subscriptions/00f1225e-37c2-4c7b-bc71-634164b667c6/resourceGroups/TSTIMPINFRGP001/providers/Microsoft.Sql/servers/TSTIMPDBSSQA001'
}

param sejParams = {
  databaseName: 'elasticjobs'
  databaseNames: ['notification-microservice']
  databaseMaxSizeGiB: 10
  jobAgentName: 'TSTIMPDBSJBA001'
  jobAgentSku: {
    name: 'JA100'
    capacity: 100
  }
  sqlServerName: 'TSTIMPDBSSQA001'
  userAssignedIdentityName: 'tst-imp-elasticjobs-sql'
}

// vim: set ts=2 sts=2 sw=2 et:
