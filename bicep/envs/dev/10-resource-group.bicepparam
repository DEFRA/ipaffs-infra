using '../../10-resource-group.bicep'

param name = 'DEVIMPINFRG1401'
param environment = 'DEV'
param location = 'uksouth'

param pimEligibilityEndDateTime = '2036-08-07T10:00:00Z'

param principalsNeedingReader = [
  '08c384da-22b5-4974-924b-5016aa8d4aca' // ADO-DefraGovUK-AZR-IMP-SND1 (ADO service connection)
]

