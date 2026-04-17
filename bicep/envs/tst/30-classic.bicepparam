using '../../30-classic.bicep'

param entraGroups = {}
param environment = 'TST'
param tenantId = ''

param newVnetResourceId = ''

param principalsNeedingContributor = [
  '7b097afb-e281-4bc4-8086-c1ff4f47964b' // ADO-DefraGovUK-AZR-IMP-TST11 (ADO service connection)
]

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'TST-IMP-DBA-Team'
      appRecipients: [
        {
          name: 'AppPush: Paul Maguire'
          upn: 'paul.maguire@defra.onmicrosoft.com'
        }
      ]
      emailRecipients: [
        {
          name: 'Email: Paul Maguire'
          email: 'paul.maguire@esynergy.co.uk'
        }
      ]
    }
  }
}

param dbwParams = {
  name: 'TSTIMPDBSDBW001'
  adminEntraGroup: 'AG-Azure-EUX-IPAFFS-Kainos-DevUsers'
  kustoName: 'TSTIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  sqlServerElasticPoolName: 'TSTIMPEDPSQA001'
  sqlServerResourceId: '/subscriptions/00f1225e-37c2-4c7b-bc71-634164b667c6/resourceGroups/TSTIMPINFRGP001/providers/Microsoft.Sql/servers/TSTIMPDBSSQA001'
}

param redisParams = {
  name: 'TSTIMPINFRDS001'
}

param searchParams = {
  name: 'tstimpinfass001'
  userAssignedIdentityName: 'TSTIMPINFASS001'
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

param serviceBusParams = {
  namespaceName: 'TSTIMPINFSBS002'
}

param sqlParams = {
  serverName: 'tstimpdbssqa001'
}

// vim: set ts=2 sts=2 sw=2 et:
