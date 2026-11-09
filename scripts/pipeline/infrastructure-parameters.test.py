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

import yaml


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("parameters", Path(__file__).with_name("infrastructure_parameters.py"))
PARAMETERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARAMETERS)


def fixtures(environment="TST"):
    values = {name: "fixture-" + name for name in PARAMETERS.ENVIRONMENT_VARIABLES}
    values["qaAutomationServiceConnectionPrincipalId"] = "qa-principal" if environment == "TST" else ""
    return values


def expected_overrides(component, environment, values):
    """The runtime values shared by deployments and previews."""
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

    def test_network_overlay_accepts_valid_existing_names_and_explicit_empty_results(self):
        names = ["Existing-PrivateEndpoint", "Existing-AKS"]
        result = PARAMETERS.render("network", "PRE", {"existingNetworkSecurityGroupNames": names})
        self.assertIn("param existingNetworkSecurityGroupNames = [\n  'Existing-AKS'\n  'Existing-PrivateEndpoint'\n]", result)
        self.assertEqual(names, ["Existing-PrivateEndpoint", "Existing-AKS"], "Validation does not mutate caller data")
        result = PARAMETERS.render("network", "PRE", {"existingNetworkSecurityGroupNames": []})
        self.assertIn("param existingNetworkSecurityGroupNames = [\n]", result)

    def test_invalid_network_name_reads_fail_without_publishing_values(self):
        for names in (None, "[]", {}, [None], ["Name", "name"], ["private-value;unexpected"],
                      ["$(pipelineVariable)"], ["a" * 81], ["Bad\nName"], ["-bad"], ["bad."]):
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, "Invalid existing network security group names") as failure:
                PARAMETERS.render("network", "PRE", {"existingNetworkSecurityGroupNames": names})
            self.assertNotIn("private-value", str(failure.exception))

    def network_task(self, script, names, status=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bicep = root / "bicep"
            bicep.mkdir()
            scripts = root / "scripts" / "pipeline"
            scripts.mkdir(parents=True)
            for filename in ("infrastructure_parameters.py", "ensure-bicep-version.sh"):
                shutil.copyfile(ROOT / "scripts" / "pipeline" / filename, scripts / filename)
            version_line = next(line for line in (scripts / "ensure-bicep-version.sh").read_text().splitlines()
                                if line.startswith("required_bicep_version="))
            version = version_line.split("=", 1)[1]
            executables = root / "bin"
            executables.mkdir()
            calls = root / "calls.jsonl"
            azure = executables / "az"
            azure.write_text("#!" + sys.executable + "\n" + "\n".join([
                "import json,os,sys",
                "args=sys.argv[1:]",
                f"with open({str(calls)!r},'a') as stream: stream.write(json.dumps(args)+'\\n')",
                f"if args[:2] == ['bicep','version']: print('Bicep CLI version {version} (fixture)')",
                "elif args[:3] == ['network','nsg','list']:",
                "    print(os.environ['FIXTURE_NAMES'])",
                "    sys.exit(int(os.environ['FIXTURE_NSG_STATUS']))",
                "elif args[:2] != ['deployment','group']: sys.exit(99)",
            ]) + "\n")
            azure.chmod(0o700)
            script = (script.replace("$(subscriptionId)", "11111111-1111-4111-8111-111111111111")
                      .replace("$(resourceGroupName)", "fixture-group").replace("$(Build.BuildId)", "123")
                      .replace("$(Build.SourcesDirectory)", str(root))
                      .replace("${{ parameters.environmentName }}", "PRE"))
            result = subprocess.run(["bash", "-c", script], cwd=root,
                                    env={**os.environ, "PATH": str(executables) + os.pathsep + os.environ["PATH"],
                                         "FIXTURE_NAMES": json.dumps(names), "FIXTURE_NSG_STATUS": str(status)},
                                    capture_output=True, text=True, timeout=10)
            runtime_params = bicep / "20-network-runtime.bicepparam"
            return (result, [json.loads(line) for line in calls.read_text().splitlines()],
                    runtime_params.read_text() if runtime_params.exists() else None)

    def test_network_what_if_and_apply_each_discover_and_validate_their_own_names_before_deployment(self):
        document = yaml.safe_load((ROOT / "pipelines/stages/deploy-bicep-network.yaml").read_text())
        steps = document["stages"][0]["jobs"][0]["strategy"]["runOnce"]["deploy"]["steps"]
        tasks = [step for step in steps if step.get("displayName") in {"WhatIf - Network", "Deploy - Network"}]
        self.assertEqual(2, len(tasks))
        for task in tasks:
            script = task["inputs"]["inlineScript"]
            self.assertNotIn("set -x", script)
            for names, status, success in ((["Existing-AKS"], 0, True), ([], 0, True),
                                           (["private-value;unexpected"], 0, False), (None, 0, False), ([], 7, False)):
                with self.subTest(task=task["displayName"], names=names, status=status):
                    result, calls, runtime_params = self.network_task(script, names, status)
                    self.assertEqual(success, result.returncode == 0, result.stderr)
                    reads = [call for call in calls if call[:3] == ["network", "nsg", "list"]]
                    self.assertEqual(1, len(reads))
                    self.assertEqual("[].name", reads[0][reads[0].index("--query") + 1])
                    writes = [call for call in calls if call[:2] == ["deployment", "group"]]
                    self.assertEqual(int(success), len(writes))
                    if success:
                        self.assertEqual(["--parameters", "bicep/20-network-runtime.bicepparam"], writes[0][-2:])
                        self.assertEqual(1, writes[0].count("--parameters"))
                        self.assertIn("extends 'envs/pre/20-network.bicepparam'", runtime_params)
                        names_lines = "".join(f"  '{name}'\n" for name in names)
                        self.assertIn(f"param existingNetworkSecurityGroupNames = [\n{names_lines}]", runtime_params)
                    else:
                        self.assertIsNone(runtime_params)
                    self.assertNotIn("private-value", result.stdout + result.stderr)

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

    def test_tenant_and_principal_inputs_must_be_resolved_before_deployment(self):
        for component, name in (("classic", "tenantId"), ("infra", "tenantId"),
                                ("infra", "serviceConnectionPrincipalId")):
            for value in (None, "", "$(unresolved)"):
                with self.subTest(component=component, name=name, value=value):
                    values = fixtures()
                    values[name] = value
                    with self.assertRaisesRegex(ValueError, name):
                        PARAMETERS.render(component, "TST", values)

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
                           "BICEP_TENANT_ID": values["tenantId"],
                           "TENANTID": "must-not-be-used"}
            result = subprocess.run([sys.executable, str(Path(PARAMETERS.__file__)),
                                     "--component", "classic", "--environment", "DEV", "--output", str(output)],
                                    env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("", result.stdout + result.stderr)
            self.assertIn(values["parameterSqlAdminGroupName"], output.read_text())
            self.assertIn(f"param tenantId = '{values['tenantId']}'", output.read_text())
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

    def test_network_existing_names_overlay_compiles_for_existing_and_new_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "bicep"
            shutil.copytree(ROOT / "bicep", root)
            for environment in PARAMETERS.ENVIRONMENTS:
                for names in ([], ["Existing-AKS", "Existing-PrivateEndpoint"]):
                    with self.subTest(environment=environment, names=names):
                        output = root / "20-network-runtime.bicepparam"
                        PARAMETERS.write_parameters("network", environment, {"existingNetworkSecurityGroupNames": names}, output)
                        self.assertEqual({"value": names}, self.compile(output)["existingNetworkSecurityGroupNames"])

    def test_escaped_bicep_string_compiles_to_original_value(self):
        value = "O'Brien \\ ${injected}\r\nsecond\t`touch /tmp/nope`"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "escaped.bicepparam"
            path.write_text("using none\nparam value = " + PARAMETERS._quote(value) + "\n")
            self.assertEqual({"value": {"value": value}}, self.compile(path))


if __name__ == "__main__":
    unittest.main()
