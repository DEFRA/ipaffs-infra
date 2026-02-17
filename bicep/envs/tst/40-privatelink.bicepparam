using '../../40-privatelink.bicep'

param environment = 'TST'
param tenantId = ''
param vnetName = 'TSTIMPNETVN1401'

param subnetNames = {
  privateLink: 'TSTIMPNETSU4403'
}

param privateLinkParams = {
  name: 'TSTIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'TSTIMPINFRG1402'
  }
}

// vim: set ts=2 sts=2 sw=2 et:
