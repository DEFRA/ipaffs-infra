#!/usr/bin/env python3
"""Exercise dashboard deployment with a local Azure CLI stub; no Azure calls.

Requires jq and Bash >= 4. Set BASH to the desired Bash executable if needed.
Run: python3 -m unittest discover -s grafana-dashboards/tests -p 'test_*.py'
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "grafana-dashboards/scripts/deploy-dashboards.sh"
DASHBOARDS = ROOT / "grafana-dashboards/dashboards"
APPLICATION = DASHBOARDS / "IPAFFSApplicationOverview.json"
PLATFORM = DASHBOARDS / "IPAFFSPlatformOverview.json"
CLASSIC_VARIABLES = {
    "CLASSIC_SUBSCRIPTION_ID": "classicSubscription",
    "CLASSIC_RESOURCE_GROUP": "classicResourceGroup",
    "CLASSIC_SERVICE_BUS": "classicServiceBus",
}


class DeployDashboardsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="grafana-deploy-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        stub = self.bin / "az"
        stub.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "if args[:2] == ['extension', 'add']:\n"
            "    sys.exit(0)\n"
            "if args[:3] == ['grafana', 'data-source', 'show']:\n"
            "    name = args[args.index('--data-source') + 1]\n"
            "    print('prometheus-test-uid' if name == 'Prometheus' else 'azure-test-uid')\n"
            "    sys.exit(0)\n"
            "if args[:3] == ['grafana', 'dashboard', 'update']:\n"
            "    assert args[args.index('--definition') + 1] == '@-'\n"
            "    capture = pathlib.Path(os.environ['AZ_STUB_CAPTURE'])\n"
            "    path = capture / ('%03d.json' % len(list(capture.glob('*.json'))))\n"
            "    path.write_text(json.dumps(json.load(sys.stdin)))\n"
            "    sys.exit(7 if os.environ.get('AZ_STUB_FAIL_UPDATE') == 'true' else 0)\n"
            "sys.exit('Unexpected az invocation: ' + repr(args))\n"
        )
        stub.chmod(0o755)
        self.run_count = 0

    @staticmethod
    def classic_values(environment="DEV", number=1):
        return {
            "CLASSIC_SUBSCRIPTION_ID": f"00000000-0000-0000-0000-{number:012d}",
            "CLASSIC_RESOURCE_GROUP": f"{environment}CLASSICRG",
            "CLASSIC_SERVICE_BUS": f"{environment.lower()}-classic-service-bus",
        }

    def deploy(self, files, values=None, environment="DEV", **overrides):
        capture = self.directory / f"capture-{self.run_count}"
        self.run_count += 1
        capture.mkdir()
        env = os.environ.copy()
        for name in (*CLASSIC_VARIABLES, "AZ_STUB_FAIL_UPDATE", "DRY_RUN", "LIST_ONLY", "DASHBOARDS_ROOT"):
            env.pop(name, None)
        env.update(
            PATH=f"{self.bin}{os.pathsep}{env.get('PATH', '')}",
            AZ_STUB_CAPTURE=str(capture),
            GRAFANA_NAME="test-grafana",
            RESOURCE_GROUP="new-infra-resource-group",
            ENVIRONMENT=environment,
            DASHBOARD_FILES=" ".join(map(str, files)),
        )
        env.update(values or {})
        env.update(overrides)
        result = subprocess.run(
            [os.environ.get("BASH", "bash"), str(SCRIPT)],
            cwd=ROOT, env=env, text=True, capture_output=True, timeout=30,
        )
        updates = [json.loads(path.read_text()) for path in sorted(capture.glob("*.json"))]
        return result, updates

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_classic_constants_and_dlq_target_for_every_environment(self):
        source_bytes = APPLICATION.read_bytes()
        source = json.loads(source_bytes)
        for number, environment in enumerate(("DEV", "TST", "PRE", "PRD"), 1):
            with self.subTest(environment=environment):
                values = self.classic_values(environment, number)
                result, updates = self.deploy([APPLICATION], values, environment)
                self.assert_success(result)
                self.assertEqual(len(updates), 1)
                dashboard = updates[0]
                variables = {variable["name"]: variable for variable in dashboard["templating"]["list"]}
                for env_name, variable_name in CLASSIC_VARIABLES.items():
                    variable = variables[variable_name]
                    value = values[env_name]
                    self.assertEqual(variable["type"], "constant")
                    self.assertEqual(variable["hide"], 2)
                    self.assertEqual(variable["query"], value)
                    self.assertEqual(variable["current"]["text"], value)
                    self.assertEqual(variable["current"]["value"], value)
                    self.assertEqual(variable["options"], [{"selected": True, "text": value, "value": value}])
                dlq = next(panel for panel in dashboard["panels"] if panel["title"] == "Service Bus DLQ counts")
                target = dlq["targets"][0]
                resource = target["azureMonitor"]["resources"][0]
                self.assertEqual(resource["subscription"], "$classicSubscription")
                self.assertEqual(resource["resourceGroup"], "$classicResourceGroup")
                self.assertEqual(resource["resourceName"], "$classicServiceBus")
                self.assertEqual(target["subscription"], "$classicSubscription")
                self.assertEqual(target["azureMonitor"]["metricName"], "DeadletteredMessages")
                self.assertEqual(dashboard["panels"], source["panels"])
                for variable in source["templating"]["list"]:
                    if variable["type"] != "datasource" and variable["name"] not in CLASSIC_VARIABLES.values():
                        self.assertEqual(variables[variable["name"]], variable)
                application_resources = [
                    resource
                    for panel in dashboard["panels"]
                    if panel["title"] != "Service Bus DLQ counts"
                    for target in panel.get("targets", [])
                    for resource in target.get("azureLogAnalytics", {}).get("resources", [])
                ]
                self.assertTrue(application_resources)
                for resource in application_resources:
                    self.assertIn("/subscriptions/$subscription/resourceGroups/$resourceGroup/", resource)
        self.assertEqual(APPLICATION.read_bytes(), source_bytes)

    def test_other_dashboard_does_not_require_classic_values(self):
        source_bytes = PLATFORM.read_bytes()
        result, updates = self.deploy([PLATFORM])
        self.assert_success(result)
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0]["panels"], json.loads(source_bytes)["panels"])
        self.assertEqual(PLATFORM.read_bytes(), source_bytes)

    def test_invalid_classic_values_fail_before_any_dashboard_update(self):
        for name in CLASSIC_VARIABLES:
            for invalid in (None, "", " \t\n", f"$({name})"):
                with self.subTest(name=name, invalid=invalid):
                    values = self.classic_values()
                    if invalid is None:
                        values.pop(name)
                    else:
                        values[name] = invalid
                    result, updates = self.deploy([PLATFORM, APPLICATION], values)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stdout + result.stderr)
                    self.assertEqual(updates, [])

    def test_failed_azure_update_exits_nonzero(self):
        result, updates = self.deploy([APPLICATION], self.classic_values(), AZ_STUB_FAIL_UPDATE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(updates), 1)
        self.assertIn("FAILED", result.stdout + result.stderr)

    def test_environment_folder_dashboards_only_deploy_to_that_environment(self):
        root = self.directory / "dashboards"
        for path, uid in (("Shared.json", "shared"), ("DEV/DevOnly.json", "dev-only"), ("TST/TstOnly.json", "tst-only")):
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(json.dumps({"uid": uid, "title": uid, "templating": {"list": []}, "panels": []}))
        expected = {"DEV": ["dev-only", "shared"], "TST": ["shared", "tst-only"], "PRE": ["shared"], "PRD": ["shared"]}
        for environment, uids in expected.items():
            with self.subTest(environment=environment):
                result, updates = self.deploy([], environment=environment, DASHBOARD_FILES="", DASHBOARDS_ROOT=str(root))
                self.assert_success(result)
                self.assertEqual(sorted(update["uid"] for update in updates), uids)
                result, updates = self.deploy([], environment=environment, DASHBOARD_FILES="", DASHBOARDS_ROOT=str(root),
                                              LIST_ONLY="true")
                self.assert_success(result)
                self.assertEqual(updates, [])
                listed = [json.loads(Path(line).read_text())["uid"] for line in result.stdout.splitlines()]
                self.assertEqual(sorted(listed), uids)

    def test_dry_run_does_not_update_dashboards(self):
        result, updates = self.deploy([APPLICATION], self.classic_values(), DRY_RUN="true")
        self.assert_success(result)
        self.assertEqual(updates, [])


if __name__ == "__main__":
    unittest.main()
