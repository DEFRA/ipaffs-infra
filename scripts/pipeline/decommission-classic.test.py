#!/usr/bin/env python3

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch


source = Path(__file__).with_name("decommission-classic.py")
spec = importlib.util.spec_from_file_location("decommission_classic", source)
decommission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decommission)

SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
OTHER_SUBSCRIPTION = "22222222-2222-2222-2222-222222222222"
GROUP = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/example"
SERVER = f"{GROUP}/providers/Microsoft.Sql/servers/legacy"
DATABASE = f"{SERVER}/databases/example-green"
EXTENSION = f"{SERVER}/providers/Microsoft.Insights/diagnosticSettings/settings"
ABSENT = "ERROR: (ResourceNotFound) The resource could not be found\n"


class CheckedInListsTests(unittest.TestCase):
    def test_lists_have_valid_ids_for_their_classic_subscriptions(self):
        lists = Path(__file__).with_name("decommission-classic") / "lists"
        subscriptions = {
            "snd": "e716414f-1f8e-48f1-8f56-65f35cfdafb6",
            "tst": "00f1225e-37c2-4c7b-bc71-634164b667c6",
        }
        for environment, subscription in subscriptions.items():
            with self.subTest(environment=environment):
                decommission.read_resources(lists / f"{environment}.txt", subscription)


class DecommissionTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(TemporaryDirectory())
        self.resources = Path(directory) / "resources.txt"
        self.plan = Path(directory) / "plan.json"
        self.current = {DATABASE, SERVER}
        self.account_id = SUBSCRIPTION
        self.check_failures = {}
        self.delete_failures = {}
        self.stuck = set()
        self.reads = []
        self.deletes = []
        self.az = self.enterContext(patch.object(decommission.subprocess, "run", side_effect=self.fake_az))
        self.enterContext(patch.object(decommission.time, "sleep"))
        self.resources.write_text(f"# Database before server\n{DATABASE}\n\n{SERVER}\n", encoding="utf-8")

    def fake_az(self, arguments, **kwargs):
        self.assertEqual("az", arguments[0])
        self.assertEqual(SUBSCRIPTION, arguments[arguments.index("--subscription") + 1])
        command = arguments[1:3]
        if command == ["account", "show"]:
            return subprocess.CompletedProcess(arguments, 0, self.account_id, "")
        resource_id = arguments[arguments.index("--ids") + 1]
        if command == ["resource", "show"]:
            self.reads.append(resource_id)
            if resource_id in self.check_failures:
                code, error = self.check_failures[resource_id]
                return subprocess.CompletedProcess(arguments, code, "", error)
            if resource_id in self.current:
                return subprocess.CompletedProcess(arguments, 0, resource_id, "")
            return subprocess.CompletedProcess(arguments, 3, "", ABSENT)
        if command == ["resource", "delete"]:
            self.deletes.append(resource_id)
            if resource_id not in self.stuck:
                self.current.remove(resource_id)
            code, error = self.delete_failures.get(resource_id, (0, ""))
            return subprocess.CompletedProcess(arguments, code, "", error)
        self.fail(f"Unexpected Azure CLI command: {arguments}")

    def execute(self, mode):
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            status = decommission.main([mode, str(self.resources), SUBSCRIPTION, "--plan-file", str(self.plan)])
        return status, output.getvalue(), errors.getvalue()

    def plan_successfully(self):
        status, output, errors = self.execute("plan")
        self.assertEqual(0, status, errors)
        self.assertEqual([], self.deletes)
        return output

    def test_plan_is_read_only_and_records_state_in_list_order(self):
        self.resources.write_text(f"{EXTENSION}\n{DATABASE}\n{SERVER}\n", encoding="utf-8")
        output = self.plan_successfully()
        self.assertIn(f"already gone\tMicrosoft.Insights/diagnosticSettings\t{EXTENSION}", output)
        self.assertIn(f"exists\tMicrosoft.Sql/servers/databases\t{DATABASE}", output)
        self.assertIn("3 listed, 2 exist, 1 already gone, 0 checks failed", output)
        self.assertEqual([EXTENSION, DATABASE, SERVER], self.reads)
        self.assertEqual({
            "subscriptionId": SUBSCRIPTION,
            "resources": [{"id": EXTENSION, "exists": False}, {"id": DATABASE, "exists": True},
                          {"id": SERVER, "exists": True}],
        }, json.loads(self.plan.read_text(encoding="utf-8")))

    def test_deletes_in_order_and_reruns_without_deletes(self):
        self.plan_successfully()
        self.reads.clear()
        status, output, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([DATABASE, SERVER], self.deletes)
        self.assertEqual([DATABASE, SERVER, DATABASE, SERVER], self.reads)
        self.assertIn("2 listed, 2 deleted, 0 already deleted", output)

        self.deletes.clear()
        status, output, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([], self.deletes)
        self.assertIn("2 listed, 0 deleted, 2 already deleted", output)

    def test_empty_allowlist_is_valid(self):
        self.resources.write_text("# Inventory pending\n", encoding="utf-8")
        self.assertIn("0 listed, 0 exist", self.plan_successfully())
        status, output, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertIn("0 listed, 0 deleted", output)
        self.assertEqual([], self.reads)
        self.assertEqual([], self.deletes)

    def test_invalid_allowlists_are_rejected_before_any_azure_call(self):
        for invalid in (GROUP, f"{SERVER}/databases/*", f"{SERVER}/databases/..",
                        f"{SERVER}/databases/%2e%2e", SERVER.upper(),
                        SERVER.replace(SUBSCRIPTION, OTHER_SUBSCRIPTION)):
            with self.subTest(invalid=invalid):
                self.resources.write_text(f"{SERVER}\n{invalid}\n", encoding="utf-8")
                status, _, errors = self.execute("plan")
                self.assertEqual(1, status, errors)
                self.assertIn(f"{self.resources}:2:", errors)
                self.az.assert_not_called()

    def test_incorrect_subscription_fails_before_resource_checks(self):
        self.account_id = OTHER_SUBSCRIPTION
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn("returned a different subscription", errors)
        self.assertEqual([], self.reads)
        self.assertFalse(self.plan.exists())

    def test_unexpected_lookup_errors_block_deletion(self):
        self.plan_successfully()
        for code, error in ((1, "ERROR: (AuthorizationFailed) Access denied"),
                            (3, "ERROR: (ProviderNotFound) Provider unavailable")):
            with self.subTest(error=error):
                self.check_failures[SERVER] = code, error
                status, _, errors = self.execute("delete")
                self.assertEqual(1, status)
                self.assertIn(f"Check {SERVER}: {error}", errors)
                self.assertEqual([], self.deletes)

    def test_changed_allowlist_blocks_deletion(self):
        self.plan_successfully()
        self.resources.write_text(f"{SERVER}\n{DATABASE}\n", encoding="utf-8")
        self.az.reset_mock()
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn("Plan does not match the ordered resource list", errors)
        self.az.assert_not_called()

    def test_appearance_after_plan_blocks_all_deletions(self):
        self.current.remove(SERVER)
        self.plan_successfully()
        self.current.add(SERVER)
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"Resource appeared after the plan: {SERVER}", errors)
        self.assertEqual([], self.deletes)

    def test_concurrent_removal_after_preflight_is_idempotent(self):
        self.plan_successfully()
        self.delete_failures[DATABASE] = (
            1, "INFO: (ResourceNotFound) The resource could not be found\n"
               "ERROR: Some resources failed to be deleted (run with `--verbose` for more information):\n",
        )
        status, output, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertIn(f"Already deleted {DATABASE}", output)
        self.assertIn("2 listed, 1 deleted, 1 already deleted", output)
        self.assertEqual([DATABASE, SERVER], self.deletes)

    def test_delete_rejection_stops_before_next_resource(self):
        self.plan_successfully()
        self.delete_failures[DATABASE] = 1, "ERROR: (ScopeLocked) Azure rejected the deletion"
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"Delete {DATABASE}: ERROR: (ScopeLocked)", errors)
        self.assertEqual([DATABASE], self.deletes)

    def test_delete_success_must_be_verified_before_next_resource(self):
        self.plan_successfully()
        self.stuck.add(DATABASE)
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"Delete {DATABASE}: resource still exists after deletion", errors)
        self.assertEqual([DATABASE], self.deletes)


if __name__ == "__main__":
    unittest.main()
