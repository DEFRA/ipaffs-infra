import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("inspect-pre-pdb.py")
SPEC = importlib.util.spec_from_file_location("pre_diagnostic", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def pod(name, kind, phase="Running", ready=True):
    labels = {"service": "enotificationevent-service", "project": "ipaffs", "helm.sh/chart": "webapp-0.129.0"}
    if kind == "Job":
        labels.update({"job-name": "enotificationevent-service-migrations", "batch.kubernetes.io/job-name": "enotificationevent-service-migrations"})
    return {"metadata": {"name": name, "namespace": "pre", "labels": labels,
                         "ownerReferences": [{"kind": kind, "name": "enotificationevent-service", "controller": True}]},
            "spec": {"nodeName": "aks-user-test", "containers": [{"env": [{"name": "PASSWORD", "value": "PRIVATE-SENSITIVE"}], "command": ["PRIVATE-COMMAND"]}]},
            "status": {"phase": phase, "conditions": [{"type": "Ready", "status": "True" if ready else "False", "message": "PRIVATE-MESSAGE"}]}}


def collections(selector=None):
    return {"deployments": [], "jobs": [], "pods": [pod("application", "ReplicaSet"), pod("completed-migration", "Job", "Succeeded", False)],
            "poddisruptionbudgets": [{"metadata": {"name": "enotificationevent-service", "namespace": "pre"},
                                      "spec": {"selector": selector if selector is not None else {"matchLabels": {"service": "enotificationevent-service"}}, "maxUnavailable": 1},
                                      "status": {"conditions": [{"type": "DisruptionAllowed", "status": "False", "reason": "SyncFailed", "message": "PRIVATE-SYNC-ERROR"}]}}]}


class DiagnosticTests(unittest.TestCase):
    def test_original_selector_proves_completed_job_inclusion(self):
        result = MODULE.build_report(collections())
        budget = result["podDisruptionBudgets"][0]
        self.assertTrue(result["complete"])
        self.assertEqual((2, 1, 1, 1, 1), tuple(budget[k] for k in ["selectedPodCount", "selectedJobPodCount", "selectedCompletedJobPodCount", "selectedAppPodCount", "selectedReadyAppPodCount"]))
        self.assertEqual({"complete": True, "selectedPodCount": 1, "selectedJobPodCount": 0, "selectedAppPodCount": 1, "preservesApplicationSelection": True}, budget["counterfactualExcludingJobLabels"])

    def test_job_exclusion_preserves_application_selection(self):
        selector = {"matchLabels": {"service": "enotificationevent-service"},
                    "matchExpressions": [{"key": key, "operator": "DoesNotExist"} for key in ["job-name", "batch.kubernetes.io/job-name"]]}
        result = MODULE.build_report(collections(selector))
        budget = result["podDisruptionBudgets"][0]
        self.assertEqual((1, 0, 1), tuple(budget[k] for k in ["selectedPodCount", "selectedJobPodCount", "selectedAppPodCount"]))

    def test_unknown_selector_is_not_zero_selected(self):
        result = MODULE.build_report(collections({"matchExpressions": [{"key": "service", "operator": "GT", "values": ["1"]}]}))
        self.assertFalse(result["complete"])
        self.assertIsNone(result["podDisruptionBudgets"][0]["selectedPodCount"])
        self.assertIsNone(result["podDisruptionBudgets"][0]["selectedJobPodCount"])

    def test_kubernetes_in_notin_and_existence_semantics(self):
        for operator, labels, expected in [("In", {"x": "a"}, True), ("In", {}, False),
                                           ("NotIn", {}, True), ("NotIn", {"x": "a"}, False)]:
            self.assertEqual(expected, MODULE.matches({"matchExpressions": [{"key": "x", "operator": operator, "values": ["a"]}]}, labels))
        self.assertTrue(MODULE.matches({"matchExpressions": [{"key": "x", "operator": "Exists"}]}, {"x": "a"}))
        self.assertTrue(MODULE.matches({"matchExpressions": [{"key": "x", "operator": "DoesNotExist"}]}, {}))
        self.assertTrue(MODULE.matches({}, {"x": "a"}))
        self.assertFalse(MODULE.matches(None, {"x": "a"}))

    def test_raw_messages_specs_commands_and_arbitrary_labels_are_private(self):
        data = collections()
        data["pods"][0]["metadata"]["labels"]["private-label"] = "PRIVATE-LABEL"
        data["poddisruptionbudgets"][0]["spec"]["maxUnavailable"] = "PRIVATE-ALLOWANCE"
        original = copy.deepcopy(data)
        serialized = json.dumps(MODULE.build_report(data))
        self.assertEqual(data, original)
        for private in ["PRIVATE-SENSITIVE", "PRIVATE-COMMAND", "PRIVATE-MESSAGE", "PRIVATE-SYNC-ERROR", "PRIVATE-LABEL", "PRIVATE-ALLOWANCE"]:
            self.assertNotIn(private, serialized)
        self.assertIn("SyncFailed", serialized)
        self.assertIn("webapp-0.129.0", serialized)

    def test_helm_release_metadata_must_match_known_service(self):
        item = pod("enotificationevent-service", "ReplicaSet")
        item["metadata"]["annotations"] = {"meta.helm.sh/release-name": "unrelated-private-release"}
        self.assertNotIn("helmRelease", MODULE.metadata(item))
        item["metadata"]["annotations"]["meta.helm.sh/release-name"] = "enotificationevent-service-webapp"
        self.assertEqual("enotificationevent-service-webapp", MODULE.metadata(item)["helmRelease"])

    def test_only_allowlisted_namespaced_get_commands_can_execute(self):
        with patch.object(MODULE.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "COMMAND_NOT_ALLOWED"):
                MODULE.read("secrets")
            run.assert_not_called()
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps({"items": []})
            MODULE.read("pods")
            command = run.call_args.args[0]
            self.assertEqual(["kubectl", "--context", "PRE-PDB-READONLY", "--namespace", "pre", "get", "pods", "--output", "json", "--request-timeout", "30s"], command)

    def test_incomplete_or_wrong_namespace_data_is_not_reported_as_success(self):
        for data in [{"items": [], "metadata": {"continue": "next"}}, {"items": [{"metadata": {"namespace": "prd"}}]}]:
            with self.subTest(data=data), patch.object(MODULE.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = json.dumps(data)
                with self.assertRaisesRegex(RuntimeError, "INVALID_OR_INCOMPLETE"):
                    MODULE.read("pods")


if __name__ == "__main__":
    unittest.main()
