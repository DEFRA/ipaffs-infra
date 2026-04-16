using '../../10-resource-group.bicep'

param name = 'PRDIMPINFRG1401'
param environment = 'PRD'
param location = 'uksouth'

param principalsNeedingReader = [
  '6ab71598-0565-4705-bb77-5070ea4916cb' // ADO-DefraGovUK-AZR-PRD_IMP (ADO service connection)
]

// vim: set ts=2 sts=2 sw=2 et:
