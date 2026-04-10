using '../../25-acr.bicep'

param environment = 'DEV'

param acrParams = {
  name: 'DEVIMPINFAC1401'
  sku: 'Premium'
  adminEnabled: true
}

// vim: set ts=2 sts=2 sw=2 et:
