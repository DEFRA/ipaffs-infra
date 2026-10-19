# Legacy image import audit

Source audit: **19 October 2026**. The five non-platform imports were traced through
104 primary repository checkouts, service Dockerfiles, shared packaging templates
and operational documentation. Relevant service default-branch commits were then
checked remotely; linked worktrees and generated/build dependencies were excluded.

| Existing import | Previous use | Outcome |
| --- | --- | --- |
| `manicminer/network-tools:latest` | No consumer found in the audited source. | Remove the unused import. |
| `manicminer/workload-identity-adal-bridge:v0.4.2` | No consumer of this mirror. Public `:0.4.1` sidecars and binary downloads are separate. | Remove the unused import; preserve public references. |
| `liquibase/liquibase:4.33.0` | 16 migration builds were redirected to ACR by the shared builder. | Remove the override and import; use each Dockerfile's public default. |
| `defradigital/java:jre-21` | 36 service builds were redirected to ACR. | Same: retain Dockerfile references and use public defaults. |
| `defradigital/node:latest-24` | 7 frontend builds were redirected to ACR. | Same: retain Dockerfile references and use public defaults. |

## Build and deployment behavior

The former shared build step passed `--build-arg IMAGE_ACR=<target ACR>`, creating
the dependency on separate base mirrors. All 59 affected Dockerfiles declare
`ARG IMAGE_ACR=docker.io` before their first `FROM`; removing the override restores
their existing public defaults. No service Dockerfiles or image tags change.

The completed application or migration image is still pushed to ACR with all its
required layers. AKS pulls that completed image from ACR. Separate Java, Node and
Liquibase image repositories are unnecessary for runtime pulls. See
[Docker's build and publish documentation](https://docs.docker.com/get-started/docker-concepts/building-images/build-tag-and-publish-an-image/).

There is no base-image parser, registry inventory, import step or Docker Hub import
credential requirement in service packaging. Existing base-image references stay
in place ahead of the planned distroless migration. Registry/subscription/tag
output overrides and DEV/TST shared final-image registry behavior remain supported.

Platform images remain mirrored by the manifest because Kubernetes pulls those
images directly. Platform apply conditions and approvals are unchanged.

## Source evidence and scope

- [Java: approvedestablishment](https://github.com/DEFRA/ipaffs-approvedestablishment-microservice/blob/f324aa1d3b9de2e8a791e0d4711644c7b1a5d629/service/Dockerfile#L1).
- [Node: frontend BCP admin](https://github.com/DEFRA/ipaffs-frontend-bcpadmin/blob/8f94f489f237cff723b5e1b46e2bb3a38fbeebc8/service/Dockerfile#L1).
- [Liquibase: notification](https://github.com/DEFRA/ipaffs-notification-microservice/blob/7faf33abf688cda19b4527fc929c5aa97d570c38/configuration/Dockerfile#L1).

Three fixed public bases are unchanged: archive-notifications' `eclipse-temurin:21-jre`,
openid-token's `defradigital/node:latest-18`, and referencedataloader's
`liquibase/liquibase:4.33.0`. These complete the 62-Dockerfile validation set.

This is a source audit, not live registry access history or Kubernetes inventory.
Unrecorded operational consumers cannot be ruled out. Existing ACR images and
Helm releases are not deleted; only the redundant import/installer pipelines are removed.
