"""Exercise release reporting with realistic ARM results and hostile payload values."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import infrastructure_plan_comparison as COMPARISON


SCRIPT = Path(__file__).with_name("infrastructure_plan_report.py")
SPEC = importlib.util.spec_from_file_location("infrastructure_plan_report", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
RID = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/ipaffs-tst/providers/"
COMMIT = "a" * 40
GENERATED_IDENTITY_IDS = {"clientId": "22222222-2222-4222-8222-222222222222",
                          "principalId": "33333333-3333-4333-8333-333333333333",
                          "tenantId": "44444444-4444-4444-8444-444444444444"}


def resource(resource_type="Microsoft.ContainerRegistry/registries", name="ipaffstst", change_type="Modify", delta=None):
    item = {"resourceId": RID + resource_type + "/" + name, "changeType": change_type,
            "before": {"type": resource_type}, "after": {"type": resource_type}}
    if delta is not None:
        item["delta"] = delta
    return item


def field(path, before, after, **extra):
    return {"path": path, "propertyChangeType": "Modify", "before": before, "after": after, **extra}


def component(changes=None, **overrides):
    return {"name": "infra", "label": "Infrastructure", "scope": "resource-group",
            "status": "complete", "result": {"status": "Succeeded", "changes": changes or []}, **overrides}


class InfrastructurePlanReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def report(self, components, environment="TST", commit=COMMIT):
        destination = self.directory / environment
        result = REPORT.write_environment_report(destination,
            {"environment": environment, "commit": commit, "sourceRef": "refs/heads/main", "buildId": "42", "generatedAt": "2026-11-03T10:20:00Z"}, components)
        self.markdown = (destination / "summary.md").read_text()
        self.serialized = (destination / "plan.json").read_text()
        self.detail_markdown = (destination / "change-details.md").read_text()
        self.assertEqual(json.loads(self.serialized), result)
        return result

    def test_safe_configuration_changes_are_readable_and_risk_labels_are_qualified(self):
        registry = resource(delta=[field("sku.name", "Standard", "Premium"),
                                   field("properties.publicNetworkAccess", "Enabled", "Disabled")])
        plan = self.report([component([registry])])
        self.assertTrue(plan["complete"])
        self.assertEqual(plan["resourceTotals"]["Modify"], 1)
        fields = plan["components"][0]["resources"][0]["fields"]
        self.assertEqual((fields[0]["before"], fields[0]["after"]), ("Standard", "Premium"))
        self.assertIn("public network access", self.markdown)
        self.assertIn("Potential impact: network", self.detail_markdown)

    def test_credentials_payloads_and_diagnostic_messages_never_escape(self):
        secrets = ["PASSWORD-SENSITIVE", "CONNECTION-SENSITIVE", "OUTPUT-SENSITIVE", "ERROR-SENSITIVE", "DIAGNOSTIC-SENSITIVE"]
        change = resource(delta=[field("properties.adminPassword", secrets[0], secrets[0]),
                                 field("properties.connectionString", secrets[1], secrets[1]),
                                 field("properties.customConfiguration", {"harmless": secrets[2]}, [secrets[2]])])
        change["after"]["properties"] = {"password": secrets[0]}
        raw = {"status": "Succeeded", "changes": [change], "outputs": secrets[2],
               "diagnostics": [{"message": secrets[4], "code": secrets[3]}]}
        plan = self.report([component(result=raw)])
        self.assertFalse(plan["complete"])
        self.assertEqual(plan["components"][0]["diagnosticCount"], 1)
        self.assertEqual(plan["executionStatus"], "succeeded")
        for secret in secrets:
            self.assertNotIn(secret, self.serialized + self.markdown + self.detail_markdown)
        self.assertIn("[withheld]", self.serialized)

    def test_nested_array_deltas_preserve_meaningful_leaf_changes(self):
        subnet = resource("Microsoft.Network/virtualNetworks", "vnet", delta=[{
            "path": "properties.subnets", "propertyChangeType": "Array", "children": [{
                "path": "0", "propertyChangeType": "Modify", "children": [
                    field("properties.addressPrefix", "10.0.0.0/24", "10.0.1.0/24"),
                    field("properties.privateEndpointNetworkPolicies", "Enabled", "Disabled"),
                ]}]}])
        plan = self.report([component([subnet])])
        fields = plan["components"][0]["resources"][0]["fields"]
        self.assertEqual([entry["path"] for entry in fields], [
            "properties.subnets.0.properties.addressPrefix",
            "properties.subnets.0.properties.privateEndpointNetworkPolicies"])
        self.assertNotIn("10.0.0.0/24", self.serialized)
        self.assertIn("network", plan["components"][0]["resources"][0]["potentialImpact"])

    def test_created_date_noise_is_separate_without_hiding_real_siblings(self):
        timestamp = resource(name="onlydate", delta=[field("tags.CreatedDate", "yesterday", "today")])
        mixed = resource(name="realchange", delta=[field("tags.CreatedDate", "yesterday", "today"), field("sku.name", "Basic", "Premium")])
        plan = self.report([component([timestamp, mixed])])
        resources = plan["components"][0]["resources"]
        self.assertTrue(resources[0]["metadataOnly"])
        self.assertFalse(resources[1]["metadataOnly"])
        self.assertEqual(plan["totals"]["Modify"], 2)
        self.assertIn("Metadata-only updates: 1", self.markdown)
        self.assertNotIn("onlydate", self.markdown)
        self.assertIn("realchange", self.markdown)
        self.assertNotIn("yesterday", self.serialized + self.markdown)

    def test_known_created_date_expression_keeps_details_without_invalidating_assessment(self):
        timestamp = resource(delta=[field("tags.CreatedDate", "yesterday", "[utcNow()]")])
        plan = self.report([component([timestamp])])
        self.assertTrue(plan["complete"])
        self.assertEqual(plan["unknowns"], 0)
        detail = plan["components"][0]["resources"][0]
        self.assertTrue(detail["fields"][0]["unresolved"])
        self.assertEqual(detail["fields"][0]["after"], "[unresolved expression]")
        self.assertFalse(detail["unresolved"])
        real_unknown = resource(name="realunknown", delta=[field("sku.name", "Basic", "[reference('future').sku.name]")])
        self.assertFalse(self.report([component([timestamp, real_unknown])])["complete"])

    def test_combined_overview_counts_created_date_modifications_separately(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            timestamp = resource(delta=[field("tags.CreatedDate", "yesterday", "[utcNow()]")])
            plan = self.report([component([timestamp])], environment)
            self.assertEqual(plan["totals"]["Modify"], 1)
            self.assertEqual(plan["resourceTotals"]["Modify"], 0)
            self.assertEqual(plan["metadataOnlyTotals"]["Modify"], 1)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertTrue(combined["complete"])
        self.assertEqual(combined["environments"][0]["totals"]["Modify"], 0)
        self.assertEqual(combined["environments"][0]["metadataOnlyTotals"]["Modify"], 1)
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertIn("Metadata-only updates", summary)
        self.assertIn("| TST | 0 | 0 | 0 | 0 | Completed |", summary)
        self.assertIn("| TST | 0 | 0 | 1 |", summary)

    def managed_identity_change(self, name, before_scope="None", after_scope=None, **before_extras):
        """The coarse ARM property deletion that originally produced noisy rows."""
        properties = {**GENERATED_IDENTITY_IDS, "isolationScope": before_scope, **before_extras}
        proposed = {"isolationScope": after_scope} if after_scope is not None else None
        item = resource("Microsoft.ManagedIdentity/userAssignedIdentities", name, delta=[
            field("properties", properties, proposed,
                  propertyChangeType="Modify" if proposed is not None else "Delete"),
            field("tags.CreatedDate", "BEFORE-DATE-PRIVATE", "[utcNow()]")])
        item["before"]["properties"] = properties
        if proposed is not None:
            item["after"]["properties"] = proposed
        return item

    def test_generated_identity_properties_stay_background_through_environment_and_combined_reports(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            scope_only = resource("Microsoft.ManagedIdentity/userAssignedIdentities", "background-scope-only", delta=[
                field("properties", {"isolationScope": "None"}, None, propertyChangeType="Delete")])
            scope_only["before"]["properties"] = {"isolationScope": "None"}
            parts = [component(([self.managed_identity_change("background-generated-" + name)]
                                if name in {"classic", "infra"} else [])
                               + ([scope_only] if name == "infra" else []), name=name)
                     for name in sorted(COMPARISON.COMPONENTS)]
            plan = self.report(parts, environment)
            self.assertTrue(plan["complete"])
            self.assertEqual(3, plan["totals"]["Modify"], "Retain ARM's raw resource classifications")
            self.assertEqual(0, plan["resourceTotals"]["Modify"])
            self.assertEqual(3, plan["metadataOnlyTotals"]["Modify"])
            self.assertNotIn("background-generated-", self.markdown)
            self.assertNotIn("background-scope-only", self.markdown)
            normalized = next(item for part in plan["components"] for item in part["resources"]
                              if item["name"] == "background-scope-only")
            self.assertEqual("UNCHANGED_IDENTITY_SCOPE_DEFAULT", normalized["fields"][0]["metadataReason"])
            for secret in GENERATED_IDENTITY_IDS.values():
                self.assertNotIn(secret, self.serialized + self.markdown + self.detail_markdown)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertTrue(combined["complete"])
        self.assertFalse(combined["comparisonAvailable"], "Confirmed metadata needs no applied DEV baseline")
        for environment in combined["environments"]:
            self.assertEqual(0, environment["totals"]["Modify"])
            self.assertEqual(3, environment["metadataOnlyTotals"]["Modify"])
            self.assertEqual({}, environment["review"]["changes"])
        for comparison in combined["devComparison"]:
            self.assertEqual([], comparison["resources"])
            self.assertEqual(3, comparison["counts"]["backgroundResources"])
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertNotIn("background-generated-", summary)
        self.assertNotIn("background-scope-only", summary)
        self.assertNotIn("Remove property from config: resource properties", summary)

    def test_mixed_identity_scope_and_unknown_properties_stay_visible_after_combining(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            changes = [self.managed_identity_change("generated-only"),
                       self.managed_identity_change("restricted-scope-removed", before_scope="Regional"),
                       self.managed_identity_change("restricted-scope-added", after_scope="Regional"),
                       self.managed_identity_change("unknown-writable-property", futureSetting="DO-NOT-PUBLISH-FUTURE")]
            parts = [component(changes if name == "infra" else [], name=name)
                     for name in sorted(COMPARISON.COMPONENTS)]
            plan = self.report(parts, environment)
            self.assertEqual(4, plan["totals"]["Modify"])
            self.assertEqual(3, plan["resourceTotals"]["Modify"])
            self.assertEqual(1, plan["metadataOnlyTotals"]["Modify"])
            self.assertIn("restricted-scope-removed", self.markdown)
            self.assertIn("restricted-scope-added", self.markdown)
            self.assertIn("unknown-writable-property", self.markdown)
            self.assertNotIn("DO-NOT-PUBLISH-FUTURE", self.serialized + self.markdown + self.detail_markdown)
            self.assertNotIn("generated-only", self.markdown)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        for comparison in combined["devComparison"]:
            by_name = {item["name"]: item for item in comparison["resources"]}
            self.assertNotIn("generated-only", by_name)
            self.assertEqual(3, len(by_name))
            for name in ("restricted-scope-removed", "restricted-scope-added"):
                self.assertEqual("policy-security-review", by_name[name]["classification"])
                scope = next(entry for entry in by_name[name]["fields"] if entry["path"] == "properties.isolationScope")
                self.assertEqual("policy-security-review", scope["classification"])
            self.assertNotEqual("background", by_name["unknown-writable-property"]["classification"])
        self.assertIn("restricted-scope-removed", summary)
        self.assertIn("restricted-scope-added", summary)
        self.assertIn("unknown-writable-property", summary)
        self.assertNotIn("generated-only", summary)

    def test_forged_identity_metadata_flags_cannot_hide_scope_in_combined_action_tables(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([self.managed_identity_change("real-scope-change", after_scope="Regional")], name=name)
                         if name == "infra" else component([], name=name)
                         for name in sorted(COMPARISON.COMPONENTS)], environment)
            path = self.directory / environment / "plan.json"
            document = json.loads(path.read_text())
            for part in document["components"]:
                for item in part["resources"]:
                    item["metadataOnly"] = True
                    for entry in item["fields"]:
                        entry.update(metadataOnly=True, metadataReason="GENERATED_IDENTITY_PROPERTY")
            path.write_text(json.dumps(document))
            inputs.append(path)
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertIn("Managed identity |", summary)
        for comparison in combined["devComparison"]:
            self.assertEqual(1, comparison["counts"]["policySecurityResources"])
            self.assertEqual("real-scope-change", comparison["resources"][0]["name"])
        self.assertIn("real-scope-change", summary)

    def test_deployment_metadata_is_grouped_and_child_resource_is_still_prominent(self):
        wrapper = resource("Microsoft.Resources/deployments", "childmodule", "Modify", [field("tags.CreatedDate", "before", "after")])
        child = resource("Microsoft.Storage/storageAccounts", "storage", "Delete")
        plan = self.report([component([wrapper, child])])
        self.assertTrue(plan["complete"])
        self.assertEqual(plan["resourceTotals"]["Delete"], 1)
        self.assertEqual(plan["deploymentMetadataTotals"]["Modify"], 1)
        self.assertIn("Delete | Storage account: storage", self.markdown)
        self.assertNotIn("childmodule", self.markdown)
        self.assertIn("deletion", self.markdown)
        self.assertIn("storage/data", self.detail_markdown)

    def test_resource_group_creation_and_deletion_remain_real_changes(self):
        for change_type in ("Create", "Delete"):
            with self.subTest(change_type=change_type):
                group = {"resourceId": "/subscriptions/subscription/resourceGroups/new-group", "changeType": change_type}
                plan = self.report([component([group])])
                self.assertEqual(plan["resourceTotals"][change_type], 1)
                self.assertEqual(plan["deploymentMetadataTotals"][change_type], 0)
                self.assertIn(f"| {change_type} | Resource group: new-group", self.markdown)

    def test_input_digest_is_validated_and_current_input_coverage_is_fixed(self):
        digest = "0123456789abcdef" * 4
        plan = self.report([component([], inputDigest=digest)])
        self.assertEqual(plan["components"][0]["inputDigest"], digest)
        self.assertEqual(plan["metadata"]["parameterSource"], "candidate parameters with current Library identity inputs")
        plan = self.report([component([], inputDigest="SECRET-DIGEST")])
        self.assertIsNone(plan["components"][0]["inputDigest"])
        self.assertNotIn("SECRET-DIGEST", self.serialized)

    def test_rest_envelope_and_creation_values_are_supported_without_snapshots(self):
        created = resource("Microsoft.ContainerService/managedClusters", "cluster", "Create")
        created["after"].update({"sku": {"name": "Base", "capacity": 3}, "location": "uksouth",
                                "properties": {"agentPoolProfiles": [{"count": 2}], "password": "DO-NOT-LEAK", "enableRbacAuthorization": True}})
        raw = {"status": "Succeeded", "properties": {"changes": [created]}}
        plan = self.report([component(result=raw)])
        self.assertTrue(plan["complete"])
        self.assertIn('"after": 2', self.serialized)
        self.assertIn('"after": true', self.serialized)
        self.assertNotIn("DO-NOT-LEAK", self.serialized)
        self.assertNotIn('"agentPoolProfiles":', self.serialized)

    def test_unknown_unsupported_ignored_and_deploy_predictions_cannot_be_no_change(self):
        for change_type in ("Unsupported", "Ignore", "Deploy", "NewAzureChangeType"):
            with self.subTest(change_type=change_type):
                plan = self.report([component([resource(change_type=change_type)])])
                self.assertFalse(plan["complete"])
                self.assertGreater(plan["unknowns"], 0)
                self.assertNotIn("No resource changes predicted", self.markdown)
                self.assertIn("INCOMPLETE", self.markdown)

    def test_unresolved_expressions_make_assessment_incomplete_without_exposing_expression(self):
        expression = "[reference('/subscriptions/hidden-resource').sku.name]"
        unresolved = field("sku.name", "Basic", expression)
        plan = self.report([component([
            resource(name="unassessed-registry", delta=[unresolved]),
            resource(name="mixed-registry", delta=[
                unresolved, field("properties.publicNetworkAccess", "Enabled", "Disabled")]),
            resource(name="opaque-network-change", delta=[
                field("properties.networkAcls", {"defaultAction": "Deny"},
                      {"defaultAction": "Allow", "virtualNetworkRules": [expression]})]),
        ])])
        self.assertFalse(plan["complete"])
        self.assertEqual(3, plan["resourceTotals"]["Modify"])
        self.assertIn("2 updates to review", self.markdown)
        self.assertIn("Updates Azure could not assess: **1**", self.markdown)
        self.assertIn("mixed-registry", self.markdown)
        self.assertIn("opaque-network-change", self.markdown)
        self.assertNotIn("unassessed-registry", self.markdown)
        self.assertIn("unassessed-registry", self.detail_markdown)
        self.assertIn("unresolved expression", self.serialized)
        self.assertNotIn(expression, self.serialized + self.markdown)
        combined_dir = self.directory / "combined"
        REPORT.combine_reports([self.directory / "TST" / "plan.json"], combined_dir)
        combined = (combined_dir / "summary.md").read_text()
        self.assertIn("| TST | 0 | 2 | 0 | 1 | Completed |", combined)
        self.assertIn("| Container registry | — | 2 update | — | — |", combined)
        self.assertIn("unassessed-registry", combined.split("## Unresolved predictions", 1)[1])
        plan["components"][0]["resources"][0]["fields"][0].pop("deploymentTimeExpression")
        self.assertIn("unassessed-registry", REPORT.environment_markdown(plan))

    def test_failed_blocked_missing_and_azure_failed_payloads_do_not_claim_no_changes(self):
        fixtures = [component(status="failed", errorCode="WHAT_IF_FAILED"),
                    component(status="blocked", errorCode="MISSING_INPUT"),
                    component(result=None), component(result={"changes": []}),
                    component(result={"status": "Failed", "changes": [], "error": {"message": "SENSITIVE-ERROR"}})]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                plan = self.report([fixture])
                self.assertFalse(plan["complete"])
                self.assertEqual(plan["executionStatus"], "failed")
                self.assertNotIn("No resource changes predicted", self.markdown)
                self.assertNotIn("SENSITIVE-ERROR", self.serialized + self.markdown)

    def test_real_empty_success_and_no_change_are_distinct_from_missing_results(self):
        plan = self.report([component([resource(change_type="NoChange")]), component(name="optional", status="not-applicable", result=None)])
        self.assertTrue(plan["complete"])
        self.assertEqual(plan["resourceTotals"]["NoChange"], 1)
        self.assertIn("0 creates, 0 updates to review and 0 resource deletions", self.markdown)
        self.assertIn("No resource actions are listed for review", self.markdown)
        self.assertTrue(self.report([component([])])["complete"])
        self.assertFalse(self.report([])["complete"])

    def test_arbitrary_markup_logging_commands_and_unapproved_scalar_values_are_withheld(self):
        attack = "<script>alert(1)</script>##vso[task.setvariable variable=x]evil"
        change = resource(delta=[field("properties.customString", attack, "apparently-safe-but-private"),
                                 field("sku.name", "Basic", attack), field(attack, attack, attack)])
        change["resourceId"] = attack
        fixture = component([change], name=attack, label=attack, scope=attack, errorCode=attack)
        plan = self.report([fixture])
        self.assertNotIn(attack, self.serialized + self.markdown + self.detail_markdown)
        self.assertNotIn("apparently-safe-but-private", self.serialized + self.markdown + self.detail_markdown)
        self.assertNotIn("<script>", self.markdown)
        self.assertNotIn("##vso[", self.markdown)
        self.assertEqual(plan["components"][0]["name"], "component")

    def test_potential_changes_are_explicit_and_diagnostic_values_are_not_published(self):
        raw = {"status": "Succeeded", "changes": [], "potentialChanges": [resource(change_type="Create")],
               "diagnostics": [{"message": "SENSITIVE", "level": "warning"}]}
        plan = self.report([component(result=raw)])
        self.assertFalse(plan["complete"])
        self.assertEqual(plan["totals"]["Create"], 1)
        self.assertTrue(plan["components"][0]["resources"][0]["potential"])
        self.assertEqual(plan["unknowns"], 2)
        self.assertNotIn("SENSITIVE", self.serialized + self.markdown)

    def test_complete_combined_report_requires_all_environments_and_same_commit(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([resource(change_type="NoChange")])], environment)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertTrue(combined["complete"])
        self.assertEqual(combined["commit"], COMMIT)
        self.assertEqual(len(combined["environments"]), 4)
        self.assertFalse(REPORT.combine_reports(inputs[:2], self.directory / "combined")["complete"])
        self.report([component([])], "PRD", commit="b" * 40)
        mixed = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertFalse(mixed["complete"])
        self.assertFalse(mixed["sameCommit"])

    def test_combined_report_rejects_duplicate_malformed_and_missing_inputs(self):
        self.report([component([])])
        path = self.directory / "TST" / "plan.json"
        invalid = self.directory / "bad.json"
        invalid.write_text("not-json-secret")
        plan = REPORT.combine_reports([path, path, invalid], self.directory / "combined")
        self.assertFalse(plan["complete"])
        self.assertTrue(plan["invalidInputs"])
        self.assertEqual(plan["missingEnvironments"], ["DEV", "PRE", "PRD"])
        self.assertNotIn("not-json-secret", (self.directory / "combined" / "plan.json").read_text())

    def test_combined_summary_compares_fixed_resource_categories_without_copying_artifact_payloads(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([resource(change_type="Create"),
                                    resource("Microsoft.Authorization/roleAssignments", "role", "Unsupported")])], environment)
            path = self.directory / environment / "plan.json"
            source = json.loads(path.read_text())
            source["components"][0]["label"] = "DO-NOT-PUBLISH-LABEL"
            source["components"][0]["resources"][0].update(
                name="DO-NOT-PUBLISH-NAME", fields=[{"before": "DO-NOT-PUBLISH-VALUE"}])
            source["arbitrary"] = "DO-NOT-PUBLISH-RAW"
            path.write_text(json.dumps(source))
            inputs.append(path)
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertIn("Reported actions by resource type", summary)
        self.assertIn("Equal counts can refer to different properties", summary)
        self.assertIn("Container registry | 1 create | 1 create | 1 create", summary)
        self.assertIn("1 Role assignment", summary)
        self.assertNotIn("DO-NOT-PUBLISH", json.dumps(combined) + summary)

    def test_combined_summary_keeps_potential_changes_separate_from_predicted_action_counts(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([resource(name="proposed", change_type="Create")],
                                   result={"status": "Succeeded", "changes": [resource(name="proposed", change_type="Create")],
                                           "potentialChanges": [resource(name="potential", change_type="Create")]})], environment)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertFalse(combined["complete"])
        self.assertEqual(combined["environments"][0]["totals"]["Create"], 2)
        self.assertIn("| TST | 1 | 0 | 0 | 0 | Completed |", summary)
        self.assertIn("Potential predictions", summary)
        self.assertIn("TST: 1", summary)

    def test_modified_or_malformed_report_headers_cannot_create_a_green_combination(self):
        inputs = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([])], environment)
            inputs.append(self.directory / environment / "plan.json")
        original = json.loads(inputs[-1].read_text())
        for mutate in (lambda document: document.pop("resourceTotals"),
                       lambda document: document.update(unknowns=2),
                       lambda document: document["metadata"].update(commit={"SENSITIVE": "value"})):
            with self.subTest(mutate=mutate):
                document = copy.deepcopy(original)
                mutate(document)
                inputs[-1].write_text(json.dumps(document))
                combined = REPORT.combine_reports(inputs, self.directory / "combined")
                self.assertFalse(combined["complete"])
                self.assertNotIn("SENSITIVE", json.dumps(combined))

    def combine_cli(self, *flags):
        return subprocess.run([sys.executable, str(SCRIPT), "--combine", str(self.directory),
                               "--output-dir", str(self.directory / "combined"), *flags],
                              text=True, capture_output=True, timeout=10)

    def comparison_inputs(self):
        """Full synthetic run, through the production sanitiser and combiner."""
        inputs = []
        default = resource("Microsoft.Network/privateEndpoints", "recurring-default", delta=[
            field("properties.ipVersionType", "IPv4", None, propertyChangeType="Delete")])
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            changes = [default, resource("Microsoft.ContainerRegistry/registries", "ignored-inventory", "Ignore")]
            if environment != "DEV":
                changes += [resource(name="new-registry", change_type="Create"),
                            resource(name="real-sku-update", delta=[field("sku.name", "Basic", "Premium")]),
                            resource("Microsoft.Network/networkSecurityGroups", "policy-rule", delta=[
                                field("properties.securityRules.0", "PRIVATE-BEFORE", "PRIVATE-AFTER")]),
                            resource("Microsoft.Authorization/roleAssignments", "unassessed-role", "Unsupported")]
            components = [component(changes if name == "infra" else [], name=name)
                          for name in sorted(COMPARISON.COMPONENTS)]
            destination = self.directory / environment
            REPORT.write_environment_report(destination,
                {"environment": environment, "commit": COMMIT, "buildId": "42",
                 "generatedAt": "2026-11-04T10:05:00Z" if environment == "DEV" else "2026-11-04T10:20:00Z"}, components)
            inputs.append(destination / "plan.json")
        proof = {"schemaVersion": 1, "status": "usable", "appliedCommit": "b" * 40,
                 "appliedBuildId": 41, "appliedPipelineId": 9217, "appliedBranch": "refs/heads/main",
                 "appliedFinishTime": "2026-11-04T10:00:00Z", "verifiedAt": "2026-11-04T10:06:00Z",
                 "previewCommit": COMMIT, "previewBuildId": "42", "deploymentInputsUnchanged": True,
                 "sourceVerified": True, "sourceDeploymentVerified": True,
                 "sourceDeploymentStages": COMPARISON.SOURCE_DEPLOYMENT_STAGES,
                 "comparedPaths": COMPARISON.COMPARED_PATHS}
        (self.directory / "DEV" / "baseline-evidence.json").write_text(json.dumps(proof))
        return inputs

    def test_automatic_dev_comparison_classifies_without_mutating_environment_evidence(self):
        inputs = self.comparison_inputs()
        original = [path.read_bytes() for path in inputs]
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertTrue(combined["comparisonAvailable"])
        self.assertFalse(combined["complete"], "Ignore/Unsupported remain incomplete coverage")
        self.assertEqual(4, len(combined["environments"]))
        for comparison in combined["devComparison"]:
            self.assertEqual(1, comparison["counts"]["potentialNoiseResources"])
            self.assertEqual(2, comparison["counts"]["reviewResources"])
            self.assertEqual(1, comparison["counts"]["policySecurityResources"])
            self.assertEqual(1, comparison["counts"]["unresolvedResources"])
            self.assertFalse(any(item["classification"] == "background" for item in comparison["resources"]))
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertIn("All four environment previews ran successfully", summary)
        self.assertIn("| TST | 3 | 1 | 1 | Available |", summary)
        review = summary.split("## Changes needing review", 1)[1].split("## Potential recurring noise", 1)[0]
        self.assertIn("new-registry", review)
        self.assertIn("policy-rule", review)
        self.assertNotIn("recurring-default", review)
        self.assertIn("Pattern only; values withheld", summary)
        self.assertNotIn("ignored-inventory", summary)
        self.assertEqual(original, [path.read_bytes() for path in inputs])
        published = json.dumps(combined) + summary + (self.directory / "combined" / "dev-comparison.json").read_text()
        self.assertNotIn("PRIVATE-BEFORE", published)
        self.assertNotIn("PRIVATE-AFTER", published)
        self.assertNotIn('"before":', published)

    def test_unusable_dev_evidence_never_labels_target_default_as_noise(self):
        inputs = self.comparison_inputs()
        evidence = self.directory / "DEV" / "baseline-evidence.json"
        for contents in (None, "not-json-PRIVATE", "[]", '{"status":"usable","sourceVerified":true}'):
            with self.subTest(contents=contents):
                if contents is None:
                    evidence.unlink(missing_ok=True)
                else:
                    evidence.write_text(contents)
                combined = REPORT.combine_reports(inputs, self.directory / "combined")
                self.assertFalse(combined["comparisonAvailable"])
                self.assertTrue(all(item["counts"]["potentialNoiseResources"] == 0 for item in combined["devComparison"]))
                self.assertTrue(all(item["counts"]["reviewResources"] == 3 for item in combined["devComparison"]))
                summary = (self.directory / "combined" / "summary.md").read_text()
                self.assertIn("recurring-default", summary)
                self.assertNotIn("not-json-PRIVATE", summary)

    def test_dev_is_required_in_the_default_combined_run(self):
        inputs = self.comparison_inputs()[1:]
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertFalse(combined["complete"])
        self.assertFalse(combined["comparisonAvailable"])
        self.assertEqual(["DEV"], combined["missingEnvironments"])

    def test_mixed_updates_keep_unresolved_fields_visible_in_the_overview(self):
        inputs = self.comparison_inputs()
        target = self.directory / "TST" / "plan.json"
        source = json.loads(target.read_text())
        for part in source["components"]:
            for item in part["resources"]:
                if item["name"] == "real-sku-update":
                    item["fields"].append({"path": "properties.futureSetting", "changeType": "Modify",
                                           "before": "[withheld]", "after": "[unresolved expression]", "unresolved": True})
        target.write_text(json.dumps(source))
        REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertIn("| TST | 3 | 1 | 2 | Available |", summary)
        self.assertIn("real-sku-update", summary.split("## Unresolved predictions", 1)[1])

    def unresolved_inputs(self, changes):
        """Exercise the real projection before rendering grouped coverage gaps."""
        paths = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            components = [component(copy.deepcopy(changes.get(environment, {}).get(name, [])), name=name)
                          for name in sorted(COMPARISON.COMPONENTS)]
            self.report(components, environment)
            paths.append(self.directory / environment / "plan.json")
        return paths

    @staticmethod
    def unavailable_resource(resource_type="Microsoft.Authorization/roleAssignments", action="Unsupported"):
        change = resource(resource_type, change_type=action)
        change["resourceId"] = "[reference('unresolved-resource-name')]"
        return change

    def unresolved_rows(self):
        summary = (self.directory / "combined" / "summary.md").read_text()
        section = summary.split("## Unresolved predictions", 1)[1].split("\n## ", 1)[0]
        self.assertIn("| Target | Component | Action | Resource | Entries |", section)
        return [tuple(cell.strip() for cell in line.strip("|").split("|"))
                for line in section.splitlines() if line.startswith(("| TST |", "| PRE |", "| PRD |"))]

    def test_unavailable_unsupported_rows_group_by_known_type_without_losing_evidence(self):
        role = self.unavailable_resource()
        search = self.unavailable_resource("Microsoft.Search/searchServices/sharedPrivateLinkResources")
        inputs = self.unresolved_inputs({"TST": {"classic": [role], "infra": [role] * 9 + [search]}})
        originals = [path.read_bytes() for path in inputs]
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        rows = self.unresolved_rows()
        self.assertCountEqual(rows, [
            ("TST", "Classic services", "Unsupported", "Role assignment — resource identity unresolved", "1"),
            ("TST", "Infrastructure", "Unsupported", "Role assignment — resource identity unresolved", "9"),
            ("TST", "Infrastructure", "Unsupported", "Search private-link resource — resource identity unresolved", "1")])
        comparison = next(item for item in combined["devComparison"] if item["environment"] == "TST")
        self.assertEqual(11, len(comparison["resources"]))
        self.assertEqual(11, comparison["counts"]["unresolvedResources"])
        self.assertTrue(all(item["classification"] == "unresolved-coverage" for item in comparison["resources"]))
        self.assertCountEqual([item["type"].lower() for item in comparison["resources"]],
                              ["microsoft.authorization/roleassignments"] * 10 + ["microsoft.search/searchservices/sharedprivatelinkresources"])
        self.assertFalse(combined["complete"])
        self.assertFalse(combined["invalidInputs"])
        self.assertEqual([], combined["missingEnvironments"])
        self.assertEqual(originals, [path.read_bytes() for path in inputs])
        tst = next(item for item in combined["environments"] if item["environment"] == "TST")
        self.assertEqual(11, tst["unknowns"])
        self.assertEqual(11, tst["totals"]["Unsupported"])
        self.assertEqual("succeeded", tst["executionStatus"])
        details = (self.directory / "TST" / "change-details.md").read_text()
        self.assertEqual(11, details.count("### Unsupported:"))
        self.assertNotIn("unavailable: unavailable", (self.directory / "combined" / "summary.md").read_text())

    def test_grouping_keeps_environments_components_and_named_resources_separate(self):
        role = self.unavailable_resource()
        named = [resource("Microsoft.Authorization/roleAssignments", name, "Unsupported")
                 for name in ("named-role-one", "named-role-two")]
        inputs = self.unresolved_inputs({
            "TST": {"classic": [role], "infra": [role] * 2 + named},
            "PRE": {"infra": [role] * 3}, "PRD": {"classic": [role] * 4}})
        REPORT.combine_reports(inputs, self.directory / "combined")
        rows = self.unresolved_rows()
        grouped = [row for row in rows if "resource identity unresolved" in row[3]]
        self.assertCountEqual([(row[0], row[1], row[4]) for row in grouped], [
            ("TST", "Classic services", "1"), ("TST", "Infrastructure", "2"),
            ("PRE", "Infrastructure", "3"), ("PRD", "Classic services", "4")])
        for name in ("named-role-one", "named-role-two"):
            individual = [row for row in rows if name in row[3]]
            self.assertEqual(1, len(individual))
            self.assertEqual(("TST", "Infrastructure", "Unsupported"), individual[0][:3])
            self.assertEqual("1", individual[0][4])

    def test_grouping_never_collapses_other_uncertain_actions_or_named_updates(self):
        deploy = self.unavailable_resource(action="Deploy")
        updates = [resource(name=name, delta=[field("properties.futureSetting", "PRIVATE", "[reference('runtime')]")])
                   for name in ("unresolved-one", "unresolved-two")]
        inputs = self.unresolved_inputs({"TST": {"infra": [self.unavailable_resource()] * 2 + [deploy] * 2 + updates}})
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        rows = self.unresolved_rows()
        self.assertEqual(5, len(rows), "Only the two unnamed Unsupported observations are grouped")
        self.assertEqual(["2"], [row[4] for row in rows if row[2] == "Unsupported"])
        self.assertEqual(["1", "1"], [row[4] for row in rows if row[2] == "Deploy"])
        self.assertEqual(2, len([row for row in rows if row[2] == "Modify" and row[4] == "1"]))
        target = next(item for item in combined["devComparison"] if item["environment"] == "TST")
        self.assertEqual(6, len(target["resources"]))
        self.assertTrue(all(item["classification"] == "unresolved-coverage" for item in target["resources"]))

    def test_unknown_unavailable_types_and_component_markup_are_not_forwarded(self):
        inputs = self.unresolved_inputs({"TST": {"infra": [self.unavailable_resource()] * 3}})
        target = self.directory / "TST" / "plan.json"
        source = json.loads(target.read_text())
        items = next(part for part in source["components"] if part["name"] == "infra")["resources"]
        for item, value in zip(items, ("Microsoft.Private/DO-NOT-PUBLISH-TYPE", {"PRIVATE-TYPE": "value"},
                                      "Microsoft.Authorization/roleAssignments##vso[task.setvariable]")):
            item["type"] = value
            item["name"] = "DO-NOT-PUBLISH-NAME"
        source["components"][0]["name"] = "<script>DO-NOT-PUBLISH-COMPONENT</script>"
        source["components"][0]["label"] = "##vso[task.setvariable variable=PRIVATE]value"
        target.write_text(json.dumps(source))
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        published = json.dumps(combined) + (self.directory / "combined" / "summary.md").read_text()
        self.assertNotIn("DO-NOT-PUBLISH", published)
        self.assertNotIn("PRIVATE-TYPE", published)
        self.assertNotIn("<script>", published)
        self.assertNotIn("##vso[", published)
        rows = self.unresolved_rows()
        self.assertEqual(1, len(rows))
        self.assertEqual("Resource type unresolved — resource identity unresolved", rows[0][3])
        self.assertEqual("3", rows[0][4])
        self.assertEqual(3, next(item for item in combined["devComparison"] if item["environment"] == "TST")["counts"]["unresolvedResources"])

    def test_grouped_coverage_does_not_turn_missing_or_failed_previews_into_zero_changes(self):
        inputs = self.unresolved_inputs({"TST": {"infra": [self.unavailable_resource()] * 2}})
        self.report([component(status="failed", errorCode="AZURE_COMMAND_FAILED")], "PRE")
        combined = REPORT.combine_reports(inputs[:-1], self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertFalse(combined["complete"])
        self.assertEqual(["PRD"], combined["missingEnvironments"])
        self.assertIn("Preview failed", summary)
        self.assertIn("Preview missing", summary)
        self.assertIn("| PRD | — | — | — | — | Missing |", summary)
        self.assertIn("| TST | Infrastructure | Unsupported | Role assignment — resource identity unresolved | 2 |", summary)

    def test_pipeline_warns_for_successful_but_incomplete_assessment_without_changing_artifacts(self):
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.report([component([resource(change_type="Ignore"), resource(change_type="Unsupported"),
                                    resource(delta=[field("sku.name", "Basic", "[reference('future').sku.name]")])])], environment)
        self.assertEqual(1, self.combine_cli().returncode, "Default CLI remains strict")
        result = self.combine_cli("--azure-pipelines")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("##vso[task.logissue type=warning;]", result.stdout)
        self.assertIn("##vso[task.complete result=SucceededWithIssues;]", result.stdout)
        combined = json.loads((self.directory / "combined" / "plan.json").read_text())
        self.assertFalse(combined["complete"])
        self.assertEqual("incomplete", combined["outcome"])
        self.assertTrue(all(not item["complete"] and item["executionStatus"] == "succeeded"
                            for item in combined["environments"]))
        self.assertIn("INCOMPLETE", (self.directory / "combined" / "summary.md").read_text())

    def test_pipeline_mode_still_fails_missing_mismatched_invalid_duplicate_and_failed_reports(self):
        for problem in ("missing", "mismatched", "invalid", "duplicate", "failed", "missing-complete", "invalid-complete"):
            with self.subTest(problem=problem):
                extra = self.directory / "extra" / "plan.json"
                extra.unlink(missing_ok=True)
                for environment in REPORT.PREVIEW_ENVIRONMENTS:
                    self.report([component([])], environment)
                target = self.directory / "PRD" / "plan.json"
                if problem == "missing":
                    target.unlink()
                elif problem == "mismatched":
                    self.report([component([])], "PRD", commit="b" * 40)
                elif problem == "invalid":
                    target.write_text("invalid report")
                elif problem == "duplicate":
                    extra.parent.mkdir(exist_ok=True)
                    extra.write_text(target.read_text())
                elif problem == "failed":
                    self.report([component(status="failed", errorCode="AZURE_COMMAND_FAILED")], "PRD")
                elif problem in {"missing-complete", "invalid-complete"}:
                    document = json.loads(target.read_text())
                    if problem == "missing-complete":
                        document.pop("complete")
                    else:
                        document["complete"] = "false"
                    target.write_text(json.dumps(document))
                result = self.combine_cli("--azure-pipelines")
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertNotIn("SucceededWithIssues", result.stdout)

    def test_combine_cli_discovers_artifacts_and_returns_nonzero_for_missing_environment(self):
        self.report([component([])])
        output = self.directory / "combined"
        result = subprocess.run([sys.executable, str(SCRIPT), "--combine", str(self.directory), "--output-dir", str(output)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn("incomplete", result.stdout)
        self.assertTrue((output / "summary.md").is_file())
        for environment in ("DEV", "PRE", "PRD"):
            self.report([component([])], environment)
        result = subprocess.run([sys.executable, str(SCRIPT), "--combine", str(self.directory), "--output-dir", str(output)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.combine_cli("--azure-pipelines")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("task.logissue", result.stdout)
        self.assertIn("SucceededWithIssues", result.stdout)


def load_tests(loader, standard_tests, pattern):
    # The existing CI reporting entry point also exercises its comparator.
    # Keep the classifier contract independently runnable for focused debugging.
    for name, filename in (("comparison_contract_tests", "infrastructure-plan-comparison.test.py"),
                           ("identity_properties_contract_tests", "infrastructure-identity-properties.test.py"),
                           ("aks_properties_contract_tests", "infrastructure-aks-properties.test.py"),
                           ("insights_properties_contract_tests", "infrastructure-insights-properties.test.py")):
        spec = importlib.util.spec_from_file_location(name, SCRIPT.with_name(filename))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        standard_tests.addTests(loader.loadTestsFromModule(module))
    return standard_tests


if __name__ == "__main__":
    unittest.main()
