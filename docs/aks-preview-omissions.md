# AKS preview omissions

This change makes stable AKS settings explicit where the source previously
relied on provider-populated values. The investigation compared the existing
template, the API schema for `managedClusters@2025-10-01`, and fresh read-only
GETs for DEV, TST, PRE and PRD on 4 November 2026. The omitted fields were not
introduced by a recent removal from the template.

## Settings declared explicitly

The following values were present in every environment's live resource. They
retain the current configuration and make the deployment's intended settings
reviewable in source.

The existing pipeline tenant input was also compared privately with each live
managed-AAD tenant. All four matched; only equality booleans were retained as
validation evidence, with no tenant values or Library parameters published.

| Area | Explicit settings |
|---|---|
| Cluster type and support | `kind: Base`, `supportPlan: KubernetesOfficial`, manual node provisioning; retain `defaultNodePools: Auto`, which is inactive in manual mode |
| Authentication | Kubernetes RBAC enabled; the existing deployment tenant input passed into the managed AAD profile |
| API server | Private cluster with public FQDN enabled, matching all four live clusters; public network access remains disabled |
| Network | Azure dataplane, alongside the existing Azure Overlay and Calico configuration |
| Node disks | Managed OS disks: 128 GiB for the system pool and 512 GiB for the user pool; Ubuntu, kubelet data on the OS disk |
| Node security | FIPS disabled, local-user SSH access, existing Secure Boot and vTPM settings |
| Pool scaling and upgrades | Delete scale-down mode; maximum surge `10%`, maximum unavailable `0` |
| Metrics and storage | Cost analysis disabled; Azure Disk/File CSI drivers and snapshot controller enabled |

The disk sizes are parameters for each environment's named pools. The API's
implicit disk defaults depend on the VM size and cache characteristics, while
OS disk type cannot be changed after pool creation. Declaring the observed
Managed disks avoids relying on a different implicit disk selection after a VM
size change; it does not request a disk migration.

Declaring manual provisioning initially exposed the nested `defaultNodePools`
omission. Fresh reads showed `Auto` in all four environments. The pinned API
schema documents that this default has no effect unless provisioning mode is
`Auto`; declaring the existing value removes the warning without enabling
automatic provisioning.

The existing autoscaler tuning is also explicit:

| Setting | Value and API type |
|---|---|
| `balance-similar-node-groups` | string `false` |
| `daemonset-eviction-for-empty-nodes` | boolean `false` |
| `daemonset-eviction-for-occupied-nodes` | boolean `true` |
| `ignore-daemonsets-utilization` | boolean `false` |
| `max-node-provision-time` | string `15m` |
| `scale-down-delay-after-add` | string `10m` |
| `skip-nodes-with-local-storage` | string `false` |

## Omissions that remain intentional or need review

The template leaves the live node count under autoscaler control. It retains the
existing minimum/maximum bounds instead of copying the observed count back into
the desired resource. Node-pool power state is writable and remains outside this
pinning change. Runtime status, provisioning state and generated identity IDs
are not deployment inputs.

Other profiles require separate ownership or support evidence before declaring
them in the template or filtering them from review:

| Profile | Investigation result |
|---|---|
| Defender | Enabled in DEV and TST; absent in PRE/PRD. Enabling it requires its intended Log Analytics workspace, so the ordinary monitoring workspace must not be substituted without verification. |
| AI toolchain operator | Enabled in TST only. Its ownership and desired cross-environment state are not established by recurrence in DEV. |
| Extension manager | Enabled in all four GETs, but AKS manages its lifecycle; a generic addon-profile shape does not establish that customer configuration is supported. |
| Service-principal, kubelet-identity, Windows and service-mesh profiles | Provider-populated shapes can contain writable settings. The whole objects are not classified as harmless merely because they were omitted. |

The PRE user pool also reported a failed provisioning state with the bounded
error code `KubernetesAPICallFailed`. This is an existing operational condition,
separate from a predicted configuration difference. Raw status messages are not
included in this document; hiding a status-field omission must not imply a
healthy pool or a successful upgrade.

## References

- [Pinned AKS resource schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.containerservice/2025-10-01/managedclusters)
- [AKS cluster autoscaler configuration](https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler)
- [Private clusters and DNS](https://learn.microsoft.com/en-us/azure/aks/private-clusters)
- [AKS extension-manager lifecycle](https://blog.aks.azure.com/2025/08/04/core-extension)

What-If remains a prediction. Compiling the template proves that the declared
shape is supported, and a read-only preview checks the proposed operations;
neither constitutes an infrastructure apply or runtime acceptance.
