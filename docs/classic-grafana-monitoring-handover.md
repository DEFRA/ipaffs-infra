# Classic Grafana monitoring permission handover

The classic resource-group Monitoring Reader grant for Grafana's managed identity
is managed with the dashboard tooling in
[`ipaffs-operations/grafana-dashboards`](https://github.com/DEFRA/ipaffs-operations/tree/main/grafana-dashboards).
Infrastructure retains Grafana/Prometheus/Log Analytics provisioning, service
identities, application runtime permissions and the classic Azure resources.

**Merge the infrastructure writer removal last.** First complete the one-off PRE
Library repair from the exact `codex/refresh-classic-monitoring-outputs` branch in
[infrastructure #428](https://github.com/DEFRA/ipaffs-infra/pull/428), without merging
it. Run the temporary helper's plan, review the two proposed Library values, then
run its explicit branch apply with PRE's existing approval checks. Verify both
values before deleting the temporary ADO pipeline definition and closing #428
unmerged. Operations does not depend on retaining the repair helper.

After that verified repair, merge
[Operations #14](https://github.com/DEFRA/ipaffs-operations/pull/14), run its plan
and approved apply, and verify the existing assignment IDs/scopes and Grafana's
actual classic Service Bus dead-letter queue queries in PRE and PRD. Only then
merge [infrastructure #429](https://github.com/DEFRA/ipaffs-infra/pull/429) to remove
the infrastructure permission writer. A successful plan, role readback or
dashboard upload alone does not establish that the queries work.

Source removal does not delete the deployed role assignments; neither pipeline
should remove or replace their stable assignment IDs. No Run Hooks, human-access
or machine runtime grant is changed by this cleanup.
