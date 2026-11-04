#!/usr/bin/env python3
"""Compile the NSG ownership boundary and exercise real environment inputs.

Set BICEP_BIN when the compiler is not installed in the Azure CLI config folder.
No Azure subscription or deployment is used by these tests.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path(os.environ.get("AZURE_CONFIG_DIR", str(Path.home() / ".azure")))
COMPILERS = (CONFIG / "bin/bicep", Path.home() / ".azure/bin/bicep")
BICEP = os.environ.get("BICEP_BIN") or next((str(path) for path in COMPILERS if path.is_file()), str(COMPILERS[0]))


def resources(template):
    entries = template["resources"]
    return entries if isinstance(entries, dict) else {str(index): entry for index, entry in enumerate(entries)}


def resolve(expression, parameters, index=0):
    """Evaluate only the parameter/loop expressions in this compiled contract."""
    if not isinstance(expression, str) or not expression.startswith("["):
        return expression
    tokens = re.findall(r"'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[(),.\[\]]", expression[1:-1])
    position = 0

    def value():
        nonlocal position
        token = tokens[position]
        position += 1
        if token.startswith("'"):
            result = ("literal", token[1:-1].replace("''", "'"))
        elif token.isdigit():
            result = ("literal", int(token))
        else:
            if tokens[position] != "(":
                raise AssertionError(f"Unsupported ARM expression: {expression}")
            position += 1
            arguments = []
            if tokens[position] != ")":
                while True:
                    arguments.append(value())
                    if tokens[position] != ",":
                        break
                    position += 1
            if tokens[position] != ")":
                raise AssertionError(f"Invalid ARM expression: {expression}")
            position += 1
            result = ("call", token, arguments)
        while position < len(tokens) and tokens[position] in (".", "["):
            accessor = tokens[position]
            position += 1
            if accessor == ".":
                result = ("lookup", result, ("literal", tokens[position]))
                position += 1
            else:
                result = ("lookup", result, value())
                if tokens[position] != "]":
                    raise AssertionError(f"Invalid ARM index: {expression}")
                position += 1
        return result

    def evaluate(node, bindings):
        if node[0] == "literal":
            return node[1]
        if node[0] == "lookup":
            return evaluate(node[1], bindings)[evaluate(node[2], bindings)]
        name, arguments = node[1:]
        if name == "lambda":
            names = [evaluate(argument, bindings) for argument in arguments[:-1]]
            return lambda *values: evaluate(arguments[-1], {**bindings, **dict(zip(names, values))})
        functions = {"parameters": lambda name: parameters[name], "copyIndex": lambda *args: index,
                     "length": len, "format": lambda pattern, *args: pattern.format(*args),
                     "contains": lambda values, item: item in values, "not": lambda argument: not argument,
                     "toLower": lambda text: text.lower(), "lambdaVariables": lambda name: bindings[name],
                     "map": lambda values, function: [function(item) for item in values]}
        return functions[name](*(evaluate(argument, bindings) for argument in arguments))

    result = value()
    if position != len(tokens):
        raise AssertionError(f"Unconsumed ARM expression: {expression}")
    return evaluate(result, {})


class NetworkSecurityGroupOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not Path(BICEP).is_file():
            raise RuntimeError("Bicep compiler required; set BICEP_BIN to the pinned compiler")
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.compiler_environment = {**os.environ, "DOTNET_BUNDLE_EXTRACT_BASE_DIR": temporary.name}
        cls.wrapper = cls.compile("build", ROOT / "bicep/modules/network-security-groups.bicep")
        cls.loop, = resources(cls.wrapper).values()
        cls.group_template = cls.loop["properties"]["template"]
        cls.group_resources = resources(cls.group_template)
        cls.parent_key, cls.parent = next((key, item) for key, item in cls.group_resources.items()
                                         if item["type"] == "Microsoft.Network/networkSecurityGroups")
        cls.child, = [item for item in cls.group_resources.values()
                      if item["type"] == "Microsoft.Network/networkSecurityGroups/securityRules"]
        cls.environment_groups = {}
        cls.network_templates = {}
        for environment in ("dev", "tst", "pre", "prd"):
            compiled = cls.compile("build-params", ROOT / f"bicep/envs/{environment}/20-network.bicepparam")
            cls.environment_groups[environment] = json.loads(compiled["parametersJson"])["parameters"]["nsgParams"]["value"]["networkSecurityGroups"]
            cls.network_templates[environment] = json.loads(compiled["templateJson"])

    @classmethod
    def compile(cls, command, path):
        result = subprocess.run([BICEP, command, str(path), "--stdout", "--no-restore"],
                                text=True, capture_output=True, timeout=120, env=cls.compiler_environment)
        if result.returncode:
            raise AssertionError(result.stderr)
        return json.loads(result.stdout)

    def group_inputs(self, groups, index, existing_names=None):
        inputs = {"nsgParams": {"networkSecurityGroups": groups}, "deploymentId": "fixture",
                  "location": "uksouth", "tags": {"Environment": "fixture"},
                  "existingNetworkSecurityGroupNames": existing_names or []}
        return {name: resolve(parameter["value"], inputs, index)
                for name, parameter in self.loop["properties"]["parameters"].items()}

    def test_existing_parent_is_never_updated_or_given_an_authoritative_rule_array(self):
        self.assertEqual({"onlyIfNotExists": []}, self.parent["@options"])
        self.assertEqual("2.0", self.group_template["languageVersion"])
        self.assertEqual({}, self.parent["properties"])
        self.assertNotIn("securityRules", self.parent)
        self.assertEqual({"Microsoft.Network/networkSecurityGroups",
                          "Microsoft.Network/networkSecurityGroups/securityRules"},
                         {item["type"] for item in self.group_resources.values()})

    def test_managed_rules_depend_on_the_bootstrapped_parent(self):
        self.assertIn(self.parent_key, self.child["dependsOn"])
        self.assertNotIn("@options", self.child, "Owned rules must still update on subsequent deployments")
        self.assertNotIn("condition", self.child, "Existing parents must not disable managed child-rule updates")
        existing, = [item for item in self.group_resources.values() if item.get("existing") is True]
        self.assertEqual("Microsoft.Network/networkSecurityGroups", existing["type"])
        self.assertEqual("serial", self.child["copy"]["mode"])
        self.assertEqual(1, self.child["copy"]["batchSize"], "A group cannot accept concurrent child-rule writes")

    def test_network_entrypoint_forwards_the_observed_group_names_without_changing_case(self):
        observed = ["preimpnetns1401-Aks", "PREIMPNETNS1401-PrivateEndpoint"]
        for environment, template in self.network_templates.items():
            with self.subTest(environment=environment):
                self.assertEqual([], template["parameters"]["existingNetworkSecurityGroupNames"]["defaultValue"])
                group_module, = [item for item in resources(template).values()
                                 if "nsgParams" in item.get("properties", {}).get("parameters", {})]
                value = group_module["properties"]["parameters"]["existingNetworkSecurityGroupNames"]["value"]
                self.assertEqual(observed, resolve(value, {"existingNetworkSecurityGroupNames": observed}))

    def test_only_missing_parents_are_planned_for_creation_while_children_stay_managed(self):
        groups = self.environment_groups["pre"]
        for index, group in enumerate(groups):
            for existing_names, exists in (([], False), ([group["name"]], True),
                                           ([group["name"].lower()], True),
                                           ([group["name"] + "-another-group"], False)):
                with self.subTest(group=group["name"], existing_names=existing_names):
                    parameters = self.group_inputs(groups, index, existing_names)
                    self.assertEqual(exists, parameters["parentExists"])
                    self.assertEqual(not exists, resolve(self.parent["condition"], parameters))
                    self.assertEqual(len(group["securityRules"]), resolve(self.child["copy"]["count"], parameters))
                    self.assertNotIn("condition", self.child)

    def test_every_environment_keeps_every_owned_rule_name_and_property(self):
        property_names = set()
        for environment, groups in self.environment_groups.items():
            for group_index, group in enumerate(groups):
                with self.subTest(environment=environment, group=group["name"]):
                    parameters = self.group_inputs(groups, group_index)
                    self.assertEqual(group["name"], resolve(self.parent["name"], parameters))
                    self.assertEqual(group["securityRules"], parameters["securityRules"])
                    count = resolve(self.child["copy"]["count"], parameters)
                    self.assertEqual(len(group["securityRules"]), count)
                    for rule_index, rule in enumerate(group["securityRules"]):
                        property_names.update(rule["properties"])
                        self.assertEqual(group["name"] + "/" + rule["name"], resolve(self.child["name"], parameters, rule_index))
                        self.assertEqual(rule["properties"], resolve(self.child["properties"], parameters, rule_index))
                    self.assertTrue(all(not rule["name"].lower().startswith("ccoe") for rule in parameters["securityRules"]),
                                    "Central rules must not be copied into the IPAFFS ownership list")
        self.assertTrue({"description", "protocol", "priority", "direction", "access", "sourceAddressPrefix",
                         "destinationAddressPrefix", "destinationAddressPrefixes",
                         "sourcePortRange", "destinationPortRange", "destinationPortRanges"}.issubset(property_names))

    def test_augmented_rule_selectors_are_forwarded_without_a_lossy_property_allowlist(self):
        properties = {"description": "Augmented rule", "protocol": "Tcp", "priority": 1200,
                      "direction": "Inbound", "access": "Allow", "sourcePortRanges": ["1024-65535"],
                      "destinationPortRanges": ["443", "8443"],
                      "sourceAddressPrefixes": ["10.0.0.0/24", "10.0.1.0/24"],
                      "destinationApplicationSecurityGroups": [{"id": "/subscriptions/fixture/resourceGroups/fixture/providers/Microsoft.Network/applicationSecurityGroups/backend"}]}
        groups = [{"name": "fresh-group", "securityRules": [{"name": "augmented", "properties": properties}]}]
        parameters = self.group_inputs(groups, 0)
        self.assertEqual("fresh-group/augmented", resolve(self.child["name"], parameters))
        self.assertEqual(properties, resolve(self.child["properties"], parameters))

    def test_fresh_agc_and_empty_rule_groups_keep_a_bootstrap_resource(self):
        for environment, groups in self.environment_groups.items():
            agc = [group for group in groups if group["purpose"] == "App Gateway for Containers"]
            self.assertEqual(1, len(agc), environment)
            self.assertTrue(agc[0]["securityRules"], environment)
            self.assertTrue(resolve(self.parent["condition"], self.group_inputs(groups, groups.index(agc[0]))))
            empty = [index for index, group in enumerate(groups) if not group["securityRules"]]
            self.assertTrue(empty, environment)
            for index in empty:
                parameters = self.group_inputs(groups, index)
                self.assertEqual(groups[index]["name"], resolve(self.parent["name"], parameters))
                self.assertEqual(0, resolve(self.child["copy"]["count"], parameters))


if __name__ == "__main__":
    unittest.main()
