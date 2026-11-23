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
        cls.parameters = {}
        cls.aks_modules = {}
        for environment in ("dev", "tst", "pre", "prd"):
            result = cls.compile("build-params", ROOT / f"bicep/envs/{environment}/40-infra.bicepparam")
            cls.parameters[environment] = {
                name: entry["value"] for name, entry in json.loads(result["parametersJson"])["parameters"].items()}
            root = json.loads(result["templateJson"])
            cls.aks_modules[environment], = [r["properties"] for r in root["resources"]
                                             if "aksParams" in r.get("properties", {}).get("parameters", {})]
        cls.module = cls.aks_modules["dev"]["template"]
        cls.config = cls.module["variables"]["clusterConfig"]
        cls.properties = cls.config["properties"]
        cls.pools = {pool["name"]: pool for pool in cls.properties["agentPoolProfiles"]}

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

    def test_only_the_system_pool_is_reserved_for_critical_addons(self):
        taint = "CriticalAddonsOnly=true:NoSchedule"
        self.assertIn(taint, self.pools["system"].get("nodeTaints", []))
        self.assertNotIn(taint, self.pools["user"].get("nodeTaints", []))

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
                    self.assertFalse(pool["enableFIPS"])
                    self.assertEqual("Delete", pool["scaleDownMode"])
                    self.assertTrue(pool["securityProfile"]["enableSecureBoot"])
                    self.assertTrue(pool["securityProfile"]["enableVTPM"])
                    self.assertEqual("LocalUser", pool["securityProfile"]["sshAccess"])
                    self.assertEqual({"maxSurge": "10%", "maxUnavailable": "0"}, pool["upgradeSettings"])

    def test_rbac_tenant_and_private_networking_are_explicit_without_disabling_existing_features(self):
        self.assertEqual("Base", self.config["kind"])
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
        for singular, plural in (("podCidr", "podCidrs"), ("serviceCidr", "serviceCidrs")):
            self.assertEqual(f"[parameters('aksParams').{plural}[0]]", network[singular])
            for environment, parameters in self.parameters.items():
                with self.subTest(environment=environment, field=plural):
                    self.assertEqual(1, len(parameter_value(network[plural], parameters)))

    def test_every_entrypoint_deploys_the_same_module_and_forwards_its_inputs(self):
        for environment, module in self.aks_modules.items():
            with self.subTest(environment=environment):
                self.assertEqual(self.module, module["template"])
                for name in ("aksParams", "tenantId"):
                    self.assertEqual(f"[parameters('{name}')]", module["parameters"][name]["value"])

    def test_cluster_apis_share_configuration_and_only_dev_merges_its_api_settings(self):
        resources = self.module["resources"]
        cluster_type = "Microsoft.ContainerService/managedClusters"
        ubuntu, = [r for r in resources if r["type"] == cluster_type]
        nested, = [r for r in resources if r["type"] == "Microsoft.Resources/deployments"
                   and "config" in r["properties"]["parameters"]]
        acl, = nested["properties"]["template"]["resources"]
        self.assertEqual(cluster_type, acl["type"])
        self.assertEqual("2025-10-01", ubuntu["apiVersion"])
        self.assertEqual("2026-03-01", acl["apiVersion"])
        self.assertEqual("[not(variables('useContainerLinuxApi'))]", ubuntu["condition"])
        self.assertEqual("[variables('useContainerLinuxApi')]", nested["condition"])
        self.assertNotIn("condition", acl)
        self.assertEqual({
            "config": {"value": "[variables('clusterConfig')]"},
            "apiSettings": {"value": "[parameters('aksParams').containerLinuxApiSettings]"},
        }, nested["properties"]["parameters"])
        self.assertEqual(self.config["name"], ubuntu["name"])
        for key in self.config:
            if key != "properties":
                self.assertEqual(f"[parameters('config').{key}]", acl[key])
            if key != "name":
                self.assertEqual(f"[variables('clusterConfig').{key}]", ubuntu[key])
        self.assertEqual("[union(parameters('config').properties, variables('additionalProperties'))]", acl["properties"])
        overrides = nested["properties"]["template"]["variables"]["additionalProperties"]
        self.assertEqual({
            "hostedSystemProfile": "[parameters('apiSettings').hostedSystemProfile]",
            "ingressProfile": {"webAppRouting": {
                "gatewayAPIImplementations": "[parameters('apiSettings').gatewayAPIImplementations]",
            }},
            "networkProfile": {"advancedNetworking": "[parameters('apiSettings').advancedNetworking]"},
        }, overrides)

    def test_dev_api_preserves_observed_addons_and_the_shared_ingress_and_network(self):
        self.assertNotIn("hostedSystemProfile", self.properties)
        self.assertNotIn("advancedNetworking", self.properties["networkProfile"])
        self.assertEqual({"webAppRouting": {"enabled": True, "nginx": {"defaultIngressControllerType": "None"}}},
                         self.properties["ingressProfile"])
        expected = {
            "hostedSystemProfile": {"enabled": False},
            "gatewayAPIImplementations": {"appRoutingIstio": {"mode": "Disabled"}},
            "advancedNetworking": {
                "enabled": True, "observability": {"enabled": True},
                "performance": {"accelerationMode": "None"},
                "security": {"advancedNetworkPolicies": "None", "enabled": False},
            },
        }
        for environment, parameters in self.parameters.items():
            with self.subTest(environment=environment):
                self.assertEqual(expected if environment == "dev" else None,
                                 parameters["aksParams"].get("containerLinuxApiSettings"))

    def test_only_dev_user_pool_selects_container_linux(self):
        self.assertEqual("[contains(parameters('aksParams'), 'containerLinuxApiSettings')]",
                         self.module["variables"]["useContainerLinuxApi"])
        for name, pool in self.pools.items():
            self.assertEqual(f"[coalesce(tryGet(parameters('aksParams').nodePools.{name}, 'osSKU'), 'Ubuntu')]",
                             pool["osSKU"])
        for environment, parameters in self.parameters.items():
            for name, pool in parameters["aksParams"]["nodePools"].items():
                with self.subTest(environment=environment, pool=name):
                    expected = "AzureContainerLinux" if environment == "dev" and name == "user" else "Ubuntu"
                    self.assertEqual(expected, pool.get("osSKU", "Ubuntu"))

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

    def test_only_dev_uses_node_image_upgrades(self):
        self.assertEqual({
            "nodeOSUpgradeChannel": "[coalesce(tryGet(parameters('aksParams'), 'nodeOSUpgradeChannel'), 'SecurityPatch')]",
            "upgradeChannel": "none",
        }, self.properties["autoUpgradeProfile"])
        for environment, parameters in self.parameters.items():
            with self.subTest(environment=environment):
                channel = parameters["aksParams"].get("nodeOSUpgradeChannel", "SecurityPatch")
                self.assertEqual("NodeImage" if environment == "dev" else "SecurityPatch", channel)

    def test_monitoring_storage_and_support_settings_are_explicit(self):
        self.assertEqual({"mode": "Manual", "defaultNodePools": "Auto"}, self.properties["nodeProvisioningProfile"])
        self.assertEqual("KubernetesOfficial", self.properties["supportPlan"])
        self.assertEqual({"costAnalysis": {"enabled": False}}, self.properties["metricsProfile"])
        self.assertEqual({"diskCSIDriver": {"enabled": True}, "fileCSIDriver": {"enabled": True},
                          "snapshotController": {"enabled": True}}, self.properties["storageProfile"])
        self.assertTrue(self.properties["azureMonitorProfile"]["metrics"]["enabled"])
        self.assertTrue(self.properties["securityProfile"]["workloadIdentity"]["enabled"])
        self.assertNotIn("defender", self.properties["securityProfile"])
        self.assertNotIn("aiToolchainOperatorProfile", self.properties)
        self.assertNotIn("extensionManager", self.properties["addonProfiles"])
        self.assertNotIn("windowsProfile", self.properties)
        self.assertEqual({"mode": "Disabled"}, self.properties["serviceMeshProfile"])
        self.assertEqual({"clientId": "msi"}, self.properties["servicePrincipalProfile"])


if __name__ == "__main__":
    unittest.main()
