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

Run [infra-platform](pipelines/infra-platform.yaml) manually to import platform
images, install shared Helm controllers/configuration, and reconcile ingress
Private Link without redeploying resource groups, networking, AKS or data services.
Core infrastructure and its existing Library outputs must already be available.
Run from `main` to apply; branch runs use Helm dry-run and Bicep what-if.
Pull requests targeting `main`, including drafts, automatically preview against
DEV when platform inputs change. Preview runs omit image imports and deployment.
Main runs add the environment build tag in the existing Helm job.

The full [infrastructure pipeline](pipelines/infrastructure.yaml) includes the
same platform stages at the end, retaining its original bootstrap sequence and
same-run infrastructure output handoff. Set `includePlatform: false` for a
core-only infrastructure run; the default remains full bootstrap. Existing CI and TST/PRE/PRD release
entrypoints remain unchanged. Schedule manual platform maintenance when core
infrastructure deployment is idle; automatic main deployments and ordering are
a separate change.

### Shared ingress certificate

The webapp, bootstrap origin and identity redirect handler Ingresses use the
NGINX controller's default certificate,
`defra-certs/star-azure-defra-cloud-cert`. They retain `spec.tls.hosts` and
existing redirect annotations, and omit `spec.tls.secretName`. The controller
must have this central default configured before adopting these chart changes.
AGC already references the same Secret directly. External Secrets continues to
refresh the central Secret from Key Vault every hour.

The main chart pipelines increment the webapp and bootstrap minor versions when
publishing: this change is intended to publish webapp `0.130.0` and bootstrap
`0.74.0` from the current `0.129.0` and `0.73.0` metadata. Coordinate the matching
`ipaffs-manifest` pins after publication. The identity redirect handler is
installed from this repository by the platform pipeline.

Keep namespace-local `ipaffs-tls` ExternalSecrets and values during the rollout.
After every environment, release/feature namespace and redirect handler has
migrated, verify the served certificate and HTTP redirect behaviour before
removing those mappings in a separate change. Their `creationPolicy: Owner`
means deleting an ExternalSecret can also delete its Secret. Update installed-copy
certificate reporting with that later cleanup.

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
