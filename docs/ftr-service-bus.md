# FTR configuration

Feature namespaces use DEV values plus optional FTR overlays. Missing service
or bootstrap FTR files retain DEV configuration; isolation checks apply only
where an FTR file exists. `master` and `RELEASE/*` keep DEV.

Service `deployment/ftr/values.yaml`:

```yaml
serviceBus:
  enabled: true
  useSecrets: true
  connectionStringSecretKey: SERVICE_BUS_CONNECTION_STRING
```

`serviceBus.connectionStringAliases` maps additional names to the same ASO secret.
Remove all external bus imports, including Trade, and retain other required
secrets. Migration Jobs do not import the ASO bus secret.

[FTR bootstrap values](../helm-charts/envs/ftr/bootstrap-values.yaml) define the
local queues, topics and subscription. Trade equivalents need seeded messages
or stubs.

## Deployment

1. Publish the infra templates and bootstrap, backoffice, webapp and job charts.
2. Let service/bootstrap pipelines publish FTR overlays on the manifest branch.
   Generated files and chart versions remain pipeline-owned.
3. Deploy the feature branch with a unique lowercase namespace of at most
   34 characters, excluding `dev`, `tst`, `pre` and `prd`.

For ticket testing, use infra `refs/heads/IMTA-21824`; replace it with the
published immutable pin before merging.
