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

### Namespace network policy

The bootstrap chart can install `ipaffs-port-baseline`, a single NetworkPolicy selecting
every pod in the release namespace. It isolates ingress and egress and permits the
configured ports below. It is disabled by default so it can be piloted in one
application namespace before wider rollout.

| Direction | Protocol / ports | Configuration dependency |
| --- | --- | --- |
| Ingress | TCP 8000, 4000 | Shared webapp pod port and OpenID's pod port |
| Ingress from the same namespace | TCP 6379 | In-cluster imports-proxy-cache Redis |
| Egress to CoreDNS in kube-system | UDP/TCP 53 | Cluster DNS |
| Egress | TCP 80, 4000, 8000 | HTTP Services and their destination pod ports |
| Egress | TCP 443 | HTTPS APIs, identity, telemetry, Azure Storage/Search/Key Vault |
| Egress | TCP 1433 | Azure SQL through Private Link in Proxy mode |
| Egress | TCP 5671 | Service Bus / Event Hubs over TLS AMQP |
| Egress | TCP 6379, 6380 | In-cluster Redis and Azure Redis TLS |
| Egress | TCP 1344 | Symantec ICAP antivirus used by upload/compression |

The defaults are a shared union of the ports in the deployment configuration. Port
5005 for remote debugging is deliberately absent. Kubernetes port-forward and
same-pod loopback traffic are not controlled by this policy.

This is a port baseline for a single-tenant cluster: application ingress accepts
any source on its listed ports, and the TCP egress list accepts any destination
on its listed ports. It does not isolate individual services or allowlist external
hostnames. DNS uses a combined namespace and pod selector; cache ingress uses a
same-namespace pod selector. Keep these restrictions in any future edits. Policies
are additive, so another policy can grant additional traffic. Traffic from a pod's
own node and host-network traffic have Kubernetes/provider-specific exceptions.
See the [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

The source settings are `helm-charts/bootstrap/values.yaml` and optional overrides
in `helm-charts/envs/<environment>/bootstrap-values.yaml`. Do not edit generated
`ipaffs-manifest/bootstrap` files: the bootstrap publishing pipeline copies these
values and updates the chart version. The lists are maintained explicitly; a new
port in application configuration requires a corresponding baseline update.

For a pilot, pass this overlay to the normal bootstrap Helm release in the chosen
namespace (an environment-file override would affect every namespace using it):

```yaml
networkPolicy:
  enabled: true
```

Before applying, confirm the cluster enforces NetworkPolicy and inspect existing
policies. Read-only checks on 9 October 2026 found Calico on DEV and TST, no existing
Kubernetes NetworkPolicies, and CoreDNS pods labelled `k8s-app: kube-dns` in
`kube-system`. Their live workload ports match the defaults. DEV SQL uses Default
policy through a private endpoint; TST SQL uses Proxy policy through a private
endpoint. Both therefore use TCP 1433. Explicit Private Link Redirect requires
TCP 1433-65535; if introduced, add a separate rule scoped to the SQL private endpoint
IP, rather than adding that range to the generic port list. See
[Microsoft's Private Link connection-policy guidance](https://learn.microsoft.com/en-us/azure/azure-sql/database/private-endpoint-overview?view=azuresql#use-redirect-connection-policy-with-private-endpoints).

Validate the pilot with DNS resolution, ingress routes and interservice calls,
SQL/migrations, Redis, Service Bus workers, antivirus upload/compression and fresh
telemetry. Confirm an unlisted TCP port and an unlisted UDP port are blocked using
known listening test endpoints in the pilot namespace; a refused connection to a
non-listening port is insufficient evidence. After those checks, enable the
environment override for rollout. To roll back, set `networkPolicy.enabled: false`
and redeploy the bootstrap release; Helm removes this policy. No policy has been
applied as part of preparing this change.
