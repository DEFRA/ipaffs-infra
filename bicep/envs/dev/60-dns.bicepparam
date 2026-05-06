using '../../60-dns.bicep'

param environment = 'DEV'

param loadBalancer = {
  name: 'kubernetes-internal'
  resourceGroup: 'DEVIMPINFRG1402'
  subscriptionId: 'f27f4f47-2766-40c8-8450-f585675f76a2' // AZR-IMP-DEV1
}

param dnsParams = {
  zoneName: 'imp.dev.azure.defra.cloud'
}

// vim: set ts=2 sts=2 sw=2 et:
