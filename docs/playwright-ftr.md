# Run Playwright against a feature namespace

`pipelines/qa-automation-ftr.yaml` adds a manual **Run Playwright Tests — FTR**
entry point. It uses the DEV agent pool, Azure connection, Key Vault credentials
and application settings, with explicit feature URLs. It has no schedule or
deployment trigger and does not create or deploy a namespace.

In Azure DevOps, open the pipeline in the **QA** folder and select **Run pipeline**.
While reviewing the draft, its default branch is `feat/playwright-ftr`.

Supply the namespace and these six URLs:

| Parameter | Target |
| --- | --- |
| `targetNamespace` | Existing feature Kubernetes namespace, such as `imta-21857` |
| `b2bBaseUrl` | Feature B2B proxy origin, normally `https://proxy-int-<namespace>.aks.imp.dev.azure.defra.cloud` |
| `b2cBaseUrl` | Feature B2C proxy origin, normally `https://proxy-<namespace>.aks.imp.dev.azure.defra.cloud` |
| `soapBaseUrl` | Feature SOAP proxy API origin |
| `openIdTokenUrl` | Feature OpenID token endpoint, including `/ad/sign` |
| `bipBaseUrl` | Feature BIP service origin |
| `notificationBaseUrl` | Feature notification service endpoint, including `/notifications` |

The URLs must use HTTP(S) without embedded credentials, query strings or
fragments. Required URLs fail validation before retrieving test credentials;
there is no implicit fallback to shared DEV services for those six endpoints.
The optional `riskEngineBaseUrl` retains the DEV setting when blank. Plants
Dynamics, identity users, credentials and other configuration also retain DEV
defaults. The application route segment remains `dev`, for example
`/notification/dev/protected/notifications`, independently of the namespace.

Select a QA `imageTag` containing the companion `ipaffs-qa-automation` URL override
change. The FTR pipeline first runs `npm run config:validate` in that image; an
older image fails before functional tests can silently use its fixed DEV URLs.
Before that companion change reaches the `latest` image, use its branch build
number from **Build QA Test Runner Image**. Checking out a QA source branch alone
does not change the code inside the selected image.

Workers, test suite, Playwright grep filter and CSV reporting work as in DEV.
For an initial smoke run, set `playwrightTag` to `@smoke`. Notifications are
optional and default off. Kubernetes status logs use the supplied namespace.
The QA context artifact records the namespace and URL overrides; Playwright
reports and JUnit results use the existing publication steps. A manual run does
not claim to verify the deployed application version or a triggering deployment.

The namespace must already contain the required services, migrations, reference
data and test accounts, and its authentication callbacks and ingress must be
reachable from the QA agents. The pipeline does not seed or clean up data.

After merging, repoint the FTR definition's default branch to `main`. Existing
DEV and TST entry points retain their schedules, deployment triggers and defaults.
