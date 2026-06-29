using '../../50-privatelink.bicep'

param environment = 'TST'
param subnets = {}

param privateLinkParams = {
  name: 'TSTIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'TSTIMPINFRG1402'
  }
}

