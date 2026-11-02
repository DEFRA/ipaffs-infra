#!/usr/bin/env python3
"""Exercise the manual Library repair with all Azure and ADO operations stubbed."""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("monitoring_outputs", Path(__file__).with_name("refresh-classic-monitoring-outputs.py"))
outputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(outputs)

SUBSCRIPTION = "81ca326e-6270-418a-b764-e02a4ca60457"
RESOURCE_GROUP = "PREIMPINFRGP001"
RESOURCE_ID = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/{RESOURCE_GROUP}/providers/Microsoft.ServiceBus/namespaces/PREIMPINFSBS003"


class AzureStub:
    def __init__(self):
        self.calls = []
        self.namespace = "PREIMPINFSBS003"
        self.resource = {"id": RESOURCE_ID, "name": self.namespace, "type": "Microsoft.ServiceBus/namespaces"}
        self.groups = [{"id": 123, "name": "PRE", "type": "Vsts"}]
        self.variables = {
            outputs.VARIABLE_NAMES[0]: {"value": "PREIMPINFSBS002", "isSecret": False},
            outputs.VARIABLE_NAMES[1]: {"value": RESOURCE_ID.replace("003", "002"), "isSecret": False},
        }
        self.ignore_updates = False

    def __call__(self, args):
        self.calls.append(args)
        if args[:2] == ["bicep", "build-params"]:
            Path(args[args.index("--outfile") + 1]).write_text(json.dumps({
                "parameters": {"serviceBusParams": {"value": {"namespaceName": self.namespace}}},
            }))
            return None
        if args[:2] == ["resource", "show"]:
            return self.resource
        if args[:3] == ["pipelines", "variable-group", "list"]:
            return copy.deepcopy(self.groups)
        if args[:4] == ["pipelines", "variable-group", "variable", "list"]:
            return copy.deepcopy(self.variables)
        if args[:4] == ["pipelines", "variable-group", "variable", "update"]:
            if not self.ignore_updates:
                self.variables[args[args.index("--name") + 1]]["value"] = args[args.index("--value") + 1]
            return None
        raise AssertionError(f"Unexpected Azure/ADO operation: {args[:4]}")

    def writes(self):
        return [args for args in self.calls if "update" in args or "create" in args or "delete" in args]


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.summary = Path(self.directory.name) / "summary.md"
        self.azure = AzureStub()
        self.values = {
            "CLASSIC_SUBSCRIPTION_ID": SUBSCRIPTION,
            "CLASSIC_RESOURCE_GROUP": RESOURCE_GROUP,
            "ADO_ORG_URL": "https://dev.azure.com/example",
            "ADO_PROJECT": "test-project",
            "AZURE_DEVOPS_EXT_PAT": "stub-token-never-printed",
            "BUILD_SOURCEBRANCH": "refs/heads/codex/refresh-classic-monitoring-outputs",
            "BUILD_REASON": "Manual",
        }

    def run_refresh(self, mode="plan", environment="PRE"):
        with contextlib.redirect_stdout(io.StringIO()) as stdout:
            result = outputs.refresh(environment, mode, self.summary, Path("/repo"), self.values, self.azure)
        self.assertNotIn("stub-token", stdout.getvalue())
        return result

    def test_plan_compiles_checked_in_parameters_and_performs_zero_writes(self):
        self.assertEqual(self.run_refresh()[outputs.VARIABLE_NAMES[0]], "PREIMPINFSBS003")
        self.assertEqual([], self.azure.writes())
        compiler = self.azure.calls[0]
        self.assertEqual("/repo/bicep/envs/pre/30-classic.bicepparam", compiler[compiler.index("--file") + 1])
        arm = next(args for args in self.azure.calls if args[:2] == ["resource", "show"])
        self.assertEqual(SUBSCRIPTION, arm[arm.index("--subscription") + 1])
        self.assertEqual(RESOURCE_ID, arm[arm.index("--ids") + 1])
        summary = self.summary.read_text()
        self.assertIn("Plan only; no changes applied", summary)
        self.assertIn("PREIMPINFSBS002", summary)
        self.assertIn("PREIMPINFSBS003", summary)

    def test_dev_reads_snd_parameters_and_updates_dev_library_group(self):
        self.azure.groups[0]["name"] = "DEV"
        self.run_refresh(environment="DEV")
        self.assertIn("/repo/bicep/envs/snd/30-classic.bicepparam", self.azure.calls[0])
        group_list = next(args for args in self.azure.calls if args[:3] == ["pipelines", "variable-group", "list"])
        self.assertEqual("DEV", group_list[group_list.index("--group-name") + 1])

    def test_all_supported_environments_use_corresponding_parameter_files(self):
        for environment, classic_environment in outputs.ENVIRONMENTS.items():
            with self.subTest(environment=environment):
                self.azure = AzureStub()
                self.azure.groups[0]["name"] = environment
                self.run_refresh(environment=environment)
                self.assertIn(f"/repo/bicep/envs/{classic_environment}/30-classic.bicepparam", self.azure.calls[0])
                self.assertEqual([], self.azure.writes())

    def test_apply_updates_exactly_two_existing_variables_then_reads_back(self):
        self.run_refresh(mode="apply")
        updates = self.azure.writes()
        self.assertEqual(2, len(updates))
        self.assertEqual(set(outputs.VARIABLE_NAMES), {args[args.index("--name") + 1] for args in updates})
        for args in updates:
            self.assertEqual(["pipelines", "variable-group", "variable", "update"], args[:4])
            self.assertEqual("123", args[args.index("--group-id") + 1])
            self.assertEqual("none", args[args.index("--output") + 1])
        self.assertEqual(2, len([args for args in self.azure.calls if args[:4] == ["pipelines", "variable-group", "variable", "list"]]))
        self.assertIn("Applied and read back", self.summary.read_text())

    def test_apply_rejects_other_branches_and_non_manual_runs_before_any_commands(self):
        for branch, reason in (("refs/heads/main", "Manual"), ("refs/heads/topic", "Manual"),
                               ("refs/heads/codex/refresh-classic-monitoring-outputs-extra", "Manual"),
                               ("refs/pull/428/merge", "PullRequest"),
                               (outputs.REPAIR_BRANCH, "PullRequest"), (outputs.REPAIR_BRANCH, "IndividualCI"),
                               (outputs.REPAIR_BRANCH, "BatchedCI"), (outputs.REPAIR_BRANCH, "Schedule"),
                               (outputs.REPAIR_BRANCH, "")):
            with self.subTest(branch=branch, reason=reason):
                self.values.update(BUILD_SOURCEBRANCH=branch, BUILD_REASON=reason)
                with self.assertRaisesRegex(ValueError, "manual PRE run from refs/heads/codex/refresh-classic-monitoring-outputs"):
                    self.run_refresh(mode="apply")
                self.assertEqual([], self.azure.calls)

    def test_apply_rejects_other_environments_before_any_commands(self):
        for environment in ("DEV", "TST", "PRD"):
            with self.subTest(environment=environment):
                with self.assertRaisesRegex(ValueError, "manual PRE run"):
                    self.run_refresh(mode="apply", environment=environment)
                self.assertEqual([], self.azure.calls)

    def test_apply_rejects_other_subscription_or_resource_group_before_any_commands(self):
        for key, value in (("CLASSIC_SUBSCRIPTION_ID", "22222222-2222-2222-2222-222222222222"),
                           ("CLASSIC_RESOURCE_GROUP", "OTHER-RG")):
            with self.subTest(key=key, value=value):
                original = self.values[key]
                self.values[key] = value
                with self.assertRaisesRegex(ValueError, "reviewed PRE classic subscription and resource group"):
                    self.run_refresh(mode="apply")
                self.values[key] = original
                self.assertEqual([], self.azure.calls)

    def test_apply_rejects_different_configured_namespace_before_arm_and_library_commands(self):
        self.azure.namespace = "PREIMPINFSBS004"
        with self.assertRaisesRegex(ValueError, "reviewed namespace PREIMPINFSBS003"):
            self.run_refresh(mode="apply")
        self.assertEqual(1, len(self.azure.calls))
        self.assertEqual(["bicep", "build-params"], self.azure.calls[0][:2])

    def test_plan_is_allowed_from_pr_but_cannot_write(self):
        self.values.update(BUILD_SOURCEBRANCH="refs/pull/1/merge", BUILD_REASON="PullRequest")
        self.run_refresh()
        self.assertEqual([], self.azure.writes())

    def test_missing_or_wrong_scope_namespace_prevents_all_library_writes(self):
        for resource in (None, {}, {**self.azure.resource, "id": RESOURCE_ID.replace(SUBSCRIPTION, "22222222-2222-2222-2222-222222222222")},
                         {**self.azure.resource, "id": RESOURCE_ID.replace(RESOURCE_GROUP, "OTHER-RG")},
                         {**self.azure.resource, "name": "PREIMPINFSBS002"},
                         {**self.azure.resource, "type": "Microsoft.Storage/storageAccounts"}):
            with self.subTest(resource=resource):
                self.azure = AzureStub()
                self.azure.resource = resource
                with self.assertRaisesRegex(ValueError, "namespace is missing|ARM ID"):
                    self.run_refresh(mode="apply")
                self.assertEqual([], self.azure.writes())
                self.assertFalse(any(args[0] == "pipelines" for args in self.azure.calls))

    def test_missing_or_invalid_compiled_namespace_prevents_arm_and_library_calls(self):
        for namespace in (None, "", "$(namespace)", "other/namespace"):
            with self.subTest(namespace=namespace):
                self.azure = AzureStub()
                self.azure.namespace = namespace
                with self.assertRaisesRegex(ValueError, "serviceBusParams.namespaceName"):
                    self.run_refresh(mode="apply")
                self.assertEqual(1, len(self.azure.calls))

    def test_missing_ambiguous_or_non_writable_group_prevents_writes(self):
        for groups in ([], self.azure.groups * 2, [{"id": 123, "name": "PRE", "type": "AzureKeyVault"}],
                       [{"id": 123, "name": "PRD", "type": "Vsts"}]):
            with self.subTest(groups=groups):
                self.azure = AzureStub()
                self.azure.groups = groups
                with self.assertRaisesRegex(ValueError, "exactly one existing writable"):
                    self.run_refresh(mode="apply")
                self.assertEqual([], self.azure.writes())

    def test_both_variables_must_exist_and_be_non_secret_before_first_write(self):
        for name in outputs.VARIABLE_NAMES:
            for invalid in (None, {"value": None}, {"value": "hidden", "isSecret": True}):
                with self.subTest(name=name, invalid=invalid):
                    self.azure = AzureStub()
                    self.azure.variables[name] = invalid
                    with self.assertRaisesRegex(ValueError, "Existing non-secret Library variable"):
                        self.run_refresh(mode="apply")
                    self.assertEqual([], self.azure.writes())

    def test_apply_skips_matching_values_and_still_verifies_them(self):
        self.azure.variables[outputs.VARIABLE_NAMES[0]]["value"] = "PREIMPINFSBS003"
        self.azure.variables[outputs.VARIABLE_NAMES[1]]["value"] = RESOURCE_ID
        self.run_refresh(mode="apply")
        self.assertEqual([], self.azure.writes())
        self.assertIn("already match", self.summary.read_text())

    def test_failed_readback_does_not_claim_success(self):
        self.azure.ignore_updates = True
        with self.assertRaisesRegex(ValueError, "Library readback did not match"):
            self.run_refresh(mode="apply")
        self.assertNotIn("Applied and read back", self.summary.read_text())
        self.assertIn("review the current values", self.summary.read_text())

    def test_missing_contract_or_invalid_subscription_is_rejected_before_commands(self):
        for key, value in (("CLASSIC_SUBSCRIPTION_ID", "not-a-uuid"), ("CLASSIC_SUBSCRIPTION_ID", "00000000-0000-0000-0000-000000000000"),
                           ("CLASSIC_RESOURCE_GROUP", "$(classicResourceGroupName)"), ("CLASSIC_RESOURCE_GROUP", "wrong/group"),
                           ("AZURE_DEVOPS_EXT_PAT", "")):
            with self.subTest(key=key, value=value):
                original = self.values[key]
                self.values[key] = value
                with self.assertRaises(ValueError):
                    self.run_refresh(mode="apply")
                self.values[key] = original
                self.assertEqual([], self.azure.calls)


if __name__ == "__main__":
    unittest.main()
