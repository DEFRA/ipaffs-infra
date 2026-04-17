using '../../35-classic-network.bicep'

param environment = 'PRE'

param newVnetResourceId = ''

param vnetParams = {
  name: 'PREINFNETVNT001'
}

// vim: set ts=2 sts=2 sw=2 et:
