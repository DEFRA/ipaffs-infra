targetScope = 'resourceGroup'

param serviceBusParams object

// API version matches ARM template at https://defradev.visualstudio.com/DEFRA-Infrastructure/_git/DEFRA-EUX-IMP?path=/database/sql.json
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-01-01-preview' existing = {
  name: serviceBusParams.namespaceName
}

output serviceBusNamespaceName string = serviceBusNamespace.name
output serviceBusNamespaceResourceId string = serviceBusNamespace.id

