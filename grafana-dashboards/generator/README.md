# IPAFFS dashboard generator

The three layered dashboards are generated from Python rather than edited in the
Grafana UI, because they share queries (partners, scheduled jobs, risk engine)
and variables that should not drift apart.

| Layer | Dashboard | Source | Question it answers |
|---|---|---|---|
| 1 | IPAFFS Service Health | `health.py` | Is IPAFFS OK for users, and where is it not? |
| 2 | IPAFFS Service Drill-down | `drilldown.py` | What is wrong with this service, here or downstream? |
| 2 | IPAFFS Messaging & Integrations | `messaging.py` | Is anything stuck between IPAFFS and its partners? |

`lib.py` holds the panel helpers, the shared App Insights queries, the
variable chain (Prometheus label → subscription → resource group → App Insights)
and the links bar that every IPAFFS dashboard carries.

## Changing a dashboard

1. Edit the `.py` file (or `lib.py` for anything shared).
2. Regenerate: `bash grafana-dashboards/generator/generate.sh`
3. Check every query against DEV (needs `az login`):
   `python3 grafana-dashboards/generator/check-queries.py grafana-dashboards/dashboards/IPAFFSServiceHealth.json dev`
   (add a service name for the drill-down, e.g. `dev checks-service`).
4. Optionally deploy just that dashboard to DEV with `scripts/deploy-dashboards.sh`
   and `DASHBOARD_FILES=...` to look at it.
5. Commit the `.py` change and the regenerated JSON together.

Do not edit the generated JSON or save these dashboards from the Grafana UI:
the next run of `generate.sh` overwrites it.

## Things worth knowing

- App Insights role names are `<namespace>.<service>` in feature namespaces and
  bare `<service>` in `dev`; queries also filter on `customDimensions["k8s.namespace.name"]`.
- Azure Managed Prometheus does not anchor regex matchers, so pod selectors use
  explicit `^...$`, and they only match Deployment pods (job and migration pods are left out).
- Service Bus metrics are split by queue or topic only, not by subscription.
- The classic Service Bus namespace is shared by every namespace in an environment;
  its values come from the ADO variable group via the `classic*` constants.
