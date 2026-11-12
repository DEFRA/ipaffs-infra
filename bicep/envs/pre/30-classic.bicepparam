using '../../30-classic.bicep'

param entraGroups = {}
param environment = 'PRE'
param tenantId = ''

param principalsNeedingContributor = [
  '53a47ce7-dbaa-494e-8a87-54b13248ccd8' // ADO-DefraGovUK-AZR-IMP-PRE1 (ADO service connection)
]

param alertsParams = {
  actionGroups: {
    notifyDba: {
      name: 'PRE-IMP-DBA-Team'
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
  name: 'PREIMPDBSDBW001'
  adminEntraGroup: 'AAG-Users-IPAFFS-Support-Admin'
  kustoName: 'PREIMPDBSKUS001'
  kustoSku: {
    name: 'Standard_E2ads_v5'
    tier: 'Standard'
    capacity: 2
  }
}

param redisParams = {
  name: 'PREIMPINFRDS001'
}

param searchParams = {
  name: 'preimpinfass001'
  userAssignedIdentityName: 'PREIMPINFASS001'
}

param sejParams = {
  // Keep the existing maintenance targets, SQL commands and schedules.
  manageMaintenanceDefinitions: false
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

param serviceBusParams = {
  namespaceName: 'PREIMPINFSBS003'
}

param sqlParams = {
  serverName: 'preimpdbssqa001'
}

param sqlPoolParams = {
  serverName: 'preimpdbssqa001'
  name: 'preimpedpsqa001'
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
    CreatedDate: '20260616  '
    Environment: 'PRE'
    Location: 'North Europe'
    Name: 'preimpedpsqa001'
    ServiceCode: 'IMP'
    ServiceName: 'EUX Imports'
    ServiceType: 'LOB'
    Tier: 'Database'
  }
}

