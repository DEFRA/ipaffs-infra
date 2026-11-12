# Infrastructure promotion previews

`pipelines/infrastructure-preview.yaml` previews the candidate infrastructure commit
against live DEV, TST, PRE and PRD. DEV supplies a post-apply comparison baseline.
The pipeline does not apply deployments, run hooks, update
Library groups or change access-group memberships. Tagged deployments run
separately through `release-pipeline.yaml`; the preview is advisory and is not
an approval gate or dependency of that release pipeline.

## Release workflow

1. Merge infrastructure changes to `main`; the `infrastructure` pipeline applies DEV.
2. When that run succeeds with the `Environment-DEV` build tag, the preview pipeline
   runs automatically using the same Git commit. DEV, TST, PRE and PRD run in
   parallel, followed by the combined summary, which waits for all four reports.
   No option is needed to include DEV. Available agents and parallel-job capacity
   determine how many environment jobs can execute at once.
3. Review the **Infrastructure promotion preview** summary in Azure DevOps and the
   downloadable `infrastructure-preview` artifact before choosing a release tag.
   Record the full candidate commit; a tag created later must point at that commit
   for this report to describe its inputs.
4. Creating a release tag such as `1` or `1.1` also starts a fresh
   preview of that tagged commit across the same four environments in parallel.
   The release pipeline starts independently from the tag and does not wait for
   this preview. The successful DEV completion preview remains available before
   choosing a tag.

Only tags whose commits contain this tag-trigger configuration can start the
preview automatically. Existing tags and tags of older pipeline code do not gain
the new trigger when this change is merged to `main`.

A failed or unresolved preview is incomplete, rather than evidence of no changes.
When every environment's what-if executes successfully but ARM cannot assess all
resources or fields, the pipeline finishes **succeeded with issues** and keeps the
assessment marked **INCOMPLETE**. Execution errors, missing or invalid reports, and
reports from different commits still fail the pipeline.
Other environments continue after an environment fails, and the overview runs
with whatever reports are available after all four finish. No deployment environments are referenced by
these ordinary agent jobs; service-connection checks and authorisation still apply.

For a manual preview, select `main` in the Azure DevOps **Run pipeline** dialog
and verify the queued commit in the report. The default source resource selects
a successful main infrastructure run tagged `Environment-DEV`. Every run verifies
that the checkout matches its queued commit. DEV completion runs also require
the exact completed main DEV commit. Tag CI runs validate the full tag ref before
authenticated preview work. The tag name must match `^[1-9][0-9]*(\.(0|[1-9][0-9]*))?$`.
The release number is positive and the optional patch can be zero. Both use
ASCII digits without leading zeroes. The pipeline validates the identifier as
text, so `1.1` and `1.10` are separate tags. Manual diagnostic previews can
select any branch or tag, including older three-component tags.
The selected DEV source run remains
baseline evidence and does not replace the tagged candidate commit.
The report records the commit, source ref, run ID and generation time. Changes to
the live environment after that time can invalidate the prediction.

### Automatic DEV baseline

Every run plans DEV with its existing Modern and Classic/SND service connections.
The pipeline obtains the applied commit and run ID from the `infrastructure`
resource; users do not supply an applied SHA. Using its job token, the DEV job
reads that build's metadata and verifies the expected infrastructure definition,
successful completion, main branch, `Environment-DEV` tag and matching commit.
It also checks the source timeline: all six deployment stages and their actual
Bicep deployment tasks must have succeeded. A successful run that omitted Private
Link or skipped a deployment does not establish a full post-apply baseline.
The job compares that commit's `bicep`, `pipelines/vars`, infrastructure pipeline,
six deployment stage mappings and shared parameter renderer with the preview
checkout. Report-only code may differ while these deployment inputs remain unchanged.

The DEV artifact contains `baseline-evidence.json` with the verified source run,
commits, compared paths and whether the baseline is usable. If source verification
fails or the deployment input trees differ, DEV and all release-target plans still
run; the comparison explains why potential-noise assessment is unavailable.
Missing reports and plan execution errors continue to fail the pipeline.

The comparison also requires all six DEV components to complete successfully,
with no ARM diagnostics, proposed resource creates/deletes or potential actions.
It checks that reports and evidence belong to the same preview run and candidate.
A baseline with unapplied resource actions cannot establish recurring noise.
Each environment's preview must start after the verified DEV apply completed;
the release-target previews do not need to wait for the DEV preview itself.
Classification happens in the combined summary after every environment finishes.

Repetition after an apply is evidence, not proof of a false positive. Current
Library values, live identities and nondeterministic metadata are not a replay of
the apply's historical runtime inputs. Controllers or policies can also recreate
settings after an apply. The report therefore labels only a narrow set of known
provider-generated/default property differences as **potential noise** when they
also recur in the verified DEV baseline. Visible scalar values must match; where
values are withheld, the report identifies the weaker pattern-only evidence.
Original observations remain available for review.

Creates/deletes, explicit configuration changes, security/policy settings and
unresolved values are kept for review. Classic differences stay visible because
DEV's Classic scope is SND and does not establish equivalence with the release
environments' Classic scopes.

## Reading the reports

Start with the **Infrastructure promotion preview** summary attached to the Azure
DevOps run. This is the single combined report; individual environment reports
are downloadable artifacts rather than additional copies in the summary tab.
The report compares all four environments and separates the information needed
for a release decision:

- Changes that need review, including creates, resource deletions and explicit
  configuration changes. A property removal is distinguished from deleting the
  resource. An ARM update alone does not prove that a live setting will reset.
- Potential noise supported by the verified post-apply DEV comparison. This is
  advisory, with the original change retained; it is not a declaration that the
  target is unchanged. Mixed updates keep their reviewable fields visible.
- Security and policy ownership differences, which need review even when they
  recur in DEV. Repeated NSG or access changes may reflect another controller
  reapplying its intended configuration.
- Coverage gaps for unsupported resources, unresolved deployment-time values
  and potential actions. The headline counts updates separately when each
  effective field has an unresolved expression as its entire proposed value.
  Mixed updates stay visible in the review list and the coverage gaps,
  including when Azure reports a whole object with an unresolved field.

The **Unresolved predictions** table retains a known resource type even when
Azure's sanitized result has no usable resource identity. Repeated unidentified
`Unsupported` observations are grouped by environment, component and resource
type with an entry count. For example, nine unidentified infrastructure role
assignments appear as one row with nine entries; a Classic role assignment has
its own row. Counts describe observations, not confirmed changes or distinct
resources. Named resources stay individual, and the JSON artifacts retain every
observation. Unrecognized types are labelled unresolved; names and resource IDs
are never inferred from template expressions or other private payloads.

Ignored/unchanged inventory and metadata-only updates are counted as background.
Updates containing only CreatedDate and fields Azure explicitly marks `NoEffect`
also belong here. Inventory can repeat across component previews and is not listed
as individual actions. Ignore can mean outside-template inventory or an expansion
limit, so coverage may still be marked incomplete.

Managed-identity updates also count as background when the only differences are
omitted Azure-generated `clientId`, `principalId` or `tenantId` fields, or an omitted
`isolationScope` whose current value is exactly `None`. Microsoft documents that
[an omitted isolation scope and `None` both allow use across regions](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identities-isolation-scope).
The reporter examines individual fields before redaction; it does not treat an
opaque identity `properties` object as harmless. Removing `Regional`, changing
between `None` and `Regional`, expressions, unknown properties and incomplete
evidence stay visible. This rule applies to both Modern and Classic identities
without relying on a DEV comparison. Resource creates, resource deletes and
potential actions remain reviewable. JSON retains ARM's original resource action,
expanded property operations and fixed metadata reasons; generated IDs stay redacted.

Application Insights' `Flow_Type: Bluefield` and `Request_Source: rest` describe
[how the component was created](https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/2020-02-02/components).
Only exact additions of these values to an existing component are background
metadata, with matching full before/after snapshots and unambiguous ARM deltas.
Explicit nulls in the current snapshot, changed origins, unknown values and
incomplete evidence remain reviewable. The canonical nonsecret markers, original
ARM operations and fixed reasons remain in `plan.json` and `change-details.md`.
Mixed workspace, authentication, network and other changes still require review.
This classification does not depend on the DEV comparison or change its proof.

For AKS, only evidenced omissions of schema-read-only, healthy output fields are
background metadata. Node-pool fields require a uniquely matched pool name in
the current and desired snapshots; an array index alone is not enough. Node
counts, pool power state, identity profiles and writable security settings stay
reviewable. Opaque, contradictory or unhealthy status is not classified as
harmless. Original ARM operations and fixed reasons remain in the audit files.
An **Existing AKS health warnings** section retains bounded cluster/pool failure
signals separately from requested configuration changes, without publishing raw
Azure diagnostic messages. See [the AKS investigation](aks-preview-omissions.md)
for the declared settings and omissions still requiring review.

Named resources and nested parent names make the review list readable without
requiring a resource ID lookup. Each environment's artifact also has a standalone
`summary.md` if a detailed environment-specific review is useful.

Download `change-details.md` from each environment's artifact for property-level
evidence, full resource identifiers and input fingerprints. `plan.json` retains
every sanitised entry, including the ignored inventory omitted from Markdown.
The combined artifact's `dev-comparison.json` records the classifications and
supporting reason codes without publishing additional source values.
Sensitive values are redacted in every file; a pair of withheld values is
described as a change with values withheld in the summary. Raw what-if responses
and generated runtime parameters are not published. Private state is removed
after reporting.

The comparison is the complete candidate configuration against the live target,
so it includes accumulated unreleased changes and drift, not only the last commit.
The Modern and Classic scopes use their existing environment service connections,
subscriptions and resource groups. TST has no separate ACR deployment. Runtime
parameter generation is shared with the deployment stages to reduce divergence.

What-if is a prediction, not a saved executable deployment plan. Unknown expressions,
provider limitations, resources that do not exist yet and inputs that currently
come from Library deployment outputs can make changes noisy or unresolved. The
report must be reviewed with these limitations visible. No write operation is
used to discover future outputs.

The report also identifies work outside Bicep: hooks, access-contract validation,
Entra group membership changes, optional hub peering and private-endpoint DNS
scripts. These are unassessed by Azure what-if; the preview does not imply that
those actions are safe or unchanged. Refresh the preview before a later promotion
if the environment or its configuration has changed.

## Preserving configuration owned outside the infrastructure templates

Existing network security groups are left untouched at the parent-resource level.
Network deployment and preview tasks first read the existing group names. The
infrastructure template explicitly skips those parents, creates a missing group,
and manages only the named IPAFFS security-rule child resources. The create-only
decorator also protects against a group appearing after the lookup. This avoids
copying or redeploying CCoE policy rules or replacing the complete parent rule list.
A failed name lookup stops planning or deployment. Existing group tags are also
left unchanged. Removing an IPAFFS rule from the template requires an explicit,
reviewed cleanup of that child resource; omission
in an incremental deployment does not delete it. Rule writes within a group are
serial; separate groups and environment previews remain independent.
Direct CLI previews should supply the same `existingNetworkSecurityGroupNames`
input so what-if can accurately exclude existing parents.

PRE and PRD set `sejParams.manageMaintenanceDefinitions: false`. Their existing
SQL maintenance target group, weekly/daily jobs, schedules and steps remain in
place. Infrastructure continues to manage the job database, identity, agent and
failure alert. SND and TST keep their current template-managed definitions. An
intentional change to PRE/PRD maintenance should reconcile the live definitions
with its owner rather than enable the bootstrap definitions without review. A
newly rebuilt PRE/PRD job agent requires its maintenance definitions to be restored
or provisioned by that owner.

TST, PRE and PRD set `sqlPoolParams` so the Classic deployment manages their
existing elastic pool (`modules/sql-pool-classic.bicep`). The parameters pin the
live SKU, per-database limits, maximum size, zone redundancy, maintenance window
and tags, so What-If shows no change until a parameter is edited. TST sets
`keepLiveCapacity: true` because something outside this repo scales its pool from
250 to 1000 eDTU on weekday mornings. It keeps whatever SKU and per-database limits
are live, and What-If shows those two properties as unresolved `reference()`
changes. SND omits `sqlPoolParams`, and the PRE-TRN pool sits in another resource
group, so neither is managed.

The Classic deployment requests one service-managed private endpoint per Elastic
Job Agent in SND, TST, PRE and PRD. Azure waits for approval before completing the
endpoint deployment. The pipeline submits ARM asynchronously, uses the Classic
service connection to approve the exact SQL connection, and waits for ARM to
succeed before publishing outputs. The existing deployment gates apply to the
whole sequence. ARM WhatIf previews the endpoint resource. Check per-database
results of a test or scheduled job execution to verify connectivity.

Microsoft blocked changes to Database Watcher resources from 9 November 2026.
The incremental Classic deployment reads the existing watcher identity for the
Kusto data store role assignment and preserves its targets and private link.
[Microsoft retirement notice](https://techcommunity.microsoft.com/blog/AzureSQLBlog/database-watcher-for-azure-sql-is-retiring-simplify-your-monitoring-with-databas/4567864)

Deployment tasks, previews and CI use the compiler pinned in
`scripts/pipeline/ensure-bicep-version.sh`. Each Azure CLI task selects the
verified Azure CLI-managed binary and stops before compilation if verification fails.

## Azure DevOps setup

Create a YAML pipeline named `infrastructure-preview` in the same repository and
project, with path `/pipelines/infrastructure-preview.yaml`. Set **Default branch
for manual and scheduled builds** to `refs/heads/main`. Azure DevOps evaluates the
completion trigger from that default branch. The completion resource must use
the full source pipeline path `\Infrastructure\infrastructure`; its successful
DEV runs already carry `Environment-DEV`. The YAML alias remains `infrastructure`.

Authorise the new pipeline to read `Common`, `LowerEnvs`, `HigherEnvs`, `DEV`, `TST`,
`PRE` and `PRD` variable groups, and to use the Modern and Classic service connections
configured by `pipelines/vars/{dev,tst,pre,prd}.yaml`, including DEV's Classic/SND
connection. Their Azure identities need the
permissions required for resource-group and subscription-scope what-if operations.
The preview job's Azure DevOps token needs permission to read the source
infrastructure build metadata in the same project. That lookup does not use an
Azure service connection. Pipeline-scoped access is sufficient; this does not
require changing the Azure identities' roles.
Missing authorisation can block the run before jobs start. Authentication failures
after initialisation leave pending/incomplete component records visible in the
report; they must not be treated as a successful plan.

The YAML excludes branch CI and PR triggers. Its native tag CI filter is `*`,
excluding the separate `ipaffs-infra-pin-*` manifest-pinning tags. Azure DevOps
tag filters do not express the release-tag format, so another tag push
can queue validation even when it is not a valid infrastructure release tag.
The source-validation step rejects every noncanonical tag before authenticated
preview work. The release pipeline applies the same format guard
before its deployment stages. The existing successful main `Environment-DEV` pipeline-completion
trigger is retained. Neither trigger changes DEV deployment batching or the
baseline's source-run, deployment-task and deployment-input verification.

Repository tests and Azure DevOps YAML preview compilation validate structure;
a manual read-only run can validate live execution. These checks do not establish
that a real tag push started a preview; verify the source ref, tagged commit and
reports on the first future release-tag run. A pre-tag preview remains advisory
and does not enforce that a future promotion uses the reviewed commit.

References: [pipeline completion triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers?view=azure-devops)
and [Bicep what-if limitations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if#limitations).
