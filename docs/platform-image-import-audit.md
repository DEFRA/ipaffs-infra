# Legacy image import audit

Source audit: **19 October 2026**. The five non-platform imports were traced through
104 primary repository checkouts, service Dockerfiles, shared packaging templates
and operational documentation. Linked worktrees and generated/build dependencies
were excluded. Relevant service default-branch commits were then checked remotely.

| Existing import | Observed consumer | Decision / owner |
| --- | --- | --- |
| `manicminer/network-tools:latest` | No consumer found in the audited source. | Remove the unused import; no replacement pipeline. |
| `manicminer/workload-identity-adal-bridge:v0.4.2` | No consumer of this ACR mirror. Charts use public `:0.4.1`; some migration images download the `v0.4.1` binary. | Remove the unused import. Preserve those existing public references and versions. |
| `liquibase/liquibase:4.33.0` | **16** migration-image builds resolve their base through `IMAGE_ACR`. | Ensure the mirror from the shared container-image build step before a consuming build. |
| `defradigital/java:jre-21` | **36** service-image builds resolve their base through `IMAGE_ACR`. | Ensure the mirror from the shared container-image build step before a consuming build. |
| `defradigital/node:latest-24` | **7** frontend-image builds resolve their base through `IMAGE_ACR`. | Ensure the mirror from the shared container-image build step before a consuming build. |

## Why these three mirrors remain necessary

Literal ACR URL searches miss this dependency: the Dockerfiles default
`IMAGE_ACR=docker.io`, but `pipelines/steps/build-container-image.yaml` overrides it
to the selected ACR login server. `PackageMigrationsImage` uses that same build
step for `configuration/Dockerfile`. These are build-time dependencies owned by
service packaging, separate from the manifest's platform-image imports.

All 43 Java/Node consumers currently select shared templates from
`ipaffs-infra` `refs/heads/main`. The 16 Liquibase consumers do likewise.
The build step inspects the Dockerfile actually selected, ensures only its
required mirrors, and retains the existing image versions. Existing mirror tags
are not overwritten; refresh floating upstream tags explicitly or select a new
tag in the Dockerfile.

Representative immutable source evidence:

- [Java builder: approvedestablishment](https://github.com/DEFRA/ipaffs-approvedestablishment-microservice/blob/f324aa1d3b9de2e8a791e0d4711644c7b1a5d629/service/Dockerfile#L4).
- [Node builder: frontend BCP admin](https://github.com/DEFRA/ipaffs-frontend-bcpadmin/blob/8f94f489f237cff723b5e1b46e2bb3a38fbeebc8/service/Dockerfile#L1).
- [Liquibase builder: notification](https://github.com/DEFRA/ipaffs-notification-microservice/blob/7faf33abf688cda19b4527fc929c5aa97d570c38/configuration/Dockerfile#L1), enabled by its [migration packaging configuration](https://github.com/DEFRA/ipaffs-notification-microservice/blob/7faf33abf688cda19b4527fc929c5aa97d570c38/pipeline.yaml#L51).

## Liquibase mirror consumers

Current default branches use `liquibase/liquibase:4.33.0` through `IMAGE_ACR` in:

- `ipaffs-approvedestablishment-microservice`
- `ipaffs-bip-microservice`
- `ipaffs-bordernotification-microservice`
- `ipaffs-bordernotification-refdata-microservice`
- `ipaffs-checks-microservice`
- `ipaffs-commoditycode-microservice`
- `ipaffs-countries-microservice`
- `ipaffs-decision-microservice`
- `ipaffs-economicoperator-microservice`
- `ipaffs-enotification-event-microservice`
- `ipaffs-fieldconfig-microservice`
- `ipaffs-in-service-messaging-microservice`
- `ipaffs-laboratories-microservice`
- `ipaffs-notification-microservice`
- `ipaffs-permissions`
- `ipaffs-soaprequest-microservice`

The [economicoperator default-branch Dockerfile](https://github.com/DEFRA/ipaffs-economicoperator-microservice/blob/2bab0352d455fdcb96ef3787156e0325aff4c0ec/configuration/Dockerfile#L1)
still uses the mirror; a local branch's direct Liquibase 5.0.4 pull is not the
current default-branch configuration.

## Public-image exceptions and audit limits

These direct public references do not consume the removed mirrors:

- [Referencedataloader migration image](https://github.com/DEFRA/ipaffs-referencedataloader-microservice/blob/a10c677dc17c76e81f1a400eda48bc48898f42a0/configuration/Dockerfile#L1) uses `FROM liquibase/liquibase:4.33.0` without `IMAGE_ACR`.
- [Archive notifications service image](https://github.com/DEFRA/ipaffs-archive-notifications-microservice/blob/a964516df8aeb947012e533eb7539fbb900f0a3c/service/Dockerfile#L1) uses `FROM eclipse-temurin:21-jre`.

The audit establishes source configuration, not live ACR access history or
Kubernetes image usage. Unrecorded ad-hoc operational consumers cannot be ruled
out. Removing import pipelines does not delete existing ACR images. Manifest
apply conditions and environment approvals remain unchanged.
