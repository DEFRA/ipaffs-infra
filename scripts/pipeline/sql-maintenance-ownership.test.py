#!/usr/bin/env python3
"""Verify preservation of live maintenance definitions using compiled ARM.

Set BICEP_BIN to run the compiled cases. No Azure authentication or deployment is
used; ARM condition evaluation below supports only the boolean expression subset
emitted for this ownership switch and rejects any unexpected expression.
"""

from collections import Counter
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "bicep/modules/sql-elastic-jobs.bicep"
MAINTENANCE_TYPES = {"Microsoft.Sql/servers/jobAgents/targetGroups",
                     "Microsoft.Sql/servers/jobAgents/jobs", "Microsoft.Sql/servers/jobAgents/jobs/steps"}
CORE_TYPES = {"Microsoft.Sql/servers/databases", "Microsoft.ManagedIdentity/userAssignedIdentities",
              "Microsoft.Sql/servers/jobAgents", "Microsoft.Insights/metricAlerts"}


def arm_boolean(expression, parameters, variables):
    """Evaluate a small ARM boolean subset, independently of Bicep source text."""
    if isinstance(expression, bool):
        return expression
    if not isinstance(expression, str) or not expression.startswith("[") or not expression.endswith("]"):
        raise AssertionError("Unexpected ARM condition")
    tokens = re.findall(r"'(?:[^']|'')*'|[A-Za-z][A-Za-z0-9]*|[(),]", expression[1:-1])
    if re.sub(r"\s+", "", expression[1:-1]) != "".join(tokens):
        raise AssertionError("Unexpected ARM condition syntax")
    position = 0

    def take():
        nonlocal position
        token = tokens[position]
        position += 1
        return token

    def evaluate():
        token = take()
        if token.startswith("'"):
            return token[1:-1].replace("''", "'")
        if take() != "(":
            raise AssertionError("Expected ARM function")
        arguments = []
        if tokens[position] != ")":
            arguments.append(evaluate())
            while tokens[position] == ",":
                take()
                arguments.append(evaluate())
        if take() != ")":
            raise AssertionError("Expected ARM function close")
        functions = {
            "true": lambda: True, "false": lambda: False,
            "parameters": lambda name: parameters[name],
            "variables": lambda name: arm_boolean(variables[name], parameters, variables),
            "tryGet": lambda value, key: value.get(key),
            "coalesce": lambda *values: next((value for value in values if value is not None), None),
        }
        if token not in functions:
            raise AssertionError("Unexpected ARM function")
        return functions[token](*arguments)

    value = evaluate()
    if position != len(tokens) or not isinstance(value, bool):
        raise AssertionError("Condition did not resolve to a boolean")
    return value


class SqlMaintenanceOwnershipSourceTests(unittest.TestCase):
    def test_pre_and_prd_explicitly_preserve_live_maintenance_definitions(self):
        for environment in ("pre", "prd"):
            source = (ROOT / f"bicep/envs/{environment}/30-classic.bicepparam").read_text()
            self.assertRegex(source, r"param sejParams = \{\s*(?://[^\n]*\n\s*)*manageMaintenanceDefinitions: false")

    def test_classic_deployment_retains_incremental_resource_preservation(self):
        deployment = (ROOT / "pipelines/stages/deploy-bicep-classic.yaml").read_text()
        self.assertNotRegex(deployment, r"(?i)--mode\s+[\"']?complete")
        self.assertIn("az deployment group create", deployment)


