targetScope = 'resourceGroup'

param alertsActionGroups object
param deploymentId string
param location string
param sejParams object
param tags object

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sejParams.sqlServerName
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: sejParams.databaseName
  location: location
  tags: tags

  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: sejParams.databaseMaxSizeGiB * 1024 * 1024 * 1024
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
    readScale: 'Disabled'
    requestedBackupStorageRedundancy: 'Local'
    maintenanceConfigurationId: '${subscription().id}/providers/Microsoft.Maintenance/publicMaintenanceConfigurations/SQL_Default'
    isLedgerOn: false
    availabilityZone: 'NoPreference'
  }

  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 20
  }
}

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: sejParams.userAssignedIdentityName
  location: location
  tags: {
    Purpose: 'SQL Elastic Jobs'
  }
}

resource jobAgent 'Microsoft.Sql/servers/jobAgents@2023-08-01' = {
  parent: sqlServer
  name: sejParams.jobAgentName
  location: location
  sku: {
    name: sejParams.jobAgentSku.name
    capacity: sejParams.jobAgentSku.capacity
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    databaseId: database.id
  }
}

resource targetGroup 'Microsoft.Sql/servers/jobAgents/targetGroups@2023-08-01' = {
  parent: jobAgent
  name: 'index-maintenance'
  properties: {
    members: [for db in sejParams.databaseNames: {
      membershipType: 'Include'
      type: 'SqlDatabase'
      serverName: sqlServer.properties.fullyQualifiedDomainName
      databaseName: db
    }]
  }
}

resource jobMaintIndexWeekly 'Microsoft.Sql/servers/jobAgents/jobs@2023-08-01' = {
  parent: jobAgent
  name: 'DBA_MAINT_INDEX_WEEKLY'
  properties: {
    description: 'DBA Maintenance of DB Indexes Weekly'
    schedule: {
      startTime: '1900-01-01T00:00:00Z'
      endTime: '9999-12-31T11:59:59Z'
      type: 'Recurring'
      enabled: true
      interval: 'P1W'
    }
  }
}

resource jobMaintStatsDaily 'Microsoft.Sql/servers/jobAgents/jobs@2023-08-01' = {
  parent: jobAgent
  name: 'DBA_MAINT_STATS_DAILY'
  properties: {
    description: 'DBA Maintenance of DB Statistics daily'
    schedule: {
      startTime: '1900-01-01T01:00:00Z'
      endTime: '9999-12-31T11:59:59Z'
      type: 'Recurring'
      enabled: true
      interval: 'P1D'
    }
  }
}

resource jobMaintIndexWeeklyStep 'Microsoft.Sql/servers/jobAgents/jobs/steps@2023-08-01' = {
  parent: jobMaintIndexWeekly
  name: 'JobStep'
  properties: {
    stepId: 1
    targetGroup: targetGroup.id
    action: {
      type: 'TSql'
      source: 'Inline'
      value: 'EXEC dbo.DBA_Sch_Weekly_Index_Maintenance  @ExclTablenames = \'dbo.notification_audit\',@FragLvl1=30,@FragLvl2=70;'
    }
    executionOptions: {
      timeoutSeconds: 43200
      retryAttempts: 10
      initialRetryIntervalSeconds: 1
      maximumRetryIntervalSeconds: 120
      retryIntervalBackoffMultiplier: json('2')
    }
  }
}

resource jobMaintStatsDailyStep 'Microsoft.Sql/servers/jobAgents/jobs/steps@2023-08-01' = {
  parent: jobMaintStatsDaily
  name: 'JobStep'
  properties: {
    stepId: 1
    targetGroup: targetGroup.id
    action: {
      type: 'TSql'
      source: 'Inline'
      value: 'EXEC dbo.DBA_Sch_Daily_Statistics_Maintenance @ExclTablenames = \'dbo.notification_audit\';'
    }
    executionOptions: {
      timeoutSeconds: 43200
      retryAttempts: 10
      initialRetryIntervalSeconds: 1
      maximumRetryIntervalSeconds: 120
      retryIntervalBackoffMultiplier: json('2')
    }
  }
}

resource alertExecutionsFailed 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: format('SqlElasticJobsFailed-{0}', sejParams.jobAgentName)
  location: 'global'
  tags: tags

  properties: {
    autoMitigate: true
    description: 'Notify DBAs when Elastic Jobs executions fail'
    enabled: true
    evaluationFrequency: 'PT1H'
    severity: 1
    targetResourceType: 'Microsoft.Sql/servers/jobAgents'
    targetResourceRegion: location
    windowSize: 'PT1H'

    actions: [
      {
        actionGroupId: alertsActionGroups.notifyDba
      }
    ]

    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          metricName: 'elastic_jobs_failed'
          metricNamespace: 'Microsoft.Sql/servers/jobAgents'
          name: 'ElasticJobsFailed'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
    }

    scopes: [jobAgent.id]
  }
}

// vim: set ts=2 sts=2 sw=2 et:
