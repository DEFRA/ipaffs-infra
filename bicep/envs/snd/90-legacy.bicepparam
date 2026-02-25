using '../../90-legacy.bicep'

param environment = 'SND'

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'IMP-DBA-Team'
      appRecipients: [
        {
          name: 'Paul Maguire'
          upn: 'paul.maguire@defra.onmicrosoftc.com'
        }
      ]
      emailRecipients: [
        {
          name: 'Paul Maguire'
          email: 'paul.maguire@esynergy.co.uk'
        }
      ]
    }
  }
}

param dbwParams = {
  name: 'SNDIMPDBSDBW001'
  adminEntraGroup: 'AG-Azure-EUX-IPAFFS-Kainos-DevUsers'
  kustoName: 'SNDIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
  sqlServerElasticPoolName: 'SNDIMPDBSSQA004'
  sqlServerResourceId: '/subscriptions/e716414f-1f8e-48f1-8f56-65f35cfdafb6/resourceGroups/SNDIMPINFRGP009/providers/Microsoft.Sql/servers/SNDIMPDBSSQA004'
}

param sejParams = {
  databaseName: 'elasticjobs'
  databaseNames: ['notification-microservice']
  databaseMaxSizeGiB: 10
  jobAgentName: 'SNDIMPDBSJBA001'

  jobAgentSku: {
    name: 'JA100'
    capacity: 100
  }

  sqlServerName: 'SNDIMPDBSSQA004'
  userAssignedIdentityName: 'snd-imp-elasticjobs-sql'
}

// vim: set ts=2 sts=2 sw=2 et:
