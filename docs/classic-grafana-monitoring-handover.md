# Classic Grafana monitoring permission handover

The classic resource-group Monitoring Reader grant for Grafana's managed identity
is managed with the dashboard tooling in
[`ipaffs-operations/grafana-dashboards`](https://github.com/DEFRA/ipaffs-operations/tree/main/grafana-dashboards).
Infrastructure retains Grafana/Prometheus/Log Analytics provisioning, service
identities, application runtime permissions and the classic Azure resources.

Handover evidence checked on 3 November 2026:

- The one-off PRE Library repair in
  [infrastructure #428](https://github.com/DEFRA/ipaffs-infra/pull/428) is complete
  and that PR is closed unmerged. Fresh Library readback confirms the classic
  Service Bus namespace name and resource ID both reference `PREIMPINFSBS003`.
  Operations does not depend on retaining the repair helper.
- [Operations #14](https://github.com/DEFRA/ipaffs-operations/pull/14) and its
  [TST adoption fix #15](https://github.com/DEFRA/ipaffs-operations/pull/15) are
  merged. [Grafana main run 1428211](https://dev.azure.com/defragovuk/DEFRA-EUTD-IPAFFS/_build/results?buildId=1428211)
  succeeded across DEV, TST, PRE and PRD, including the classic permission tasks
  and dashboard presence checks.
- Independent Azure readback confirms PRE's assignment
  `e7629b39-a4bb-5a17-90f6-d0605a514ae0` and PRD's assignment
  `8cd98202-8b3c-5daf-a0fb-92ef3c09327c` retain Monitoring Reader for their live
  Grafana identities at the exact classic resource-group scopes.
- The service owner confirmed on 3 November 2026 that the actual PRE and PRD
  classic Service Bus dead-letter queue panels both work after the Operations
  handover. This is user-confirmed functional verification; the available CLI
  identity has no Grafana Viewer role and could not run those queries itself.

The handover gates for [infrastructure #429](https://github.com/DEFRA/ipaffs-infra/pull/429)
are complete. The infrastructure writer removal can merge after its current
branch checks pass. For future handovers, verify actual queries as well as
assignment IDs/scopes: a successful plan, role readback or dashboard upload alone
does not establish that the queries work.

The removal also updates the consolidated pipeline dependencies and promotion
preview components. Infrastructure previews retain the classic Azure resource
deployment; classic Grafana grants are reconciled by Operations.

Source removal does not delete the deployed role assignments; neither pipeline
should remove or replace their stable assignment IDs. No Run Hooks, human-access
or machine runtime grant is changed by this cleanup.
