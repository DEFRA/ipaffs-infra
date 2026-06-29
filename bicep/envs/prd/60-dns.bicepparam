using '../../60-dns.bicep'

param environment = 'PRD'

param loadBalancer = {
  name: 'kubernetes-internal'
  resourceGroup: 'PRDIMPINFRG1402'
  subscriptionId: '5f38dc6f-69b9-4d1b-9000-7e0b8277e515' // AZR-IMP-PRD1
}

param dnsParams = {
  zoneName: 'imp.azure.defra.cloud'
}

