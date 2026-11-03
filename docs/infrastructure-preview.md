# Infrastructure promotion previews

`pipelines/infrastructure-preview.yaml` previews the candidate infrastructure commit
against live TST, PRE and PRD. It does not apply deployments, run hooks, update
Library groups or change access-group memberships. Tag-triggered promotion is a
separate follow-up; the current DEV deployment pipeline remains unchanged.

## Release workflow

1. Merge infrastructure changes to `main`; the `infrastructure` pipeline applies DEV.
2. When that run succeeds with the `Environment-DEV` build tag, the preview pipeline
   runs automatically using the same Git commit. TST, PRE and PRD run sequentially.
3. Review the **Infrastructure promotion preview** summary in Azure DevOps and the
   downloadable `infrastructure-preview` artifact before choosing a release tag.
   Record the full candidate commit; a tag created later must point at that commit
   for this report to describe its inputs.

A failed or unresolved preview is incomplete, rather than evidence of no changes.
When every environment's what-if executes successfully but ARM cannot assess all
resources or fields, the pipeline finishes **succeeded with issues** and keeps the
assessment marked **INCOMPLETE**. Execution errors, missing or invalid reports, and
reports from different commits still fail the pipeline.
The next environment is still attempted after a failure, and the overview runs
with whatever reports are available. No deployment environments are referenced by
these ordinary agent jobs; service-connection checks and authorisation still apply.

For a manual preview, select `main` in the Azure DevOps **Run pipeline** dialog
and verify the queued commit in the report. Automatic runs verify both the
checked-out commit and the completed DEV run's commit and branch before any
authenticated preview work.
The report records the commit, source ref, run ID and generation time. Changes to
the live environment after that time can invalidate the prediction.

### DEV post-apply baseline

To investigate recurring predictions, run the same preview pipeline manually with
`devBaselineOnly: true` and `devAppliedCommit` set to the full commit from a
successful DEV infrastructure apply. The job compares the candidate's Bicep,
environment YAML and shared parameter renderer with that commit before any
authenticated planning. Report-only code can differ; deployment inputs must not.
The DEV plan includes Classic/SND and publishes its source comparison evidence.
The normal TST/PRE/PRD flow remains the default.

Compare the baseline with the release targets to find recurring provider/default
differences and unresolved references. Repetition is evidence, not proof of a
false positive: environment-specific values can differ, and another controller or
policy can recreate settings after an apply. Keep those ownership differences
visible. Always review new resource creates/deletes and explicit configuration
changes. The current Library/live identity inputs and nondeterministic deployment
metadata also mean this is not an exact replay of the apply's historical inputs.

## Reading the reports

Start with the release comparison: it shows the create/update/delete counts and
resource types affected in TST, PRE and PRD side by side. Then read the environment
summary for the named resources and a short description of each predicted action.
Nested resources include their parent names so security rules and identity
credentials can be distinguished.

The summary has three parts:

- **Predicted changes** lists creates, reported updates and resource deletions.
  Property removals are described separately from resource deletions. An update
  can include provider defaults or omitted properties; it does not prove a live
  setting will reset. Potential changes remain explicitly labelled and are
  excluded from the headline action counts.
- **Coverage gaps** groups entries Azure did not preview and changes containing
  unresolved deployment-time values. Inspect the intended Bicep configuration
  and refresh the preview before promotion where those gaps matter.
- **Background inventory** counts ignored/unchanged observations and metadata-only
  updates. Updates containing only CreatedDate plus fields Azure explicitly marks
  `NoEffect` are also counted here; mixed updates remain in the review list.
  These can repeat across component previews. They are not presented as
  individual actions to review; Ignore can mean outside-template inventory or
  an expansion limit, so coverage is still marked incomplete.

Download `change-details.md` from each environment's artifact for property-level
evidence, full resource identifiers and input fingerprints. `plan.json` retains
every sanitised entry, including the ignored inventory omitted from Markdown.
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

## Azure DevOps setup

Create a YAML pipeline named `infrastructure-preview` in the same repository and
project, with path `/pipelines/infrastructure-preview.yaml`. Set **Default branch
for manual and scheduled builds** to `refs/heads/main`. Azure DevOps evaluates the
completion trigger from that default branch. The completion resource must use
the full source pipeline path `\Infrastructure\infrastructure`; its successful
DEV runs already carry `Environment-DEV`. The YAML alias remains `infrastructure`.

Authorise the new pipeline to read `Common`, `LowerEnvs`, `HigherEnvs`, `TST`, `PRE`
and `PRD` variable groups, and to use the Modern and Classic service connections
configured by `pipelines/vars/{tst,pre,prd}.yaml`. Their Azure identities need the
permissions required for resource-group and subscription-scope what-if operations.
Missing authorisation can block the run before jobs start. Authentication failures
after initialisation leave pending/incomplete component records visible in the
report; they must not be treated as a successful plan.

The YAML has no CI or PR trigger. Its automatic trigger requires a successful
source-pipeline completion on `refs/heads/main` with `Environment-DEV`. It does not
react to release tags and does not alter the manifest-style batching of DEV.

Repository tests and Azure DevOps YAML preview compilation validate structure;
the first live what-if run still needs checking after registration. A pre-tag
preview is advisory and does not yet enforce that a future promotion uses the
reviewed commit.

References: [pipeline completion triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers?view=azure-devops)
and [Bicep what-if limitations](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if#limitations).
