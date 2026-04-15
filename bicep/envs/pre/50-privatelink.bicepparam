using '../../50-privatelink.bicep'

param environment = 'PRE'
param subnets = {}

param privateLinkParams = {
  name: 'PREIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'PREIMPINFRG1402'
  }
}

// vim: set ts=2 sts=2 sw=2 et:
