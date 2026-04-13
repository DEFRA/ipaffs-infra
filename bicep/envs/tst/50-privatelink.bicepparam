using '../../50-privatelink.bicep'

param environment = 'TST'
param subnets = {}
param vnetName = 'TSTIMPNETVN1401'

param privateLinkParams = {
  name: 'TSTIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'TSTIMPINFRG1402'
  }
}

// vim: set ts=2 sts=2 sw=2 et:
