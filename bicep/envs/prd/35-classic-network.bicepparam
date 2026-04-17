using '../../35-classic-network.bicep'

param environment = 'PRD'

param newVnetResourceId = ''

param vnetParams = {
  name: 'PRDINFNETVNT001'
}

// vim: set ts=2 sts=2 sw=2 et:
