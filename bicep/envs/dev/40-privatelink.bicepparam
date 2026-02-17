using '../../40-privatelink.bicep'

param environment = 'DEV'
param vnetName = 'DEVIMPNETVN1401'

param subnetNames = {
  privateLink: 'DEVIMPNETSU4403'
}

param privateLinkParams = {
  name: 'DEVIMPINFPL1401'
  loadBalancer: {
    name: 'kubernetes-internal'
    resourceGroup: 'DEVIMPINFRG1402'
  }
}

// vim: set ts=2 sts=2 sw=2 et:
