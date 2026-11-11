using '../../30-classic.bicep'

param entraGroups = {}
param environment = 'PRD'
param tenantId = ''

param principalsNeedingContributor = [
  'a3e0f04c-827a-4abc-89c2-249e476b3cf2' // ADO-DefraGovUK-AZR-IMP-PRD1 (ADO service connection)
]

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'PRD-IMP-DBA-Team'
      appRecipients: [
        {
          name: 'AppPush: Paul Maguire (Admin)'
          upn: 'a-paul.maguire@defra.onmicrosoft.com'
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
  name: 'PRDIMPDBSDBW001'
  adminEntraGroup: 'AAG-Users-IPAFFS-Support-Admin'
  kustoName: 'PRDIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
}

param redisParams = {
  name: 'PRDIMPINFRDS001'
}

param searchParams = {
  name: 'prdimpinfass001'
  userAssignedIdentityName: 'PRDIMPINFASS001'
}

param sejParams = {
  // Keep the existing maintenance targets, SQL commands and schedules.
  manageMaintenanceDefinitions: false
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

param serviceBusParams = {
  namespaceName: 'PRDIMPINFSBS002'
}

param sqlParams = {
  serverName: 'prdimpdbssqa001'
}

