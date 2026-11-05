"""Show writable Redis settings while proving the narrow background exceptions."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import infrastructure_plan_comparison as COMPARISON
import infrastructure_plan_markdown as MARKDOWN
import infrastructure_plan_metadata as METADATA
import infrastructure_plan_redis as REDIS
import infrastructure_plan_report as REPORT


TYPE = "Microsoft.Cache/redis"
RID = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/" + TYPE + "/cache"
CONFIG = {"maxclients": "1000", "maxmemory-reserved": "125", "maxmemory-delta": "125",
          "maxfragmentationmemory-reserved": "125"}
SKU = {"name": "Standard", "family": "C", "capacity": 1}
ABSENT = object()


def delta(path, before=ABSENT, after=ABSENT, action="Delete"):
    result = {"path": path, "propertyChangeType": action}
    for side, value in (("before", before), ("after", after)):
        if value is not ABSENT:
            result[side] = value
    return result


def cache_change(config=None, zone="Automatic"):
    config = copy.deepcopy(CONFIG if config is None else config)
    return {"resourceId": RID, "changeType": "Modify",
            "before": {"type": TYPE, "id": RID, "name": "cache", "zones": None,
                       "properties": {"sku": dict(SKU), "redisVersion": "6.0",
                                      "redisConfiguration": config, "zonalAllocationPolicy": zone}},
            "after": {"type": TYPE, "id": RID, "name": "cache", "apiVersion": "2024-11-01",
                      "properties": {"sku": dict(SKU), "redisVersion": "6.0"}},
            "delta": [delta(REDIS.CONFIG, config, None), delta(REDIS.ZONE, zone, None)]}


def leaves(raw):
    config = raw["before"]["properties"]["redisConfiguration"]
    raw["delta"] = [delta(REDIS.CONFIG + "." + key, value) for key, value in config.items()] + raw["delta"][1:]
    return raw


class RedisPropertyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, raw, environment="TST", potential=False):
        result = {"status": "Succeeded", "changes": [] if potential else [raw]}
        if potential:
            result["potentialChanges"] = [raw]
        destination = self.root / environment
        report = REPORT.write_environment_report(destination, {
            "environment": environment, "commit": "a" * 40, "buildId": "42",
            "sourceRef": "refs/heads/main", "generatedAt": "2026-11-05T10:00:00Z"},
            [{"name": "infra", "status": "complete", "result": result}])
        self.summary = (destination / "summary.md").read_text()
        self.details = (destination / "change-details.md").read_text()
        self.serialized = (destination / "plan.json").read_text()
        return report

    def fields(self, raw):
        return {field["path"]: field for field in REPORT._resource(raw)["fields"]}

    def assert_not_background(self, raw, potential=False):
        resource = REPORT._resource(raw, potential=potential)
        self.assertFalse(resource["metadataOnly"])
        self.assertFalse(COMPARISON._background(resource))
        return resource

    def combine(self):
        output = self.root / "combined"
        result = subprocess.run([sys.executable, str(Path(REPORT.__file__)), "--combine", str(self.root),
                                 "--output-dir", str(output)], capture_output=True, text=True, timeout=10)
        return result, json.loads((output / "plan.json").read_text()), (output / "summary.md").read_text()

    def test_complete_omitted_bag_expands_without_mutating_input_or_hiding_memory(self):
        raw = cache_change()
        original = copy.deepcopy(raw)
        report = self.write(raw)
        resource = report["components"][0]["resources"][0]
        self.assertEqual(original, raw)
        self.assertEqual(1, report["resourceTotals"]["Modify"])
        self.assertFalse(resource["metadataOnly"])
        self.assertFalse(resource["unresolved"])
        fields = {field["path"]: field for field in resource["fields"]}
        self.assertEqual({REDIS.CONFIG + "." + key for key in CONFIG} | {REDIS.ZONE}, set(fields))
        for key in REDIS.MEMORY_KEYS:
            entry = fields[REDIS.CONFIG + "." + key]
            self.assertFalse(entry["metadataOnly"])
            self.assertEqual("125", entry["before"])
            self.assertEqual(REPORT.MISSING, entry["after"])
            self.assertEqual(REDIS.OMISSION, entry["configurationOmission"])
            self.assertEqual(REDIS.EXPANSION, entry["configurationSource"])
            self.assertEqual("Delete", entry["configurationOperation"])
            self.assertIn(key, self.summary)
        self.assertEqual(2, sum(field["metadataOnly"] for field in fields.values()))
        self.assertIn("Not explicitly configured", self.summary)
        self.assertIn("current: 125 MB; writable setting", self.summary)
        self.assertIn("expanded from Delete configuration bag", self.details)
        self.assertNotIn("Remove property from proposed config: resource properties", self.summary)

    def test_direct_leaf_omissions_have_same_meaning_without_claiming_bag_expansion(self):
        raw = leaves(cache_change())
        resource = REPORT._resource(raw)
        self.assertFalse(resource["metadataOnly"])
        self.assertEqual(3, sum(field.get("configurationOmission") == REDIS.OMISSION for field in resource["fields"]))
        self.assertFalse(any("configurationSource" in field for field in resource["fields"]))

    def test_only_read_only_maxclients_and_unchanged_automatic_are_background(self):
        for config in ({"maxclients": "1000"}, {"maxclients": "2000"}):
            raw = cache_change(config)
            report = self.write(raw)
            resource = report["components"][0]["resources"][0]
            self.assertEqual(0, report["resourceTotals"]["Modify"])
            self.assertTrue(resource["metadataOnly"])
            self.assertEqual({REDIS.READ_ONLY, REDIS.AUTOMATIC}, {field["metadataReason"] for field in resource["fields"]})
            self.assertIn("read-only connection-limit", self.details)
            self.assertNotIn("| Update | Redis cache", self.summary)

    def test_each_proven_field_can_be_assessed_independently(self):
        raw = leaves(cache_change({"maxclients": "1000"}))
        raw["delta"] = raw["delta"][:1]
        raw["after"]["properties"]["zonalAllocationPolicy"] = "Automatic"
        self.assertTrue(REPORT._resource(raw)["metadataOnly"])
        raw = cache_change({})
        raw["before"]["properties"].pop("redisConfiguration")
        raw["delta"] = raw["delta"][1:]
        self.assertTrue(REPORT._resource(raw)["metadataOnly"])

    def test_memory_defaults_are_not_inferred_from_sku_or_current_value(self):
        for value in ("0", "125", "250", "999999999"):
            raw = cache_change({key: value for key in REDIS.MEMORY_KEYS})
            fields = self.fields(raw)
            for key in REDIS.MEMORY_KEYS:
                entry = fields[REDIS.CONFIG + "." + key]
                self.assertFalse(entry["metadataOnly"])
                self.assertEqual(value, entry["before"])
                self.assertEqual(REDIS.OMISSION, entry["configurationOmission"])
            self.assert_not_background(raw)

    def test_real_memory_edit_is_visible_with_values_and_other_omissions(self):
        raw = cache_change()
        after = {"maxmemory-reserved": "250"}
        raw["after"]["properties"]["redisConfiguration"] = after
        raw["delta"][0] = delta(REDIS.CONFIG, copy.deepcopy(CONFIG), after, "Modify")
        report = self.write(raw)
        self.assertEqual(1, report["resourceTotals"]["Modify"])
        self.assertIn("maxmemory-reserved, MB): 125 → 250", self.summary)
        self.assertEqual("250", self.fields(raw)[REDIS.CONFIG + ".maxmemory-reserved"]["after"])

    def test_explicit_zone_edit_precedes_memory_omissions_in_primary_summaries(self):
        for after in ("NoZones", "UserDefined"):
            raw = cache_change()
            raw["after"]["properties"]["zonalAllocationPolicy"] = after
            raw["delta"][1] = delta(REDIS.ZONE, "Automatic", after, "Modify")
            for environment in REPORT.PREVIEW_ENVIRONMENTS:
                self.write(raw, environment)
            self.assertIn("Redis zone allocation policy: Automatic → " + after, self.summary)
            self.assertLess(self.summary.index("Redis zone allocation policy"), self.summary.index("Not explicitly configured"))
            result, report, summary = self.combine()
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("Change Redis zone allocation policy", summary)
            relevant = next(line for line in summary.splitlines() if "| Update | Redis cache: cache |" in line)
            self.assertLess(relevant.index("Change Redis zone allocation policy"), relevant.index("Not explicitly configured"))
            self.assertIn("maxmemory-reserved", relevant)
            self.assertIn("maxmemory-delta", relevant)
            self.assertIn("+1 more", relevant)

    def test_explicit_policy_additions_removals_and_migrations_are_not_background(self):
        for before, after, action in (("NoZones", ABSENT, "Delete"), ("UserDefined", ABSENT, "Delete"),
                                      ("NoZones", "Automatic", "Modify"), (ABSENT, "Automatic", "Create"),
                                      ("Automatic", "Automatic", "Modify"), ("Automatic", None, "Modify")):
            raw = cache_change({"maxclients": "1000"})
            if before is ABSENT:
                raw["before"]["properties"].pop("zonalAllocationPolicy")
            else:
                raw["before"]["properties"]["zonalAllocationPolicy"] = before
            if after is not ABSENT:
                raw["after"]["properties"]["zonalAllocationPolicy"] = after
            raw["delta"][1] = delta(REDIS.ZONE, before, after, action)
            resource = self.assert_not_background(raw)
            self.assertFalse(next(field for field in resource["fields"] if field["path"] == REDIS.ZONE)["metadataOnly"])

    def test_automatic_proof_requires_canonical_unchanged_documented_sku(self):
        invalid = ({}, {"unexpected": "x"}, {"name": "Standard", "family": "C", "capacity": True},
                   {"name": "Standard", "family": "C", "capacity": "1"},
                   {"name": "Standard", "family": "C", "capacity": 7},
                   {"name": "Premium", "family": "P", "capacity": 5},
                   {"name": "Basic", "family": "C", "capacity": 1},
                   {**SKU, "Capacity": 1}, {**SKU, "unknown": "x"})
        for sku in invalid:
            raw = cache_change({"maxclients": "1000"})
            for side in ("before", "after"):
                raw[side]["properties"]["sku"] = copy.deepcopy(sku)
            self.assertFalse(self.fields(raw)[REDIS.ZONE]["metadataOnly"], repr(sku))
        for name, family, capacity in (("Standard", "C", 0), ("Standard", "C", 6), ("Premium", "P", 1), ("Premium", "P", 4)):
            raw = cache_change({"maxclients": "1000"})
            for side in ("before", "after"):
                raw[side]["properties"]["sku"] = {"name": name, "family": family, "capacity": capacity}
            self.assertTrue(self.fields(raw)[REDIS.ZONE]["metadataOnly"])
        raw = cache_change({"maxclients": "1000"})
        raw["after"]["properties"]["sku"]["capacity"] = 2
        self.assertFalse(self.fields(raw)[REDIS.ZONE]["metadataOnly"])

    def test_any_explicit_or_changed_zones_prevents_automatic_exception(self):
        for before, after in ((["1", "2"], ["1", "2"]), (None, ["1"]), (["1"], None), ([], [])):
            raw = cache_change({"maxclients": "1000"})
            raw["before"]["zones"], raw["after"]["zones"] = before, after
            self.assertFalse(self.fields(raw)[REDIS.ZONE]["metadataOnly"])
        raw = cache_change({"maxclients": "1000"})
        raw["delta"].append(delta("zones", None, None, "NoEffect"))
        self.assertFalse(self.fields(raw)[REDIS.ZONE]["metadataOnly"])

    def test_snapshot_identity_type_and_api_must_validate_before_values_are_published(self):
        mutations = [lambda x: x.update(resourceId="unavailable"),
                     lambda x: x.update(resourceId=RID.replace("Microsoft.Cache/redis", "Microsoft.Insights/components")),
                     lambda x: x.update(resourceId=RID + "/nested/other"),
                     lambda x: x.pop("before"), lambda x: x.pop("after"),
                     lambda x: x["before"].update(type="Microsoft.Storage/storageAccounts"),
                     lambda x: x["after"].update(id=RID + "-other"),
                     lambda x: x["before"].update(name="another-cache"),
                     lambda x: x["after"].update(apiVersion="1900-01-01"),
                     lambda x: x["after"].update(properties=None)]
        for mutate in mutations:
            raw = cache_change()
            mutate(raw)
            resource = self.assert_not_background(raw)
            self.assertFalse(any(field.get("metadataReason") in {REDIS.READ_ONLY, REDIS.AUTOMATIC} for field in resource["fields"]))
            self.assertNotIn('"125"', json.dumps(resource))
        for resource_type in (TYPE, "Microsoft.Insights/components", ""):
            self.assertEqual(REPORT.WITHHELD, REPORT._public_value(REDIS.CONFIG + ".maxmemory-reserved", "123456", True, resource_type))

    def test_explicit_null_and_mismatched_raw_bag_do_not_establish_omission(self):
        for key, value in (("redisConfiguration", None), ("redisConfiguration", {}), ("zonalAllocationPolicy", None)):
            raw = cache_change({"maxclients": "1000"})
            raw["after"]["properties"][key] = value
            self.assert_not_background(raw)
        raw = cache_change({"maxclients": "1000"})
        raw["delta"][0]["before"] = {"maxclients": "2000"}
        fields = self.fields(raw)
        self.assertTrue(fields[REDIS.CONFIG]["unresolved"])
        self.assert_not_background(raw)

    def test_unknown_keys_and_secret_configuration_values_never_use_global_allowlists(self):
        values = {"name": "PRIVATE-NAME", "type": "PRIVATE-TYPE", "capacity": 654321, "enabled": True,
                  "maxmemory-policy": "PRIVATE-POLICY", "rdb-storage-connection-string": "PRIVATE-CONNECTION",
                  "nested": {"name": "PRIVATE-NESTED"}, "maxmemory-reserved": "125"}
        for action in ("Delete", "Create", "Modify"):
            raw = cache_change(values)
            if action == "Create":
                raw["before"]["properties"].pop("redisConfiguration")
                raw["after"]["properties"]["redisConfiguration"] = copy.deepcopy(values)
                raw["delta"][0] = delta(REDIS.CONFIG, None, copy.deepcopy(values), "Create")
            elif action == "Modify":
                changed = {key: "PRIVATE-AFTER" for key in values}
                raw["after"]["properties"]["redisConfiguration"] = changed
                raw["delta"][0] = delta(REDIS.CONFIG, copy.deepcopy(values), changed, "Modify")
            report = self.write(raw)
            public = self.serialized + self.summary + self.details + json.dumps(COMPARISON.analyze_comparison(None, report, {}))
            for secret in ("PRIVATE-", "654321"):
                self.assertNotIn(secret, public)
            for field in report["components"][0]["resources"][0]["fields"]:
                if field["path"].startswith(REDIS.CONFIG + ".") and field["path"] != REDIS.CONFIG + ".maxmemory-reserved":
                    self.assertIn(field["before"], (REPORT.WITHHELD, REPORT.MISSING))
                    self.assertIn(field["after"], (REPORT.WITHHELD, REPORT.MISSING))
            self.assert_not_background(raw)

    def test_only_canonical_numeric_strings_are_public_and_never_expressions(self):
        self.assertEqual(REPORT.WITHHELD, REDIS.public_config_value("maxmemory-reserved", "125"))
        for value in (125, True, 1.0, "0125", "-1", "125.0", "1000000000", "[reference('PRIVATE')]", None, {}, []):
            raw = cache_change({"maxmemory-reserved": value, "maxclients": value})
            fields = self.fields(raw)
            for key in ("maxmemory-reserved", "maxclients"):
                field = fields[REDIS.CONFIG + "." + key]
                self.assertEqual("[unresolved expression]" if value == "[reference('PRIVATE')]" else REPORT.WITHHELD, field["before"])
                self.assertFalse(field["metadataOnly"])
                self.assertNotIn("configurationOmission", field)
            self.assert_not_background(raw)

    def test_sparse_background_deltas_cannot_hide_other_snapshot_changes(self):
        for mutation in (lambda x: x["after"]["properties"].update(unknownSetting="PRIVATE-NEW"),
                         lambda x: x["after"].update(location="ukwest"),
                         lambda x: x["after"]["properties"]["sku"].update(capacity=2),
                         lambda x: x["after"]["properties"].update(redisConfiguration={"maxmemory-reserved": "250"})):
            raw = cache_change({"maxclients": "1000"})
            mutation(raw)
            report = self.write(raw)
            resource = report["components"][0]["resources"][0]
            self.assertFalse(resource["metadataOnly"])
            self.assertEqual(1, report["resourceTotals"]["Modify"])
            if resource["unresolved"]:
                self.assertFalse(report["complete"])
            else:
                self.assertFalse(next(field for field in resource["fields"] if field["path"] == REDIS.ZONE)["metadataOnly"])
            self.assertNotIn("PRIVATE-NEW", self.serialized + self.summary + self.details)

    def test_coarse_containers_and_conflicting_children_cannot_hide_settings(self):
        raw = cache_change({"maxclients": "1000", "maxmemory-reserved": "125"})
        raw["delta"][0]["children"] = [delta("maxclients", "1000")]
        resource = self.assert_not_background(raw)
        self.assertTrue(resource["unresolved"])
        self.assertTrue(any(field["path"] == REDIS.CONFIG and field["unresolved"] for field in resource["fields"]))
        raw = cache_change()
        raw["delta"] = [{"path": "properties", "propertyChangeType": "Modify",
                         "before": copy.deepcopy(raw["before"]["properties"]),
                         "after": copy.deepcopy(raw["after"]["properties"]),
                         "children": [delta("tags.CreatedDate", "before", "after", "Modify")]}]
        resource = self.assert_not_background(raw)
        self.assertTrue(resource["unresolved"])
        self.assertTrue(any(field["path"] == "properties" for field in resource["fields"]))

    def test_structural_aliases_duplicate_paths_and_value_carrying_parents_fail_closed(self):
        for canonical in ("resourceId", "changeType", "before", "after", "delta"):
            raw = cache_change({"maxclients": "1000"})
            raw[canonical.upper()] = raw[canonical]
            self.assert_not_background(raw)
        for alias in ("Before", "After", "Children", "ChildDelta", "Path", "PropertyChangeType"):
            raw = cache_change({"maxclients": "1000"})
            raw["delta"][0][alias] = "PRIVATE-ALIAS"
            self.assert_not_background(raw)
        for duplicate in (copy.deepcopy(cache_change()["delta"][0]),
                          delta("properties.redisconfiguration", {"maxclients": "1000"})):
            raw = cache_change({"maxclients": "1000"})
            raw["delta"].append(duplicate)
            self.assert_not_background(raw)
        raw = cache_change({"maxclients": "1000"})
        raw["delta"] = [{"path": "properties", "propertyChangeType": "Delete", "children": raw["delta"]}]
        self.assert_not_background(raw)

    def test_transparent_parent_supports_complete_evidence(self):
        raw = cache_change({"maxclients": "1000"})
        raw["delta"] = [{"path": "properties", "propertyChangeType": "Modify", "children": raw["delta"]}]
        self.assertTrue(REPORT._resource(raw)["metadataOnly"])

    def test_invalid_context_cannot_disappear_behind_date_only_delta(self):
        mutations = (lambda x: x["before"].update(Properties=x["before"].pop("properties")),
                     lambda x: x["before"]["properties"].update(RedisConfiguration=x["before"]["properties"].pop("redisConfiguration")),
                     lambda x: x["before"].update(properties=None),
                     lambda x: x.pop("before"))
        for mutate in mutations:
            raw = cache_change()
            raw["delta"] = [delta("tags.CreatedDate", "before", "after", "Modify")]
            mutate(raw)
            resource = self.assert_not_background(raw)
            self.assertTrue(resource["unresolved"])
            self.assertTrue(any(field["path"] == REDIS.CONFIG and field["unresolved"] for field in resource["fields"]))

    def test_sparse_date_only_delta_cannot_hide_changed_redis_snapshots(self):
        for mutate in (lambda x: x["after"]["properties"]["redisConfiguration"].update({"maxmemory-reserved": "250"}),
                       lambda x: x["after"]["properties"].update(zonalAllocationPolicy="NoZones"),
                       lambda x: x["after"].update(zones=["1", "2"])):
            raw = cache_change()
            raw["after"]["properties"].update(redisConfiguration=copy.deepcopy(CONFIG), zonalAllocationPolicy="Automatic")
            raw["delta"] = [delta("tags.CreatedDate", "before", "after", "Modify")]
            mutate(raw)
            report = self.write(raw)
            resource = report["components"][0]["resources"][0]
            self.assertFalse(resource["metadataOnly"])
            self.assertTrue(resource["unresolved"])
            self.assertFalse(report["complete"])
            self.assertEqual(1, report["resourceTotals"]["Modify"])

    def test_resource_creates_deletes_and_potential_actions_stay_reviewable(self):
        for action in ("Create", "Delete", "Deploy", "Unknown"):
            raw = cache_change({"maxclients": "1000"})
            raw["changeType"] = action
            self.assert_not_background(raw)
        self.assert_not_background(cache_change({"maxclients": "1000"}), potential=True)

    def test_sanitized_rechecks_reject_forged_metadata_and_omission_facts(self):
        original = REPORT._resource(cache_change({"maxclients": "1000"}))
        for key, value in (("metadataReason", "untrusted"), ("before", "PRIVATE"), ("after", None),
                           ("unresolved", True), ("changeType", "Modify"), ("metadataOnly", False)):
            item = copy.deepcopy(original)
            for field in item["fields"]:
                field[key] = value
            self.assertFalse(METADATA.is_metadata_only(item), (key, value))
            self.assertFalse(COMPARISON._background(item))
        for rid in ("unavailable", RID + "/nested/other", RID.replace("redis", "other")):
            item = copy.deepcopy(original)
            item["resourceId"] = rid
            self.assertFalse(METADATA.is_metadata_only(item))
            self.assertFalse(COMPARISON._background(item))
        original = self.fields(cache_change())[REDIS.CONFIG + ".maxmemory-reserved"]
        for key, value in (("configurationOmission", "untrusted"), ("before", 125), ("before", "PRIVATE"),
                           ("after", REPORT.WITHHELD), ("unresolved", True), ("changeType", "Modify"),
                           ("metadataOnly", True)):
            field = {**original, key: value}
            self.assertFalse(REDIS.omission_reason(TYPE, field, RID), (key, value))
            self.assertEqual({}, REDIS.comparison_setting(TYPE, field, RID))

    def test_unresolved_resource_flag_and_noeffect_guards_remain_intact(self):
        raw = cache_change({"maxclients": "1000"})
        item = REPORT._resource(raw)
        item["unresolved"] = True
        self.assertFalse(METADATA.is_metadata_only(item))
        self.assertFalse(COMPARISON._background(item))
        item["fields"].append({"path": "location", "changeType": "NoEffect"})
        self.assertFalse(MARKDOWN.is_no_effect_only(item))
        raw["delta"].append(delta("location", "uksouth", "uksouth", "NoEffect"))
        self.assertTrue(MARKDOWN.is_no_effect_only(REPORT._resource(raw)))

    def test_combined_cli_copies_only_validated_memory_omission_values(self):
        for environment in REPORT.PREVIEW_ENVIRONMENTS:
            self.write(cache_change(), environment)
        result, combined, summary = self.combine()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(combined["comparisonAvailable"])
        self.assertIn("Not explicitly configured: Redis memory reserve (maxmemory-reserved, MB) (current: 125 MB; writable setting)", summary)
        self.assertIn("Redis fragmentation reserve (maxfragmentationmemory-reserved, MB)", summary)
        self.assertNotIn("Remove property from config: resource properties", summary)
        for comparison in combined["devComparison"]:
            resource = comparison["resources"][0]
            self.assertEqual("review-needed", resource["classification"])
            self.assertEqual(3, sum(field.get("configurationOmission") == REDIS.OMISSION for field in resource["fields"]))
            self.assertEqual(2, sum(field["classification"] == "background" for field in resource["fields"]))
            self.assertTrue(all(field.get("currentMemoryMB") == "125" for field in resource["fields"] if "currentMemoryMB" in field))
            self.assertFalse(any("before" in field or "after" in field for field in resource["fields"]))

    def test_zone_policy_is_not_in_generic_recurring_noise_allowlist(self):
        self.assertNotIn(REDIS.ZONE.lower(), COMPARISON._OMITTED_DEFAULTS[REDIS.REDIS_TYPE])


if __name__ == "__main__":
    unittest.main()
