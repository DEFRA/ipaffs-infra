#!/usr/bin/env python3
"""Check the compiled AKS contract without querying or applying Azure state."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PARAMETER = re.compile(r"\[parameters\('([^']+)'\)((?:\.[A-Za-z_][A-Za-z0-9_]*)*)\]")


def parameter_value(value, parameters):
    """Resolve only parameter property references emitted by this contract.

    Unexpected expression types fail rather than borrowing their implementation
    from the Bicep module or silently returning an unevaluated value.
    """
    if not isinstance(value, str) or not value.startswith("["):
        return value
    match = PARAMETER.fullmatch(value)
    if not match:
        raise AssertionError("Unexpected compiled parameter expression")
    result = parameters[match.group(1)]
    for key in match.group(2).split(".")[1:]:
        result = result[key]
    return result


@unittest.skipUnless(os.environ.get("BICEP_BIN"), "Set BICEP_BIN to compile AKS settings")
class CompiledAksSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.compiler_environment = {**os.environ, "DOTNET_BUNDLE_EXTRACT_BASE_DIR": temporary.name}
        module = cls.compile("build", ROOT / "bicep/modules/aks.bicep")
        cls.cluster, = [r for r in module["resources"] if r["type"] == "Microsoft.ContainerService/managedClusters"]
        cls.properties = cls.cluster["properties"]
        cls.pools = {pool["name"]: pool for pool in cls.properties["agentPoolProfiles"]}
        cls.parameters = {}
        cls.root_templates = {}
        for environment in ("dev", "tst", "pre", "prd"):
            result = cls.compile("build-params", ROOT / f"bicep/envs/{environment}/40-infra.bicepparam")
            cls.parameters[environment] = {
                name: entry["value"] for name, entry in json.loads(result["parametersJson"])["parameters"].items()}
            cls.root_templates[environment] = json.loads(result["templateJson"])

    @classmethod
    def compile(cls, command, path):
        result = subprocess.run([os.environ["BICEP_BIN"], command, str(path), "--stdout", "--no-restore"],
                                capture_output=True, text=True, env=cls.compiler_environment, timeout=120)
        if result.returncode or "BCP037" in result.stderr:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    def test_all_environments_keep_named_autoscaling_pools_and_existing_capacity_bounds(self):
        self.assertEqual({"system", "user"}, set(self.pools))
        for environment, parameters in self.parameters.items():
            for name, pool in self.pools.items():
                with self.subTest(environment=environment, pool=name):
                    self.assertTrue(pool["enableAutoScaling"])
                    self.assertEqual(3, parameter_value(pool["minCount"], parameters))
                    self.assertEqual(5 if name == "system" else 12, parameter_value(pool["maxCount"], parameters))
                    self.assertEqual(250, parameter_value(pool["maxPods"], parameters))
                    generation = "v6" if environment == "dev" else "v7"
                    expected = "Standard_E2as_" if name == "system" else "Standard_E16as_"
                    self.assertEqual(expected + generation, parameter_value(pool["vmSize"], parameters))

    def test_autoscaled_counts_runtime_states_and_generated_node_metadata_are_not_pinned(self):
        for name, pool in self.pools.items():
            with self.subTest(pool=name):
                for key in ("count", "powerState", "status", "provisioningState", "nodeImageVersion",
                            "currentOrchestratorVersion", "eTag"):
                    self.assertNotIn(key, pool)
        for key in ("identityProfile", "powerState", "provisioningState", "currentKubernetesVersion",
                    "fqdn", "privateFQDN", "resourceUID"):
            self.assertNotIn(key, self.properties)

    def test_disk_and_node_security_settings_preserve_the_observed_environment_contract(self):
        for environment, parameters in self.parameters.items():
            for name, pool in self.pools.items():
                with self.subTest(environment=environment, pool=name):
                    self.assertEqual(128 if name == "system" else 512,
                                     parameter_value(pool["osDiskSizeGB"], parameters))
                    self.assertEqual("Managed", pool["osDiskType"])
                    self.assertEqual("OS", pool["kubeletDiskType"])
                    self.assertEqual("Ubuntu", pool["osSKU"])
                    self.assertFalse(pool["enableFIPS"])
                    self.assertEqual("Delete", pool["scaleDownMode"])
                    self.assertTrue(pool["securityProfile"]["enableSecureBoot"])
                    self.assertTrue(pool["securityProfile"]["enableVTPM"])
                    self.assertEqual("LocalUser", pool["securityProfile"]["sshAccess"])
                    self.assertEqual({"maxSurge": "10%", "maxUnavailable": "0"}, pool["upgradeSettings"])

    def test_rbac_tenant_and_private_networking_are_explicit_without_disabling_existing_features(self):
        self.assertEqual("2025-10-01", self.cluster["apiVersion"])
        self.assertEqual("Base", self.cluster["kind"])
        self.assertTrue(self.properties["enableRBAC"])
        self.assertTrue(self.properties["aadProfile"]["managed"])
        self.assertTrue(self.properties["aadProfile"]["enableAzureRBAC"])
        self.assertEqual("[parameters('tenantId')]", self.properties["aadProfile"]["tenantID"])
        self.assertEqual("Disabled", self.properties["publicNetworkAccess"])
        api = self.properties["apiServerAccessProfile"]
        self.assertTrue(api["enablePrivateCluster"])
        self.assertTrue(api["enableVnetIntegration"])
        self.assertTrue(api["enablePrivateClusterPublicFQDN"])
        network = self.properties["networkProfile"]
        self.assertEqual("azure", network["networkDataplane"])
        self.assertEqual(("azure", "overlay", "calico"),
                         tuple(network[key] for key in ("networkPlugin", "networkPluginMode", "networkPolicy")))
        self.assertEqual(["IPv4"], network["ipFamilies"])
        self.assertEqual("userDefinedRouting", network["outboundType"])

    def test_existing_tenant_input_is_forwarded_from_every_real_entrypoint(self):
        for environment, template in self.root_templates.items():
            with self.subTest(environment=environment):
                modules = [r for r in template["resources"]
                           if "aksParams" in r.get("properties", {}).get("parameters", {})]
                self.assertEqual(1, len(modules))
                self.assertEqual("[parameters('tenantId')]",
                                 modules[0]["properties"]["parameters"]["tenantId"]["value"])

    def test_autoscaler_settings_keep_boolean_and_string_api_types(self):
        self.assertEqual({
            "balance-similar-node-groups": "false",
            "daemonset-eviction-for-empty-nodes": False,
            "daemonset-eviction-for-occupied-nodes": True,
            "ignore-daemonsets-utilization": False,
            "max-node-provision-time": "15m",
            "scale-down-delay-after-add": "10m",
            "skip-nodes-with-local-storage": "false",
        }, self.properties["autoScalerProfile"])

    def test_monitoring_storage_and_support_settings_are_explicit_without_changing_patch_policy(self):
        self.assertEqual({"mode": "Manual", "defaultNodePools": "Auto"}, self.properties["nodeProvisioningProfile"])
        self.assertEqual("KubernetesOfficial", self.properties["supportPlan"])
        self.assertEqual({"costAnalysis": {"enabled": False}}, self.properties["metricsProfile"])
        self.assertEqual({"diskCSIDriver": {"enabled": True}, "fileCSIDriver": {"enabled": True},
                          "snapshotController": {"enabled": True}}, self.properties["storageProfile"])
        self.assertTrue(self.properties["azureMonitorProfile"]["metrics"]["enabled"])
        self.assertTrue(self.properties["securityProfile"]["workloadIdentity"]["enabled"])
        self.assertEqual({"nodeOSUpgradeChannel": "SecurityPatch", "upgradeChannel": "none"},
                         self.properties["autoUpgradeProfile"])
        self.assertNotIn("defender", self.properties["securityProfile"])
        self.assertNotIn("aiToolchainOperatorProfile", self.properties)
        self.assertNotIn("extensionManager", self.properties["addonProfiles"])
        self.assertNotIn("windowsProfile", self.properties)
        self.assertEqual({"mode": "Disabled"}, self.properties["serviceMeshProfile"])
        self.assertEqual({"clientId": "msi"}, self.properties["servicePrincipalProfile"])


if __name__ == "__main__":
    unittest.main()
