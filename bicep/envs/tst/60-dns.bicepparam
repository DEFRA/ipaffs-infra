using '../../60-dns.bicep'

param environment = 'TST'

param loadBalancer = {
  name: 'kubernetes-internal'
  resourceGroup: 'TSTIMPINFRG1402'
  subscriptionId: '0022ef8e-d44e-49c5-8cfd-5e8e9c6e913e' // AZR-IMP-TST1
}

param dnsParams = {
  zoneName: 'imp.tst.azure.defra.cloud'
}

