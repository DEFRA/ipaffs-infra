"""Exercise output synchronisation and pipeline wiring without contacting Azure."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/pipeline/sync-deployment-outputs.py"
ENVIRONMENT = {
    "ADO_ORG_URL": "https://dev.azure.com/test-org",
    "ADO_PROJECT": "test-project",
    "ADO_GROUP_NAME": "DEV",
    "DEPLOYMENT_NAME": "Infrastructure-123",
    "RESOURCE_GROUP": "test-resource-group",
    "SUBSCRIPTION_ID": "test-subscription",
    "AZURE_DEVOPS_EXT_PAT": "pat-that-must-not-be-logged",
}
FAKE_AZ = r'''import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
fixture = json.loads(Path(os.environ["AZ_FIXTURE"]).read_text())
state_path = Path(os.environ["AZ_STATE"])
groups = json.loads(state_path.read_text())
with open(os.environ["AZ_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "env": {key: value for key, value in os.environ.items()
        if key.startswith("AZURE_DEVOPS_EXT_PIPELINE_VAR_")}}) + "\n")

def argument(name, default=None):
    if name in args:
        return args[args.index(name) + 1]
    return next((value[len(name) + 1:] for value in args if value.startswith(name + "=")), default)

if args[:3] == ["deployment", "group", "show"]:
    operation = "deployment"
    result = fixture["outputs"]
elif args[:3] == ["pipelines", "variable-group", "list"]:
    operation = "groups"
    result = groups
    if fixture.get("omit_variables"):
        result = [{key: value for key, value in group.items() if key != "variables"} for group in groups]
elif args[:4] == ["pipelines", "variable-group", "variable", "list"]:
    operation = "variables"
    result = groups[0]["variables"]
elif args[:3] == ["pipelines", "variable-group", "variable"] and args[3] in ("create", "update"):
    operation = "write"
    calls = [json.loads(line) for line in Path(os.environ["AZ_LOG"]).read_text().splitlines()]
    writes = sum(call["args"][:3] == ["pipelines", "variable-group", "variable"]
                 and call["args"][3] in ("create", "update") for call in calls)
    if fixture.get("fail_write") == writes:
        print("CLI error containing " + fixture.get("sensitive", "sensitive-output"), file=sys.stderr)
        sys.exit(17)
    group = next(group for group in groups if str(group["id"]) == argument("--id"))
    name = argument("--name")
    variables = group["variables"]
    if args[3] == "create" and name in variables:
        sys.exit("variable already exists")
    if args[3] == "update" and name not in variables:
        sys.exit("variable does not exist")
    value = argument("--value")
    if argument("--prompt-value") == "true":
        value = os.environ["AZURE_DEVOPS_EXT_PIPELINE_VAR_" + name]
    metadata = variables.setdefault(name, {"isSecret": False})
    metadata["value"] = value
    if "--secret" in args:
        metadata["isSecret"] = argument("--secret") == "true"
    state_path.write_text(json.dumps(groups))
    # A CLI can emit variable values: the helper must suppress its output.
    print(json.dumps(variables))
    sys.exit(0)
else:
    sys.exit("unexpected az command")

if fixture.get("fail_command") == operation:
    print("CLI error containing " + fixture.get("sensitive", "sensitive-output"), file=sys.stderr)
    sys.exit(19)
raw = fixture.get(operation + "_raw")
print(raw if raw is not None else json.dumps(result))
'''


def output(value):
    return {"type": "String", "value": value}


class OutputSyncTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.binary = self.directory / "bin"
        self.binary.mkdir()
        az = self.binary / "az"
        az.write_text(f"#!{sys.executable}\n" + FAKE_AZ)
        az.chmod(0o755)
        self.log = self.directory / "az.jsonl"
        self.fixture = {
            "outputs": {"firstOutput": output("new-first"), "secondOutput": output("new-second"),
                        "thirdOutput": output("new-third")},
            "groups": [{"id": 42, "name": "DEV", "type": "Vsts", "variables": {
                "first": {"value": "old-first", "isSecret": False},
                "second": {"value": "old-second", "isSecret": False},
                "unrelated": {"value": "retain-me", "isSecret": False},
                "unrelatedSecret": {"value": None, "isSecret": True},
            }}],
            "sensitive": "value-must-never-appear-in-logs",
        }

    def run_helper(self, *mappings, fixture=None, missing_env=None):
        fixture = copy.deepcopy(self.fixture if fixture is None else fixture)
        fixture_path = self.directory / "fixture.json"
        fixture_path.write_text(json.dumps(fixture))
        self.state = self.directory / "state.json"
        self.state.write_text(json.dumps(fixture["groups"]))
        self.log.unlink(missing_ok=True)
        environment = {**os.environ, **ENVIRONMENT,
                       "PATH": str(self.binary) + os.pathsep + os.environ["PATH"],
                       "AZ_FIXTURE": str(fixture_path), "AZ_STATE": str(self.state), "AZ_LOG": str(self.log)}
        if missing_env:
            environment.pop(missing_env)
        result = subprocess.run([sys.executable, str(SCRIPT), *mappings], env=environment,
                                text=True, capture_output=True, timeout=10)
        self.calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        self.groups = json.loads(self.state.read_text())
        return result

    def writes(self):
        return [call for call in self.calls if call["args"][:3] == ["pipelines", "variable-group", "variable"]
                and call["args"][3] in ("create", "update")]

    def assert_no_value_logs(self, result, *values):
        for value in (*values, ENVIRONMENT["AZURE_DEVOPS_EXT_PAT"], self.fixture["sensitive"]):
            self.assertNotIn(value, result.stdout + result.stderr)

    def test_fetches_deployment_and_group_once_and_only_writes_changes(self):
        self.fixture["groups"][0]["variables"]["second"]["value"] = "new-second"
        result = self.run_helper("first=firstOutput", "second=secondOutput", "third=thirdOutput")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, sum(call["args"][:3] == ["deployment", "group", "show"] for call in self.calls))
        self.assertEqual(1, sum(call["args"][:3] == ["pipelines", "variable-group", "list"] for call in self.calls))
        self.assertEqual(4, len(self.calls), self.calls)
        self.assertIn("requested=3 updated=1 created=1 unchanged=1 failed=0", result.stdout)
        self.assertEqual(["update", "create"], [call["args"][3] for call in self.writes()])
        self.assertEqual(["first", "third"], [call["args"][call["args"].index("--name") + 1] for call in self.writes()])
        variables = self.groups[0]["variables"]
        self.assertEqual("new-first", variables["first"]["value"])
        self.assertEqual("new-third", variables["third"]["value"])
        for name in ("unrelated", "unrelatedSecret"):
            self.assertEqual(self.fixture["groups"][0]["variables"][name], variables[name])
        self.assert_no_value_logs(result, "new-first", "new-second", "new-third", "retain-me")

    def test_unchanged_outputs_do_not_mutate_the_group(self):
        self.fixture["groups"][0]["variables"]["first"]["value"] = "new-first"
        result = self.run_helper("first=firstOutput")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.writes())
        self.assertEqual(self.fixture["groups"], self.groups)
        self.assertIn("requested=1 updated=0 created=0 unchanged=1 failed=0", result.stdout)

    def test_falls_back_to_one_variables_read_if_group_list_omits_them(self):
        result = self.run_helper("first=firstOutput", "second=secondOutput",
                                 fixture={**self.fixture, "omit_variables": True})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, sum(call["args"][:4] == ["pipelines", "variable-group", "variable", "list"]
                                for call in self.calls))
        self.assertEqual(5, len(self.calls))

    def test_values_with_leading_dashes_and_shell_syntax_are_passed_literally(self):
        value = "--leading-dash\n$(must-remain-literal) 'quoted'"
        self.fixture["outputs"]["firstOutput"] = output(value)
        result = self.run_helper("first=firstOutput")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(value, self.groups[0]["variables"]["first"]["value"])
        self.assert_no_value_logs(result, value)

    def test_existing_secret_uses_environment_input_and_preserves_secret_flag_and_case(self):
        self.fixture["groups"][0]["variables"]["First"] = {"value": None, "isSecret": True}
        del self.fixture["groups"][0]["variables"]["first"]
        result = self.run_helper("first=firstOutput")
        self.assertEqual(0, result.returncode, result.stderr)
        write, = self.writes()
        self.assertEqual("First", write["args"][write["args"].index("--name") + 1])
        self.assertNotIn("--value", write["args"])
        self.assertEqual("true", write["args"][write["args"].index("--secret") + 1])
        self.assertEqual("true", write["args"][write["args"].index("--prompt-value") + 1])
        self.assertEqual("new-first", write["env"]["AZURE_DEVOPS_EXT_PIPELINE_VAR_First"])
        self.assertEqual({"value": "new-first", "isSecret": True},
                         self.groups[0]["variables"]["First"])
        self.assert_no_value_logs(result, "new-first")

    def test_missing_null_empty_or_invalid_output_fails_before_any_write(self):
        for invalid in (None, {}, {"value": None}, output(""), output("  \t"), output("bad\0value"),
                        output(7), output(False), output({"a": 1})):
            with self.subTest(invalid=invalid):
                fixture = copy.deepcopy(self.fixture)
                if invalid is None:
                    del fixture["outputs"]["secondOutput"]
                else:
                    fixture["outputs"]["secondOutput"] = invalid
                result = self.run_helper("first=firstOutput", "second=secondOutput", fixture=fixture)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.writes())
                self.assertEqual(fixture["groups"], self.groups)
                self.assert_no_value_logs(result, "new-first", "old-first")

    def test_invalid_group_metadata_cannot_cause_a_partial_update(self):
        for change in ({"id": 0}, {"type": "AzureKeyVault"}, {"variables": []},
                       {"variables": {"second": {"value": "old", "isSecret": "true"}}},
                       {"variables": {"second": {"value": "old", "isSecret": 1}}},
                       {"variables": {"second": {"value": 4, "isSecret": False}}},
                       {"variables": {"second": {"value": "old"}, "SECOND": {"value": "old"}}}):
            with self.subTest(change=change):
                fixture = copy.deepcopy(self.fixture)
                fixture["groups"][0].update(change)
                result = self.run_helper("first=firstOutput", "second=secondOutput", fixture=fixture)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.writes())
                self.assertEqual(fixture["groups"], self.groups)
                self.assert_no_value_logs(result, "new-first", "old-first")

    def test_malformed_cli_json_fails_before_any_write(self):
        for operation in ("deployment", "groups"):
            with self.subTest(operation=operation):
                fixture = copy.deepcopy(self.fixture)
                fixture[operation + "_raw"] = "not JSON " + fixture["sensitive"]
                result = self.run_helper("first=firstOutput", fixture=fixture)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.writes())
                self.assert_no_value_logs(result)

    def test_missing_ambiguous_or_wrong_group_fails_before_any_write(self):
        for groups in ([], self.fixture["groups"] * 2, [{**self.fixture["groups"][0], "name": "OTHER"}]):
            with self.subTest(groups=groups):
                fixture = {**self.fixture, "groups": groups}
                result = self.run_helper("first=firstOutput", fixture=fixture)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.writes())

    def test_deployment_or_group_read_failure_is_nonzero_and_suppresses_cli_output(self):
        for operation in ("deployment", "groups"):
            with self.subTest(operation=operation):
                result = self.run_helper("first=firstOutput", fixture={**self.fixture, "fail_command": operation})
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.writes())
                self.assert_no_value_logs(result)

    def test_first_or_middle_write_failure_stops_subsequent_writes(self):
        for fail_write in (1, 2):
            with self.subTest(fail_write=fail_write):
                result = self.run_helper("first=firstOutput", "second=secondOutput", "third=thirdOutput",
                                         fixture={**self.fixture, "fail_write": fail_write})
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(fail_write, len(self.writes()))
                self.assertIn(f"updated={fail_write - 1} created=0 unchanged=0 failed=1", result.stdout)
                self.assertNotIn("third", self.groups[0]["variables"])
                self.assert_no_value_logs(result, "new-first", "new-second", "new-third")

    def test_invalid_mapping_or_missing_environment_fails_without_cli_calls(self):
        for mappings in ((), ("invalid",), ("first=",), ("=firstOutput",),
                         ("first=firstOutput", "FIRST=secondOutput"), ("bad name=firstOutput",)):
            with self.subTest(mappings=mappings):
                result = self.run_helper(*mappings)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.calls)
        for name in ENVIRONMENT.keys() - {"AZURE_DEVOPS_EXT_PAT"}:
            with self.subTest(missing_env=name):
                result = self.run_helper("first=firstOutput", missing_env=name)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.calls)


EXPECTED_MAPPINGS = {
    "acr": """acrLoginServer=acrLoginServer acrName=acrName acrResourceId=acrResourceId""".split(),
    "classic": """classicRedisName=redisName classicRedisResourceId=redisResourceId
        classicSearchServiceSubscriptionId=searchServiceSubscriptionId
        classicSearchServiceResourceGroupName=searchServiceResourceGroupName
        classicSearchServiceName=searchServiceName
        classicSearchServiceManagedIdentityPrincipalId=searchServiceManagedIdentityPrincipalId
        classicSearchServiceManagedIdentityPrincipalName=searchServiceManagedIdentityPrincipalName
        classicSearchServiceResourceId=searchServiceResourceId
        classicServiceBusNamespaceName=serviceBusNamespaceName
        classicServiceBusNamespaceResourceId=serviceBusNamespaceResourceId
        classicSqlServerName=sqlServerName classicSqlServerResourceId=sqlServerResourceId""".split(),
    "network": """aksApiServerSubnetId=aksApiServerSubnetId aksApiServerSubnetName=aksApiServerSubnetName
        aksSystemNodesSubnetId=aksSystemNodesSubnetId aksSystemNodesSubnetName=aksSystemNodesSubnetName
        aksUserNodesSubnetId=aksUserNodesSubnetId aksUserNodesSubnetName=aksUserNodesSubnetName
        appGatewayForContainersSubnetId=appGatewayForContainersSubnetId
        appGatewayForContainersSubnetName=appGatewayForContainersSubnetName
        privateEndpointsSubnetId=privateEndpointsSubnetId privateEndpointsSubnetName=privateEndpointsSubnetName
        vnetName=vnetName vnetResourceId=vnetResourceId""".split(),
    "infra": """aksClusterResourceId=aksClusterResourceId aksKubeletPrincipalId=aksKubeletPrincipalId
        albControllerClientId=albControllerClientId appGatewayForContainersResourceId=appGatewayForContainersResourceId
        appGatewayForContainersFrontendName=appGatewayForContainersFrontendName
        appGatewayForContainersFrontendFqdn=appGatewayForContainersFrontendFqdn
        azureServiceOperatorClientId=azureServiceOperatorClientId externalSecretsClientId=externalSecretsClientId
        externalSecretsPrincipalObjectId=externalSecretsPrincipalObjectId aksOidcIssuer=aksOidcIssuer
        keyVaultName=keyVaultName keyVaultUrl=keyVaultUri kubernetesCluster=aksClusterName redisName=redisName
        searchServiceSubscriptionId=searchServiceSubscriptionId
        searchServiceResourceGroupName=searchServiceResourceGroupName searchServiceName=searchServiceName
        searchServiceManagedIdentityPrincipalId=searchServiceManagedIdentityPrincipalId
        searchServiceManagedIdentityPrincipalName=searchServiceManagedIdentityPrincipalName
        sqlServerName=sqlServerName sqlServerManagedIdentityObjectId=sqlServerManagedIdentityObjectId
        storageAccountName=storageAccountName insightsConnectionString=insightsConnectionString
        insightsInstrumentationKey=insightsInstrumentationKey grafanaManagedIdentityPrincipalId=grafanaManagedIdentityPrincipalId
        grafanaName=grafanaName prometheusName=prometheusName""".split(),
}
QA_MAPPINGS = ["qaKeyVaultName=qaKeyVaultName", "qaKeyVaultUrl=qaKeyVaultUri"]


def dictionaries(node):
    if isinstance(node, dict):
        yield node
        for child in node.values():
            yield from dictionaries(child)
    elif isinstance(node, list):
        for child in node:
            yield from dictionaries(child)


class PipelineOutputWiringTests(unittest.TestCase):
    def test_actual_inline_scripts_preserve_all_environment_mappings_and_failure_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            collector = directory / "python3"
            collector.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
with open(os.environ["MAPPING_LOG"], "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
sys.exit(int(os.environ["COLLECTOR_EXIT"]))
''')
            collector.chmod(0o755)
            log = directory / "mappings.jsonl"
            for environment in ("DEV", "TST", "PRE", "PRD"):
                count = 0
                for component, expected in EXPECTED_MAPPINGS.items():
                    if component == "acr" and environment == "TST":
                        continue
                    path = ROOT / f"pipelines/stages/deploy-bicep-{component}.yaml"
                    pipeline = yaml.safe_load(path.read_text())
                    tasks = [node for node in dictionaries(pipeline)
                             if "sync-deployment-outputs.py" in node.get("inputs", {}).get("inlineScript", "")]
                    self.assertEqual(1, len(tasks), str(path))
                    task, = tasks
                    self.assertEqual("and(not(failed()), not(canceled()), eq(variables['Build.SourceBranch'], 'refs/heads/main'))",
                                     task["condition"])
                    self.assertEqual(set(ENVIRONMENT), set(task["env"]))
                    self.assertNotIn("set -x", task["inputs"]["inlineScript"])
                    script = task["inputs"]["inlineScript"].replace("${{ parameters.environmentName }}", environment)
                    actual_expected = expected + (QA_MAPPINGS if component == "infra" and environment == "TST" else [])
                    count += len(actual_expected)
                    for collector_exit in (0, 23):
                        with self.subTest(environment=environment, component=component, collector_exit=collector_exit):
                            log.unlink(missing_ok=True)
                            result = subprocess.run([shutil.which("bash"), "-c", script], cwd=ROOT,
                                                    env={**os.environ, "PATH": str(directory) + os.pathsep + os.environ["PATH"],
                                                         "MAPPING_LOG": str(log), "COLLECTOR_EXIT": str(collector_exit)},
                                                    text=True, capture_output=True, timeout=10)
                            self.assertEqual(collector_exit, result.returncode, result.stderr)
                            calls = [json.loads(line) for line in log.read_text().splitlines()]
                            self.assertEqual([["scripts/pipeline/sync-deployment-outputs.py", *actual_expected]], calls)
                self.assertEqual(53 if environment == "TST" else 54, count)


if __name__ == "__main__":
    unittest.main()
