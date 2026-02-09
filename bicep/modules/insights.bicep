targetScope = 'resourceGroup'

param insightsParams object
param deploymentId string
param logAnalyticsId string
param location string
param tags object

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsParams.name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsId
  }
  tags: tags
}

output insightsId string = insights.id

// vim: set ts=2 sts=2 sw=2 et:
