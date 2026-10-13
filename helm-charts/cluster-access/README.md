# Cluster access controls

The shared infrastructure and Helm installation pipelines install this chart once
per cluster, in the `kube-system` Helm release namespace. The two flags are defined
independently in `pipelines/vars/<environment>.yaml`:

| Environment | `kubectlExecEnabled` | `kubectlPortForwardEnabled` |
| --- | --- | --- |
| DEV, including FTR namespaces | `true` | `true` |
| TST | `false` | `false` |
| PRE | `false` | `false` |
| PRD | `false` | `false` |

A disabled capability installs a Kubernetes `ValidatingAdmissionPolicy` and
binding that reject `CONNECT` requests to `pods/exec` or `pods/portforward` in
every namespace. Rejections use `Forbidden` and add an admission audit annotation.
The audit annotation is recorded when the cluster's audit logging is enabled.
The policies require Kubernetes 1.30 or later and apply after authorization,
including for identities with Writer or Cluster Admin roles. There are no
identity or namespace exemptions. Pod reads, logs, deployments and other
subresources are outside these rules.

Set either flag to `true` and run the installation pipeline to remove that
capability's restriction. The pipeline always upgrades the Helm release, even
when both capabilities are enabled. Non-main branches retain the existing Helm
dry-run behavior. FTR runs on the DEV cluster, so it inherits DEV's settings.

Administrators able to change admission policies can remove these controls.
These flags govern new Kubernetes API connections; they do not terminate existing
sessions, remove RBAC grants, or control direct node/kubelet access. Restrict
policy administration separately from routine operational access.

## Validation and deployment

Run the local chart and pipeline checks:

```sh
helm lint helm-charts/cluster-access
helm unittest --strict helm-charts/cluster-access
bash scripts/pipeline/test-cluster-access.sh
```

Deploy through `pipelines/install-helm-charts.yaml` or
`pipelines/infrastructure.yaml` on `main`, selecting the target environment.
Read back each installed policy's `status.observedGeneration` and
`status.typeChecking.expressionWarnings`, then test real `kubectl exec` and
`kubectl port-forward` connections using the intended operational identities.
`kubectl auth can-i` checks authorization and may return `yes` even when the
admission policy rejects the connection.

DEV and FTR must retain both capabilities. TST, PRE and PRD must reject both
with the policy's custom error message while normal reads, logs and deployments
continue to work. Test toggling each flag independently and returning it to its
configured value. Helm must remove the corresponding policy and binding when
that capability is re-enabled.
