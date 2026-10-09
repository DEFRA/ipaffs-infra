# FTR Service Bus isolation

FTR is a feature configuration profile deployed from a feature branch of
`ipaffs-manifest` into its own Kubernetes namespace on the DEV cluster.
It overlays the shared service values and DEV values. Azure `environment` remains
`dev`, so ASO uses the existing DEV Azure resource group and naming conventions.
The Service Bus namespace is `devimpinfsb1401-<Kubernetes namespace>`.

The manifest branch pipeline selects `ftr` for feature branches; `master` and
`RELEASE/*` retain the DEV profile. Supply the existing Namespace Override when
starting a branch deployment. Subsequent runs can reuse its branch annotation.
Feature namespaces must be distinct from `dev`, `tst`, `pre` and `prd`, and at most
34 characters so the Azure bus name stays within its 50-character limit.
`CONFIGURATION_ENVIRONMENT=ftr` is passed separately from `ENVIRONMENT=dev`.

## Service inventory

Audited against refreshed remote default branches on 9 October 2026. All ten
services are present in the DEV manifest. Their `deployment/ftr/values.yaml` files
set `serviceBus.enabled: true`, `useSecrets: true` and the exported key
`SERVICE_BUS_CONNECTION_STRING`. Named connections are aliases of that same
service's ASO-generated Kubernetes Secret, including the Trade connections.

| Repository | Manifest service | Additional connection aliases |
| --- | --- | --- |
| ipaffs-bulk-upload-microservice | bulkupload-service | SERVICE_BUS_TRADE_CONNECTION_STRING |
| ipaffs-dmp-integration-microservice | dmpintegration-service | DECISION_NOTIFICATION_QUEUE_CONNECTION_NAME, GMR_MATCH_RESULT_QUEUE_CONNECTION_NAME |
| ipaffs-enotification-event-listener-microservice | enotificationeventlistener-service | None |
| ipaffs-enotification-processing-microservice | enotificationprocessing-service | SERVICE_BUS_TRADE_CONNECTION_STRING |
| ipaffs-file-upload-microservice | upload-service | None |
| ipaffs-gvms-microservice | gvms-service | GVMS_QUEUE_CONNECTION_NAME |
| ipaffs-notification-microservice | notification-service | TRADE_CHARGE_QUEUE_CONNECTION_STRING |
| ipaffs-notify-microservice | notify-service | NOTIFY_QUEUE_CONNECTION_NAME |
| ipaffs-risk-locking-microservice | risklocking-job | None |
| ipaffs-soapsearch-microservice | soapsearch-service | None |

The effective FTR ExternalSecret lists remove all 15 DEV Service Bus connection
imports and retain every other import. Lists replace the inherited DEV/base
lists; adding one new secret requires keeping the complete retained list in FTR.
Application properties and KEDA triggers use the existing entity names unchanged.
Deployments, migration Jobs, ScaledJobs and CronJobs use explicit required
`secretKeyRef` entries, preventing an imported secret from overriding an alias.

## Feature topology

`helm-charts/envs/ftr/bootstrap-values.yaml` provisions seven queues:

- `notify_queue`
- `enotification_event_queue`
- `defra.trade.imports.notifications.create`
- `defra.trade.eds.decisionoutput.snd.1002`
- `defra.trade.dmp.gto.ipaffsoutput.snd.1002`
- `defra.trade.dmp.ipaffsoutput.snd.1002`
- `defra.trade.charge.cuc.chargeableevents`

It also provisions `notification-topic`, `alvs_topic` and `messaging_topic`, with
`commodity_file_upload` subscribed to `messaging_topic`. ASO-safe Kubernetes
identities preserve underscore-containing Azure entity names using `spec.azureName`.
Bulk upload and processing both publish status messages to
`enotification_event_queue`; no separate processing-status queue is needed.

Trade queues are local equivalents. Remote Trade producers and consumers are not
created by this configuration. Feature tests must seed messages or supply stubs.
Other outbound Trade HTTP integrations, storage and other DEV settings continue
to use their existing configuration. The isolation provided here covers Service
Bus connections and entities.

`ipaffs-traces-data-processor-microservice` and the `ipaffs-service-bus-queue-reader`
utility have Service Bus code but no current DEV manifest deployment, so they
have no FTR deployment values. `ipaffs-enotification-event-microservice` declares
a queue-name property without a Service Bus client or imported connection.

## Publication and deployment

1. Land the ASO-safe bootstrap entity naming change from infra PR #383. This
   feature work is based on that branch; the normal DEV topology stays with it.
2. Publish the updated bootstrap, backoffice, webapp and job charts through their
   existing pipelines. Chart versions and manifest chart pins are pipeline-owned.
3. For ticket branch testing, the manifest loads infra templates from
   `refs/heads/IMTA-21824`, which accepts the configuration-profile parameter.
   Publish the infra changes and replace that temporary branch ref with the
   immutable pin produced by the existing infra-ref updater before merging.
4. Publish the service source FTR files and run their pipelines. The service
   generator and both Java/Node staging loops now include `ftr`. Bootstrap's
   generator also copies the optional FTR overlay. Their manifest outputs remain
   pipeline-owned and are excluded from manually authored source PRs.
5. Include the manifest pipeline/template changes in the feature manifest branch.
   Let the owning pipelines publish its FTR overlays, then run its deployment
   with the namespace override.

Helmfile and identity-value generation reject FTR in other cloud environments,
canonical namespaces, oversized namespaces, shared Service Bus overrides, remote
Service Bus ExternalSecret imports and literal remote bus connections in config.
A missing service overlay therefore fails when it would inherit a DEV bus import.

## Local validation

All 117 backoffice/bootstrap/webapp/job chart tests passed, as did chart lint.
Eight FTR Helmfile/generator regression tests and seven existing telemetry tests
passed with the deployment toolchain's Helm 3. Service and bootstrap copy tests,
changed YAML/JSON parsing, Bash syntax and whitespace checks also passed.

Full chart rendering of all ten services in two feature namespaces confirmed
different bus namespace owners, required secret references for every connection
alias, zero remote Service Bus imports, retained non-bus imports, and complete
application/KEDA topology coverage. This used source charts and generated FTR
manifest values; publication dependencies above still apply.

No Azure resources were changed during preparation. Local rendering uses mock
identity IDs; ASO readiness, generated secret contents and application journeys
must be checked after an actual feature deployment.
