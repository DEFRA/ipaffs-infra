using '../../60-dns.bicep'

param environment = 'PRE'

param loadBalancer = {
  name: 'kubernetes-internal'
  resourceGroup: 'PREIMPINFRG1402'
  subscriptionId: '3978eb4f-add1-415d-839b-db398e65a7d9' // AZR-IMP-PRE1
}

param dnsParams = {
  zoneName: 'imp.pre.azure.defra.cloud'
}

// vim: set ts=2 sts=2 sw=2 et:
