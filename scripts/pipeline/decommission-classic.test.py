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
from urllib.parse import parse_qs, urlsplit


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
OTHER_APP = f"{GROUP}/providers/Microsoft.Web/sites/other-app"
SLOT = f"{APP}/slots/staging"
APP_PLAN = f"{GROUP}/providers/Microsoft.Web/serverfarms/legacy-plan"
OTHER_APP_PLAN = f"{GROUP}/providers/Microsoft.Web/serverfarms/other-plan"
SUBNET = f"{GROUP}/providers/Microsoft.Network/virtualNetworks/vnet/subnets/subnet"
OTHER_SUBNET = f"{GROUP}/providers/Microsoft.Network/virtualNetworks/vnet/subnets/other"
AUTOSCALE = f"{GROUP}/providers/Microsoft.Insights/autoscalesettings/legacy-plan"
AUTOSCALE_QUERY = ("{id:id,enabled:properties.enabled,target:properties.targetResourceUri,"
                   "profiles:properties.profiles}")
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
        self.autoscale_setting = {
            "id": AUTOSCALE,
            "enabled": False,
            "target": APP_PLAN,
            "profiles": [{
                "name": "default",
                "capacity": {"minimum": "1", "maximum": "2", "default": "1"},
                "rules": [{
                    "metricTrigger": {
                        "metricName": "CpuPercentage", "metricResourceUri": APP_PLAN,
                        "timeGrain": "PT1M", "statistic": "Average", "timeWindow": "PT5M",
                        "timeAggregation": "Average", "operator": "GreaterThan", "threshold": 70,
                    },
                    "scaleAction": {"direction": "Increase", "type": "ChangeCount", "value": "1", "cooldown": "PT5M"},
                }],
            }],
        }
        self.before_autoscale_read = lambda: None
        self.apply_autoscale_patch = True
        self.app_states = {APP: "Stopped", SLOT: "Stopped"}
        self.app_subnets = {}
        self.slot_response = None
        self.slot_reads = 0
        self.vnet_responses = {}
        self.vnet_reads = []
        self.detaches = []
        self.detach_effect = lambda resource_id: self.app_subnets.pop(resource_id)
        self.plan_pages = {}
        self.plan_reads = []
        self.after_delete = lambda resource_id: None
        self.check_failures = {}
        self.delete_failures = {}
        self.stuck = set()
        self.reads = []
        self.deletes = []
        self.mutations = []
        self.enterContext(patch.dict(decommission.os.environ, {}, clear=True))
        self.az = self.enterContext(patch.object(decommission.subprocess, "run", side_effect=self.fake_az))
        self.enterContext(patch.object(decommission.time, "sleep"))
        self.resources.write_text(f"# Database before server\n{DATABASE}\n\n{SERVER}\n", encoding="utf-8")

    def fake_az(self, arguments, **kwargs):
        self.assertEqual("az", arguments[0])
        self.assertEqual(SUBSCRIPTION, arguments[arguments.index("--subscription") + 1])
        command = arguments[1:3]
        if command == ["account", "show"]:
            return subprocess.CompletedProcess(arguments, 0, self.account_id, "")
        if command == ["rest", "--method"]:
            url = urlsplit(arguments[arguments.index("--url") + 1])
            self.assertFalse(url.netloc)
            if arguments[3] == "patch":
                self.assertEqual(AUTOSCALE, url.path)
                self.assertEqual({"api-version": ["2022-10-01"]}, parse_qs(url.query))
                self.assertEqual({"properties": {"enabled": False, "profiles": self.autoscale_setting["profiles"]}},
                                 json.loads(arguments[arguments.index("--body") + 1]))
                self.assertNotIn(self.autoscale_setting["target"], self.current)
                self.mutations.append(("patch", AUTOSCALE))
                if self.apply_autoscale_patch:
                    self.autoscale_setting["enabled"] = False
                return subprocess.CompletedProcess(arguments, 0, "", "")
            self.assertEqual("get", arguments[3])
            self.assertEqual(f"{APP_PLAN}/sites", url.path)
            token = parse_qs(url.query).get("$skipToken", [None])[0]
            self.plan_reads.append(token)
            page = {"value": [{"id": APP}] if APP in self.current else [], "nextLink": None}
            page = self.plan_pages.get(token, page)
            if callable(page):
                page = page()
            return subprocess.CompletedProcess(arguments, 0, json.dumps(page), "")
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
            self.assertIn("[].{subnetId:vnetResourceId,certThumbprint:certThumbprint}", arguments)
            subnet_id = self.app_subnets.get(resource_id)
            integrations = [{"subnetId": subnet_id, "certThumbprint": None}] if subnet_id else []
            response = self.vnet_responses.get(resource_id, integrations)
            if isinstance(response, str):
                return subprocess.CompletedProcess(arguments, 1, "", response)
            return subprocess.CompletedProcess(arguments, 0, json.dumps(response), "")
        if arguments[1:4] == ["webapp", "vnet-integration", "remove"]:
            resource_id = SLOT if "--slot=staging" in arguments else APP
            self.detaches.append(resource_id)
            self.detach_effect(resource_id)
            return subprocess.CompletedProcess(arguments, 0, "", "")
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
                if query == AUTOSCALE_QUERY:
                    self.assertEqual(AUTOSCALE, resource_id)
                    self.before_autoscale_read()
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(self.autoscale_setting), "")
                if query == "{id:id,state:properties.state,subnetId:properties.virtualNetworkSubnetId}":
                    app = {"id": resource_id, "state": self.app_states.get(resource_id),
                           "subnetId": self.app_subnets.get(resource_id)}
                    return subprocess.CompletedProcess(arguments, 0, json.dumps(app), "")
                self.assertEqual("id", query)
                return subprocess.CompletedProcess(arguments, 0, resource_id, "")
            return subprocess.CompletedProcess(arguments, 3, "", ABSENT)
        if command in (["resource", "delete"], ["webapp", "delete"]):
            if resource_id in (APP, SLOT):
                self.assertEqual(["webapp", "delete"], command)
            self.deletes.append(resource_id)
            self.mutations.append(("delete", resource_id))
            if resource_id not in self.stuck:
                self.current.remove(resource_id)
            self.after_delete(resource_id)
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
        self.assertEqual([], self.detaches)
        self.assertEqual([], self.mutations)
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

    def test_unknown_or_legacy_vnet_integration_blocks_deletion(self):
        self.current = {DATABASE, APP}
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        cases = (
            ([{"subnetId": SUBNET.rsplit("/subnets/", 1)[0], "certThumbprint": "legacy-cert"}],
             "native integration does not match an exact regional subnet"),
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
                self.assertEqual([], self.detaches)
                self.assertEqual([], self.deletes)

    def test_plan_previews_exact_subnet_and_delete_disconnects_only_listed_slot(self):
        self.current = {APP, SLOT, APP_PLAN}
        self.app_subnets.update({APP: OTHER_SUBNET, SLOT: SUBNET})
        self.resources.write_text(f"{SLOT}\n", encoding="utf-8")
        self.assertIn(f"{SLOT} will disconnect from {SUBNET}", self.plan_successfully())
        self.assertEqual([{"id": SLOT, "exists": True, "subnetId": SUBNET}],
                         json.loads(self.plan.read_text())["resources"])
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([SLOT], self.detaches)
        self.assertEqual([SLOT], self.deletes)
        self.assertEqual({APP: OTHER_SUBNET}, self.app_subnets)
        self.assertEqual({APP, APP_PLAN}, self.current)
        self.assertEqual([SLOT] * 4, self.vnet_reads)

    def test_subnet_drift_blocks_all_mutation_in_preflight(self):
        self.current = {DATABASE, APP}
        self.app_subnets[APP] = SUBNET
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.app_subnets[APP] = OTHER_SUBNET
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"VNet integration changed after the plan: {APP}", errors)
        self.assertEqual([], self.detaches)
        self.assertEqual([], self.deletes)

    def test_subnet_drift_after_preflight_blocks_disconnect(self):
        self.current = {DATABASE, APP}
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.after_delete = lambda resource_id: self.app_subnets.update({APP: SUBNET})
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"VNet integration changed after the plan: {APP}", errors)
        self.assertEqual([], self.detaches)
        self.assertEqual([DATABASE], self.deletes)

    def test_app_reconnected_after_disconnected_preflight_requires_new_plan(self):
        self.current = {DATABASE, APP}
        self.app_subnets[APP] = SUBNET
        self.resources.write_text(f"{DATABASE}\n{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.app_subnets.clear()
        self.after_delete = lambda resource_id: self.app_subnets.update({APP: SUBNET})
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"VNet integration changed after the plan: {APP}", errors)
        self.assertEqual([], self.detaches)
        self.assertEqual([DATABASE], self.deletes)

    def test_disconnect_must_leave_app_stopped_and_without_vnet(self):
        self.current = {APP}
        self.app_subnets[APP] = SUBNET
        self.resources.write_text(f"{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.detach_effect = lambda resource_id: None
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn("VNet integration still present", errors)
        self.assertEqual([], self.deletes)

        def restart_app(resource_id):
            self.app_subnets.pop(resource_id)
            self.app_states[resource_id] = "Running"

        self.detach_effect = restart_app
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn("App Service or slot must be Stopped", errors)
        self.assertEqual([], self.deletes)

    def test_retry_after_successful_disconnect_skips_second_disconnect(self):
        self.current = {APP}
        self.app_subnets[APP] = SUBNET
        self.resources.write_text(f"{APP}\n", encoding="utf-8")
        self.plan_successfully()
        self.stuck.add(APP)
        self.delete_failures[APP] = 1, "ERROR: (ScopeLocked) Azure rejected the deletion"
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn("ScopeLocked", errors)
        self.assertEqual([APP], self.detaches)
        self.assertIn(APP, self.current)

        self.stuck.remove(APP)
        self.delete_failures.clear()
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([APP], self.detaches)
        self.assertNotIn(APP, self.current)

    def test_plan_requires_earlier_member_then_deletes_only_when_empty(self):
        self.current = {APP, APP_PLAN}
        self.resources.write_text(f"{APP_PLAN}\n{APP}\n", encoding="utf-8")
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(f"app must be present and listed earlier: {APP}", errors)
        self.assertFalse(self.plan.exists())
        self.resources.write_text(f"{APP}\n{APP_PLAN}\n", encoding="utf-8")
        self.plan_successfully()
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([APP, APP_PLAN], self.deletes)
        self.deletes.clear()
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([], self.deletes)

    def test_new_plan_member_blocks_plan_delete_after_app_delete(self):
        self.current = {APP, APP_PLAN}
        self.resources.write_text(f"{APP}\n{APP_PLAN}\n", encoding="utf-8")
        self.plan_successfully()
        self.plan_pages[None] = lambda: {
            "value": [{"id": OTHER_APP if self.deletes else APP}], "nextLink": None,
        }
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"plan must be empty before deletion; found {OTHER_APP}", errors)
        self.assertEqual([APP], self.deletes)

    def test_retry_after_rejected_plan_delete_skips_the_deleted_app(self):
        self.current = {APP, APP_PLAN}
        self.resources.write_text(f"{APP}\n{APP_PLAN}\n", encoding="utf-8")
        self.plan_successfully()
        self.stuck.add(APP_PLAN)
        self.delete_failures[APP_PLAN] = 1, "ERROR: (ScopeLocked) Azure rejected the deletion"
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn("ScopeLocked", errors)
        self.assertEqual({APP_PLAN}, self.current)

        self.stuck.clear()
        self.delete_failures.clear()
        self.deletes.clear()
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([APP_PLAN], self.deletes)

    def test_plan_checks_authoritative_later_membership_pages(self):
        self.current = {APP_PLAN}
        self.resources.write_text(f"{APP_PLAN}\n", encoding="utf-8")
        path = f"{APP_PLAN}/sites"
        self.plan_pages[None] = {
            "value": [], "nextLink": f"https://management.azure.com{path}?api-version=2025-05-01&$skipToken=a%2Bb",
        }
        self.plan_pages["a+b"] = {"value": [{"id": OTHER_APP}], "nextLink": None}
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(OTHER_APP, errors)
        self.assertEqual([None, "a+b"], self.plan_reads)
        self.assertFalse(self.plan.exists())

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
        for enabled, message in (
                (True, "only disabled autoscale settings can be deleted"),
                ("false", "Azure did not return a boolean enabled state"),
                (None, "Azure did not return a boolean enabled state")):
            with self.subTest(enabled=enabled):
                self.autoscale_setting["enabled"] = enabled
                status, _, errors = self.execute("plan")
                self.assertEqual(1, status)
                self.assertIn(message, errors)

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
        self.assertEqual([("delete", DATABASE), ("delete", AUTOSCALE)], self.mutations)

    def test_enabled_autoscale_is_disabled_and_deleted_after_its_approved_plan(self):
        self.current = {APP_PLAN, AUTOSCALE}
        self.autoscale_setting["enabled"] = True
        self.resources.write_text(f"{APP_PLAN}\n{AUTOSCALE}\n", encoding="utf-8")
        output = self.plan_successfully()
        self.assertIn("disabl", output.lower())
        entries = json.loads(self.plan.read_text(encoding="utf-8"))["resources"]
        self.assertEqual(APP_PLAN, entries[1]["targetPlanId"])
        self.assertIs(True, entries[1]["disableAfterPlan"])
        self.assertTrue(self.autoscale_setting["enabled"])

        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([("delete", APP_PLAN), ("patch", AUTOSCALE), ("delete", AUTOSCALE)], self.mutations)
        self.assertEqual(set(), self.current)

    def test_enabled_autoscale_requires_an_earlier_target_and_scaling_profiles(self):
        self.current = {APP_PLAN, AUTOSCALE}
        self.autoscale_setting["enabled"] = True
        self.resources.write_text(f"{AUTOSCALE}\n{APP_PLAN}\n", encoding="utf-8")
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(AUTOSCALE, errors)
        self.assertFalse(self.plan.exists())
        self.assertEqual([], self.mutations)

        self.resources.write_text(f"{APP_PLAN}\n{AUTOSCALE}\n", encoding="utf-8")
        self.autoscale_setting["profiles"] = []
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn("Azure did not return its scaling profiles", errors)
        self.assertFalse(self.plan.exists())
        self.assertEqual([], self.mutations)

    def test_autoscale_rule_read_must_return_the_exact_id(self):
        self.current = {AUTOSCALE}
        self.autoscale_setting["id"] = f"{AUTOSCALE}-other"
        self.resources.write_text(f"{AUTOSCALE}\n", encoding="utf-8")
        status, _, errors = self.execute("plan")
        self.assertEqual(1, status)
        self.assertIn(AUTOSCALE, errors)
        self.assertFalse(self.plan.exists())
        self.assertEqual([], self.mutations)

    def test_autoscale_stays_untouched_if_target_reappears_or_changes_after_plan_delete(self):
        self.resources.write_text(f"{APP_PLAN}\n{AUTOSCALE}\n", encoding="utf-8")
        for change in ("recreated", "retargeted"):
            with self.subTest(change=change):
                self.current = {APP_PLAN, AUTOSCALE}
                self.autoscale_setting.update(enabled=True, target=APP_PLAN)
                self.mutations.clear()
                self.deletes.clear()
                self.before_autoscale_read = lambda: None
                self.plan_successfully()

                def change_target_after_plan_delete():
                    if APP_PLAN not in self.deletes:
                        return
                    if change == "recreated":
                        self.current.add(APP_PLAN)
                    else:
                        self.autoscale_setting["target"] = OTHER_APP_PLAN

                self.before_autoscale_read = change_target_after_plan_delete
                status, _, errors = self.execute("delete")
                self.assertEqual(1, status)
                self.assertIn(AUTOSCALE, errors)
                self.assertEqual([("delete", APP_PLAN)], self.mutations)
                self.assertIn(AUTOSCALE, self.current)
                self.assertTrue(self.autoscale_setting["enabled"])

    def test_autoscale_delete_rechecks_target_after_disabling_the_rule(self):
        self.current = {APP_PLAN, AUTOSCALE}
        self.autoscale_setting["enabled"] = True
        self.resources.write_text(f"{APP_PLAN}\n{AUTOSCALE}\n", encoding="utf-8")
        self.plan_successfully()

        def recreate_target_after_patch():
            if ("patch", AUTOSCALE) in self.mutations:
                self.current.add(APP_PLAN)

        self.before_autoscale_read = recreate_target_after_patch
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(f"target plan still exists: {APP_PLAN}", errors)
        self.assertEqual([("delete", APP_PLAN), ("patch", AUTOSCALE)], self.mutations)

    def test_autoscale_patch_requires_disabled_readback_and_can_retry_after_plan_delete(self):
        self.current = {APP_PLAN, AUTOSCALE}
        self.autoscale_setting["enabled"] = True
        self.resources.write_text(f"{APP_PLAN}\n{AUTOSCALE}\n", encoding="utf-8")
        self.plan_successfully()
        self.apply_autoscale_patch = False
        status, _, errors = self.execute("delete")
        self.assertEqual(1, status)
        self.assertIn(AUTOSCALE, errors)
        self.assertEqual([("delete", APP_PLAN), ("patch", AUTOSCALE)], self.mutations)
        self.assertEqual({AUTOSCALE}, self.current)

        self.apply_autoscale_patch = True
        self.mutations.clear()
        status, _, errors = self.execute("delete")
        self.assertEqual(0, status, errors)
        self.assertEqual([("patch", AUTOSCALE), ("delete", AUTOSCALE)], self.mutations)

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


class PipelineSignInTests(unittest.TestCase):
    ENVIRON = {
        "SYSTEM_OIDCREQUESTURI": "https://dev.azure.com/org/project/_apis/distributedtask/hubs/build/plans/p/jobs/j/oidctoken",
        "SYSTEM_ACCESSTOKEN": "pipeline-token",
        "AZURESUBSCRIPTION_SERVICE_CONNECTION_ID": "33333333-3333-3333-3333-333333333333",
        "AZURESUBSCRIPTION_CLIENT_ID": "44444444-4444-4444-4444-444444444444",
        "AZURESUBSCRIPTION_TENANT_ID": "55555555-5555-5555-5555-555555555555",
    }

    def setUp(self):
        self.now = 0
        self.logins = []
        self.requests = []
        self.enterContext(patch.object(decommission.subprocess, "run", side_effect=self.fake_az))
        self.enterContext(patch.object(decommission, "urlopen", side_effect=self.fake_urlopen))
        self.enterContext(redirect_stdout(io.StringIO()))

    def fake_az(self, arguments, **kwargs):
        self.assertEqual(["az", "login", "--service-principal"], arguments[:3])
        self.logins.append(arguments)
        return subprocess.CompletedProcess(arguments, 0, "", "")

    def fake_urlopen(self, request, timeout):
        self.requests.append(request)
        return io.BytesIO(json.dumps({"oidcToken": f"oidc-{len(self.requests)}"}).encode())

    def sign_in(self, environ=None):
        return decommission.PipelineSignIn(self.ENVIRON if environ is None else environ, clock=lambda: self.now)

    def test_outside_a_pipeline_the_existing_sign_in_is_kept(self):
        self.sign_in({}).renew_if_due()
        self.assertEqual([], self.logins)
        self.assertEqual([], self.requests)

    def test_signs_in_with_a_fresh_federated_token_then_again_after_the_interval(self):
        sign_in = self.sign_in()
        sign_in.renew_if_due()
        self.now = decommission.SIGN_IN_INTERVAL - 1
        sign_in.renew_if_due()
        self.assertEqual(1, len(self.logins))
        self.now = decommission.SIGN_IN_INTERVAL
        sign_in.renew_if_due()
        self.assertEqual(2, len(self.logins))

        request = self.requests[0]
        self.assertEqual("POST", request.get_method())
        self.assertEqual("Bearer pipeline-token", request.get_header("Authorization"))
        query = parse_qs(urlsplit(request.full_url).query)
        self.assertEqual({"api-version": ["7.1"], "serviceConnectionId": [self.ENVIRON[
            "AZURESUBSCRIPTION_SERVICE_CONNECTION_ID"]]}, query)
        login = self.logins[1]
        self.assertEqual("oidc-2", login[login.index("--federated-token") + 1])
        self.assertEqual(self.ENVIRON["AZURESUBSCRIPTION_CLIENT_ID"], login[login.index("--username") + 1])
        self.assertEqual(self.ENVIRON["AZURESUBSCRIPTION_TENANT_ID"], login[login.index("--tenant") + 1])

    def test_missing_pipeline_variables_fail_before_any_azure_call(self):
        environ = dict(self.ENVIRON)
        del environ["SYSTEM_ACCESSTOKEN"]
        with self.assertRaisesRegex(decommission.DecommissionError, "SYSTEM_ACCESSTOKEN"):
            self.sign_in(environ)
        self.assertEqual([], self.requests)

    def test_token_endpoint_without_a_token_stops_the_run(self):
        self.enterContext(patch.object(decommission, "urlopen", return_value=io.BytesIO(b"{}")))
        with self.assertRaisesRegex(decommission.DecommissionError, "no token returned"):
            self.sign_in().renew_if_due()
        self.assertEqual([], self.logins)


if __name__ == "__main__":
    unittest.main()
