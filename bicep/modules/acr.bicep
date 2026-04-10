targetScope = 'resourceGroup'

param acrParams object
param deploymentId string
param location string
param tags object

resource acr 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: acrParams.name
  location: location
  tags: tags

  sku: {
    name: acrParams.sku
  }

  properties: {
    adminUserEnabled: acrParams.adminEnabled
  }
}

// vim: set ts=2 sts=2 sw=2 et:
