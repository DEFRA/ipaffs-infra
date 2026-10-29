## Next Generation Infrastructure-as-Code for IPAFFS

Please note this project is still a proof-of-concept. We are currently aiming to:

- provide a smooth working development environment based on Kubernetes
- validate our new architecture as quickly as possible by investigating unknowns and looking for unknown unknowns
- set up pipeline-driven infrastructure-as-code using Bicep
- port IPAFFS to new container infrastructure

Currently we are focused on establishing a local development environment using [K3S](https://k3s.io/), so that we can
validate our plans and assumptions, port IPAFFS to Kubernetes, and overhaul the development experience.

### Getting Started

1. Clone this repository

   ```shell
   git clone git@github.com:DEFRA/ipaffs-infra
   ```

2. Install the following prerequisite software:
    - [Lima](https://github.com/lima-vm/lima)
    - [Kubernetes command line tool](https://kubernetes.io/docs/reference/kubectl/)
    - [Docker Engine](https://docs.docker.com/engine/)
    - [Microsoft ODBC Driver for SQL Server](https://learn.microsoft.com/en-us/sql/connect/odbc/microsoft-odbc-driver-for-sql-server?view=sql-server-ver16)

   This can be achieved on macOS with the following:

   ```shell
   brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
   brew update
   HOMEBREW_ACCEPT_EULA=Y brew install microsoft/mssql-release/msodbcsql17 microsoft/mssql-release/mssql-tools
   brew install lima kubectl docker docker-buildx
   ```
   
3. Ensure you have the `docker-local` repository cloned and have checked out the `feature/support-sourcing-scripts` branch. This
   requires access to the private repository on GitLab and is a temporary requirement we expect to eliminate in the near future.

   ```shell
   mkdir -p ~/git/defra && cd ~/git/defra
   git clone git@github.com:DEFRA/ipaffs-docker-local
   ```

4. Set the `DEFRA_WORKSPACE` environment variable to the parent directory of your `docker-local` clone.

   ```shell
   export IPAFFS_KEYVAULT=<IPAFFS KEYVAULT> # Please populate correct key vault
   export DEFRA_WORKSPACE="${HOME}/git/defra"
   ```
   
5. Run the Lima/K3S setup script.

   ```shell
   cd ~/git/ipaffs-infra
   scripts/lima-k3s.sh
   ```
   
6. Follow the printed instructions to set the `KUBECONFIG` environment variable and configure a Docker context.

   ```shell
   export KUBECONFIG="${HOME}/.lima/ipaffs/copied-from-guest/kubeconfig.yaml"
   docker context create lima-ipaffs --docker "host=unix://${HOME}/.lima/ipaffs/sock/docker.sock"
   docker context use lima-ipaffs
   ```
   
7. Run the database setup script to build, push and run the SQL Server container, and populate the databases.

   ```shell
   scripts/setup-database.sh
   ```

   Note that the first time the newly built container is started, it may take a few minutes for SQL Server to begin accepting 
   connections, and the subsequent migration may fail. If this happens, you can re-run the above script and it should begin
   the migrations and data load. Once the data load has started, you can no longer safely re-run this script and you will need
   to delete all databases (or the database server) and start again. To delete the entire SQL Server instance:

   ```shell
   kubectl delete statefulset database
   kubectl delete pvc database-data
   ```
   
8. Once the database has been initialized and populated, you are ready to begin building and deploying services!

### Migrating Services to Kubernetes

Things are moving along quickly. At the time of writing, migration of ipaffs-imports-proxy is well underway and can be tested.

* Check out the `spike/dev-containers` branch of `ipaffs-imports-proxy`
* Ensure your development VM is set up with K3S as detailed above.
* Run `scripts/build.sh` to build the service, package a container and push to the local registry.
* Run `scripts/deploy.sh` to deploy the latest built container image and run with remote debugger enabled.

### Platform deployment ownership

- **Manifest:** configuration, image mirrors and deployment of shared platform Helm
  releases. See the [platform guide](https://github.com/DEFRA/ipaffs-manifest/blob/master/platform/README.md)
  for configuration and apply rules.
- **Infrastructure:** Azure resources, workload identities, runtime permissions and Private Link.
- **Operations:** human/team groups, membership, human RBAC and PIM eligibility, plus operational tooling. See [`ipaffs-operations`](https://github.com/DEFRA/ipaffs-operations).
- **Helm charts:** chart sources and publishing live in
  [`ipaffs-helm-charts`](https://github.com/DEFRA/ipaffs-helm-charts).

`infra-platform` handles Private Link only: `main` applies; branches and PRs run
what-if. `includePlatform` controls this stage in the full infrastructure pipeline.

**Cutover:** validate the manifest rollout before retiring the infrastructure
installers. Retire ADO definitions `import-acr-artifacts` (10054) and
`install-helm-charts` (10078), preserving history. Keep one platform Helm writer.

**Fresh environment:** core infrastructure (`includePlatform: false`) → manifest
platform stage → Private Link → applications.

### Operational tooling ownership

Grafana dashboards, their deployment pipeline and datasource helpers, and the
standalone routing and uptime checkers live in
[`ipaffs-operations`](https://github.com/DEFRA/ipaffs-operations).
Grafana, Prometheus and Log Analytics Azure instances remain defined here,
alongside their managed identities and runtime permissions.

The Grafana definition **11662** now reads `ipaffs-operations/main` in the
Azure DevOps `\Operations` folder.

### Human access ownership

Human/team membership, access-group creation, human Azure RBAC and PIM eligibility
move to [`pipelines/access-management.yaml`](https://github.com/DEFRA/ipaffs-operations/blob/main/pipelines/access-management.yaml)
in `ipaffs-operations`. Infrastructure no longer writes those grants or reconciles
human membership. Existing group names, object IDs and assignment names are retained.

Infrastructure still owns SQL's Entra administrator configuration, SQL Directory
Readers, kubelet/ACR and External Secrets memberships, automation grants, workload
identities and all Azure parent resources. The SQLAdmins and ACR pull groups have
machine members: operations adds its nested human groups without removing those
machine identities. The exceptional `remove-entra-group-members` pipeline remains
here for its existing targeted service-principal cleanup.

Before deployment, `ValidateAccessContract` checks the existing `sqlAdminGroupId`,
`sqlAdminGroupName`, `acrPullGroupId` and `defraCertificateReadersGroupId` Library
variables. The check is local and fails before provisioning if the contract is
missing. For a fresh environment, run operations with `groupsOnly: true`, provision
infrastructure, then run the full operations access pipeline. Bootstrap DEV before
TST and PRD before PRE because their team groups are shared.

Merge the operations PR first, repoint the existing **entra-groups** definition
**10313** to operations and its new YAML path, then validate the handover before
merging this cleanup. Reuse its existing definition/history and keep one active
human-access writer. See the
[access handover](https://github.com/DEFRA/ipaffs-operations/blob/main/access/README.md)
for the exact order. These incremental source removals do not delete deployed
role assignments, groups or Azure resources.

QA, configuration validation and classic maintenance/switch tooling remain here.

### SND App Services

`pipelines/snd-app-services.yaml` cuts the cost of the legacy App Services in
AZR-SND. It acts only on the resource groups listed in
`scripts/pipeline/snd-app-services-targets.txt`, and has one parameter, `action`:

| Action | What it does |
| --- | --- |
| `disable` | Records each plan's original SKU, instance count and the autoscale settings it turns off as `ipaffs-*` tags, turns that autoscale off, lists its running apps and slots on the plan and stops them, turns off Premium only logs (File Change Audit and Antivirus Scan), then scales it to B1 x1 (S1 x1 when it hosts slots, which Basic does not support). Safe to rerun; the original tags are never overwritten. |
| `restore` | Undoes `disable` on plans with the `ipaffs-disabled` tag: scales each back to its original SKU and instance count, turns the Premium only logs and the recorded autoscale settings back on, starts only the apps and slots listed in the plan's `ipaffs-stopped-*` tags, then removes the `ipaffs-*` tags. Plans without the tag are left alone. Safe to rerun. |
| `delete` | **Dry run only.** Logs the slots, apps and plans it would delete as `DRY RUN: az ...` lines and changes nothing. Resource groups are never deleted. |

App Service is billed per plan instance, so stopped apps on a Premium plan still
cost the full price; the saving comes from scaling the plans down.

Delete is locked to dry run in two places: the pipeline hardcodes `DRY_RUN: "true"`
for it, and the script only prints delete commands while `DELETE_ENABLED=false`.
Enabling real deletion needs a reviewed change to both. When enabled, delete also
refuses any plan without the `ipaffs-disabled` tag.

Before acting, the script checks that the subscription is `AZR-SND`, and that every
listed resource group exists, starts with `SNDIMP` and has no `ReadOnly` lock.

| Tag | On | Set by `disable` to |
| --- | --- | --- |
| `ipaffs-disabled` | plan | the date it was disabled |
| `ipaffs-original-sku`, `ipaffs-original-capacity` | plan | its size before disable |
| `ipaffs-autoscale-off` | plan | `group/name` of each autoscale setting it turned off, or `none` |
| `ipaffs-stopped-1`, `ipaffs-stopped-2`, ... | plan | the apps and slots it stopped, comma separated and split to fit the 256 character tag limit; apps already stopped are not listed |
| `ipaffs-file-audit-off` | app or slot | `setting:category` for each Premium only log category it turned off |

`restore` scales the plan up before anything else, because File Change Audit logs
need the Premium plan back, and removes the plan tags last so a failed run can be rerun.

Within each plan, the per app work runs 4 apps at a time (set `PARALLEL_JOBS` to
change it). The plan is only scaled once every app on it has finished, and if any
app fails the run stops before scaling that plan. When Azure throttles the
subscription (HTTP 429) a change is retried up to 6 times with a growing wait.

`restore` waits up to 3 minutes after scaling a plan up for Azure to show the Premium
only log categories again, and fails without removing the app's tag if one stays hidden.

File Change Audit logs (`AppServiceFileAuditLogs`) need a Premium plan, so Azure
refuses to scale a plan to B1 or S1 while any of its apps sends them. Before scaling,
`disable` turns that one log category off in each such app's diagnostic setting and
records the setting names in an `ipaffs-file-audit-off` tag on the app. `restore`
turns the category back on.

#### Run locks

A `delete` run adds a `CanNotDelete` lock named `ipaffs-pipeline-run` to each
listed resource group before listing anything, and removes it when the run ends,
including when the run fails or is cancelled. While the lock is in place, any delete
in those resource groups fails with `ScopeLocked`, whether it comes from a script
bug, another tool or a person. `disable` does not add a lock.

The lock only protects for the duration of a run; the pipeline itself adds and
removes it. Other locks on the resource groups are left alone. If a run is killed
before it can clean up, rerun the pipeline (it takes over and removes the leftover
lock) or remove it by hand:

```bash
az lock delete --subscription AZR-SND --resource-group <resource-group> --name ipaffs-pipeline-run
```

The `ADO-DefraGovUK-AZR-IMP-SND1` service connection needs lock permissions, which
Contributor does not include. An Owner creates this role once and assigns it on each
listed resource group:

```json
{
  "Name": "IPAFFS SND Lock Operator",
  "Description": "Add and remove management locks for the SND App Services pipeline",
  "Actions": [
    "Microsoft.Authorization/locks/read",
    "Microsoft.Authorization/locks/write",
    "Microsoft.Authorization/locks/delete"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/e716414f-1f8e-48f1-8f56-65f35cfdafb6"]
}
```

```bash
az role definition create --role-definition @ipaffs-snd-lock-operator.json
az role assignment create \
  --assignee <service-connection-app-id> \
  --role "IPAFFS SND Lock Operator" \
  --scope /subscriptions/e716414f-1f8e-48f1-8f56-65f35cfdafb6/resourceGroups/<resource-group>
```

Without this role a `delete` run fails at the first `az lock create`, before it
lists anything. `disable` does not need it.

Shared SND resources in `SNDIMPINFRGP009` are managed by `bicep/envs/snd/30-classic.bicepparam`;
change those through Bicep instead.

### DEV SQL elastic pool

The DEV parameters configure `DEVIMPDBSEP1401` for 4 vCores and 128 GiB of storage.
At the 22 October 2026 review, 107 databases had 55.52 GiB allocated; this capacity
accommodates that count and leaves about 72 GiB of storage headroom.
The per-database minimum remains zero and maximum remains 2 vCores. Resizing the
pool therefore preserves each database's existing compute ceiling. SQL licensing
remains `BasePrice`.

After review and deployment approval, resize the pool before enabling the paired
backoffice chart's `elasticPoolReference.armId` assignments. Moving existing
databases into the pool can briefly interrupt connections; pilot the move and
roll out in batches, checking pool CPU, IO, workers and storage before continuing.
The pool remains infrastructure-owned; the chart references it without adopting
or recreating it. Recheck database count and storage before deployment; this
capacity change alone does not move any databases into the pool.

### Shared ingress certificate

Configure `defra-certs/star-azure-defra-cloud-cert` as NGINX's default certificate.
External Secrets refreshes it hourly from Key Vault; AGC references it directly.
Webapp, origin and identity redirect handler Ingresses omit `tls[].secretName`,
retaining TLS hosts and redirect settings.

Publish the webapp/bootstrap charts before updating `ipaffs-manifest` pins.
Deploy the identity redirect handler through the platform pipeline.

Keep namespace-local `ipaffs-tls` ExternalSecrets until every namespace and the
redirect handler has migrated and passed certificate/redirect checks. Deleting
an owned ExternalSecret can also delete its Secret; clean these up separately.

The wildcard covers `*.azure.defra.cloud`, but deeper service hostnames and
short aliases need separate certificate coverage.

### Namespace network policy

The bootstrap chart's optional `ipaffs-port-baseline` restricts ingress and egress
for all pods in the release namespace. FTR, DEV, TST, PRE and PRD enable it using
environment overrides; the shared default is disabled.

| Direction | Allowed traffic |
| --- | --- |
| Application ingress | TCP 4000/8000 from any source |
| Redis ingress | TCP 6379 from pods in the same namespace |
| DNS egress | UDP/TCP 53 to CoreDNS in `kube-system` |
| Other egress | TCP 80, 443, 1344, 1433, 4000, 5671, 6379, 6380 and 8000 to any destination |

Configure ports in [bootstrap values](https://github.com/DEFRA/ipaffs-helm-charts/blob/main/helm-charts/bootstrap/values.yaml), with overrides
in the charts repository's `helm-charts/envs/<environment>/bootstrap-values.yaml`. Add new application ports
explicitly; the publishing pipeline generates `ipaffs-manifest/bootstrap` values.

Enable with `networkPolicy.enabled: true` in a pilot namespace's Helm values.
An environment override enables it for every namespace using those values.
Other NetworkPolicies can grant additional traffic.

SQL Proxy mode uses TCP 1433. [Private Link Redirect](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview?view=azuresql#use-redirect-connection-policy-with-private-endpoints)
requires a separate TCP 1433–65535 rule scoped to the SQL endpoint.

Before rollout, verify required application/dependency traffic and blocked TCP/UDP
ports against known listening endpoints. To roll back, set `networkPolicy.enabled: false`
and redeploy bootstrap; Helm removes the policy.
