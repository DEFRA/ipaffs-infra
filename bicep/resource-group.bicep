targetScope = 'subscription'

param environment string
param name string
param location string

param createdDate string = utcNow('yyyy-MM-dd')

var tags = union(loadJsonContent('default-tags.json'), {
  CreatedDate: createdDate
  Environment: environment
  Location: location
})

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: name
  location: location
  tags: tags
}

output resourceGroupId string = resourceGroup.id

// vim: set ts=2 sts=2 sw=2 et:
