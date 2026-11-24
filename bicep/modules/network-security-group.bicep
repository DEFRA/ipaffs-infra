targetScope = 'resourceGroup'

param name string
param location string
param tags object
param securityRules array
param parentExists bool

// Bootstrap only: updating the parent NSG would replace CCoE-owned rules too.
// Existing NSG tags stay unchanged; this deployment owns only the named children.
@onlyIfNotExists()
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2025-05-01' = if (!parentExists) {
  name: name
  location: location
  tags: tags
  properties: {}
}

// Removing an IPAFFS rule from this list requires an explicit child-rule cleanup.
// The Network provider serialises writes to a group; avoid competing child PUTs.
@batchSize(1)
resource managedRules 'Microsoft.Network/networkSecurityGroups/securityRules@2025-05-01' = [for rule in securityRules: {
  parent: networkSecurityGroup
  name: rule.name
  properties: rule.properties
}]
