using '../../10-resource-group.bicep'

param name = 'DEVIMPINFRG1401'
param environment = 'DEV'
param location = 'uksouth'

param principalsNeedingReader = [
  '08c384da-22b5-4974-924b-5016aa8d4aca' // ADO-DefraGovUK-AZR-IMP-SND1 (ADO service connection)
]

// vim: set ts=2 sts=2 sw=2 et:
