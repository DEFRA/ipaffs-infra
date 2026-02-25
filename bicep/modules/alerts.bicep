targetScope = 'resourceGroup'

param alertsParams object
param deploymentId string
param location string
param tags object

// Note: Resource-specific alerts should be configured in the same module as the resource

resource actionGroupNotifyDba 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: alertsParams.actionGroups.notifyDba.name
  location: 'global'
  tags: tags

  properties: {
    azureAppPushReceivers: [for user in alertsParams.actionGroups.notifyDba.appRecipients: {
        emailAddress: user.upn
        name: user.name
      }
    ]
    emailReceivers: [for user in alertsParams.actionGroups.notifyDba.emailRecipients: {
        emailAddress: user.email
        name: user.name
      }
    ]
    enabled: true
    groupShortName: length(alertsParams.actionGroups.notifyDba.name) > 12 ? substring(alertsParams.actionGroups.notifyDba.name, 0, 12) : alertsParams.actionGroups.notifyDba.name
  }
}

output actionGroups object = {
  notifyDba: actionGroupNotifyDba.id
}

// vim: set ts=2 sts=2 sw=2 et:
