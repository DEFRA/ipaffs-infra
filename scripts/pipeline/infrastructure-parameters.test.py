#!/usr/bin/env python3
"""Renderer safety tests. Set BICEP_BIN to also compile all environment cases."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("parameters", Path(__file__).with_name("infrastructure_parameters.py"))
PARAMETERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARAMETERS)


def fixtures(environment="TST"):
    values = {name: "fixture-" + name for name in PARAMETERS.ENVIRONMENT_VARIABLES}
    values["qaAutomationServiceConnectionPrincipalId"] = "qa-principal" if environment == "TST" else ""
    return values


def expected_overrides(component, environment, values):
    """The existing deployment overlays, plus the existing CLI overrides."""
    result = {}
    if component == "acr":
        result["entraGroups"] = {"acrPull": {
            "id": values["acrPullGroupId"], "name": values["acrPullGroupName"]}}
    if component == "classic":
        result["entraGroups"] = {"sqlAdmins": {
            "id": values["parameterSqlAdminGroupId"], "name": values["parameterSqlAdminGroupName"]}}
    if component == "infra":
        result.update({
            "qaAutomationPrincipalObjectId": values["qaAutomationServiceConnectionPrincipalId"],
            "classicResourceIds": {
                "redis": values["classicRedisResourceId"],
                "searchService": values["classicSearchServiceResourceId"],
                "serviceBusNamespace": values["classicServiceBusNamespaceResourceId"],
                "sqlServer": values["classicSqlServerResourceId"]},
            "entraGroups": {"sqlAdmins": {
                "id": values["sqlAdminGroupId"], "name": values["sqlAdminGroupName"]}}})
    if component in ("acr", "infra", "privatelink"):
        names = ("aksApiServer", "aksSystemNodes", "aksUserNodes", "appGatewayForContainers", "privateEndpoints") if component == "infra" else ("privateEndpoints",)
        result["subnets"] = {name: {
            "id": values[name + "SubnetId"], "name": values[name + "SubnetName"]} for name in names}
    if component in ("classic", "infra"):
        result["tenantId"] = values["tenantId"]
    if component == "infra":
        result["deployServicePrincipalObjectId"] = values["serviceConnectionPrincipalId"]
    return result


class InfrastructureParameterTests(unittest.TestCase):
    def test_every_component_and_environment_uses_existing_relative_base(self):
        for environment in PARAMETERS.ENVIRONMENTS:
            for component, filename in PARAMETERS.COMPONENTS.items():
                if component == "acr" and environment == "TST":
                    continue
                with self.subTest(environment=environment, component=component):
                    result = PARAMETERS.render(component, environment, fixtures(environment))
                    classic = "snd" if environment == "DEV" else environment.lower()
                    base = classic if component == "classic" else environment.lower()
                    self.assertTrue(result.startswith(f"using '{filename}.bicep'\nextends 'envs/{base}/{filename}.bicepparam'\n"))
                    self.assertTrue((ROOT / "bicep" / f"envs/{base}/{filename}.bicepparam").is_file())
                    self.assertNotIn("$(", result)

    def test_classic_can_override_default_dev_to_snd_mapping(self):
        result = PARAMETERS.render("classic", "DEV", fixtures(), classic_environment="PRE")
        self.assertIn("extends 'envs/pre/30-classic.bicepparam'", result)

    def test_network_and_resource_group_have_no_runtime_overlays(self):
        for component in ("network", "resource-group"):
            self.assertEqual(2, len(PARAMETERS.render(component, "PRD", {}).splitlines()))

    def test_missing_and_unresolved_required_values_fail_without_echoing_values(self):
        for value in (None, "", " ", "$(sqlAdminGroupId)", "${{ variables.sqlAdminGroupId }}",
                      "$[ stageDependencies.Validate.outputs['group'] ]", "secret\x00value"):
            with self.subTest(value=value):
                values = fixtures()
                values["sqlAdminGroupId"] = value
                with self.assertRaises(ValueError) as failure:
                    PARAMETERS.render("infra", "TST", values)
                self.assertIn("sqlAdminGroupId", str(failure.exception))
                if value and value.strip():
                    self.assertNotIn(value, str(failure.exception))

    def test_missing_qa_principal_is_only_optional_outside_tst(self):
        values = fixtures()
        del values["qaAutomationServiceConnectionPrincipalId"]
        for environment in ("DEV", "PRE", "PRD"):
            result = PARAMETERS.render("infra", environment, values)
            self.assertIn("param qaAutomationPrincipalObjectId = ''", result)
        with self.assertRaisesRegex(ValueError, "qaAutomationServiceConnectionPrincipalId"):
            PARAMETERS.render("infra", "TST", values)

    def test_optional_qa_principal_still_rejects_unresolved_variable(self):
        values = fixtures()
        values["qaAutomationServiceConnectionPrincipalId"] = "$(missingQaPrincipal)"
        with self.assertRaisesRegex(ValueError, "qaAutomationServiceConnectionPrincipalId"):
            PARAMETERS.render("infra", "PRD", values)

    def test_cli_overrides_are_optional_in_shared_deployment_parameter_files(self):
        values = fixtures()
        del values["tenantId"]
        del values["serviceConnectionPrincipalId"]
        for component in ("classic", "infra"):
            result = PARAMETERS.render(component, "TST", values)
            self.assertNotIn("param tenantId", result)
            self.assertNotIn("param deployServicePrincipalObjectId", result)

    def test_quotes_interpolation_and_shell_characters_are_data(self):
        values = fixtures()
        values["parameterSqlAdminGroupName"] = "O'Brien \\ ${injected}\nsecond\t`touch /tmp/nope`"
        result = PARAMETERS.render("classic", "PRD", values)
        self.assertIn(r"name: 'O\'Brien \\ \${injected}\nsecond\t`touch /tmp/nope`'", result)

    def test_rejects_unknown_component_environment_and_tst_acr(self):
        for args in (("../infra", "TST"), ("infra-to-classic", "TST"),
                     ("infra", "../../prd"), ("acr", "TST")):
            with self.subTest(args=args), self.assertRaises(ValueError):
                PARAMETERS.render(*args, fixtures())

    def test_write_validates_before_replacing_an_existing_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "runtime.bicepparam"
            output.write_text("original")
            with self.assertRaises(ValueError):
                PARAMETERS.write_parameters("infra", "TST", {}, output)
            self.assertEqual("original", output.read_text())
            with self.assertRaisesRegex(ValueError, "absolute"):
                PARAMETERS.write_parameters("network", "TST", {}, Path("relative.bicepparam"))

    def test_cli_only_reads_explicit_allowlist_and_does_not_log_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "runtime.bicepparam"
            values = fixtures()
            environment = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", ""),
                           "BICEP_PARAMETER_SQL_ADMIN_GROUP_ID": values["parameterSqlAdminGroupId"],
                           "BICEP_PARAMETER_SQL_ADMIN_GROUP_NAME": values["parameterSqlAdminGroupName"],
                           "TENANTID": "must-not-be-used"}
            result = subprocess.run([sys.executable, str(Path(PARAMETERS.__file__)),
                                     "--component", "classic", "--environment", "DEV", "--output", str(output)],
                                    env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("", result.stdout + result.stderr)
            self.assertIn(values["parameterSqlAdminGroupName"], output.read_text())
            self.assertNotIn("must-not-be-used", output.read_text())


@unittest.skipUnless(os.environ.get("BICEP_BIN"), "Set BICEP_BIN to enable actual Bicep compilation")
class CompiledParameterParityTests(unittest.TestCase):
    def compile(self, path):
        result = subprocess.run([os.environ["BICEP_BIN"], "build-params", str(path), "--stdout", "--no-restore"],
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(json.loads(result.stdout)["parametersJson"])["parameters"]

    def test_all_environment_parameters_keep_base_values_and_exact_deployment_overlays(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bicep"
            shutil.copytree(ROOT / "bicep", root)
            for environment in PARAMETERS.ENVIRONMENTS:
                values = fixtures(environment)
                for component, filename in PARAMETERS.COMPONENTS.items():
                    if component == "acr" and environment == "TST":
                        continue
                    with self.subTest(environment=environment, component=component):
                        base_environment = "SND" if component == "classic" and environment == "DEV" else environment
                        expected = self.compile(root / f"envs/{base_environment.lower()}/{filename}.bicepparam")
                        expected.update({key: {"value": value} for key, value in expected_overrides(component, environment, values).items()})
                        output = root / f"{filename}-runtime.bicepparam"
                        PARAMETERS.write_parameters(component, environment, values, output)
                        self.assertEqual(expected, self.compile(output))

    def test_escaped_bicep_string_compiles_to_original_value(self):
        value = "O'Brien \\ ${injected}\r\nsecond\t`touch /tmp/nope`"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "escaped.bicepparam"
            path.write_text("using none\nparam value = " + PARAMETERS._quote(value) + "\n")
            self.assertEqual({"value": {"value": value}}, self.compile(path))


if __name__ == "__main__":
    unittest.main()
