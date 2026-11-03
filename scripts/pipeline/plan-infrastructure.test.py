#!/usr/bin/env python3
"""Exercise the read-only preview runner with fake Azure responses and files."""

from contextlib import ExitStack, redirect_stdout
import html
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("infrastructure_runner", SCRIPTS / "plan-infrastructure.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)

COMMIT = "a" * 40
MODERN_SUBSCRIPTION = "11111111-1111-4111-8111-111111111111"
CLASSIC_SUBSCRIPTION = "22222222-2222-4222-8222-222222222222"
GRAFANA_PRINCIPAL = "33333333-3333-4333-8333-333333333333"
RAW_VALUE = "private-do-not-publish-connection-value"
REAL_SUBPROCESS_RUN = subprocess.run


def parameter(value):
    return {"value": value}


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "bicep").mkdir()
        self.args = SimpleNamespace(environment="TST", scope="modern", initialize=False,
                                    commit=COMMIT, source_ref="refs/heads/main", build_id="123",
                                    state_dir=self.root / "private-state", output_dir=self.root / "artifacts" / "TST")
        self.environment = {
            "PLATFORM_SUBSCRIPTION_ID": MODERN_SUBSCRIPTION,
            "PLATFORM_RESOURCE_GROUP": "proposed-modern-group",
            "PLATFORM_LOCATION": "uksouth",
            "PLATFORM_CLASSIC_SUBSCRIPTION_ID": CLASSIC_SUBSCRIPTION,
            "PLATFORM_CLASSIC_RESOURCE_GROUP": "proposed-classic-group",
            **{variable: "fixture-" + name for name, variable in RUNNER.ENVIRONMENT_VARIABLES.items()},
        }
        self.calls = []
        self.cli_version = "2.75.0"
        self.results = {}
        self.compilations = []
        self.patches = ExitStack()
        self.addCleanup(self.patches.close)
        self.output = io.StringIO()
        self.patches.enter_context(redirect_stdout(self.output))
        self.patches.enter_context(mock.patch.object(RUNNER, "ROOT", self.root))
        self.git = self.patches.enter_context(mock.patch.object(
            RUNNER.subprocess, "run", return_value=SimpleNamespace(stdout=COMMIT + "\n")))

    def compile(self, component, environment, values, private_dir):
        self.compilations.append((component, dict(values)))
        params = {
            "network": {
                "vnetParams": parameter({"name": "candidate-vnet", "subnets": [
                    {"name": "candidate-" + prefix} for prefix in RUNNER.SUBNETS]}),
                "subnetNames": parameter({prefix: "candidate-" + prefix for prefix in RUNNER.SUBNETS})},
            "classic": {
                "redisParams": parameter({"name": "candidate-redis"}),
                "searchParams": parameter({"name": "candidate-search"}),
                "serviceBusParams": parameter({"namespaceName": "candidate-servicebus"}),
                "sqlParams": parameter({"serverName": "candidate-sql"})},
            "infra": {"monitoringParams": parameter({"grafanaName": "candidate-grafana"})},
        }.get(component, {})
        template_path = private_dir / f"{component}.template.json"
        parameters_path = private_dir / f"{component}.parameters.json"
        template_path.write_text(json.dumps({"raw": RAW_VALUE}))
        parameters_path.write_text(json.dumps({"parameters": params, "raw": RAW_VALUE}))
        return params, template_path, parameters_path

    def az(self, arguments, timeout=900):
        self.calls.append(arguments)
        if arguments == ["version"]:
            return {"azure-cli": self.cli_version}
        if arguments[:2] == ["resource", "show"]:
            return GRAFANA_PRINCIPAL
        if arguments[:3] in (["deployment", "group", "what-if"], ["deployment", "sub", "what-if"]):
            component = arguments[arguments.index("--name") + 1].removeprefix("Preview-").removesuffix("-123")
            result = self.results.get(component, {"status": "Succeeded", "changes": []})
            if isinstance(result, Exception):
                raise result
            return result
        self.fail("Unexpected Azure invocation: " + str(arguments))

    def run_preview(self):
        with mock.patch.object(RUNNER, "compile_parameters", side_effect=self.compile), \
             mock.patch.object(RUNNER, "az_json", side_effect=self.az):
            return RUNNER.run(self.args, self.environment)

    def report(self):
        return json.loads((self.args.output_dir / "plan.json").read_text())

    def component(self, name):
        return next(component for component in self.report()["components"] if component["name"] == name)

    def test_mutating_azure_commands_fail_before_starting_a_process(self):
        for arguments in (["deployment", "group", "create"], ["deployment", "sub", "create"],
                          ["deployment", "group", "wait"], ["resource", "update"],
                          ["role", "assignment", "create"], ["pipelines", "variable-group", "variable", "update"]):
            with self.subTest(arguments=arguments), self.assertRaisesRegex(RUNNER.PlanError, "COMMAND_NOT_ALLOWED"):
                RUNNER.az_json(arguments)
        self.git.assert_not_called()

    def test_allowed_operations_use_argument_lists_without_a_shell(self):
        self.git.return_value = SimpleNamespace(returncode=0, stdout='{"ok": true}')
        for arguments in (["version"], ["bicep", "build-params", "--file", "input.bicepparam"],
                          ["resource", "show", "--ids", "resource-id"],
                          ["deployment", "sub", "what-if"], ["deployment", "group", "what-if"]):
            with self.subTest(arguments=arguments):
                self.assertEqual({"ok": True}, RUNNER.az_json(arguments))
                positional, keyword = self.git.call_args
                self.assertEqual(["az", *arguments, "--only-show-errors", "--output", "json"], positional[0])
                self.assertNotIn("shell", keyword)
                self.assertTrue(keyword["capture_output"])

    def test_azure_errors_do_not_echo_stderr_or_values(self):
        self.git.return_value = SimpleNamespace(returncode=1, stdout=RAW_VALUE, stderr=RAW_VALUE)
        with self.assertRaisesRegex(RUNNER.PlanError, "^AZURE_COMMAND_FAILED$"):
            RUNNER.az_json(["version"])
        self.git.side_effect = subprocess.TimeoutExpired(["az"], 1, output=RAW_VALUE, stderr=RAW_VALUE)
        with self.assertRaisesRegex(RUNNER.PlanError, "^AZURE_RESPONSE_UNAVAILABLE$"):
            RUNNER.az_json(["version"])

    def test_source_commit_must_match_checkout_before_any_azure_or_artifact_work(self):
        self.git.return_value.stdout = "b" * 40
        with mock.patch.object(RUNNER, "az_json") as azure:
            with self.assertRaisesRegex(RUNNER.PlanError, "SOURCE_COMMIT_MISMATCH"):
                RUNNER.run(self.args, self.environment)
            azure.assert_not_called()
        self.assertFalse(self.args.output_dir.exists())

    def test_initialize_publishes_incomplete_coverage_before_authentication_without_azure(self):
        self.args.initialize = True
        with mock.patch.object(RUNNER, "az_json") as azure:
            self.assertEqual(0, RUNNER.run(self.args, {}))
            azure.assert_not_called()
        report = self.report()
        self.assertFalse(report["complete"])
        self.assertEqual(COMMIT, report["metadata"]["commit"])
        self.assertEqual("not-applicable", self.component("acr")["status"])
        self.assertEqual("blocked", self.component("infra")["status"])
        self.assertTrue((self.args.state_dir / "state.json").exists())

    def test_agent_cli_275_runs_with_default_validation_and_older_clients_fail_closed(self):
        self.assertEqual(0, self.run_preview())
        operations = [arguments for arguments in self.calls if arguments[:1] == ["deployment"]]
        self.assertTrue(operations)
        for arguments in operations:
            self.assertNotIn("--validation-level", arguments)
        self.cli_version = "2.74.0"
        self.calls.clear()
        self.assertEqual(1, self.run_preview())
        self.assertEqual("AZURE_CLI_TOO_OLD", self.component("network")["errorCode"])
        self.assertFalse(any(arguments[:1] == ["deployment"] for arguments in self.calls))

    def test_state_from_another_source_or_build_cannot_be_reused(self):
        self.args.initialize = True
        RUNNER.run(self.args, {})
        self.args.initialize = False
        self.args.build_id = "124"
        with self.assertRaisesRegex(RUNNER.PlanError, "PREVIEW_STATE_MISMATCH"):
            RUNNER.run(self.args, self.environment)

    def test_raw_state_and_artifacts_must_be_separate_including_path_aliases(self):
        artifacts = self.root / "published"
        aliases = [artifacts, artifacts / "raw", artifacts / ".." / "published" / "raw"]
        artifacts.mkdir()
        symlink = self.root / "published-alias"
        symlink.symlink_to(artifacts, target_is_directory=True)
        aliases.append(symlink / "raw")
        for raw in aliases:
            with self.subTest(raw=raw):
                self.args.output_dir = artifacts
                self.args.state_dir = raw
                self.args.initialize = True
                with self.assertRaisesRegex(RUNNER.PlanError, "PRIVATE_STATE_OVERLAPS_REPORT"):
                    RUNNER.run(self.args, {})

    def test_desired_subnets_and_classic_ids_come_from_candidate_names_not_library_ids(self):
        self.args.state_dir.mkdir()
        old = {name: "stale-library-id" for name in RUNNER.ENVIRONMENT_VARIABLES}
        with mock.patch.object(RUNNER, "compile_parameters", side_effect=self.compile):
            result = RUNNER.desired_inputs("TST", old, self.environment, self.args.state_dir)
        for prefix in RUNNER.SUBNETS:
            self.assertEqual("candidate-" + prefix, result[prefix + "SubnetName"])
            self.assertEqual(f"/subscriptions/{MODERN_SUBSCRIPTION}/resourceGroups/proposed-modern-group/providers/Microsoft.Network/virtualNetworks/candidate-vnet/subnets/candidate-{prefix}", result[prefix + "SubnetId"])
        for target, kind, name in (
            ("classicRedisResourceId", "Microsoft.Cache/Redis", "candidate-redis"),
            ("classicSearchServiceResourceId", "Microsoft.Search/searchServices", "candidate-search"),
            ("classicServiceBusNamespaceResourceId", "Microsoft.ServiceBus/namespaces", "candidate-servicebus"),
            ("classicSqlServerResourceId", "Microsoft.Sql/servers", "candidate-sql")):
            self.assertEqual(f"/subscriptions/{CLASSIC_SUBSCRIPTION}/resourceGroups/proposed-classic-group/providers/{kind}/{name}", result[target])
        self.assertEqual("stale-library-id", old["privateEndpointsSubnetId"])

    def test_generated_raw_parameters_and_responses_stay_outside_artifacts(self):
        self.assertEqual(0, self.run_preview())
        self.args.scope = "classic"
        self.assertEqual(0, self.run_preview())
        self.assertTrue(self.report()["complete"])
        state = json.loads((self.args.state_dir / "state.json").read_text())
        self.assertEqual(GRAFANA_PRINCIPAL, state["privateInputs"]["grafanaManagedIdentityPrincipalId"])
        self.assertIn(RAW_VALUE, (self.args.state_dir / "infra.parameters.json").read_text())
        self.assertEqual({"plan.json", "summary.md", "change-details.md"}, {path.name for path in self.args.output_dir.iterdir()})
        for artifact in self.args.output_dir.iterdir():
            self.assertNotIn(RAW_VALUE, artifact.read_text())
            self.assertNotIn(GRAFANA_PRINCIPAL, artifact.read_text())
        self.assertEqual(0o700, self.args.state_dir.stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.args.state_dir / "state.json").stat().st_mode & 0o777)

    def test_new_proposed_grafana_identity_blocks_bridge_without_library_fallback(self):
        target = f"/subscriptions/{MODERN_SUBSCRIPTION}/resourceGroups/proposed-modern-group/providers/Microsoft.Dashboard/grafana/candidate-grafana"
        self.results["infra"] = {"status": "Succeeded", "changes": [{"resourceId": target, "changeType": "Create"}]}
        self.assertEqual(0, self.run_preview())
        self.assertFalse(any(arguments[:2] == ["resource", "show"] for arguments in self.calls))
        self.args.scope = "classic"
        self.assertEqual(1, self.run_preview())
        self.assertEqual("complete", self.component("classic")["status"])
        self.assertEqual("blocked", self.component("infra-to-classic")["status"])
        self.assertEqual("UPSTREAM_IDENTITY_WILL_CHANGE", self.component("infra-to-classic")["errorCode"])
        self.assertNotIn("grafanaManagedIdentityPrincipalId", json.loads((self.args.state_dir / "state.json").read_text())["privateInputs"])
        bridge_calls = [arguments for arguments in self.calls if "Preview-infra-to-classic-123" in arguments]
        self.assertEqual([], bridge_calls)

    def test_failed_retry_cannot_reuse_a_previous_identity_or_bridge_plan(self):
        self.results["infra-to-classic"] = {"status": "Succeeded", "changes": [{
            "resourceId": "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Authorization/roleAssignments/previous",
            "changeType": "Create"}]}
        self.assertEqual(0, self.run_preview())
        self.args.scope = "classic"
        self.assertEqual(0, self.run_preview())
        self.assertTrue(self.component("infra-to-classic")["resources"])
        self.results["infra"] = RUNNER.PlanError("AZURE_COMMAND_FAILED")
        self.args.scope = "modern"
        self.assertEqual(1, self.run_preview())
        self.args.scope = "classic"
        self.assertEqual(1, self.run_preview())
        self.assertEqual("blocked", self.component("infra-to-classic")["status"])
        self.assertEqual([], self.component("infra-to-classic")["resources"])
        state = json.loads((self.args.state_dir / "state.json").read_text())
        self.assertNotIn("grafanaManagedIdentityPrincipalId", state["privateInputs"])

    def test_failed_what_if_is_incomplete_and_does_not_prevent_classic_scope_preview(self):
        self.results["infra"] = RUNNER.PlanError("AZURE_COMMAND_FAILED")
        self.assertEqual(1, self.run_preview())
        self.assertEqual("failed", self.component("infra")["status"])
        self.assertFalse(self.report()["complete"])
        self.args.scope = "classic"
        self.assertEqual(1, self.run_preview())
        self.assertEqual("complete", self.component("classic")["status"])
        self.assertEqual("blocked", self.component("infra-to-classic")["status"])
        markdown = (self.args.output_dir / "summary.md").read_text()
        self.assertIn("INCOMPLETE", markdown)
        self.assertIn("Infrastructure | Component execution | 1 | failed: AZURE_COMMAND_FAILED", html.unescape(markdown))
        self.assertNotIn("No resource changes predicted by ARM.", markdown)

    def test_unsuccessful_or_malformed_what_if_cannot_be_a_clean_result(self):
        for result in ({"status": "Failed", "changes": []}, {"status": "Succeeded"},
                       {"status": "Succeeded", "changes": "unexpected"},
                       {"status": "Succeeded", "changes": [None]}):
            with self.subTest(result=result):
                self.results["network"] = result
                self.assertEqual(1, self.run_preview())
                self.assertFalse(self.component("network")["complete"])
                self.assertEqual("WHAT_IF_INCOMPLETE", self.component("network")["errorCode"])

    def test_unknown_resources_and_diagnostics_remain_explicitly_unassessed_and_redacted(self):
        self.results["network"] = {
            "status": "Succeeded", "changes": [{"resourceId": "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/example", "changeType": "FutureAzureChange"}],
            "diagnostics": [{"message": RAW_VALUE, "level": "Warning"}]}
        self.assertEqual(0, self.run_preview())
        component = self.component("network")
        self.assertFalse(component["complete"])
        self.assertEqual(1, component["totals"]["Unknown"])
        self.assertEqual(1, component["diagnosticCount"])
        self.assertGreaterEqual(component["unknowns"], 2)
        for artifact in self.args.output_dir.iterdir():
            self.assertNotIn(RAW_VALUE, artifact.read_text())

    def test_compile_parameters_keeps_private_files_and_removes_temporary_bicepparam(self):
        self.args.state_dir.mkdir()
        def compiled(arguments, timeout=900):
            path = Path(arguments[arguments.index("--file") + 1])
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertIn("10-resource-group.bicep", path.read_text())
            return {"parametersJson": json.dumps({"parameters": {"secret": parameter(RAW_VALUE)}}),
                    "templateJson": json.dumps({"raw": RAW_VALUE})}
        with mock.patch.object(RUNNER, "az_json", side_effect=compiled):
            values, template, parameters = RUNNER.compile_parameters("resource-group", "TST", {}, self.args.state_dir)
        self.assertEqual(RAW_VALUE, values["secret"]["value"])
        self.assertEqual([], list((self.root / "bicep").glob(".preview-*")))
        for path in (template, parameters):
            self.assertEqual(self.args.state_dir, path.parent)
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertIn(RAW_VALUE, path.read_text())

    def test_real_fake_az_process_keeps_partial_report_and_withholds_failure_stderr(self):
        executables = self.root / "bin"
        executables.mkdir()
        calls = self.root / "azure-calls.jsonl"
        executable = executables / "az"
        executable.write_text("#!" + sys.executable + "\n" + "\n".join([
            "import json, sys",
            f"with open({str(calls)!r}, 'a') as log: log.write(json.dumps(sys.argv[1:]) + '\\n')",
            "args = sys.argv[1:]",
            "if args[:1] == ['version']: print(json.dumps({'azure-cli': '2.75.0'}))",
            f"elif args[:2] == ['resource', 'show']: print(json.dumps({GRAFANA_PRINCIPAL!r}))",
            "elif args[:3] in (['deployment', 'group', 'what-if'], ['deployment', 'sub', 'what-if']):",
            "    if '--validation-level' in args: sys.exit(98)",
            "    if 'Preview-network-123' in args:",
            f"        print({RAW_VALUE!r}, file=sys.stderr)",
            "        sys.exit(7)",
            "    print(json.dumps({'status': 'Succeeded', 'changes': []}))",
            "else: sys.exit(99)",
        ]) + "\n")
        executable.chmod(0o700)

        def process(arguments, **kwargs):
            if arguments == ["git", "rev-parse", "HEAD"]:
                return SimpleNamespace(stdout=COMMIT + "\n")
            return REAL_SUBPROCESS_RUN(arguments, **kwargs)

        with mock.patch.dict(os.environ, {"PATH": str(executables) + os.pathsep + os.environ["PATH"]}), \
             mock.patch.object(RUNNER.subprocess, "run", side_effect=process), \
             mock.patch.object(RUNNER, "compile_parameters", side_effect=self.compile):
            self.assertEqual(1, RUNNER.run(self.args, self.environment))
        self.assertEqual("failed", self.component("network")["status"])
        self.assertEqual("AZURE_COMMAND_FAILED", self.component("network")["errorCode"])
        self.assertEqual("complete", self.component("infra")["status"])
        self.assertFalse(self.report()["complete"])
        for artifact in self.args.output_dir.iterdir():
            self.assertNotIn(RAW_VALUE, artifact.read_text())
        invocations = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertTrue(any(arguments[:3] == ["deployment", "group", "what-if"] for arguments in invocations))
        self.assertTrue(all(arguments[:1] == ["version"] or arguments[:2] == ["resource", "show"] or
                            arguments[:3] in (["deployment", "group", "what-if"], ["deployment", "sub", "what-if"])
                            for arguments in invocations))


if __name__ == "__main__":
    unittest.main()
