# Job chart filesystem policy

CronJob and KEDA ScaledJob application containers always use a read-only root,
writable disk-backed `/tmp` `emptyDir`, and pod `fsGroup: 1000`. Agent diagnostics
are fixed at `/tmp/applicationinsights.log` through a direct container environment
variable. Filesystem overrides are rejected.

Init containers and workload-identity bridges retain their separate policies.

Adopting the new chart version changes every job using it. Verify startup,
completion, output and telemetry in DEV before wider promotion.
