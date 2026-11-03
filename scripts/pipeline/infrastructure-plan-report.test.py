"""Exercise release reporting with realistic ARM results and hostile payload values."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("infrastructure_plan_report.py")
SPEC = importlib.util.spec_from_file_location("infrastructure_plan_report", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
RID = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/ipaffs-tst/providers/"
COMMIT = "a" * 40


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
        self.assertIn("CreatedDate-only updates: 1", self.markdown)
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
        for environment in REPORT.RELEASE_ENVIRONMENTS:
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
        self.assertIn("CreatedDate-only updates", summary)
        self.assertIn("| TST | 0 | 0 | 0 | Completed |", summary)
        self.assertIn("| TST | 0 | 0 | 1 |", summary)

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
        self.assertEqual(plan["metadata"]["parameterSource"], "candidate parameters with current Library/live identity inputs")
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
        plan = self.report([component([resource(delta=[field("sku.name", "Basic", expression)])])])
        self.assertFalse(plan["complete"])
        self.assertIn("unresolved expression", self.serialized)
        self.assertNotIn(expression, self.serialized + self.markdown)

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
        self.assertIn("0 creates, 0 reported updates and 0 resource deletions", self.markdown)
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
        for environment in REPORT.RELEASE_ENVIRONMENTS:
            self.report([component([resource(change_type="NoChange")])], environment)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        self.assertTrue(combined["complete"])
        self.assertEqual(combined["commit"], COMMIT)
        self.assertEqual(len(combined["environments"]), 3)
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
        self.assertEqual(plan["missingEnvironments"], ["PRE", "PRD"])
        self.assertNotIn("not-json-secret", (self.directory / "combined" / "plan.json").read_text())

    def test_combined_summary_compares_fixed_resource_categories_without_copying_artifact_payloads(self):
        inputs = []
        for environment in REPORT.RELEASE_ENVIRONMENTS:
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
        self.assertIn("Changes by resource type", summary)
        self.assertIn("Container registry | 1 create | 1 create | 1 create", summary)
        self.assertIn("1 Role assignment", summary)
        self.assertNotIn("DO-NOT-PUBLISH", json.dumps(combined) + summary)

    def test_combined_summary_keeps_potential_changes_separate_from_predicted_action_counts(self):
        inputs = []
        for environment in REPORT.RELEASE_ENVIRONMENTS:
            self.report([component([resource(name="proposed", change_type="Create")],
                                   result={"status": "Succeeded", "changes": [resource(name="proposed", change_type="Create")],
                                           "potentialChanges": [resource(name="potential", change_type="Create")]})], environment)
            inputs.append(self.directory / environment / "plan.json")
        combined = REPORT.combine_reports(inputs, self.directory / "combined")
        summary = (self.directory / "combined" / "summary.md").read_text()
        self.assertFalse(combined["complete"])
        self.assertEqual(combined["environments"][0]["totals"]["Create"], 2)
        self.assertIn("| TST | 1 | 0 | 0 | Completed |", summary)
        self.assertIn("Potential predictions", summary)
        self.assertIn("TST: 1", summary)

    def test_modified_or_malformed_report_headers_cannot_create_a_green_combination(self):
        inputs = []
        for environment in REPORT.RELEASE_ENVIRONMENTS:
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

    def test_pipeline_warns_for_successful_but_incomplete_assessment_without_changing_artifacts(self):
        for environment in REPORT.RELEASE_ENVIRONMENTS:
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
                for environment in REPORT.RELEASE_ENVIRONMENTS:
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
        for environment in ("PRE", "PRD"):
            self.report([component([])], environment)
        result = subprocess.run([sys.executable, str(SCRIPT), "--combine", str(self.directory), "--output-dir", str(output)], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.combine_cli("--azure-pipelines")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("task.logissue", result.stdout)
        self.assertNotIn("SucceededWithIssues", result.stdout)


if __name__ == "__main__":
    unittest.main()
