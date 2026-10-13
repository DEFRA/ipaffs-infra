# PIM migration

Role assignments on Azure resources are moving from permanent to PIM eligible,
one role at a time. Each is a `*-role-assignment.bicep` module call whose
`roleAssignmentType` goes from `roleAssignmentsType` (`permanent` in every
environment) to `'eligible'`. Bicep then creates the eligible assignment but,
being incremental, leaves the permanent one in place. Two hooks in this folder
close that gap.

## Migrated roles

| Role                   | Group       | Resource type                                | Bicep                     |
|------------------------|-------------|----------------------------------------------|---------------------------|
| AKS RBAC Cluster Admin | `-AksAdmin` | `Microsoft.ContainerService/managedClusters` | `bicep/modules/aks.bicep` |

## How it works

`10-remove-permanent-role-assignments.sh` runs on every deployment, before the
Bicep stages. For each row in its `roles` table it:

1. looks up the Entra group `${ENTRA_ACCESS_GROUP_BASE_NAME}-<suffix>`
2. lists that group's assignments of the role across the subscription
3. keeps those on resources of the row's type inside the environment's
   resource group
4. deletes them, or only logs them when `DRY_RUN=true`

A row is three space-separated fields: group suffix, role definition id,
resource type. The hook needs nothing beyond what the `RunHooks` stage already
passes, so adding a role is adding a row.

Role definition ids are the GUIDs the Bicep modules use, e.g.
`b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b` from `aks.bicep`.

## Migrating a role

In one change:

1. Set `roleAssignmentType: 'eligible'` on the module call in Bicep.
2. Add the row to `10-remove-permanent-role-assignments.sh`.
3. Add the role to the table above.

### Running it from a branch

The whole migration can run from a branch, one environment at a time, so main
is not touched until the end. The infrastructure pipeline's `applyOnBranch`
parameter runs the hooks for real and lets the infrastructure Bicep deploy run
off `main`; without it the hooks dry-run and Bicep only runs what-if.

1. Run the pipeline from the branch against the environment with the
   parameter off. The hook logs the permanent assignment it would remove and
   "DRY RUN". What-if shows the `roleEligibilityScheduleRequests` resource to
   be added. Nothing changes.
2. Run it again with `applyOnBranch` ticked. The hook removes the permanent
   assignment and, a few stages later, Bicep creates the eligible one. Check
   in PIM that the group is eligible for the role on the resource, and have a
   member activate it.
3. Run it once more with the parameter off. The hook reports "nothing to do".
4. Repeat for the next environment.

Merge to main once every environment is done. The main run then finds nothing
to remove and nothing new to deploy.

The pipeline's own service principal has its own permanent assignment of the
AKS role (`pipelines/stages/infra-permissions.yaml`), so deployments are not
affected by the group losing standing access between steps.

## Rolling back a role

Bicep never deletes an eligible assignment either, so going back takes
`10-remove-eligible-role-assignments.sh.rollback`. It reads the same row
format and removes the matching eligible assignments through the ARM
`roleEligibilityScheduleRequests` API with an `AdminRemove` request, since
`az` has no PIM commands. In one change:

1. Set the module call back to `roleAssignmentType: roleAssignmentsType`.
2. Move the role's row from `10-remove-permanent-role-assignments.sh` to the
   rollback hook, leaving no other rows there.
3. Rename the rollback hook to `10-remove-eligible-role-assignments.sh`.
4. Remove the role from the table above.

Then run the pipeline from the branch against each environment the same way:
first with `applyOnBranch` off to see the eligible assignment listed, then
with it on. The rollback hook removes the eligible assignment and Bicep
recreates the permanent one in the same run. Afterwards rename the hook back
to `.rollback`; it is idempotent, so a late rename only costs an API call per
run.
