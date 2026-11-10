"""Keep identity response metadata quiet without hiding writable properties."""

import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import infrastructure_plan_report as REPORT


TYPE = "Microsoft.ManagedIdentity/userAssignedIdentities"
RID = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/"
ABSENT = object()
IDS = {
    "clientId": "11111111-2222-4333-8444-555555555555",
    "principalId": "22222222-3333-4444-8555-666666666666",
    "tenantId": "33333333-4444-4555-8666-777777777777",
}


def field(path="properties", before=ABSENT, after=ABSENT, action="Delete", **extra):
    result = {"path": path, "propertyChangeType": action, **extra}
    if before is not ABSENT:
        result["before"] = before
    if after is not ABSENT:
        result["after"] = after
    return result


def identity(delta, action="Modify", before_properties=ABSENT, after_properties=ABSENT, resource_type=TYPE):
    result = {"resourceId": RID + resource_type + "/identity", "changeType": action,
              "before": {"type": resource_type}, "after": {"type": resource_type}, "delta": delta}
    if before_properties is not ABSENT:
        result["before"]["properties"] = before_properties
    if after_properties is not ABSENT:
        result["after"]["properties"] = after_properties
    return result


class IdentityPropertyProjectionTests(unittest.TestCase):
    def project(self, raw, potential=False):
        return REPORT._resource(raw, potential=potential)

    def assert_actionable(self, item):
        self.assertFalse(item["metadataOnly"])
        self.assertEqual("Modify", item["changeType"])
        self.assertIn("identity/permissions", item["potentialImpact"])

    def test_actual_arm_default_scope_bag_is_retained_as_explained_background(self):
        # Azure has already excluded generated IDs from this observed ARM shape.
        raw = identity([field(before={"isolationScope": "None"}, after=None)])
        item = self.project(raw)
        self.assertTrue(item["metadataOnly"])
        self.assertEqual("Modify", item["changeType"], "Keep the original ARM resource action")
        self.assertFalse(item["unresolved"])
        self.assertEqual(item["fields"], [{
            "path": "properties.isolationScope", "changeType": "Delete", "before": "None",
            "after": REPORT.MISSING, "unresolved": False, "metadataOnly": True,
            "metadataReason": "UNCHANGED_IDENTITY_SCOPE_DEFAULT"}])

    def test_full_generated_property_bag_is_split_before_redaction(self):
        properties = {**IDS, "isolationScope": "None"}
        raw = identity([field(before=properties, after=None)], before_properties=properties)
        original = copy.deepcopy(raw)
        item = self.project(raw)
        self.assertEqual(raw, original, "Never mutate Azure's input")
        self.assertTrue(item["metadataOnly"])
        self.assertEqual(len(item["fields"]), 4)
        for projected in item["fields"]:
            self.assertTrue(projected["metadataOnly"])
            self.assertEqual(projected["after"], REPORT.MISSING)
            if projected["path"] != "properties.isolationScope":
                self.assertEqual(projected["before"], REPORT.WITHHELD)
                self.assertEqual(projected["metadataReason"], "GENERATED_IDENTITY_PROPERTY")
        for value in IDS.values():
            self.assertNotIn(value, json.dumps(item))

    def test_exact_generated_id_leaf_omissions_are_background(self):
        for name, value in IDS.items():
            for after in [ABSENT, None]:
                with self.subTest(name=name, after=after):
                    item = self.project(identity([field("properties." + name, value, after)]))
                    self.assertTrue(item["metadataOnly"])
                    self.assertEqual(item["fields"][0]["metadataReason"], "GENERATED_IDENTITY_PROPERTY")
                    self.assertEqual(item["fields"][0]["after"], REPORT.MISSING)

    def test_malformed_or_missing_generated_id_evidence_is_unresolved(self):
        for value in [ABSENT, None, "not-a-uuid", "[withheld]", "[reference('future')]", 123, {}, []]:
            with self.subTest(value=value):
                item = self.project(identity([field("properties.clientId", value)]))
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
                self.assertNotIn("metadataReason", item["fields"][0])

    def test_changed_generated_id_values_are_not_blanket_suppressed(self):
        for name, value in IDS.items():
            with self.subTest(name=name):
                item = self.project(identity([field("properties." + name, value, IDS["tenantId"], "Modify")]))
                self.assert_actionable(item)
                self.assertFalse(item["fields"][0]["metadataOnly"])

    def test_explicit_scope_changes_are_public_and_actionable(self):
        for before, after in [("None", "Regional"), ("Regional", "None")]:
            with self.subTest(before=before, after=after):
                item = self.project(identity([field("properties.isolationScope", before, after, "Modify")]))
                self.assert_actionable(item)
                projected, = item["fields"]
                self.assertEqual((projected["before"], projected["after"]), (before, after))

    def test_regional_restriction_removal_stays_actionable_in_coarse_and_leaf_forms(self):
        for delta in [[field("properties.isolationScope", "Regional")],
                      [field(before={**IDS, "isolationScope": "Regional"}, after=None)]]:
            with self.subTest(delta=delta):
                item = self.project(identity(delta))
                self.assert_actionable(item)
                scope, = [entry for entry in item["fields"] if entry["path"] == "properties.isolationScope"]
                self.assertEqual(scope["before"], "Regional")
                self.assertEqual(scope["after"], REPORT.MISSING)
                self.assertFalse(scope["metadataOnly"])

    def test_explicit_null_scope_is_not_the_none_enum_or_omission(self):
        for delta in [[field("properties.isolationScope", "None", None)],
                      [field(before={"isolationScope": "None"}, after={"isolationScope": None}, action="Modify")]]:
            with self.subTest(delta=delta):
                item = self.project(identity(delta, after_properties={"isolationScope": None}))
                self.assert_actionable(item)
                self.assertFalse(any(entry["metadataOnly"] for entry in item["fields"]))

    def test_null_delta_requires_snapshot_proof_of_omission(self):
        for after in [ABSENT, None, {"type": TYPE, "properties": None},
                      {"type": TYPE, "properties": {"isolationScope": None}}]:
            with self.subTest(after=after):
                raw = identity([field(before={"isolationScope": "None"}, after=None)])
                if after is ABSENT:
                    del raw["after"]
                else:
                    raw["after"] = after
                item = self.project(raw)
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
                self.assertEqual(item["fields"][0]["path"], "properties")

    def test_contradictory_desired_snapshot_never_hides_scope_change(self):
        for scope in [None, "None", "Regional"]:
            with self.subTest(scope=scope):
                item = self.project(identity([field("properties.isolationScope", "None")],
                                             after_properties={"isolationScope": scope}))
                self.assert_actionable(item)
                self.assertFalse(item["fields"][0]["metadataOnly"])
                self.assertTrue(item["fields"][0]["unresolved"])

    def test_contradictory_snapshot_cannot_reclassify_generated_field_as_background(self):
        for key, value in IDS.items():
            with self.subTest(key=key):
                item = self.project(identity([field("properties." + key, value)],
                                             after_properties={key: value}))
                self.assert_actionable(item)
                self.assertTrue(item["fields"][0]["unresolved"])

    def test_missing_withheld_empty_or_malformed_coarse_payload_stays_unresolved(self):
        for before in [ABSENT, None, "[withheld]", "[unresolved expression]", [], {}, "opaque-value"]:
            with self.subTest(before=before):
                item = self.project(identity([field(before=before, after=None)]))
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
                self.assertEqual(item["fields"][0]["path"], "properties")

    def test_unknown_writable_siblings_are_retained_without_values(self):
        for value in [True, "private-configuration", {"permissions": "private-inner-value"}]:
            with self.subTest(value=value):
                item = self.project(identity([field(before={**IDS, "isolationScope": "None", "futureSetting": value}, after=None)]))
                self.assert_actionable(item)
                unknown, = [entry for entry in item["fields"] if entry["path"] == "properties.futureSetting"]
                self.assertFalse(unknown["metadataOnly"])
                self.assertNotIn("private-configuration", json.dumps(item))
                self.assertNotIn("private-inner-value", json.dumps(item))

    def test_unknown_writable_changes_do_not_use_python_scalar_equality(self):
        for before, after in [(1, True), ({"a": 1}, {"a": True})]:
            with self.subTest(before=before, after=after):
                item = self.project(identity([field(before={"futureSetting": before}, after={"futureSetting": after}, action="Modify")]))
                self.assert_actionable(item)
                self.assertEqual(item["fields"][0]["path"], "properties.futureSetting")

    def test_unknown_scope_values_or_expressions_stay_private_and_actionable(self):
        for value in ["FutureScope", "REGIONAL", "private-scope-value", "[reference('future').scope]", None, 1]:
            with self.subTest(value=value):
                item = self.project(identity([field("properties.isolationScope", value)]))
                self.assert_actionable(item)
                self.assertFalse(item["fields"][0]["metadataOnly"])
                self.assertNotIn("private-scope-value", json.dumps(item))

    def test_generated_metadata_does_not_hide_real_sibling_changes(self):
        item = self.project(identity([field("properties.clientId", IDS["clientId"]),
                                      field("properties.isolationScope", "None", "Regional", "Modify"),
                                      field("tags.CreatedDate", "yesterday", "[utcNow()]", "Modify")]))
        self.assert_actionable(item)
        self.assertEqual([entry["metadataOnly"] for entry in item["fields"]], [True, False, True])

    def test_coarse_modify_preserves_scope_and_skips_identical_generated_values(self):
        before = {**IDS, "isolationScope": "None"}
        after = {**IDS, "isolationScope": "Regional"}
        item = self.project(identity([field(before=before, after=after, action="Modify")], after_properties=after))
        self.assert_actionable(item)
        self.assertEqual([entry["path"] for entry in item["fields"]], ["properties.isolationScope"])
        self.assertEqual(item["fields"][0]["after"], "Regional")

    def test_children_and_child_delta_forms_keep_absolute_and_relative_paths(self):
        for key, path in [("children", "isolationScope"), ("childDelta", "properties.isolationScope")]:
            with self.subTest(key=key):
                parent = field(action="Modify", **{key: [field(path, "None", "Regional", "Modify")]})
                item = self.project(identity([parent], after_properties={"isolationScope": "Regional"}))
                self.assert_actionable(item)
                self.assertEqual(item["fields"][0]["path"], "properties.isolationScope")

    def test_resource_creates_deletes_and_potential_updates_are_never_metadata_only(self):
        for action, potential in [("Create", False), ("Delete", False), ("Modify", True)]:
            with self.subTest(action=action, potential=potential):
                item = self.project(identity([field(before={**IDS, "isolationScope": "None"}, after=None)], action=action), potential)
                self.assertFalse(item["metadataOnly"])
                self.assertFalse(any(entry["metadataOnly"] for entry in item["fields"]))
                self.assertEqual(item["changeType"], action)

    def test_unrelated_types_and_lookalike_paths_never_receive_identity_metadata_rules(self):
        cases = [identity([field("properties.clientId", IDS["clientId"])], resource_type="Microsoft.Example/resources"),
                 identity([field("properties.isolationScope", "None")], resource_type=TYPE + "/federatedIdentityCredentials"),
                 identity([field("properties.nested.clientId", IDS["clientId"])]),
                 identity([field("properties.clientIdSuffix", IDS["clientId"])])]
        for raw in cases:
            with self.subTest(raw=raw):
                item = self.project(raw)
                self.assertFalse(item["metadataOnly"])
                self.assertFalse(any(entry["metadataOnly"] for entry in item["fields"]))

    def test_scope_enum_publication_is_limited_to_the_exact_identity_type_and_path(self):
        for kind, path in [("Microsoft.Example/resources", "properties.isolationScope"),
                           (TYPE + "/federatedIdentityCredentials", "properties.isolationScope"),
                           (TYPE, "properties.nested.isolationScope")]:
            with self.subTest(kind=kind, path=path):
                item = self.project(identity([field(path, "None", "Regional", "Modify")], resource_type=kind))
                self.assertEqual(item["fields"][0]["after"], REPORT.WITHHELD)

    def test_invalid_or_ambiguous_coarse_keys_keep_original_coarse_gap(self):
        for properties in [{"clientId": IDS["clientId"], "ClientId": IDS["clientId"]},
                           {"isolationScope": "None", "unsafe.key": "private-value"},
                           {1: "private-value"}]:
            with self.subTest(properties=properties):
                item = self.project(identity([field(before=properties, after=None)]))
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
                self.assertEqual(item["fields"][0]["path"], "properties")
                self.assertNotIn("private-value", json.dumps(item))

    def test_incomplete_children_cannot_erase_writable_coarse_properties(self):
        for properties in [{**IDS, "isolationScope": "Regional"},
                           {**IDS, "isolationScope": "None", "futureSetting": True}]:
            with self.subTest(properties=properties):
                partial = field(before=properties, after=None,
                                children=[field("clientId", IDS["clientId"])])
                item = self.project(identity([partial]))
                self.assert_actionable(item)
                self.assertTrue(any(not entry["metadataOnly"] for entry in item["fields"]))

    def test_malformed_child_evidence_keeps_coarse_gap_but_normal_null_is_allowed(self):
        for children in ["invalid", {"path": "private"}, [None]]:
            with self.subTest(children=children):
                raw = identity([field(before={"isolationScope": "None"}, after=None, children=children)])
                item = self.project(raw)
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
        normal = self.project(identity([field(before={"isolationScope": "None"}, after=None, children=None)]))
        self.assertTrue(normal["metadataOnly"])

    def test_unavailable_or_mismatched_resource_identity_keeps_the_assessment_gap(self):
        invalid_ids = [ABSENT, None, "unavailable", "[reference('future').id]",
                       RID + "Microsoft.Network/networkSecurityGroups/identity",
                       RID + TYPE + "/identity/providers/Microsoft.Authorization/roleAssignments/assignment",
                       RID.replace("11111111-1111-4111-8111-111111111111", "not-a-subscription") + TYPE + "/identity"]
        for resource_id in invalid_ids:
            with self.subTest(resource_id=resource_id):
                raw = identity([field(before={**IDS, "isolationScope": "None"}, after=None)])
                if resource_id is ABSENT:
                    del raw["resourceId"]
                else:
                    raw["resourceId"] = resource_id
                item = self.project(raw)
                self.assert_actionable(item)
                self.assertTrue(item["unresolved"])
                self.assertFalse(REPORT.is_metadata_only(item))
                self.assertTrue(all(entry["unresolved"] for entry in item["fields"]))
                self.assertTrue(all(not entry["metadataOnly"] for entry in item["fields"]))
                self.assertTrue(all("metadataReason" not in entry for entry in item["fields"]))


if __name__ == "__main__":
    unittest.main()
