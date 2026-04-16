using '../../10-resource-group.bicep'

param name = 'TSTIMPINFRG1401'
param environment = 'TST'
param location = 'uksouth'

param principalsNeedingReader = [
  '7b097afb-e281-4bc4-8086-c1ff4f47964b' // ADO-DefraGovUK-AZR-IMP-TST11 (ADO service connection)
]

// vim: set ts=2 sts=2 sw=2 et:
