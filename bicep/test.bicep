targetScope = 'subscription'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'POCIMPINFRGP001'
  location: 'North Europe'
}

# vim: set ft=bicep ts=2 sts=2 sw=2 et:
