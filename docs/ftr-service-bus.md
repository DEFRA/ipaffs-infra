# FTR Service Bus isolation

Feature manifest branches use base + DEV + FTR values on the DEV cluster.
`ENVIRONMENT=dev` keeps the DEV infrastructure settings;
`CONFIGURATION_ENVIRONMENT=ftr` selects the overlay. ASO creates a bus named
`devimpinfsb1401-<namespace>` for each feature namespace.
Services and bootstrap without FTR files keep their DEV configuration.

## Service connections

Set `serviceBus.enabled: true`, `useSecrets: true` and
`connectionStringSecretKey: SERVICE_BUS_CONNECTION_STRING` in each service's
`deployment/ftr/values.yaml`. Additional connection names reference the same
ASO-generated `<service>-servicebus` Secret.

Repositories use the name `ipaffs-<slug>-microservice`:

| Slug | Manifest service | Connection aliases |
| --- | --- | --- |
| bulk-upload | bulkupload-service | SERVICE_BUS_TRADE_CONNECTION_STRING |
| dmp-integration | dmpintegration-service | DECISION_NOTIFICATION_QUEUE_CONNECTION_NAME, GMR_MATCH_RESULT_QUEUE_CONNECTION_NAME |
| enotification-event-listener | enotificationeventlistener-service | None |
| enotification-processing | enotificationprocessing-service | SERVICE_BUS_TRADE_CONNECTION_STRING |
| file-upload | upload-service | None |
| gvms | gvms-service | GVMS_QUEUE_CONNECTION_NAME |
| notification | notification-service | TRADE_CHARGE_QUEUE_CONNECTION_STRING |
| notify | notify-service | NOTIFY_QUEUE_CONNECTION_NAME |
| risk-locking | risklocking-job | None |
| soapsearch | soapsearch-service | None |

Replace all external Service Bus imports, including Trade connections, while
retaining the complete list of other required secrets. Application workloads
use required ASO secret references; database migration Jobs do not import the
ASO Service Bus secret.

The [FTR bootstrap values](../helm-charts/envs/ftr/bootstrap-values.yaml) define
seven queues, three topics and one subscription. Trade queues are local
equivalents and need seeded messages or stubs. Other DEV integrations retain
their existing configuration.

## Deployment

1. Publish the infra templates and bootstrap, backoffice, webapp and job charts.
2. Run the owning service/bootstrap pipelines with those templates to generate
   `environments/ftr/<service>.yaml` and `bootstrap/environments/ftr.yaml` on the
   feature manifest branch. Keep generated outputs out of manual PRs.
3. Run the manifest branch pipeline with a unique Namespace Override: lowercase
   letters, numbers and hyphens, at most 34 characters, excluding `dev`, `tst`,
   `pre` and `prd`. Later runs can reuse its registered namespace.

The ticket branch uses infra `refs/heads/IMTA-21824` for testing; replace it with
the publisher-generated immutable pin before merging. Chart versions remain
pipeline-owned. `master` and `RELEASE/*` continue to use DEV configuration.

FTR validation rejects shared bus overrides and remote connections only where
an FTR file is present. Publish overlays for services that need isolated buses;
other services retain their environment settings.
