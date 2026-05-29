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
resource actionGroupNoncritical 'Microsoft.Insights/actionGroups@2023-01-01' = {  // Name to be confirmed, keeping same as classic for now
  name: alertsParams.actionGroups.noncritical.name
  location: 'global'
  tags: tags

  properties: {
    emailReceivers: [for user in alertsParams.actionGroups.noncritical.emailRecipients: {
        emailAddress: user.email
        name: user.name
      }
    ]
    enabled: true
    groupShortName: length(alertsParams.actionGroups.noncritical.name) > 12 ? substring(alertsParams.actionGroups.noncritical.name, 0, 12) : alertsParams.actionGroups.noncritical.name
  }
}

resource actionGroupPriority1 'Microsoft.Insights/actionGroups@2023-01-01' = { // Name to be confirmed, keeping same as classic for now
  name: alertsParams.actionGroups.priority1.name
  location: 'global'
  tags: tags

  properties: {
    emailReceivers: [for user in alertsParams.actionGroups.priority1.emailRecipients: {
        emailAddress: user.email
        name: user.name
      }
    ]
    enabled: true
    groupShortName: length(alertsParams.actionGroups.priority1.name) > 12 ? substring(alertsParams.actionGroups.priority1.name, 0, 12) : alertsParams.actionGroups.priority1.name
  }
}

resource actionGroupPriority2 'Microsoft.Insights/actionGroups@2023-01-01' = { // Name to be confirmed, keeping same as classic for now
  name: alertsParams.actionGroups.priority2.name
  location: 'global'
  tags: tags

  properties: {
    emailReceivers: [for user in alertsParams.actionGroups.priority2.emailRecipients: {
        emailAddress: user.email
        name: user.name
      }
    ]
    enabled: true
    groupShortName: length(alertsParams.actionGroups.priority2.name) > 12 ? substring(alertsParams.actionGroups.priority2.name, 0, 12) : alertsParams.actionGroups.priority2.name
  }
}

output actionGroups object = {
  notifyDba: actionGroupNotifyDba.id
  noncritical: actionGroupNoncritical.id
  priority1: actionGroupPriority1.id
  priority2: actionGroupPriority2.id
}

// vim: set ts=2 sts=2 sw=2 et:
