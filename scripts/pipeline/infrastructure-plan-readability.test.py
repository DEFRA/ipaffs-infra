"""Keep release previews useful when ARM returns a large background inventory."""

import html
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest


DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(DIRECTORY))
SPEC = importlib.util.spec_from_file_location(
    "infrastructure_plan_report_readability", DIRECTORY / "infrastructure_plan_report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)

RESOURCE_PREFIX = (
    "/subscriptions/11111111-1111-1111-1111-111111111111/"
    "resourceGroups/preview-pre/providers/")


def resource(name, change_type="Modify", resource_type="Microsoft.Storage/storageAccounts", delta=None):
    result = {
        "resourceId": RESOURCE_PREFIX + resource_type + "/" + name,
        "changeType": change_type,
        "before": {"type": resource_type},
        "after": {"type": resource_type},
    }
    if delta is not None:
        result["delta"] = delta
    return result


def field(path, before, after, change_type="Modify"):
    return {"path": path, "propertyChangeType": change_type,
            "before": before, "after": after}


def component(name, changes=None, potential=None):
    result = {"status": "Succeeded", "changes": changes or []}
    if potential is not None:
        result["potentialChanges"] = potential
    return {"name": name, "label": name, "scope": "resource-group",
            "status": "complete", "result": result}


class InfrastructurePlanReadabilityTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)

    def write_report(self, components):
        report = REPORT.write_environment_report(
            self.directory,
            {"environment": "PRE", "commit": "a" * 40,
             "sourceRef": "refs/heads/main", "buildId": "42",
             "generatedAt": "2026-11-03T10:20:00Z"},
            components)
        self.summary = (self.directory / "summary.md").read_text()
        self.details = (self.directory / "change-details.md").read_text()
        self.serialized = (self.directory / "plan.json").read_text()
        self.assertEqual(json.loads(self.serialized), report)
        return report

    def test_a_thousand_ignored_resources_do_not_bury_the_predicted_change(self):
        inventory = [resource(f"background-rule-{index:04d}", "Ignore")
                     for index in range(1000)]
        update = resource("release-storage", delta=[field("sku.name", "Standard", "Premium")])
        report = self.write_report([component("Infrastructure", inventory + [update])])

        self.assertIn("release-storage", self.summary)
        self.assertIn("Standard", self.summary + self.details)
        self.assertIn("Premium", self.summary + self.details)
        self.assertIn("1000", self.summary)
        self.assertNotIn("background-rule-", self.summary + self.details)
        self.assertLess(len(self.summary), 15000)
        self.assertLess(len(self.details), 15000)
        resources = report["components"][0]["resources"]
        self.assertEqual(len(resources), 1001)
        self.assertEqual(report["resourceTotals"]["Ignore"], 1000)
        for name in ("background-rule-0000", "background-rule-0999"):
            self.assertIn(name, self.serialized)

    def test_ignored_observation_does_not_hide_an_update_from_another_component(self):
        ignored = resource("shared-storage", "Ignore")
        updated = resource("shared-storage", delta=[field("sku.name", "Standard", "Premium")])
        report = self.write_report([
            component("Resource group", [ignored]), component("Infrastructure", [updated])])

        self.assertEqual(ignored["resourceId"], updated["resourceId"])
        self.assertEqual(report["resourceTotals"]["Ignore"], 1)
        self.assertEqual(report["resourceTotals"]["Modify"], 1)
        action_rows = [line for line in self.summary.splitlines()
                       if "shared-storage" in line]
        self.assertTrue(any("Update" in line or "Modify" in line for line in action_rows))
        self.assertIn("Premium", self.summary + self.details)

    def test_nested_rules_retain_parent_context_in_the_compact_summary(self):
        rules = []
        for parent in ("nsg-public", "nsg-private"):
            rule = resource("AllowHttps", "Create", "Microsoft.Network/networkSecurityGroups/securityRules")
            rule["resourceId"] = (RESOURCE_PREFIX + "Microsoft.Network/networkSecurityGroups/"
                                  + parent + "/securityRules/AllowHttps")
            rules.append(rule)
        report = self.write_report([component("Network", rules)])

        self.assertEqual(report["resourceTotals"]["Create"], 2)
        self.assertIn("nsg-public", self.summary)
        self.assertIn("nsg-private", self.summary)
        self.assertIn("AllowHttps", self.summary)
        self.assertNotIn("/subscriptions/", self.summary)

    def test_a_property_removal_is_presented_as_an_update_not_a_resource_deletion(self):
        update = resource("existing-registry", resource_type="Microsoft.ContainerRegistry/registries",
                          delta=[field("properties.dataEndpointEnabled", True, None, "Delete")])
        report = self.write_report([component("Registry", [update])])

        self.assertEqual(report["resourceTotals"]["Modify"], 1)
        self.assertEqual(report["resourceTotals"]["Delete"], 0)
        action_rows = [line for line in self.summary.splitlines()
                       if "existing-registry" in line]
        self.assertTrue(any("Update" in line or "Modify" in line for line in action_rows))
        self.assertFalse(any(re.search(r"\|\s*Delete\s*\|", line) for line in action_rows))
        explanation = (self.summary + self.details).lower()
        self.assertRegex(explanation, r"(?:remov\w*[^\n]{0,100}propert|propert[^\n]{0,100}remov\w*)")

    def test_potential_creation_is_qualified_next_to_the_resource(self):
        report = self.write_report([
            component("Infrastructure", potential=[resource("possible-new-store", "Create")])])

        self.assertFalse(report["complete"])
        self.assertTrue(report["components"][0]["resources"][0]["potential"])
        self.assertRegex(self.summary.lower(),
                         r"(?:potential[\s\S]{0,200}possible-new-store|possible-new-store[\s\S]{0,200}potential)")
        self.assertNotRegex(self.summary.lower(), r"possible-new-store[^\n]*will be created")

    def test_an_ignored_only_report_stays_incomplete_without_claiming_no_changes(self):
        report = self.write_report([
            component("Infrastructure", [resource("background-monitoring-rule", "Ignore")])])

        self.assertFalse(report["complete"])
        self.assertEqual(report["executionStatus"], "succeeded")
        self.assertIn("INCOMPLETE", self.summary)
        self.assertIn("Ignore", self.summary)
        self.assertNotIn("background-monitoring-rule", self.summary + self.details)
        self.assertNotRegex(self.summary.lower(), r"no (?:resource )?changes (?:predicted|detected|required)")

    def test_withheld_values_have_an_explanation_instead_of_an_empty_comparison(self):
        report = self.write_report([component("Infrastructure", [resource(
            "existing-store", delta=[field("properties.customConfiguration",
                                           "CURRENT-PRIVATE-VALUE", "PROPOSED-PRIVATE-VALUE")])])])

        self.assertEqual(report["resourceTotals"]["Modify"], 1)
        markdown = self.summary + self.details
        self.assertIn("customConfiguration", markdown)
        self.assertIn("values withheld", markdown.lower())
        self.assertNotRegex(html.unescape(self.summary),
                            r"\[withheld\]\s*(?:\||→|->)\s*\[withheld\]")
        self.assertNotIn("CURRENT-PRIVATE-VALUE", markdown + self.serialized)
        self.assertNotIn("PROPOSED-PRIVATE-VALUE", markdown + self.serialized)

    def test_no_effect_only_updates_leave_the_review_list_but_keep_the_evidence(self):
        no_effect = field("sku.tier", "Standard", "Premium", "NoEffect")
        changes = [
            resource("no-effect-only-store", delta=[no_effect]),
            resource("no-effect-with-date", delta=[
                no_effect, field("tags.CreatedDate", "yesterday", "[utcNow()]")]),
        ]
        report = self.write_report([component("Infrastructure", changes)])

        self.assertTrue(report["complete"])
        self.assertEqual(report["resourceTotals"]["Modify"], 2)
        self.assertEqual(report["metadataOnlyTotals"]["Modify"], 0)
        self.assertIn("0 updates to review", self.summary)
        self.assertIn("NoEffect-only updates: 2", self.summary)
        for name in ("no-effect-only-store", "no-effect-with-date"):
            self.assertNotIn(name, self.summary)
            self.assertIn(name, self.details)
            self.assertIn(name, self.serialized)
        self.assertIn("NoEffect", self.details)
        self.assertIn("Premium", self.details)
        self.assertIn("tags.CreatedDate", self.details)
        self.assertEqual(report["components"][0]["resources"][1]["fields"][0]["changeType"], "NoEffect")

    def test_no_effect_siblings_do_not_hide_a_real_update(self):
        report = self.write_report([component("Infrastructure", [resource(
            "mixed-effect-store", delta=[
                field("sku.tier", "Standard", "Premium", "NoEffect"),
                field("properties.publicNetworkAccess", "Enabled", "Disabled")])])])

        self.assertEqual(report["resourceTotals"]["Modify"], 1)
        self.assertIn("mixed-effect-store", self.summary)
        self.assertIn("1 updates to review", self.summary)
        self.assertIn("Disabled", self.summary)
        self.assertIn("NoEffect-only updates: 0", self.summary)

    def test_potential_no_effect_only_update_stays_visible_as_uncertain(self):
        report = self.write_report([component("Infrastructure", potential=[resource(
            "potential-no-effect-store", delta=[
                field("sku.tier", "Standard", "Premium", "NoEffect")])])])

        self.assertFalse(report["complete"])
        self.assertEqual(report["resourceTotals"]["Modify"], 1)
        self.assertIn("potential-no-effect-store", self.summary)
        self.assertIn("Potential update", self.summary)
        self.assertIn("NoEffect-only updates: 0", self.summary)

    def test_unknown_predictions_and_hostile_values_stay_visible_as_gaps_without_leaking(self):
        attack = "<script>UNSAFE-MARKUP</script>##vso[task.setvariable variable=x]evil"
        unknown = resource("unknown-resource", change_type="FUTURE-SENSITIVE-CHANGE-TYPE")
        update = resource("existing-store", delta=[
            field("properties.customConfiguration", "PRIVATE-OLD-VALUE", attack),
            field(attack, attack, attack)])
        report = self.write_report([component("Infrastructure", [unknown, update])])

        self.assertFalse(report["complete"])
        self.assertEqual(report["resourceTotals"]["Unknown"], 1)
        self.assertIn("unknown-resource", self.summary + self.details)
        self.assertRegex(self.summary.lower(), r"unknown|unassessed|coverage")
        published = self.summary + self.details + self.serialized
        for private in (attack, "UNSAFE-MARKUP", "##vso[", "PRIVATE-OLD-VALUE",
                        "FUTURE-SENSITIVE-CHANGE-TYPE"):
            self.assertNotIn(private, published)

    def write_combined_inputs(self, components):
        paths = []
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            destination = self.directory / environment
            REPORT.write_environment_report(
                destination, {"environment": environment, "commit": "a" * 40}, components)
            paths.append(destination / "plan.json")
        return paths

    def test_combined_summary_does_not_describe_missing_or_failed_coverage_as_clear(self):
        for missing in (True, False):
            with self.subTest(missing=missing):
                paths = self.write_combined_inputs([component("Infrastructure")])
                if missing:
                    paths = paths[:2]
                else:
                    REPORT.write_environment_report(
                        paths[-1].parent, {"environment": "PRD", "commit": "a" * 40},
                        [{"name": "infra", "label": "Infrastructure", "status": "failed",
                          "errorCode": "AZURE_COMMAND_FAILED"}])
                combined = REPORT.combine_reports(paths, self.directory / "comparison")
                summary = (self.directory / "comparison" / "summary.md").read_text()
                self.assertFalse(combined["complete"])
                prd_rows = [line for line in summary.splitlines() if line.startswith("| PRD |")]
                self.assertTrue(prd_rows)
                self.assertFalse(any("None reported" in line for line in prd_rows),
                                 "Missing or failed coverage cannot be presented as having no gaps")
                status = "missing" if missing else "failed"
                self.assertIn(f"| PRD | — | — | — | Preview {status} |", summary)
                self.assertNotIn("| PRD | 0 | 0 | 0 | Unavailable |", summary)

    def test_combined_counts_do_not_present_potential_creates_as_confirmed(self):
        paths = self.write_combined_inputs([component(
            "Infrastructure",
            [resource("existing-store", delta=[field("sku.name", "Standard", "Premium")])],
            [resource("possible-new-store", "Create")])])
        combined = REPORT.combine_reports(paths, self.directory / "comparison")
        summary = (self.directory / "comparison" / "summary.md").read_text()

        self.assertFalse(combined["complete"])
        for environment in combined["environments"]:
            self.assertEqual(environment["review"]["potential"]["Create"], 1)
            self.assertEqual(sum(counts["Create"] for counts in environment["review"]["changes"].values()), 0)
        self.assertRegex(summary, r"\| TST \| 0 \| 1 \| 0 \|")
        self.assertIn("potential", summary.lower())

    def test_combined_review_counts_exclude_only_confirmed_no_effect_only_updates(self):
        paths = self.write_combined_inputs([component(
            "Infrastructure", [
                resource("new-store", "Create"),
                resource("no-effect-only-store", delta=[
                    field("sku.tier", "Standard", "Premium", "NoEffect"),
                    field("tags.CreatedDate", "yesterday", "[utcNow()]")]),
                resource("real-update-store", delta=[
                    field("sku.tier", "Standard", "Premium", "NoEffect"),
                    field("properties.publicNetworkAccess", "Enabled", "Disabled")]),
                resource("date-only-store", delta=[
                    field("tags.CreatedDate", "yesterday", "[utcNow()]")]),
            ], [resource("potential-no-effect-store", delta=[
                field("sku.tier", "Standard", "Premium", "NoEffect")])])])
        originals = [path.read_bytes() for path in paths]
        combined = REPORT.combine_reports(paths, self.directory / "comparison")
        summary = (self.directory / "comparison" / "summary.md").read_text()

        for environment in combined["environments"]:
            # Raw environment totals and completion retain Azure's projection;
            # the separate review view is the only place noise is filtered.
            self.assertEqual(environment["totals"]["Modify"], 3)
            self.assertEqual(environment["metadataOnlyTotals"]["Modify"], 1)
            self.assertEqual(environment["review"]["noEffectOnly"], 1)
            self.assertEqual(environment["review"]["potential"]["Modify"], 1)
            self.assertEqual(sum(counts["Modify"] for counts in environment["review"]["changes"].values()), 1)
        self.assertEqual([path.read_bytes() for path in paths], originals)
        self.assertRegex(summary, r"\| TST \| 1 \| 1 \| 0 \| 0 \| Completed \|")
        self.assertIn("NoEffect-only updates", summary)
        self.assertIn("| TST | 0 | 0 | 1 | 1 |", summary)

    def test_combined_aggregation_does_not_publish_arbitrary_artifact_strings(self):
        paths = self.write_combined_inputs([component(
            "Infrastructure", [resource("existing-store", delta=[field("sku.name", "Standard", "Premium")])])])
        private = "<script>PRIVATE-ARTIFACT-CONTENT</script>##vso[task.setvariable variable=x]evil"
        document = json.loads(paths[0].read_text())
        document["components"][0]["label"] = private
        entry = document["components"][0]["resources"][0]
        entry.update({"type": private, "name": private, "resourceId": private})
        entry["fields"][0].update({"path": private, "before": private, "after": private})
        paths[0].write_text(json.dumps(document))

        REPORT.combine_reports(paths, self.directory / "comparison")
        published = ((self.directory / "comparison" / "summary.md").read_text()
                     + (self.directory / "comparison" / "plan.json").read_text())
        self.assertNotIn("PRIVATE-ARTIFACT-CONTENT", published)
        self.assertNotIn("##vso[", published)
        self.assertNotIn("<script>", published)


if __name__ == "__main__":
    unittest.main()
