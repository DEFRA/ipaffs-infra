using '../../25-acr.bicep'

param environment = 'PRD'

param entraGroups = {}

param acrParams = {
  name: 'PRDIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
  principalsNeedingContributor: [
    '53a47ce7-dbaa-494e-8a87-54b13248ccd8' // ADO-DefraGovUK-AZR-IMP-PRE1 (ADO service connection)
    'a3e0f04c-827a-4abc-89c2-249e476b3cf2' // ADO-DefraGovUK-AZR-IMP-PRD1 (ADO service connection)
  ]
}

// vim: set ts=2 sts=2 sw=2 et:
