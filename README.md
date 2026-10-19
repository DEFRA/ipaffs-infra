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

[ipaffs-manifest](https://github.com/DEFRA/ipaffs-manifest) owns configuration,
image mirrors and deployment for all 13 shared platform Helm releases. DEV current
`master` and numeric TST/PRE/PRD release tags apply in canonical namespaces under
existing approvals; FTR and branches remain plan-only.

Infrastructure retains Azure provisioning, identities, permissions, Private Link,
local chart sources and application chart publishing. `infra-platform` reconciles
Private Link only: `main` can apply; branch/PR runs retain Bicep what-if. The full
infrastructure pipeline's `includePlatform` flag controls this Private Link tail.

The legacy import and Helm installer pipelines are removed. Existing ACR images
and Helm releases remain. The five non-platform imports are no longer needed:

| Former import | Outcome |
| --- | --- |
| `manicminer/network-tools:latest` | No source consumer found; remove import |
| `manicminer/workload-identity-adal-bridge:v0.4.2` | No mirror consumer found; preserve separate public references |
| `liquibase/liquibase:4.33.0` | Migration builds use existing public Dockerfile defaults |
| `defradigital/java:jre-21` | Service builds use existing public Dockerfile defaults |
| `defradigital/node:latest-24` | Frontend builds use existing public Dockerfile defaults |

Shared builds no longer force `IMAGE_ACR`. Completed images still go to ACR with
all required layers. Dockerfile image references, build authentication,
subscription fallback and explicit output overrides are unchanged.

**Cutover**

1. Merge and validate the manifest change, including canonical applies and
   branch/FTR plans. Prevent overlapping platform deployments.
2. Merge the infrastructure retirement after chart and application validation.
3. Retire ADO definitions `import-acr-artifacts` (10054) and `install-helm-charts`
   (10078) after merge; preserve their build history.

For a fresh environment: core infrastructure (`includePlatform: false`) → manifest
platform stage only → infrastructure Private Link → application deployment.
Existing release approvals apply. Private Link needs the ingress controller's
internal load balancer. Normal manifest releases reuse infrastructure outputs
without rerunning provisioning. Disable manifest applies before any return to
infrastructure chart ownership.

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

Configure ports in [bootstrap values](helm-charts/bootstrap/values.yaml), with overrides
in `helm-charts/envs/<environment>/bootstrap-values.yaml`. Add new application ports
explicitly; the publishing pipeline generates `ipaffs-manifest/bootstrap` values.

Enable with `networkPolicy.enabled: true` in a pilot namespace's Helm values.
An environment override enables it for every namespace using those values.
Other NetworkPolicies can grant additional traffic.

SQL Proxy mode uses TCP 1433. [Private Link Redirect](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview?view=azuresql#use-redirect-connection-policy-with-private-endpoints)
requires a separate TCP 1433–65535 rule scoped to the SQL endpoint.

Before rollout, verify required application/dependency traffic and blocked TCP/UDP
ports against known listening endpoints. To roll back, set `networkPolicy.enabled: false`
and redeploy bootstrap; Helm removes the policy.
