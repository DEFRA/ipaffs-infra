using '../../30-classic.bicep'

param entraGroups = {}
param environment = 'TST'
param tenantId = ''

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

param sqlPoolsParams = [
  {
    serverName: 'tstimpdbssqa001'
    name: 'tstimpedpsqa001'
    // Scaled to 1000 eDTU on weekday mornings outside this repo; keep the live SKU.
    keepLiveCapacity: true
    sku: {
      name: 'PremiumPool'
      tier: 'Premium'
      capacity: 250
    }
    perDatabaseSettings: {
      minCapacity: 0
      maxCapacity: 250
    }
    maxSizeGiB: 750
    zoneRedundant: true
    maintenanceConfigurationName: 'SQL_Default'
    // The pool's own tags from the original ARM template, kept as they are live.
    tags: {
      CreatedDate: '20260609  '
      Environment: 'TST'
      Location: 'North Europe'
      Name: 'tstimpedpsqa001'
      ServiceCode: 'IMP'
      ServiceName: 'EUX Imports'
      ServiceType: 'LOB'
      Tier: 'Database'
    }
  }
]

