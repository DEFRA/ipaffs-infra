using '../../90-legacy.bicep'

param environment = 'PRE'

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'PRE-IMP-DBA-Team'
      appRecipients: [
        {
          name: 'AppPush: Paul Maguire (Admin)'
          upn: 'a-paul.maguire@defra.onmicrosoftc.com'
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
  name: 'PREIMPDBSDBW001'
  adminEntraGroup: 'AAG-Users-IPAFFS-Support-Admin'
  kustoName: 'PREIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  sqlServerElasticPoolName: 'PREIMPEDPSQA001'
  sqlServerResourceId: '/subscriptions/81ca326e-6270-418a-b764-e02a4ca60457/resourceGroups/PREIMPINFRGP001/providers/Microsoft.Sql/servers/PREIMPDBSSQA001'
}

param sejParams = {
  databaseName: 'elasticjobs'
  databaseNames: ['notification-microservice']
  databaseMaxSizeGiB: 10
  jobAgentName: 'PREIMPDBSJBA001'
  jobAgentSku: {
    name: 'JA100'
    capacity: 100
  }
  sqlServerName: 'PREIMPDBSSQA001'
  userAssignedIdentityName: 'pre-imp-elasticjobs-sql'
}

// vim: set ts=2 sts=2 sw=2 et:
