# Deployment hooks

Scripts in this folder run on every infrastructure deployment, in the `RunHooks`
stage directly after the Entra group stages. The stage calls
`scripts/pipeline/run-hooks.sh`, which discovers the hooks itself: adding a hook
means adding a file here, with no pipeline change.

## Naming and order

Hooks are `NN-what-it-does.sh` and run in lexical filename order, so the numeric
prefix sets the sequence (`10-` before `20-`), as with the Bicep layers.

## Environment overrides

Hooks in `scripts/hooks/<env>/` (`dev`, `tst`, `pre`, `prd`) are merged in by
filename before sorting:

- a same-named file replaces the common hook for that environment
- a new name is added to the sequence for that environment only
- a same-named no-op (`exit 0`) disables a common hook for that environment

## Contract

Every hook must:

- be idempotent: a second run makes no changes and exits 0
- honour `DRY_RUN`: when `true`, log what would change and change nothing
- exit non-zero with a clear message on failure; the runner then fails the
  pipeline and skips the remaining hooks

Hooks run with `bash`, so the execute bit is not required.

## Environment variables

Set by the stage for every hook:

| Variable              | Value                                                   |
|-----------------------|---------------------------------------------------------|
| `ENVIRONMENT`         | `dev`, `tst`, `pre` or `prd`                             |
| `DRY_RUN`             | `true` off `main`, `false` on `main` or when forced      |
| `SUBSCRIPTION_ID`     | the environment's subscription                          |
| `RESOURCE_GROUP_NAME` | the environment's infrastructure resource group         |

The task runs under the environment's `$(serviceConnection)` inside `AzureCLI@2`,
so `az` is already logged in. Inputs a specific hook needs beyond the above are
added to `pipelines/stages/run-hooks.yaml` when that hook lands.

## Dry run

Off `main` the stage always runs with `DRY_RUN=true`. The infrastructure pipeline
has a `runHooksOnBranch` parameter that forces a real run from a branch so a new
hook can be tested end to end. Use it sparingly and only against lower
environments.
