using '../../25-acr.bicep'

param environment = 'DEV'

param entraGroups = {}

param acrParams = {
  name: 'DEVIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
  principalsNeedingContributor: [
    '7b097afb-e281-4bc4-8086-c1ff4f47964b' // ADO-DefraGovUK-AZR-IMP-TST11 (ADO service connection)
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
