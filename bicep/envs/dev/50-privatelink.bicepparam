using '../../50-privatelink.bicep'

param environment = 'DEV'
param subnets = {}

param privateLinkParams = {
  name: 'DEVIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'DEVIMPINFRG1402'
  }
}

