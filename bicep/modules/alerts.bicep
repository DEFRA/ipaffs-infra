targetScope = 'resourceGroup'

param alertsParams object
param deploymentId string
param location string
param tags object

// Note: Resource-specific alerts should be configured in the same module as the resource

resource actionGroupNotifyIpaffs 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: alertsParams.actionGroups.notifyIpaffs.name
  location: 'global'
  tags: tags

  properties: {
    emailReceivers: [for user in alertsParams.actionGroups.notifyIpaffs.emailRecipients: {
        emailAddress: user.email
        name: user.name
      }
    ]
    enabled: true
    groupShortName: length(alertsParams.actionGroups.notifyIpaffs.name) > 12 ? substring(alertsParams.actionGroups.notifyIpaffs.name, 0, 12) : alertsParams.actionGroups.notifyIpaffs.name
  }
}

output actionGroups object = {
  notifyIpaffs: actionGroupNotifyIpaffs.id
}

