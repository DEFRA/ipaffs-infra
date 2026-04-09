param alertsParams object
param dbwParams object
param sejParams object

@allowed(['SND', 'TST', 'PRE', 'PRD'])
param environment string

param createdDate string = utcNow('yyyy-MM-dd')
param deploymentId string = uniqueString(utcNow())
param location string = resourceGroup().location

var databaseNames = [
  'notification-microservice'
  'approvedestablishment-microservice-blue'
  'approvedestablishment-microservice-green'
  'bip-microservice'
  'bordernotification-microservice'
  'bordernotification-refdata-microservice-blue'
  'bordernotification-refdata-microservice-green'
  'checks-microservice'
  'commoditycode-microservice-blue'
  'commoditycode-microservice-green'
  'countries-microservice-blue'
  'countries-microservice-green'
  'decision-microservice-blue'
  'decision-microservice-green'
  'economicoperator-microservice'
  'economicoperator-microservice-public-blue'
  'economicoperator-microservice-public-green'
  'enotification-event-microservice'
  'fieldconfig-microservice-blue'
  'fieldconfig-microservice-green'
  'in-service-messaging-microservice'
  'laboratories-microservice-blue'
  'laboratories-microservice-green'
  'permissions-blue'
  'permissions-green'
  'referencedataloader-microservice-blue'
  'referencedataloader-microservice-green'
  'soaprequest-microservice'
]

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

module alerts './modules/alerts.bicep' = {
  name: 'alerts-${deploymentId}'
  scope: resourceGroup()
  params: {
    alertsParams: alertsParams
    deploymentId: deploymentId
    location: location
    tags: tags
  }
}

module dbw './modules/database-watcher.bicep' = {
  name: 'dbw-${deploymentId}'
  scope: resourceGroup()
  params: {
    databaseNames: databaseNames
    deploymentId: deploymentId
    location: location
    dbwParams: dbwParams
    tags: tags
  }
}

module sej './modules/sql-elastic-jobs.bicep' = {
  name: 'sej-${deploymentId}'
  scope: resourceGroup()
  params: {
    alertsActionGroups: alerts.outputs.actionGroups
    deploymentId: deploymentId
    location: location
    sejParams: sejParams
    tags: tags
  }
}

// vim: set ts=2 sts=2 sw=2 et:
