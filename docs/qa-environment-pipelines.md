# Environment-specific QA pipelines

Two ADO definitions run the same execution/reporting template with a fixed target.
They have no environment selector. Workers, suite/filter, image tag, CSV report and
notification options remain available for manual runs.

| Suggested ADO definition | YAML in this repository | Deployment resource | Successful marker stage |
| --- | --- | --- | --- |
| `QA / QA - DEV` | `pipelines/qa-automation-dev.yaml` | `\Releasing\Deploy DEV` | `QA_DEV_Ready` |
| `QA / QA - TST` | `pipelines/qa-automation-tst.yaml` | `\Releasing\Release Pipeline` | `QA_TST_Ready` |

Each entry point owns its manual, scheduled and pipeline-resource triggers. Both
preserve the previous **06:00 UTC, Monday–Friday** schedule and use `always: true`
to run even without source changes. This is 07:00 UK time during British Summer
Time. Source CI and PR triggers are disabled; manual runs remain available.
Schedules and resource triggers must be in the entry points, not the shared template.

The companion `ipaffs-manifest` change publishes successful marker stages:

- DEV requires `DEV_DeployChart` to succeed and the **resolved namespace** to be
  `dev`. Deploying a release or branch namespace does not qualify. A non-master
  deployment explicitly targeting canonical `dev` does qualify.
- TST requires `TST_DeployChart` to succeed. It does not wait for PRE/PRD approval
  or completion of the entire release pipeline.

These markers do not queue tests themselves. They provide completion events for
the native resource triggers. QA remains asynchronous; PRE retains its existing
manual approval and does not become gated on the test outcome.

## Execution and evidence

`pipelines/templates/qa-automation.yaml` holds shared variables, repository checkout,
execution and report publishing for DEV and TST only. The old environment-selector
pipeline (`pipelines/qa-automation.yaml`) and nightly wrapper
(`pipelines/qa-automation-nightly.yaml`) are deleted. There are no compatibility
entry points or no-op wrappers, and no PRE/VNET execution path in this template.

Test execution now fails the pipeline on a nonzero exit. JUnit publication fails
on failed tests, a missing result file or publication failure. JUnit, Playwright
HTML, test-result artifacts and CSV generation still run after a test failure.
The diagnostic AKS status step remains non-blocking.

The `qa-run-context/run.json` artifact records the fixed environment, effective
suite/filter, requested image tag, QA run/definition IDs and trigger reason. Only
an actual `ResourceTrigger` from the `deployment` alias records the upstream run,
definition, source ref and commit. Manual/nightly runs do not claim that their
selected/default pipeline resource caused the tests or describes current state.

This is provenance, not verification of the application version observed during
testing. Another deployment can occur while tests run; `deployedVersionVerified`
is therefore false. The requested image tag can still be mutable (`latest`);
pinning and recording the actual image digest is separate follow-up work. Do not
combine full regression and targeted/specialist suites into an unqualified pass rate.

## Coordinated cutover (not performed by these PRs)

1. Review the infra and manifest companion PRs together. Arrange the cutover away
   from the weekday schedule and complete active releases that use the old QA queue
   step. Disable the old schedules before merging: their YAML files will be deleted.
2. Merge the infra change. Create the two definitions above from this repo, using
   `refs/heads/main` as **Default branch for manual and scheduled builds**. Authorize
   the existing pipeline resources, variable groups, agent pool, GitHub connection
   and service connections for the new definitions. No new identities are needed.
3. Check for UI-defined schedule overrides on the new definitions and confirm their
   YAML schedules are active. This change does not migrate old runs; decide how any
   required historical QA evidence will be preserved before removing old definitions.
4. Run each new definition manually and verify its fixed target, suite, native ADO
   Tests results, report artifacts and `qa-run-context` artifact. Check that a known
   failing test run is Failed and still publishes its evidence.
5. Update Release Explorer to recognise both new QA definition IDs and the native
   upstream resource relationship. That app
   change is not part of this pipeline split; its current single-definition/log
   lookup will not automatically discover the new QA runs.
6. Merge the companion manifest change. DEV deployments containing the new marker
   can then trigger QA. TST releases must be cut from manifest code containing the
   new marker. Backport to a maintained release branch if needed, then create a new
   release tag; do not move existing tags.
7. Verify one canonical DEV deployment triggers one DEV QA run, a branch-namespace
   deployment triggers none, and a TST deployment triggers one TST QA run while PRE
   is still awaiting approval. Remove the retired environment-selector and nightly
   ADO definitions and their UI schedules as part of this later cutover. Verify the
   next scheduled run for each replacement definition.

Older release tags retain their explicit queue step and PRE's dependency on it.
After retirement, those pipelines cannot be used unchanged: the obsolete queue
step will fail and block PRE. Update the maintained release branch and cut a new
tag containing the readiness stage before deploying or promoting that release.
Do not move existing tags. Starting the new TST QA pipeline manually does not fix
an old release pipeline's obsolete dependency. New environment trends begin in
the replacement definitions.

Schedules and deployment triggers can overlap. `batch: true` is not a cross-trigger
mutex (and `always: true` overrides schedule batching). If shared test data cannot
tolerate parallel runs, configure and validate per-environment serialization before
enabling both triggers; this change does not introduce a lock or cancel older runs.

## Validation

Local and GitHub checks parse YAML and exercise run-context attribution and the
actual container execution script with stubbed external commands. They do not
compile templates in ADO, run QA against an environment or validate live trigger
delivery. Those checks belong to the coordinated cutover above.

References: [pipeline stage triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers?view=azure-devops#stage-filters),
[scheduled triggers](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/scheduled-triggers?view=azure-devops),
[resource metadata](https://learn.microsoft.com/en-us/azure/devops/pipelines/yaml-schema/resources-pipelines-pipeline?view=azure-pipelines#pipeline-resource-metadata-as-predefined-variables).
