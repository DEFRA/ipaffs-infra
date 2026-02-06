using '../../_null.bicep'

param environment = 'DEV'
param location = 'uksouth'
param tenantId = ''

param builtInGroups = {
  contributors: '04b12060-3b12-49aa-a92a-d62873d8d29e' // AG-Azure-IMP_DEV1-Contributors
  owners: 'dbaf1ee8-c128-4f27-b159-791866210c2e' // AG-Azure-IMP_DEV1-Owners
}

// vim: set ts=2 sts=2 sw=2 et:
