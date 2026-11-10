"""Exercise AKS omission evidence through raw ARM reporting and publication."""

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import infrastructure_plan_aks as AKS
import infrastructure_plan_report as REPORT


TYPE = "Microsoft.ContainerService/managedClusters"
RID = "/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/" + TYPE + "/cluster"
ABSENT = object()
POOL = {
    "name": "system", "provisioningState": "Succeeded", "powerState": {"code": "Running"},
    "enableAutoScaling": True, "minCount": 3, "maxCount": 5,
}


def field(path, before=ABSENT, after=None, action="Delete", **extra):
    result = {"path": path, "propertyChangeType": action, **extra}
    if before is not ABSENT:
        result["before"] = before
    if after is not ABSENT:
        result["after"] = after
    return result


def set_path(snapshot, path, value):
    parts = path.split(".")
    cursor = snapshot
    for part in parts[:-1]:
        if isinstance(cursor, list):
            cursor = cursor[int(part)]
        else:
            cursor = cursor.setdefault(part, {})
    if isinstance(cursor, list):
        cursor[int(parts[-1])] = value
    else:
        cursor[parts[-1]] = value


def cluster(delta, action="Modify", resource_id=RID, resource_type=TYPE):
    before = {
        "type": resource_type,
        "properties": {
            "provisioningState": "Succeeded", "powerState": {"code": "Running"},
            "agentPoolProfiles": [copy.deepcopy(POOL), {**copy.deepcopy(POOL), "name": "user", "maxCount": 12}],
        },
    }
    after = {
        "type": resource_type,
        "properties": {"agentPoolProfiles": [
            {"name": "system", "enableAutoScaling": True, "minCount": 3, "maxCount": 5},
            {"name": "user", "enableAutoScaling": True, "minCount": 3, "maxCount": 12},
        ]},
    }
    for change in delta:
        if "before" in change:
            set_path(before, change["path"], copy.deepcopy(change["before"]))
    return {"resourceId": resource_id, "changeType": action, "before": before, "after": after, "delta": delta}


class AksPropertyProjectionTests(unittest.TestCase):
    def project(self, raw, potential=False):
        return REPORT._resource(raw, potential=potential)

    def assert_background(self, raw, path, pool=None):
        original = copy.deepcopy(raw)
        item = self.project(raw)
        self.assertEqual(original, raw, "Projection must not mutate ARM input")
        self.assertTrue(item["metadataOnly"])
        self.assertFalse(item["unresolved"])
        self.assertEqual("Modify", item["changeType"], "Retain the original ARM resource action")
        projected, = item["fields"]
        self.assertEqual(path, projected["path"])
        self.assertTrue(projected["metadataOnly"])
        self.assertEqual(REPORT.MISSING, projected["after"])
        self.assertEqual("AKS_READ_ONLY_PROPERTY", projected["metadataReason"])
        if pool:
            self.assertEqual(pool, projected["aksPoolName"])
        return item

    def test_exact_readonly_cluster_omissions_retain_auditable_metadata(self):
        values = {
            "provisioningState": "Succeeded", "powerState": {"code": "Running"},
            "maxAgentPools": 100, "currentKubernetesVersion": "1.34.7",
            "fqdn": "PRIVATE-FQDN.cluster.example", "privateFQDN": "PRIVATE-FQDN.internal.example",
            "azurePortalFQDN": "PRIVATE-FQDN.portal.example",
            "resourceUID": "22222222-3333-4444-8555-666666666666",
        }
        for name, value in values.items():
            path = "properties." + name
            with self.subTest(path=path):
                item = self.assert_background(cluster([field(path, value)]), path)
                self.assertNotIn("PRIVATE-FQDN", json.dumps(item))
                self.assertNotIn("22222222-3333-4444-8555-666666666666", json.dumps(item))

    def test_readonly_pool_omissions_require_named_pool_attribution(self):
        values = {"eTag": "PRIVATE-ETAG", "currentOrchestratorVersion": "1.34.7",
                  "nodeImageVersion": "AKSUbuntu-2204gen2containerd-202611.01.0",
                  "provisioningState": "Succeeded", "status": {}}
        for index, name in [(0, "system"), (1, "user")]:
            for leaf, value in values.items():
                path = f"properties.agentPoolProfiles.{index}.{leaf}"
                with self.subTest(pool=name, leaf=leaf):
                    item = self.assert_background(cluster([field(path, value)]), path, name)
                    self.assertNotIn("PRIVATE-ETAG", json.dumps(item))

    def test_only_actual_omissions_are_filtered_not_explicit_updates(self):
        path = "properties.currentKubernetesVersion"
        raw = cluster([field(path, "1.34.6", "1.34.7", "Modify")])
        set_path(raw["after"], path, "1.34.7")
        self.assertFalse(self.project(raw)["metadataOnly"])
        for value in [None, "1.34.7"]:
            raw = cluster([field(path, "1.34.7")])
            set_path(raw["after"], path, value)
            with self.subTest(desired=value):
                self.assertFalse(self.project(raw)["metadataOnly"])

    def test_missing_or_contradictory_raw_evidence_stays_reviewable(self):
        path = "properties.currentKubernetesVersion"
        fixtures = []
        for snapshot in ["before", "after"]:
            for value in [ABSENT, None, {}, {"type": TYPE, "properties": None}]:
                raw = cluster([field(path, "1.34.7")])
                if value is ABSENT:
                    del raw[snapshot]
                else:
                    raw[snapshot] = value
                fixtures.append(raw)
        raw = cluster([field(path, "1.34.7")])
        raw["before"]["properties"]["currentKubernetesVersion"] = "1.34.6"
        fixtures.append(raw)
        fixtures.append(cluster([field(path)]))
        for raw in fixtures:
            with self.subTest(raw=raw):
                self.assertFalse(self.project(raw)["metadataOnly"])

    def test_invalid_resource_reference_or_type_cannot_create_metadata_evidence(self):
        path = "properties.currentKubernetesVersion"
        for rid in [None, "unavailable", "[resourceId('future')]", RID.replace("managedClusters", "otherType"),
                    RID + "/agentPools/system", RID.replace("11111111-1111-4111-8111-111111111111", "bad")]:
            with self.subTest(rid=rid):
                self.assertFalse(self.project(cluster([field(path, "1.34.7")], resource_id=rid))["metadataOnly"])
        self.assertFalse(self.project(cluster([field(path, "1.34.7")], resource_type=TYPE + "/agentPools"))["metadataOnly"])

    def test_pool_reordering_uses_the_same_name_and_never_the_wrong_index(self):
        path = "properties.agentPoolProfiles.0.nodeImageVersion"
        raw = cluster([field(path, "image-current")])
        raw["after"]["properties"]["agentPoolProfiles"].reverse()
        self.assert_background(raw, path, "system")
        # The matching system pool now occupies index 1. Explicitly specifying
        # the field there contradicts an omission even though index 0 omits it.
        raw["after"]["properties"]["agentPoolProfiles"][1]["nodeImageVersion"] = "image-desired"
        self.assertFalse(self.project(raw)["metadataOnly"])

    def test_missing_duplicate_or_renamed_pools_prevent_index_based_suppression(self):
        path = "properties.agentPoolProfiles.0.nodeImageVersion"
        for side in ["before", "after"]:
            for pools in [None, {}, [], [{"name": "other"}], [{"name": "system"}, {"name": "system"}],
                          [{}, {"name": "user"}], [{"name": "[unknown]"}, {"name": "user"}]]:
                raw = cluster([field(path, "image-current")])
                raw[side]["properties"]["agentPoolProfiles"] = pools
                with self.subTest(side=side, pools=pools):
                    self.assertFalse(self.project(raw)["metadataOnly"])

    def test_writable_configuration_is_never_hidden_as_reported_state(self):
        values = {
            "properties.agentPoolProfiles.0.count": 3,
            "properties.agentPoolProfiles.0.powerState": {"code": "Running"},
            "properties.agentPoolProfiles.0.osDiskSizeGB": 128,
            "properties.agentPoolProfiles.0.enableAutoScaling": True,
            "properties.agentPoolProfiles.0.securityProfile.sshAccess": "LocalUser",
            "properties.enableRBAC": True,
            "properties.identityProfile": {"kubeletidentity": {"resourceId": "PRIVATE-CUSTOM-IDENTITY"}},
            "properties.securityProfile.defender": {"securityMonitoring": {"enabled": True}},
            "properties.servicePrincipalProfile": {"clientId": "msi"},
        }
        for path, value in values.items():
            with self.subTest(path=path):
                self.assertFalse(self.project(cluster([field(path, value)]))["metadataOnly"])

    def test_mixed_readonly_and_security_or_capacity_changes_remain_actions(self):
        readonly = "properties.agentPoolProfiles.0.nodeImageVersion"
        for path, before, after in [("properties.enableRBAC", True, False),
                                    ("properties.agentPoolProfiles.0.minCount", 3, 4),
                                    ("properties.agentPoolProfiles.0.enableAutoScaling", True, False)]:
            raw = cluster([field(readonly, "image-current"), field(path, before, after, "Modify")])
            set_path(raw["after"], path, after)
            item = self.project(raw)
            self.assertFalse(item["metadataOnly"])
            self.assertTrue(next(f for f in item["fields"] if f["path"] == readonly)["metadataOnly"])
            self.assertFalse(next(f for f in item["fields"] if f["path"] == path)["metadataOnly"])

    def test_failed_stopped_or_unknown_reported_states_stay_visible(self):
        for path, values in {
            "properties.provisioningState": ["Failed", "Canceled", "Updating", "Unknown"],
            "properties.powerState": [{"code": "Stopped"}, {"code": "Unknown"}, {}],
            "properties.agentPoolProfiles.0.provisioningState": ["Failed", "Canceled", "Updating"],
            "properties.agentPoolProfiles.0.status": [{"provisioningError": {"message": "PRIVATE-ERROR", "code": "PrivateCode"}}, {"futureField": None}],
        }.items():
            for value in values:
                item = self.project(cluster([field(path, value)]))
                with self.subTest(path=path, value=value):
                    self.assertFalse(item["metadataOnly"])
                    self.assertNotIn("PRIVATE-ERROR", json.dumps(item))

    def test_expressions_invalid_values_and_lookalike_paths_are_not_accepted(self):
        cases = [("properties.maxAgentPools", True), ("properties.maxAgentPools", 0),
                 ("properties.maxAgentPools", -1), ("properties.maxAgentPools", "100"),
                 ("properties.currentKubernetesVersion", "[reference('future')]"),
                 ("properties.agentPoolProfiles.0.nodeImageVersion", ""),
                 ("properties.future.currentKubernetesVersion", "1.34.7"),
                 ("properties.agentPoolProfiles.99.nodeImageVersion", "image-current")]
        for path, value in cases:
            raw = cluster([])
            raw["delta"] = [field(path, value)]
            if ".99." not in path:
                set_path(raw["before"], path, value)
            with self.subTest(path=path, value=value):
                self.assertFalse(self.project(raw)["metadataOnly"])

    def test_resource_creates_deletes_potential_and_unsupported_actions_stay_visible(self):
        for action, potential in [("Create", False), ("Delete", False), ("Modify", True), ("Unsupported", False)]:
            raw = cluster([field("properties.currentKubernetesVersion", "1.34.7")], action=action)
            with self.subTest(action=action, potential=potential):
                self.assertFalse(self.project(raw, potential=potential)["metadataOnly"])

    def test_health_warning_codes_never_publish_azure_error_messages(self):
        raw = cluster([field("properties.agentPoolProfiles.1.status", {
            "provisioningError": {"code": "PRIVATE-ERROR-CODE", "message": "PRIVATE-ERROR-MESSAGE"}})])
        raw["before"]["properties"]["agentPoolProfiles"][1]["provisioningState"] = "Failed"
        raw["before"]["properties"]["provisioningState"] = "Failed"
        warnings = AKS.aks_health_warnings(raw)
        self.assertIn({"code": "AKS_POOL_PROVISIONING_FAILED", "poolName": "user"}, warnings)
        self.assertIn({"code": "AKS_CLUSTER_PROVISIONING_FAILED"}, warnings)
        self.assertNotIn("PRIVATE-ERROR", json.dumps(warnings))
        for rid in ["unavailable", RID.replace("managedClusters", "otherType")]:
            malformed = {**raw, "resourceId": rid}
            self.assertEqual([], AKS.aks_health_warnings(malformed))

    def test_end_to_end_counts_audit_and_mixed_changes_do_not_require_a_dev_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = []
            for environment in ["DEV", "TST", "PRE", "PRD"]:
                raw = cluster([field("properties.agentPoolProfiles.1.status", {})])
                changes = [raw]
                if environment == "PRD":
                    mixed = cluster([field("properties.currentKubernetesVersion", "1.34.7"),
                                     field("properties.enableRBAC", True, False, "Modify")])
                    set_path(mixed["after"], "properties.enableRBAC", False)
                    mixed["resourceId"] = RID + "-security-change"
                    changes.append(mixed)
                components = [{"name": name, "label": name, "status": "complete",
                               "result": {"status": "Succeeded", "changes": changes if name == "infra" else []}}
                              for name in ["resource-group", "network", "acr", "classic", "infra", "privatelink"]]
                directory = root / environment
                report = REPORT.write_environment_report(directory, {
                    "environment": environment, "commit": "a" * 40, "sourceRef": "refs/heads/main", "buildId": "42"}, components)
                self.assertEqual(1 if environment == "PRD" else 0, report["resourceTotals"]["Modify"])
                self.assertEqual(1, report["metadataOnlyTotals"]["Modify"])
                self.assertIn("AKS_READ_ONLY_PROPERTY", (directory / "plan.json").read_text())
                inputs.append(directory / "plan.json")
            combined = REPORT.combine_reports(inputs, root / "combined")
            self.assertFalse(combined["comparisonAvailable"])
            summary = (root / "combined/summary.md").read_text()
            self.assertIn("security-change", summary)
            for comparison in combined["devComparison"]:
                self.assertFalse(any(r["name"] == "cluster" for r in comparison["resources"]))

    def test_existing_health_warnings_survive_environment_and_combined_reports_without_raw_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = []
            for environment in ["DEV", "TST", "PRE", "PRD"]:
                raw = cluster([field("properties.agentPoolProfiles.1.status", {
                    "provisioningError": {"message": "PRIVATE-RAW-HEALTH-ERROR", "code": "PrivateCode"}})])
                raw["before"]["properties"]["agentPoolProfiles"][1]["provisioningState"] = "Failed"
                components = [{"name": name, "label": name, "status": "complete",
                               "result": {"status": "Succeeded", "changes": [raw] if name == "infra" else []}}
                              for name in ["resource-group", "network", "acr", "classic", "infra", "privatelink"]]
                directory = root / environment
                report = REPORT.write_environment_report(directory, {
                    "environment": environment, "commit": "a" * 40, "sourceRef": "refs/heads/main", "buildId": "42"}, components)
                self.assertEqual(1, report["resourceTotals"]["Modify"])
                self.assertIn("## Existing AKS health warnings", (directory / "summary.md").read_text())
                self.assertNotIn("PRIVATE-RAW-HEALTH-ERROR", json.dumps(report) + (directory / "summary.md").read_text())
                inputs.append(directory / "plan.json")
            REPORT.combine_reports(inputs, root / "combined")
            summary = (root / "combined/summary.md").read_text()
            self.assertIn("## Existing AKS health warnings", summary)
            self.assertIn("user", summary)
            self.assertNotIn("PRIVATE-RAW-HEALTH-ERROR", summary)
            source = json.loads(inputs[1].read_text())
            resource = next(c for c in source["components"] if c["name"] == "infra")["resources"][0]
            resource["healthWarnings"] = [
                {"code": "PRIVATE-UNKNOWN-WARNING", "poolName": "user", "message": "PRIVATE-INJECTED-MESSAGE"},
                {"code": "AKS_POOL_PROVISIONING_FAILED", "poolName": "PRIVATE-POOL##vso[task.setvariable variable=x]value"},
            ]
            inputs[1].write_text(json.dumps(source))
            REPORT.combine_reports(inputs, root / "combined")
            published = (root / "combined/summary.md").read_text() + (root / "combined/plan.json").read_text()
            for private in ["PRIVATE-UNKNOWN-WARNING", "PRIVATE-INJECTED-MESSAGE", "PRIVATE-POOL", "##vso["]:
                self.assertNotIn(private, published)

    def test_reported_pool_error_survives_when_arm_omits_readonly_provisioning_state(self):
        for key in ["errordetail", "provisioningError"]:
            raw = cluster([field("properties.agentPoolProfiles.1.status", {
                key: {"code": "KubernetesAPICallFailed", "message": "PRIVATE-POOL-ERROR"}})])
            del raw["before"]["properties"]["agentPoolProfiles"][1]["provisioningState"]
            with self.subTest(error_key=key):
                self.assertEqual([{"code": "AKS_POOL_REPORTED_ERROR", "poolName": "user"}],
                                 AKS.aks_health_warnings(raw))
                self.assertFalse(self.project(raw)["metadataOnly"])
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    inputs = []
                    for environment in ["DEV", "TST", "PRE", "PRD"]:
                        components = [{"name": name, "label": name, "status": "complete",
                                       "result": {"status": "Succeeded", "changes": [raw] if name == "infra" else []}}
                                      for name in ["resource-group", "network", "acr", "classic", "infra", "privatelink"]]
                        directory = root / environment
                        plan = REPORT.write_environment_report(directory, {
                            "environment": environment, "commit": "a" * 40, "sourceRef": "refs/heads/main", "buildId": "42"}, components)
                        self.assertEqual(1, plan["resourceTotals"]["Modify"])
                        self.assertIn("AKS_POOL_REPORTED_ERROR", json.dumps(plan))
                        self.assertIn("## Existing AKS health warnings", (directory / "summary.md").read_text())
                        self.assertNotIn("PRIVATE-POOL-ERROR", json.dumps(plan) + (directory / "summary.md").read_text())
                        inputs.append(directory / "plan.json")
                    combined = REPORT.combine_reports(inputs, root / "combined")
                    summary = (root / "combined/summary.md").read_text()
                    self.assertIn("AKS_POOL_REPORTED_ERROR", json.dumps(combined))
                    self.assertIn("## Existing AKS health warnings", summary)
                    self.assertNotIn("PRIVATE-POOL-ERROR", json.dumps(combined) + summary)


if __name__ == "__main__":
    unittest.main()
