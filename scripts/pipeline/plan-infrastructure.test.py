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
        self.nsg_names = ["Existing-PrivateEndpoint", "Existing-AKS"]
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
        if arguments[:3] == ["network", "nsg", "list"]:
            if isinstance(self.nsg_names, Exception):
                raise self.nsg_names
            return self.nsg_names
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

    def test_unsupported_azure_commands_fail_before_starting_a_process(self):
        for arguments in (["deployment", "group", "create"], ["deployment", "sub", "create"],
                          ["deployment", "group", "wait"], ["resource", "update"],
                          ["resource", "show", "--ids", "retired-grafana"],
                          ["role", "assignment", "create"], ["pipelines", "variable-group", "variable", "update"],
                          ["network", "nsg", "list"], ["network", "nsg", "show"],
                          ["network", "nsg", "list", "--subscription", MODERN_SUBSCRIPTION, "--resource-group", "rg", "--query", "[]"],
                          ["network", "nsg", "list", "--subscription", MODERN_SUBSCRIPTION, "--resource-group", "rg", "--query", "[].name", "--debug"]):
            with self.subTest(arguments=arguments), self.assertRaisesRegex(RUNNER.PlanError, "COMMAND_NOT_ALLOWED"):
                RUNNER.az_json(arguments)
        self.git.assert_not_called()

    def test_allowed_operations_use_argument_lists_without_a_shell(self):
        self.git.return_value = SimpleNamespace(returncode=0, stdout='{"ok": true}')
        for arguments in (["version"], ["bicep", "build-params", "--file", "input.bicepparam"],
                          ["deployment", "sub", "what-if"], ["deployment", "group", "what-if"],
                          ["network", "nsg", "list", "--subscription", MODERN_SUBSCRIPTION,
                           "--resource-group", "rg", "--query", "[].name"]):
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

    def test_desired_subnets_come_from_candidate_names(self):
        self.args.state_dir.mkdir()
        old = {name: "stale-library-id" for name in RUNNER.ENVIRONMENT_VARIABLES}
        with mock.patch.object(RUNNER, "compile_parameters", side_effect=self.compile):
            result = RUNNER.desired_inputs("TST", old, self.environment, self.args.state_dir)
        for prefix in RUNNER.SUBNETS:
            self.assertEqual("candidate-" + prefix, result[prefix + "SubnetName"])
            self.assertEqual(f"/subscriptions/{MODERN_SUBSCRIPTION}/resourceGroups/proposed-modern-group/providers/Microsoft.Network/virtualNetworks/candidate-vnet/subnets/candidate-{prefix}", result[prefix + "SubnetId"])
        self.assertEqual("stale-library-id", old["privateEndpointsSubnetId"])

    def test_generated_raw_parameters_and_responses_stay_outside_artifacts(self):
        self.assertEqual(0, self.run_preview())
        self.args.scope = "classic"
        self.assertEqual(0, self.run_preview())
        self.assertTrue(self.report()["complete"])
        self.assertIn(RAW_VALUE, (self.args.state_dir / "infra.parameters.json").read_text())
        self.assertEqual({"plan.json", "summary.md", "change-details.md"}, {path.name for path in self.args.output_dir.iterdir()})
        for artifact in self.args.output_dir.iterdir():
            self.assertNotIn(RAW_VALUE, artifact.read_text())
        self.assertEqual(0o700, self.args.state_dir.stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.args.state_dir / "state.json").stat().st_mode & 0o777)

    def test_all_current_components_are_previewed_without_retired_monitoring_bridge(self):
        self.assertEqual(0, self.run_preview())
        self.args.scope = "classic"
        self.assertEqual(0, self.run_preview())
        components = {item["name"] for item in self.report()["components"]}
        self.assertEqual({"resource-group", "network", "acr", "classic", "infra", "privatelink"}, components)
        self.assertEqual(set(RUNNER.COMPONENTS), {item for scope in RUNNER.SCOPES.values() for item in scope})
        self.assertFalse(any(arguments[:2] == ["resource", "show"] for arguments in self.calls))

    def test_network_discovers_fresh_parent_names_and_does_not_reuse_supplied_or_previous_names(self):
        self.assertEqual(0, self.run_preview())
        network_compilations = [values for component, values in self.compilations if component == "network"]
        self.assertEqual(2, len(network_compilations))
        self.assertNotIn("existingNetworkSecurityGroupNames", network_compilations[0], "Desired-input compilation needs no Azure read")
        self.assertEqual(["Existing-AKS", "Existing-PrivateEndpoint"], network_compilations[1]["existingNetworkSecurityGroupNames"])
        reads = [arguments for arguments in self.calls if arguments[:3] == ["network", "nsg", "list"]]
        self.assertEqual([["network", "nsg", "list", "--subscription", MODERN_SUBSCRIPTION,
                           "--resource-group", "proposed-modern-group", "--query", "[].name"]], reads)
        self.nsg_names = ["Newly-Observed"]
        self.compilations.clear()
        with mock.patch.object(RUNNER, "compile_parameters", side_effect=self.compile), \
             mock.patch.object(RUNNER, "az_json", side_effect=self.az):
            RUNNER.preview("network", "TST", {"existingNetworkSecurityGroupNames": ["Stale-Supplied"]},
                           self.environment, self.args.state_dir, "123")
        self.assertEqual(["Newly-Observed"], self.compilations[-1][1]["existingNetworkSecurityGroupNames"])

    def test_empty_network_name_read_is_an_explicit_new_resource_case(self):
        self.nsg_names = []
        self.assertEqual(0, self.run_preview())
        actual = [values for component, values in self.compilations if component == "network"][-1]
        self.assertEqual([], actual["existingNetworkSecurityGroupNames"])
        self.assertEqual("complete", self.component("network")["status"])

    def test_network_read_failures_and_malformed_names_cannot_plan_with_empty_or_stale_fallback(self):
        for result, error in ((RUNNER.PlanError("AZURE_COMMAND_FAILED"), "AZURE_COMMAND_FAILED"),
                              (None, "INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES"),
                              ({"value": []}, "INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES"),
                              ([RAW_VALUE + ";unexpected"], "INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES"),
                              (["Name", "name"], "INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES")):
            with self.subTest(result=result):
                self.nsg_names = result
                self.calls.clear()
                self.compilations.clear()
                self.assertEqual(1, self.run_preview())
                self.assertEqual("failed", self.component("network")["status"])
                self.assertEqual(error, self.component("network")["errorCode"])
                self.assertFalse(any("Preview-network-123" in arguments for arguments in self.calls))
                self.assertEqual(1, sum(component == "network" for component, _ in self.compilations))
                self.assertEqual("complete", self.component("infra")["status"])
                for artifact in self.args.output_dir.iterdir():
                    self.assertNotIn(RAW_VALUE, artifact.read_text())

    def test_classic_scope_compiles_desired_network_inputs_without_reading_modern_nsgs(self):
        self.args.scope = "classic"
        self.nsg_names = RUNNER.PlanError("SHOULD_NOT_READ_MODERN")
        self.assertEqual(0, self.run_preview())
        self.assertTrue(any(component == "network" for component, _ in self.compilations))
        self.assertFalse(any(arguments[:3] == ["network", "nsg", "list"] for arguments in self.calls))
        self.assertEqual("complete", self.component("classic")["status"])

    def test_failed_retry_cannot_reuse_a_previous_component_plan(self):
        self.results["infra"] = {"status": "Succeeded", "changes": [{
            "resourceId": "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Authorization/roleAssignments/previous",
            "changeType": "Create"}]}
        self.assertEqual(0, self.run_preview())
        self.assertTrue(self.component("infra")["resources"])
        self.results["infra"] = RUNNER.PlanError("AZURE_COMMAND_FAILED")
        self.assertEqual(1, self.run_preview())
        self.assertEqual("failed", self.component("infra")["status"])
        self.assertEqual([], self.component("infra")["resources"])

    def test_failed_what_if_is_incomplete_and_does_not_prevent_classic_scope_preview(self):
        self.results["infra"] = RUNNER.PlanError("AZURE_COMMAND_FAILED")
        self.assertEqual(1, self.run_preview())
        self.assertEqual("failed", self.component("infra")["status"])
        self.assertFalse(self.report()["complete"])
        self.args.scope = "classic"
        self.assertEqual(0, self.run_preview())
        self.assertEqual("complete", self.component("classic")["status"])
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
            "elif args[:3] == ['network', 'nsg', 'list']: print('[]')",
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
        self.assertTrue(all(arguments[:1] == ["version"] or
                            arguments[:3] in (["deployment", "group", "what-if"], ["deployment", "sub", "what-if"], ["network", "nsg", "list"])
                            for arguments in invocations))


if __name__ == "__main__":
    unittest.main()
