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