@unittest.skipUnless(os.environ.get("BICEP_BIN"), "Set BICEP_BIN to compile the ownership cases")
class CompiledSqlMaintenanceOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.environment = dict(os.environ)
        cls.environment.setdefault("DOTNET_BUNDLE_EXTRACT_BASE_DIR", cls.temporary.name)
        cls.template = cls.compile("build", MODULE)
        cls.parameters = {}
        for environment in ("snd", "tst", "pre", "prd"):
            result = cls.compile("build-params", ROOT / f"bicep/envs/{environment}/30-classic.bicepparam")
            cls.parameters[environment] = {name: value["value"] for name, value in json.loads(result["parametersJson"])["parameters"].items()}

    @classmethod
    def compile(cls, command, path):
        result = subprocess.run([os.environ["BICEP_BIN"], command, str(path), "--stdout", "--no-restore"],
                                capture_output=True, text=True, timeout=60, env=cls.environment)
        if result.returncode:
            raise AssertionError(result.stderr)
        if "BCP318" in result.stderr:
            raise AssertionError("Conditional maintenance reference may be null: " + result.stderr)
        return json.loads(result.stdout)

    def active(self, parameters):
        return [resource for resource in self.template["resources"]
                if arm_boolean(resource.get("condition", True), parameters, self.template.get("variables", {}))]

    def test_pre_and_prd_omit_all_five_maintenance_resources_but_keep_agent_and_alert(self):
        for environment in ("pre", "prd"):
            with self.subTest(environment=environment):
                resources = self.active(self.parameters[environment])
                self.assertEqual(CORE_TYPES, {resource["type"] for resource in resources})
                self.assertEqual(4, len(resources))
                self.assertFalse(any(resource["type"] in MAINTENANCE_TYPES for resource in resources))

    def test_snd_and_tst_keep_the_existing_bootstrap_without_an_explicit_flag(self):
        expected = Counter({**{resource_type: 1 for resource_type in CORE_TYPES},
                            "Microsoft.Sql/servers/jobAgents/targetGroups": 1,
                            "Microsoft.Sql/servers/jobAgents/jobs": 2,
                            "Microsoft.Sql/servers/jobAgents/jobs/steps": 2})
        for environment in ("snd", "tst"):
            with self.subTest(environment=environment):
                self.assertNotIn("manageMaintenanceDefinitions", self.parameters[environment]["sejParams"])
                self.assertEqual(expected, Counter(resource["type"] for resource in self.active(self.parameters[environment])))

    def test_an_explicit_true_value_can_reenable_management(self):
        parameters = copy.deepcopy(self.parameters["pre"])
        parameters["sejParams"]["manageMaintenanceDefinitions"] = True
        self.assertEqual(9, len(self.active(parameters)))

    def test_only_maintenance_resources_are_conditional(self):
        guarded = [resource for resource in self.template["resources"] if "condition" in resource]
        self.assertEqual(5, len(guarded))
        self.assertEqual(MAINTENANCE_TYPES, {resource["type"] for resource in guarded})
        for resource in guarded:
            self.assertEqual("[variables('manageMaintenanceDefinitions')]", resource["condition"])

    def test_managed_mode_retains_commands_schedules_and_parameter_driven_targets(self):
        resources = self.active(self.parameters["tst"])
        target = next(resource for resource in resources if resource["type"].endswith("/targetGroups"))
        membership = target["properties"]["copy"][0]
        self.assertEqual("[length(parameters('sejParams').databaseNames)]", membership["count"])
        self.assertEqual("Include", membership["input"]["membershipType"])
        self.assertEqual("SqlDatabase", membership["input"]["type"])
        self.assertEqual("[parameters('sejParams').databaseNames[copyIndex('members')]]", membership["input"]["databaseName"])
        steps = [resource for resource in resources if resource["type"].endswith("/steps")]
        self.assertEqual({"EXEC dbo.DBA_Sch_Weekly_Index_Maintenance  @ExclTablenames = 'dbo.notification_audit',@FragLvl1=30,@FragLvl2=70;",
                          "EXEC dbo.DBA_Sch_Daily_Statistics_Maintenance @ExclTablenames = 'dbo.notification_audit';"},
                         {resource["properties"]["action"]["value"] for resource in steps})
        schedules = [resource["properties"]["schedule"] for resource in resources if resource["type"].endswith("/jobs")]
        self.assertEqual({"P1W", "P1D"}, {schedule["interval"] for schedule in schedules})
        self.assertTrue(all(schedule["enabled"] for schedule in schedules))


if __name__ == "__main__":
    unittest.main()
