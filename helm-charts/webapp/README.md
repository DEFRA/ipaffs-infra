# Webapp availability controls

Defaults:

- PodDisruptionBudget: `maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`.
- Soft node spreading: `kubernetes.io/hostname`, `maxSkew: 1`, `ScheduleAnyway`.
- Readiness/startup probes: disabled unless supplied by the service.

## Service overrides

Use your service's health endpoint and startup timings:

```yaml
readinessProbe:
  httpGet:
    path: /admin/health-check
    port: http
  periodSeconds: 5
startupProbe:
  httpGet:
    path: /admin/health-check
    port: http
  periodSeconds: 5
  failureThreshold: 60
```

Probes support native HTTP, TCP, exec and gRPC handlers. Existing populated
readiness values become active when adopting this chart; validate them first.

Disable the PDB with `podDisruptionBudget.enabled: false`. To override its budget,
supply either `maxUnavailable` or `minAvailable` as an integer or percentage.
PDB selectors exclude Job pods, including running and completed database migrations,
while continuing to protect existing application pods.

A custom `topologySpreadConstraints` array replaces the default; `[]` disables
explicit spreading. Each entry needs `maxSkew`, `topologyKey` and
`whenUnsatisfiable`. The chart supplies selectors matching the Deployment.
`DoNotSchedule` can leave pods pending without sufficient capacity.
Use `minDomains` only with `DoNotSchedule`.

## Rollout impact

Adopting the chart changes pod templates and triggers a rollout. PDBs control
voluntary evictions, not Deployment updates. Single replicas remain interruptible;
`minAvailable: 1` blocks their eviction. Soft spreading prefers separate nodes
without guaranteeing placement. Validate readiness, replicas and spare capacity
before promotion.

## Read-only application filesystem

Application containers always use a read-only root, writable disk-backed `/tmp`
`emptyDir`, and pod `fsGroup: 1000`. Agent diagnostics are fixed at
`/tmp/applicationinsights.log` through a direct container environment variable.
Filesystem overrides are rejected.

Database migration Jobs and their optional SQL identity bridge retain separate
filesystem policies.

Adopting the new chart version rolls every application using it. Validate one DEV
service's startup, certificate trust, health, requests and telemetry with its actual
image before wider promotion.

## SQL authentication

Generated application JDBC URLs always use `authentication=ActiveDirectoryDefault`,
and application Deployments omit the SQL identity bridge. Existing service accounts,
client IDs and workload-identity labels are retained so AKS can inject federated
credentials. Explicit connection-string overrides in `config` retain their existing
precedence and must use compatible authentication.

Application images need an MSSQL JDBC driver and Azure Identity dependencies that
support workload identity. Retain both dependencies when removing bridge tooling.
Source compatibility does not validate every promoted image or business workflow;
check the actual image, identity, SQL connectivity and connection/token renewal
before promotion.

`database.workloadIdentity.enabled` controls migration Jobs only. Its default
`false` retains managed-identity JDBC authentication and the migration bridge.
`true` selects `ActiveDirectoryDefault` and removes that bridge. Keep it disabled
for BCP uploads that still use the bridge's HTTP token client until their token
acquisition is converted and tested.

Scheduled and KEDA jobs use the separate Job chart, which retains its own native
workload-identity opt-in. Validate those workloads independently.
