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

### Platform configuration pipeline

Shared cluster Helm releases are deployed by
[ipaffs-manifest](https://github.com/DEFRA/ipaffs-manifest), using its platform
release contract. Manifest `master` deployments apply platform updates in DEV.
Existing numeric-tag releases apply them in TST, PRE and PRD under the existing
environment approvals. Feature branches and FTR remain plan-only.

| Responsibility | Owner after cutover |
| --- | --- |
| Install and upgrade the 13 shared platform chart releases, including AMA metrics settings | Manifest release pipeline |
| Azure resources, identities, permissions and Private Link | Infrastructure pipelines |
| Import shared container images, including application tools and images used by TST's shared DEV registry | Infrastructure pipelines; manifest also imports the images required by its platform contract |
| Develop, test, package and publish bootstrap, backoffice, webapp and job charts | Existing chart producer pipelines in this repository |
| Local platform chart source and shared values | Retained here for manifest consumers pinned to an immutable infrastructure revision |

The old [standalone Helm pipeline](pipelines/install-helm-charts.yaml) no longer
runs automatically. Manual runs print the ownership handoff. Its shared stage
also prints the handoff when called from the full infrastructure pipeline or
[infra-platform](pipelines/infra-platform.yaml); it performs no Azure login,
Helm install/upgrade, rollout restart or Kubernetes changes. Installed releases
and their resources stay in place for the manifest pipeline to adopt.

Run `infra-platform` manually from `main` to import shared images and reconcile
Azure Private Link. Core infrastructure, Library outputs and the existing
ingress load balancer must already be available. Branch and pull request runs
preview Bicep against DEV and omit image imports. The full
[infrastructure pipeline](pipelines/infrastructure.yaml) includes the same tail
when `includePlatform: true`; `false` runs only the core infrastructure stages.

**Cutover order**

1. Merge and validate the companion manifest change first. Confirm its canonical
   release pipelines apply all 13 platform releases with the existing Helm
   release names and namespaces; branch and FTR runs must remain plan-only.
2. Prevent overlapping platform deployments while checking the first manifest
   apply in each environment. Confirm chart readiness and application health.
3. Merge this infrastructure retirement only after that verification. Do not
   uninstall releases or remove cluster resources during handover.

**Fresh environment bootstrap after cutover**

1. Run the full infrastructure pipeline with `includePlatform: false` to create
   the core resources and publish their Library outputs.
2. Run the standalone image import pipeline for the environment's registry
   (TST uses the DEV registry).
3. Run the canonical manifest deployment (`master` for DEV; an approved numeric
   release tag for TST, PRE or PRD) to install the platform charts and establish
   the internal ingress load balancer.
4. Run `infra-platform` from `main` to reconcile Private Link. Its Bicep module
   requires the existing `kubernetes-internal` load balancer, so this step follows
   the first platform apply.

To return deployment ownership to infrastructure, first disable manifest
platform applies, then revert this retirement. Keep a single platform writer
throughout the handover.

### Namespace network policy

The bootstrap chart's optional `ipaffs-port-baseline` restricts ingress and egress
for all pods in the release namespace. FTR, DEV and TST enable it using environment
overrides; the shared default is disabled.

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
