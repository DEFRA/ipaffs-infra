"""Keep creation-origin metadata quiet while retaining real component changes."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import infrastructure_plan_comparison as COMPARISON
import infrastructure_plan_insights as INSIGHTS
import infrastructure_plan_markdown as MARKDOWN
import infrastructure_plan_metadata as METADATA
import infrastructure_plan_report as REPORT


TYPE = "Microsoft.Insights/components"
RID = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/" + TYPE + "/insights"
ORIGIN = {"Flow_Type": "Bluefield", "Request_Source": "rest"}
ABSENT = object()


def field(name, before=None, after=ABSENT, action="Create"):
    result = {"path": "properties." + name, "propertyChangeType": action, "before": before}
    if after is not ABSENT:
        result["after"] = after
    return result


def component_change():
    return {"resourceId": RID, "changeType": "Modify",
            "before": {"type": TYPE, "id": RID, "name": "insights", "properties": {}},
            "after": {"type": TYPE, "id": RID, "name": "insights", "apiVersion": "2020-02-02",
                      "properties": dict(ORIGIN)},
            "delta": [field(name, after=value) for name, value in ORIGIN.items()]}


def components(change):
    return [{"name": "infra", "status": "complete", "result": {"status": "Succeeded", "changes": [change]}}]


class InsightsOriginPropertyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, raw, environment="TST", potential=False):
        source = components(raw)
        if potential:
            source[0]["result"] = {"status": "Succeeded", "changes": [], "potentialChanges": [raw]}
        destination = self.root / environment
        report = REPORT.write_environment_report(destination, {
            "environment": environment, "commit": "a" * 40, "buildId": "42",
            "sourceRef": "refs/heads/main", "generatedAt": "2026-11-04T10:00:00Z"}, source)
        self.summary = (destination / "summary.md").read_text()
        self.details = (destination / "change-details.md").read_text()
        self.serialized = (destination / "plan.json").read_text()
        return report

    def assert_reviewable(self, raw, potential=False):
        resource = REPORT._resource(raw, potential=potential)
        self.assertFalse(resource["metadataOnly"])
        self.assertFalse(any(f.get("metadataReason") == INSIGHTS.METADATA_REASON for f in resource["fields"]))
        return resource

    def test_exact_origin_additions_are_explained_background_and_input_is_immutable(self):
        for delta_before in (None, ABSENT):
            raw = component_change()
            if delta_before is ABSENT:
                for entry in raw["delta"]:
                    del entry["before"]
            original = copy.deepcopy(raw)
            report = self.write(raw)
            resource = report["components"][0]["resources"][0]
            self.assertEqual(original, raw)
            self.assertEqual(0, report["resourceTotals"]["Modify"])
            self.assertTrue(resource["metadataOnly"])
            self.assertFalse(resource["unresolved"])
            self.assertEqual("Modify", resource["changeType"])
            self.assertNotIn("| Update | Application Insights", self.summary)
            self.assertIn("creation-origin additions are background metadata", self.details)
            for entry in resource["fields"]:
                self.assertEqual(INSIGHTS.METADATA_REASON, entry["metadataReason"])
                self.assertEqual(REPORT.MISSING, entry["before"])
                self.assertEqual(ORIGIN[entry["path"].split(".")[-1]], entry["after"])
                self.assertEqual("Create", entry["changeType"])
                self.assertIn(MARKDOWN.md(entry["path"]), self.details)

    def test_each_canonical_field_has_independent_proof(self):
        for name in ORIGIN:
            raw = component_change()
            raw["delta"] = [entry for entry in raw["delta"] if entry["path"] == "properties." + name]
            raw["after"]["properties"] = {name: ORIGIN[name]}
            self.assertTrue(REPORT._resource(raw)["metadataOnly"])

    def test_noncanonical_or_unresolved_values_and_changed_origin_fields_stay_visible(self):
        for value in (None, False, 1, {}, [], "bluefield", "REST", "PRIVATE-ORIGIN-VALUE", "[reference('future')]"):
            raw = component_change()
            raw["delta"][0]["after"] = raw["after"]["properties"]["Flow_Type"] = value
            item = REPORT._resource(raw)
            self.assertFalse(item["fields"][0]["metadataOnly"], repr(value))
            self.assertNotIn("PRIVATE-ORIGIN-VALUE", json.dumps(item))
        for action in ("Modify", "Delete", "NoEffect", "Unknown"):
            raw = component_change()
            for entry in raw["delta"]:
                entry["propertyChangeType"] = action
            self.assert_reviewable(raw)

    def test_before_null_existing_values_and_case_aliases_do_not_prove_absence(self):
        for value in (None, "Bluefield", "PRIVATE-PREVIOUS-ORIGIN", "[reference('previous')]"):
            raw = component_change()
            raw["before"]["properties"] = {"Flow_Type": value, "Request_Source": value}
            self.assert_reviewable(raw)
        raw = component_change()
        raw["before"]["properties"] = {"flow_type": "Bluefield", "request_source": "rest"}
        self.assert_reviewable(raw)

    def test_snapshots_must_agree_with_delta_and_resource_identity(self):
        mutations = [
            lambda x: x.pop("before"), lambda x: x.pop("after"),
            lambda x: x["before"].pop("properties"), lambda x: x["after"].pop("properties"),
            lambda x: x["before"].update(properties=None),
            lambda x: x["after"].update(properties={}),
            lambda x: x["after"].update(type="Microsoft.Storage/storageAccounts"),
            lambda x: x["after"].update(id=RID + "-other"),
            lambda x: x["before"].update(name="another-component"),
            lambda x: x["after"].update(apiVersion="1900-01-01"),
            lambda x: x.update(resourceId="unavailable"),
            lambda x: x.update(resourceId=RID + "/nested/other"),
        ]
        for mutate in mutations:
            raw = component_change()
            mutate(raw)
            self.assert_reviewable(raw)
        for side in ("before", "after"):
            for canonical in ("id", "name", "type", "properties", "apiVersion"):
                raw = component_change()
                snapshot = raw[side]
                snapshot[canonical.upper()] = snapshot.pop(canonical, "PRIVATE-ALIAS")
                self.assert_reviewable(raw)

    def test_lone_structural_aliases_and_duplicate_paths_fail_closed(self):
        for alias, value in (("Before", "PRIVATE-ALIAS"), ("Children", [{"path": "WorkspaceResourceId"}]),
                             ("ChildDelta", []), ("Path", "properties.other"),
                             ("PropertyChangeType", "Modify"), ("After", "PRIVATE-ALIAS")):
            raw = component_change()
            for entry in raw["delta"]:
                entry[alias] = value
            self.assert_reviewable(raw)
        raw = component_change()
        for entry in raw["delta"]:
            del entry["before"]
            entry["Before"] = "PRIVATE-ALIAS"
        self.assert_reviewable(raw)
        for duplicate in (copy.deepcopy(component_change()["delta"][0]),
                          {"path": "properties.flow_type", "propertyChangeType": "Create", "after": "Bluefield"}):
            raw = component_change()
            raw["delta"].append(duplicate)
            self.assertFalse(REPORT._resource(raw)["fields"][0]["metadataOnly"])

    def test_coarse_parent_bags_cannot_hide_unreported_configuration_changes(self):
        raw = component_change()
        raw["delta"] = [{"path": "properties", "propertyChangeType": "Modify",
                         "before": {"WorkspaceResourceId": "PRIVATE-OLD"},
                         "after": {**ORIGIN, "WorkspaceResourceId": "PRIVATE-NEW"},
                         "children": raw["delta"]}]
        self.assert_reviewable(raw)
        raw = component_change()
        raw["delta"].append({"path": "properties", "propertyChangeType": "Modify", "after": dict(ORIGIN)})
        self.assert_reviewable(raw)

    def test_sparse_origin_only_delta_cannot_erase_other_snapshot_configuration(self):
        for key in ("WorkspaceResourceId", "DisableLocalAuth", "unknownConfiguration"):
            raw = component_change()
            raw["before"]["properties"][key] = "PRIVATE-OLD"
            raw["after"]["properties"][key] = "PRIVATE-NEW"
            report = self.write(raw)
            item = report["components"][0]["resources"][0]
            self.assertFalse(item["metadataOnly"])
            self.assertTrue(item["unresolved"])
            self.assertFalse(report["complete"])
            self.assertEqual(1, report["resourceTotals"]["Modify"])
            self.assertNotIn("PRIVATE-", self.serialized + self.summary + self.details)
            self.assertIn("| Update | Application Insights", self.summary)
            comparison = COMPARISON.analyze_comparison(None, report, {})
            self.assertEqual("unresolved-coverage", comparison["resources"][0]["classification"])
        raw = component_change()
        raw["before"]["kind"], raw["after"]["kind"] = "web", "other"
        self.assert_reviewable(raw)
        for before, after in ((False, 0), (True, 1), (1, 1.0), (float("nan"), float("nan"))):
            raw = component_change()
            raw["before"]["properties"]["DisableLocalAuth"] = before
            raw["after"]["properties"]["DisableLocalAuth"] = after
            self.assert_reviewable(raw)
        for changed in ("PRIVATE-CHANGED", None, "rest"):
            raw = component_change()
            raw["delta"] = [raw["delta"][0]]
            raw["before"]["properties"]["Request_Source"] = "PRIVATE-OLD"
            raw["after"]["properties"]["Request_Source"] = changed
            self.assert_reviewable(raw)

    def test_origin_only_resource_allows_unchanged_configuration_and_created_date(self):
        raw = component_change()
        for side in ("before", "after"):
            raw[side]["properties"]["WorkspaceResourceId"] = "PRIVATE-UNCHANGED"
            raw[side]["location"] = "uksouth"
            raw[side]["tags"] = {"Environment": "TST", "CreatedDate": side}
        raw["delta"].append({"path": "tags.CreatedDate", "propertyChangeType": "Modify",
                             "before": "before", "after": "after"})
        self.assertTrue(REPORT._resource(raw)["metadataOnly"])

    def test_transparent_parent_is_supported_but_leaf_children_are_not(self):
        raw = component_change()
        raw["delta"] = [{"path": "properties", "propertyChangeType": "Modify", "children": raw["delta"]}]
        self.assertTrue(REPORT._resource(raw)["metadataOnly"])
        for children in ([{"path": "unexpected", "propertyChangeType": "Delete"}], {}, "PRIVATE-CHILDREN"):
            raw = component_change()
            for entry in raw["delta"]:
                entry["children"] = children
            self.assert_reviewable(raw)
        for action in ("Create", "Delete", "Array", "NoEffect", "Unknown"):
            raw = component_change()
            raw["delta"] = [{"path": "properties", "propertyChangeType": action, "children": raw["delta"]}]
            self.assert_reviewable(raw)

    def test_case_aliases_of_raw_change_keys_do_not_establish_evidence(self):
        for canonical in ("resourceId", "changeType", "before", "after", "delta"):
            for duplicate in (False, True):
                raw = component_change()
                raw[canonical.upper()] = raw[canonical] if duplicate else raw.pop(canonical)
                self.assert_reviewable(raw)

    def test_resource_creates_deletes_and_potential_actions_remain_actions(self):
        for action in ("Create", "Delete", "Deploy", "Unknown"):
            raw = component_change()
            raw["changeType"] = action
            self.assert_reviewable(raw)
        self.assert_reviewable(component_change(), potential=True)

    def test_mixed_workspace_auth_network_and_unknown_changes_remain_actionable(self):
        for name in ("WorkspaceResourceId", "DisableLocalAuth", "publicNetworkAccessForIngestion", "unknownProperty"):
            raw = component_change()
            raw["before"]["properties"][name] = "PRIVATE-OLD"
            raw["after"]["properties"][name] = "[reference('PRIVATE-FUTURE')]"
            raw["delta"].append(field(name, "PRIVATE-OLD", "[reference('PRIVATE-FUTURE')]", "Modify"))
            report = self.write(raw)
            resource = report["components"][0]["resources"][0]
            self.assertEqual(1, report["resourceTotals"]["Modify"])
            self.assertFalse(resource["metadataOnly"])
            self.assertTrue(resource["unresolved"])
            self.assertEqual(2, sum(f["metadataOnly"] for f in resource["fields"]))
            self.assertFalse(resource["fields"][-1]["metadataOnly"])
            self.assertNotIn("Flow Type", self.summary)
            self.assertNotIn("Request Source", self.summary)
            for secret in ("PRIVATE-OLD", "PRIVATE-FUTURE"):
                self.assertNotIn(secret, self.serialized + self.summary + self.details)
            compared = COMPARISON.analyze_comparison(None, report, {})
            item = compared["resources"][0]
            self.assertNotEqual("background", item["classification"])
            self.assertEqual(["background", "background", "unresolved-coverage"],
                             [f["classification"] for f in item["fields"]])

    def test_sanitized_recheck_rejects_forged_flags_values_and_resource_ids(self):
        original = REPORT._resource(component_change())
        for key, value in (("metadataReason", "untrusted"), ("before", None), ("after", "changed"),
                           ("unresolved", True), ("changeType", "Delete"), ("metadataOnly", False)):
            resource = copy.deepcopy(original)
            for entry in resource["fields"]:
                entry[key] = value
            self.assertFalse(METADATA.is_metadata_only(resource), (key, value))
            self.assertEqual(2, len(MARKDOWN._runtime_fields(resource)))
        for rid in ("unavailable", RID + "/nested/other", RID.replace("components", "other")):
            resource = copy.deepcopy(original)
            resource["resourceId"] = rid
            self.assertFalse(METADATA.is_metadata_only(resource))
            self.assertEqual(2, len(MARKDOWN._runtime_fields(resource)))
            self.assertFalse(COMPARISON._background(resource))

    def test_real_authentication_change_stays_security_review_and_noeffect_stays_background(self):
        raw = component_change()
        raw["before"]["properties"]["DisableLocalAuth"] = False
        raw["after"]["properties"]["DisableLocalAuth"] = True
        raw["delta"].append(field("DisableLocalAuth", False, True, "Modify"))
        report = self.write(raw)
        self.assertEqual(1, report["resourceTotals"]["Modify"])
        self.assertIn("local authentication setting", self.summary)
        comparison = COMPARISON.analyze_comparison(None, report, {})
        resource = comparison["resources"][0]
        self.assertEqual("policy-security-review", resource["classification"])
        self.assertEqual("policy-security-review", resource["fields"][-1]["classification"])
        raw = component_change()
        raw["delta"].append(field("Application_Type", "web", "web", "NoEffect"))
        resource = REPORT._resource(raw)
        self.assertFalse(resource["metadataOnly"])
        self.assertTrue(MARKDOWN.is_no_effect_only(resource))
        self.assertTrue(COMPARISON._background(resource))

    def test_resource_level_unresolved_flag_is_not_erased_by_background_fields(self):
        resource = REPORT._resource(component_change())
        resource["unresolved"] = True
        self.assertFalse(METADATA.is_metadata_only(resource))
        self.assertFalse(COMPARISON._background(resource))
        resource["fields"].append({"path": "sku.tier", "changeType": "NoEffect"})
        self.assertFalse(MARKDOWN.is_no_effect_only(resource))

    def test_combined_cli_preserves_mixed_review_and_audit_fields(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            raw = component_change()
            raw["before"]["properties"]["WorkspaceResourceId"] = "PRIVATE-WORKSPACE"
            raw["after"]["properties"]["WorkspaceResourceId"] = "[reference('future')]"
            raw["delta"].append(field("WorkspaceResourceId", "PRIVATE-WORKSPACE", "[reference('future')]", "Modify"))
            self.write(raw, environment)
        output = self.root / "combined"
        result = subprocess.run([sys.executable, str(Path(REPORT.__file__)), "--combine", str(self.root),
                                 "--output-dir", str(output), "--azure-pipelines"], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        combined = json.loads((output / "plan.json").read_text())
        self.assertFalse(combined["comparisonAvailable"])
        for environment in combined["environments"]:
            self.assertEqual(1, environment["review"]["changes"]["Application Insights"]["Modify"])
        for comparison in combined["devComparison"]:
            resource = comparison["resources"][0]
            self.assertEqual("unresolved-coverage", resource["classification"])
            self.assertEqual(INSIGHTS.METADATA_REASON, resource["fields"][0]["reasonCode"])
        summary = (output / "summary.md").read_text()
        self.assertIn("Application Insights: insights", summary)
        self.assertIn("properties.WorkspaceResourceId", json.dumps(combined))
        self.assertNotIn("Add property to config: Flow Type", summary)
        self.assertNotIn("Add property to config: Request Source", summary)
        self.assertNotIn("PRIVATE-WORKSPACE", summary + json.dumps(combined))

    def test_combined_cli_keeps_sparse_snapshot_changes_as_incomplete_actions(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            raw = component_change()
            raw["before"]["properties"]["WorkspaceResourceId"] = "PRIVATE-OLD"
            raw["after"]["properties"]["WorkspaceResourceId"] = "PRIVATE-NEW"
            self.write(raw, environment)
        output = self.root / "combined"
        result = subprocess.run([sys.executable, str(Path(REPORT.__file__)), "--combine", str(self.root),
                                 "--output-dir", str(output)], capture_output=True, text=True)
        self.assertEqual(1, result.returncode, result.stderr)
        report = json.loads((output / "plan.json").read_text())
        self.assertFalse(report["complete"])
        for environment in report["environments"]:
            self.assertEqual(1, environment["totals"]["Modify"])
            self.assertEqual(1, environment["review"]["changes"]["Application Insights"]["Modify"])
        for comparison in report["devComparison"]:
            self.assertEqual("unresolved-coverage", comparison["resources"][0]["classification"])
        summary = (output / "summary.md").read_text()
        self.assertIn("| Application Insights | 1 update | 1 update | 1 update | 1 update |", summary)
        self.assertNotIn("PRIVATE-", summary + json.dumps(report))


if __name__ == "__main__":
    unittest.main()
