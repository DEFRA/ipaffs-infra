using '../../25-acr.bicep'

param environment = 'DEV'

param entraGroups = {}
param subnets = {}

param acrParams = {
  name: 'DEVIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
  principalsNeedingContributor: [
    'c5daee65-10cb-4d04-b721-d3da81357568' // ADO-DefraGovUK-AZR-IMP-DEV1 (ADO service connection)
    '7b097afb-e281-4bc4-8086-c1ff4f47964b' // ADO-DefraGovUK-AZR-IMP-TST11 (ADO service connection)
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
