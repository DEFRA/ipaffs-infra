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
APP = f"{GROUP}/providers/Microsoft.Web/sites/legacy-app"
SLOT = f"{APP}/slots/staging"
APP_PLAN = f"{GROUP}/providers/Microsoft.Web/serverfarms/legacy-plan"
AUTOSCALE = f"{GROUP}/providers/Microsoft.Insights/autoscalesettings/legacy-plan"
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
        self.autoscale_setting = {"enabled": False, "target": APP_PLAN}
        self.app_states = {APP: "Stopped", SLOT: "Stopped"}
        self.slot_response = None
        self.slot_reads = 0
        self.vnet_responses = {}
        self.vnet_reads = []
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
        if command[0] == "webapp":
            self.assertIn("--resource-group=example", arguments)
            self.assertIn("--name=legacy-app", arguments)
        if arguments[1:5] == ["webapp", "deployment", "slot", "list"]:
            self.assertIn("[].{id:id,state:state}", arguments)
            self.assertNotIn("--slot=staging", arguments)
            self.slot_reads += 1
            slots = [{"id": SLOT, "state": self.app_states[SLOT]}] if SLOT in self.current else []
            response = self.slot_response() if self.slot_response else slots
            if isinstance(response, str):
                return subprocess.CompletedProcess(arguments, 1, "", response)
            return subprocess.CompletedProcess(arguments, 0, json.dumps(response), "")
        if arguments[1:4] == ["webapp", "vnet-integration", "list"]:
            resource_id = SLOT if "--slot=staging" in arguments else APP
            self.vnet_reads.append(resource_id)
            response = self.vnet_responses.get(resource_id, [])
            if isinstance(response, str):
                return subprocess.CompletedProcess(arguments, 1, "", response)
            return subprocess.CompletedProcess(arguments, 0, json.dumps(response), "")
        if command == ["webapp", "delete"]:
            self.assertIn("--keep-empty-plan", arguments)
            self.assertIn("--keep-metrics", arguments)
            resource_id = SLOT if "--slot=staging" in arguments else APP
        else:
            resource_id = arguments[arguments.index("--ids") + 1]
        if command == ["resource", "show"]:
            self.reads.append(resource_id)
            if resource_id in self.check_failures:
                code, error = self.check_failures[resource_id]
                return subprocess.CompletedProcess(arguments, code, "", error)
            if resource_id in self.current:
                query = arguments[arguments.index("--query") + 1]
                if query == "{enabled:properties.enabled,target:properties.targetResourceUri}":
                    self.assertEqual(AUTOSCALE, resource_id)
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(self.autoscale_setting), "")
                if query == "{id:id,state:properties.state}":
                    app = {"id": resource_id, "state": self.app_states.get(resource_id)}
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(app), "")
                self.assertEqual("id", query)
                return subprocess.CompletedProcess(arguments, 0, resource_id, "")
            return subprocess.CompletedProcess(arguments, 3, "", ABSENT)
        if command in (["resource", "delete"], ["webapp", "delete"]):
            if resource_id in (APP, SLOT):
                self.assertEqual(["webapp", "delete"], command)
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

    def test_delete_app_and_slot_preserves_the_unlisted_hosting_plan(self):
        self.current = {APP, SLOT, APP_PLAN}
        self.resources.write_text(f"{SLOT}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        status, output, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([SLOT, APP], self.deletes)
        self.assertEqual({APP_PLAN}, self.current)
        self.assertIn("2 listed, 2 deleted, 0 already deleted", output)
        self.assertEqual(3, self.slot_reads)
        self.assertEqual([SLOT, APP] * 3, self.vnet_reads)

    def test_app_or_slot_must_still_be_stopped_when_delete_starts(self):
        self.current = {DATABASE, SLOT, APP}
        self.resources.write_text(f"{DATABASE}\n{SLOT}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        for resource, state in ((APP, "Running"), (SLOT, None)):
            with self.subTest(resource=resource):
                self.app_states[resource] = state
                status, _, errors = self.execute("delete")
                self.assertEqual(1, status)
                self.assertIn(f"Check {resource}: App Service or slot must be Stopped", errors)
                self.assertEqual([], self.deletes)
                self.app_states[resource] = "Stopped"

    def test_vnet_integration_or_unknown_state_blocks_deletion(self):
        self.current = {DATABASE, APP}
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        cases = (
            ([{"id": "vnet-connection"}], "disconnect VNet integration before deletion"),
            (None, "Azure did not return a VNet integration list"),
            ("ERROR: (AuthorizationFailed) Access denied", "AuthorizationFailed"),
        )
        for response, message in cases:
            with self.subTest(message=message):
                self.vnet_responses[APP] = response
                status, _, errors = self.execute("delete")
                self.assertEqual(1, status)
                self.assertIn(f"Check App Service VNet integrations for {APP}", errors)
                self.assertIn(message, errors)
                self.assertEqual([], self.deletes)

    def test_app_state_lookup_error_blocks_deletion(self):
        self.current = {DATABASE, APP}
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.check_failures[APP] = (1, "ERROR: (AuthorizationFailed) Access denied")
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"Check {APP}: ERROR: (AuthorizationFailed)", errors)
        self.assertEqual([], self.deletes)

    def test_live_slot_must_be_listed_earlier(self):
        self.current = {SLOT, APP}
        for resources in ([APP], [APP, SLOT]):
            with self.subTest(resources=resources):
                self.resources.write_text("\n".join(resources), encoding="utf-8")
                status, _, errors = self.execute("plan")
                self.assertEqual(1, status)
                self.assertIn(f"slot must be present and listed earlier: {SLOT}", errors)
                self.assertFalse(self.plan.exists())

    def test_site_must_have_no_slots_immediately_before_its_delete(self):
        self.current = {SLOT, APP}
        self.resources.write_text(f"{SLOT}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        new_slot = f"{APP}/slots/new-slot"
        self.slot_response = lambda: [{"id": new_slot if self.deletes else SLOT, "state": "Stopped"}]
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"must be empty before deletion; found {new_slot}", errors)
        self.assertEqual([SLOT], self.deletes)

    def test_parent_slot_list_must_confirm_the_earlier_slot_is_stopped(self):
        self.current = {APP, SLOT}
        self.resources.write_text(f"{SLOT}\n{APP}\n", encoding="utf-8")
        self.slot_response = lambda: [{"id": SLOT, "state": "Running"}]
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(f"slot must be Stopped: {SLOT}", errors)
        self.assertFalse(self.plan.exists())

    def test_plan_refuses_unknown_slot_inventory(self):
        self.current = {APP}
        self.resources.write_text(f"{APP}\n", encoding="utf-8")
        cases = (
            (None, "did not return a slot list"),
            ([{"id": None}], "invalid slot ID"),
            ("ERROR: (AuthorizationFailed) Access denied", "AuthorizationFailed"),
        )
        for response, message in cases:
            with self.subTest(message=message):
                self.slot_response = lambda: response
                status, _, errors = self.execute("plan")
                self.assertEqual(1, status)
                self.assertIn(message, errors)
                self.assertFalse(self.plan.exists())

    def test_plan_requires_a_disabled_autoscale_with_a_confirmed_absent_target(self):
        self.current = {AUTOSCALE}
        self.resources.write_text(f"{AUTOSCALE}\n", encoding="utf-8")
        for enabled in (True, "false", None):
            with self.subTest(enabled=enabled):
                self.autoscale_setting["enabled"] = enabled
                status, _, errors = self.execute("plan")
                self.assertEqual(1, status)
                self.assertIn("only disabled autoscale settings can be deleted", errors)

        self.autoscale_setting["enabled"] = False
        self.autoscale_setting["target"] = APP_PLAN.replace(SUBSCRIPTION, OTHER_SUBSCRIPTION)
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn("target must be an App Service plan in the same subscription", errors)

        self.autoscale_setting["target"] = APP_PLAN
        self.check_failures[APP_PLAN] = (1, "ERROR: (AuthorizationFailed) Access denied")
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(f"Check {APP_PLAN}: ERROR: (AuthorizationFailed)", errors)
        self.assertFalse(self.plan.exists())
        self.assertEqual([], self.deletes)

    def test_delete_rechecks_that_the_autoscale_target_has_not_reappeared(self):
        self.current = {DATABASE, AUTOSCALE}
        self.resources.write_text(f"{DATABASE}\n{AUTOSCALE}\n", encoding="utf-8")
        self.assertIn(f"{AUTOSCALE} is disabled and its target plan is absent: {APP_PLAN}", self.plan_successfully())
        self.current.add(APP_PLAN)
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"target plan still exists: {APP_PLAN}", errors)
        self.assertEqual([], self.deletes)

        self.current.remove(APP_PLAN)
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([DATABASE, AUTOSCALE], self.deletes)

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
