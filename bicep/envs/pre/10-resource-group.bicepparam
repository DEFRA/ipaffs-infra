using '../../10-resource-group.bicep'

param name = 'PREIMPINFRG1401'
param environment = 'PRE'
param location = 'uksouth'

param principalsNeedingReader = [
  '35489e07-546a-4c2b-82ec-405d20fd1f0b' // ADO-DefraGovUK-AZR-PRE_IMP (ADO service connection)
]

// vim: set ts=2 sts=2 sw=2 et:
