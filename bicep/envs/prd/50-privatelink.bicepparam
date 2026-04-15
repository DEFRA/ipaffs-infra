using '../../50-privatelink.bicep'

param environment = 'PRD'
param subnets = {}

param privateLinkParams = {
  name: 'PRDIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'PRDIMPINFRG1402'
  }
}

// vim: set ts=2 sts=2 sw=2 et:
