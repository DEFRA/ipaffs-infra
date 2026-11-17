using '../../30-classic.bicep'

param entraGroups = {}
param environment = 'SND'
param tenantId = ''

param principalsNeedingContributor = [
  'c5daee65-10cb-4d04-b721-d3da81357568' // ADO-DefraGovUK-AZR-IMP-DEV1 (ADO service connection)
]

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'SND-IMP-DBA-Team'
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
  name: 'SNDIMPDBSDBW001'
  adminEntraGroup: 'AG-Azure-EUX-IPAFFS-Kainos-DevUsers'
  kustoName: 'SNDIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
}

param serviceBusParams = {
  namespaceName: 'SNDIMPINFSBS002'
}

