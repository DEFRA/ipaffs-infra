"""Check job consolidation, runtime parameter files and explicit output contracts.

The small expander below handles this repository's local stage/job-template clauses;
it does not emulate Azure DevOps scheduling or replace server-side validation.
All scripts run against temporary files and fake executables, without Azure.
"""

import ast
import fnmatch
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
MAIN_ONLY = "and(not(failed()), not(canceled()), eq(variables['Build.SourceBranch'], 'refs/heads/main'))"
COMPONENTS = {
    "resource-group": "DeployResourceGroup",
    "network": "DeployNetwork",
    "acr": "DeployACR",
    "classic": "DeployClassic",
    "infra": "DeployInfrastructure",
    "infra-to-classic": "DeployInfrastructureToClassic",
    "privatelink": "PrivateLink",
}
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


def split_arguments(text):
    """Split only function arguments, respecting quoted strings and nesting."""
    parts, start, depth, quote = [], 0, 0, None
    for index, char in enumerate(text):
        if quote:
            if char == quote:
                quote = None
        elif char in "'\"":
            quote = char
        elif char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(text[start:index].strip())
            start = index + 1
    if text[start:].strip():
        parts.append(text[start:].strip())
    return parts


def evaluate(expression, context):
    expression = expression.strip()
    call = re.fullmatch(r"(\w+)\((.*)\)", expression)
    if call:
        name, arguments = call.groups()
        values = [evaluate(argument, context) for argument in split_arguments(arguments)]
        functions = {"eq": lambda a, b: a == b, "ne": lambda a, b: a != b,
                     "or": lambda *items: any(items), "and": lambda *items: all(items),
                     "not": lambda value: not value, "lower": str.lower,
                     "length": len, "gt": lambda a, b: a > b, "replace": str.replace}
        return functions[name](*values)
    reference = re.fullmatch(r"(\w+)\.(\w+)", expression)
    if reference:
        parent, name = reference.groups()
        return context[parent][name]
    reference = re.fullmatch(r"variables\['([^']+)'\]", expression)
    if reference:
        return context["variables"][reference[1]]
    if expression in ("true", "false"):
        return expression == "true"
    if expression in context:
        return context[expression]
    return ast.literal_eval(expression)


def expand(node, context):
    if isinstance(node, str):
        match = EXPRESSION.fullmatch(node)
        if match:
            return evaluate(match[1], context)
        return EXPRESSION.sub(lambda match: str(evaluate(match[1], context)), node)
    if not isinstance(node, (dict, list)):
        return node
    result = [] if isinstance(node, list) else {}
    previous_condition = None
    entries = [(None, item) for item in node] if isinstance(node, list) else node.items()
    for key, value in entries:
        directive = None
        if key is not None:
            directive = EXPRESSION.fullmatch(key)
        elif isinstance(value, dict) and len(value) == 1:
            directive_key, directive_value = next(iter(value.items()))
            directive = EXPRESSION.fullmatch(directive_key)
            if directive:
                value = directive_value
        if directive:
            clause = directive[1].strip()
            loop = re.fullmatch(r"each (\w+) in (.*)", clause)
            if loop:
                name, source = loop.groups()
                collection = evaluate(source, context)
                items = [{"key": key, "value": value} for key, value in collection.items()] if isinstance(collection, dict) else collection
                for item in items:
                    child = expand(value, {**context, name: item})
                    result.extend(child)
                continue
            if clause.startswith("if "):
                selected = evaluate(clause[3:], context)
                previous_condition = selected
            elif clause == "else":
                selected = not previous_condition
            elif clause.startswith("elseif "):
                selected = not previous_condition and evaluate(clause[7:], context)
                previous_condition = previous_condition or selected
            else:
                raise AssertionError(f"Unsupported template clause: {clause}")
            if selected:
                child = expand(value, context)
                result.extend(child) if isinstance(result, list) else result.update(child)
        elif isinstance(result, list):
            result.append(expand(value, context))
        else:
            result[expand(key, context)] = expand(value, context)
    return result


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def parameters(document, overrides):
    return {**{item["name"]: item.get("default") for item in document.get("parameters", [])}, **overrides}


def template_path(path, template):
    if "@" in template:
        raise AssertionError(f"External job/stage template cannot be expanded locally: {template}")
    return posixpath.normpath(template.lstrip("/") if template.startswith("/")
                             else str(Path(path).parent / template))


def expand_jobs(path, entries, branch, sources):
    jobs = []
    for entry in entries:
        if "template" not in entry:
            jobs.append(entry)
            continue
        source = template_path(path, entry["template"])
        sources.add(source)
        document = load(source)
        context = {"parameters": parameters(document, entry.get("parameters", {})),
                   "variables": {"Build.SourceBranch": branch}}
        jobs.extend(expand_jobs(source, expand(document["jobs"], context), branch, sources))
    return jobs


def expand_stages(path, overrides=None, branch="refs/heads/main", sources=None):
    sources = sources if sources is not None else set()
    sources.add(posixpath.normpath(path))
    document = load(path)
    context = {"parameters": parameters(document, overrides or {}),
               "variables": {"Build.SourceBranch": branch}}
    stages = []
    for entry in expand(document["stages"], context):
        if "template" in entry:
            template = template_path(path, entry["template"])
            stages.extend(expand_stages(template, entry.get("parameters"), branch, sources))
        else:
            entry["jobs"] = expand_jobs(path, entry["jobs"], branch, sources)
            stages.append(entry)
    return stages


def steps(stage):
    job, = stage["jobs"]
    return job_steps(job)


def job_steps(job):
    return job.get("steps") or job["strategy"]["runOnce"]["deploy"]["steps"]


class ConsolidatedBicepJobTests(unittest.TestCase):
    def test_seven_components_each_use_one_gated_deployment_and_no_downloads(self):
        for component, stage_name in COMPONENTS.items():
            for environment in ("DEV", "TST", "PRE", "PRD"):
                with self.subTest(component=component, environment=environment):
                    stage, = expand_stages(f"pipelines/stages/deploy-bicep-{component}.yaml", {
                        "environmentName": environment,
                        "classicEnvironmentName": "SND" if environment == "DEV" else environment})
                    self.assertEqual(stage_name, stage["stage"])
                    job, = stage["jobs"]
                    self.assertEqual("RunBicep", job["deployment"])
                    expected_environment = "SND" if component == "classic" and environment == "DEV" else environment
                    self.assertEqual(expected_environment, job["environment"]["name"])
                    tasks = steps(stage)
                    self.assertEqual([{"download": "none"}, {"checkout": "self"}], tasks[:2])
                    self.assertFalse(any(task.get("task", "").startswith("Download") for task in tasks))
                    task_names = [task.get("displayName", "") for task in tasks]
                    preview, = [index for index, name in enumerate(task_names) if name.startswith("WhatIf - ")]
                    deploy, = [index for index, name in enumerate(task_names) if name.startswith("Deploy - ")]
                    self.assertLess(preview, deploy)
                    self.assertNotIn("condition", tasks[preview])
                    self.assertEqual(MAIN_ONLY, tasks[deploy]["condition"])
                    connection = "$(classicServiceConnection)" if component in ("classic", "infra-to-classic") else "$(serviceConnection)"
                    for task in tasks:
                        if task.get("task") == "AzureCLI@2":
                            self.assertEqual(connection, task["inputs"]["azureSubscription"])
                        if "sync-deployment-outputs.py" in task.get("inputs", {}).get("inlineScript", ""):
                            self.assertGreater(tasks.index(task), deploy)
                            self.assertEqual(MAIN_ONLY, task["condition"])

    def test_all_environment_and_optional_paths_remain_serial_and_output_references_exist(self):
        for pipeline in ("infrastructure", "deploy-bicep"):
            for environment in ("DEV", "TST", "PRE", "PRD"):
                for peering in (False, True):
                    for platform in (False, True):
                        for branch in ("refs/heads/main", "refs/heads/consolidate"):
                            with self.subTest(pipeline=pipeline, environment=environment, peering=peering,
                                              platform=platform, branch=branch):
                                stages = expand_stages(f"pipelines/{pipeline}.yaml", {
                                    "environmentName": environment, "establishPeering": peering,
                                    "includePlatform": platform}, branch)
                                expected = ["TagBuild", "ValidateAccessContract"]
                                if pipeline == "infrastructure":
                                    expected += ["RunHooks"]
                                expected += ["DeployResourceGroup", "DeployNetwork"]
                                if peering:
                                    expected += ["EstablishPeering"]
                                if environment != "TST":
                                    expected += ["DeployACR"]
                                expected += ["DeployClassic", "DeployInfrastructure", "DeployInfrastructureToClassic"]
                                if pipeline == "infrastructure":
                                    expected += ["InfraPermissions", "PrivateLinkDNSRecords"]
                                if pipeline == "deploy-bicep" or platform:
                                    expected += ["PrivateLink"]
                                self.assertEqual(expected, [stage["stage"] for stage in stages])
                                seen = {}
                                for stage in stages:
                                    name = stage["stage"]
                                    dependency = stage.get("dependsOn", list(seen)[-1:])
                                    dependencies = [dependency] if isinstance(dependency, str) else dependency
                                    self.assertLessEqual(set(dependencies), set(seen), name)
                                    # Preserve the preceding stage as a gate: explicit output imports must
                                    # not accidentally turn this serial consolidation into parallelism.
                                    if seen:
                                        self.assertIn(list(seen)[-1], dependencies, name)
                                    imports = {variable["name"]: variable["value"] for variable in stage.get("variables", [])
                                               if "stageDependencies" in str(variable.get("value", ""))}
                                    expected_imports = {
                                        "DeployClassic": {"parameterSqlAdminGroupId", "parameterSqlAdminGroupName"}}
                                    if branch == "refs/heads/main":
                                        subnet_names = {prefix + suffix for prefix in ("aksApiServer", "aksSystemNodes", "aksUserNodes", "appGatewayForContainers", "privateEndpoints")
                                                        for suffix in ("SubnetId", "SubnetName")}
                                        expected_imports.update({
                                            "EstablishPeering": {"vnetName"},
                                            "DeployACR": {"privateEndpointsSubnetId", "privateEndpointsSubnetName"},
                                            "DeployInfrastructure": subnet_names | {"classicRedisResourceId", "classicSearchServiceResourceId", "classicServiceBusNamespaceResourceId", "classicSqlServerResourceId"},
                                            "DeployInfrastructureToClassic": {"grafanaManagedIdentityPrincipalId"},
                                            "InfraPermissions": {"aksClusterResourceId", "aksKubeletPrincipalId", "externalSecretsPrincipalObjectId", "sqlServerManagedIdentityObjectId", "searchServiceManagedIdentityPrincipalId"},
                                            "PrivateLinkDNSRecords": {"keyVaultName", "redisName", "searchServiceName", "sqlServerName", "storageAccountName", "qaKeyVaultName" if environment == "TST" else "acrName"},
                                            "PrivateLink": {"privateEndpointsSubnetId", "privateEndpointsSubnetName"},
                                        })
                                    self.assertEqual(expected_imports.get(name, set()), set(imports), name)
                                    for variable in stage.get("variables", []):
                                        expression = variable.get("value", "")
                                        reference = re.fullmatch(r"\$\[ stageDependencies\.(\w+)\.(\w+)\.outputs\['([^']+)'\] \]", expression)
                                        if not reference:
                                            continue
                                        producer, job_name, output_name = reference.groups()
                                        self.assertIn(producer, dependencies, (name, expression))
                                        self.assertIn(producer, seen, expression)
                                        job, = [job for job in seen[producer]["jobs"]
                                                if job.get("deployment", job.get("job")) == job_name]
                                        producer_steps = job.get("steps") or job["strategy"]["runOnce"]["deploy"]["steps"]
                                        if "deployment" in job:
                                            prefix, task_name, output_variable = output_name.split(".")
                                            self.assertEqual(job_name, prefix)
                                            task, = [task for task in producer_steps if task.get("name") == task_name]
                                            self.assertIn("--emit-output=" + output_variable,
                                                          task["inputs"]["inlineScript"])
                                            self.assertEqual("refs/heads/main", branch)
                                        else:
                                            task_name, output_variable = output_name.split(".")
                                            task, = [task for task in producer_steps if task.get("name") == task_name]
                                            self.assertIn(output_variable, task.get("script", ""))
                                    seen[name] = stage
                                components = [stage for stage in stages if stage["stage"] in COMPONENTS.values()]
                                self.assertEqual(7 - (environment == "TST") - (pipeline == "infrastructure" and not platform),
                                                 sum(len(stage["jobs"]) for stage in components))

    def test_classic_preserves_snd_deployment_scope_and_modern_sql_group_on_both_branches(self):
        for branch in ("refs/heads/main", "refs/heads/consolidate"):
            for pipeline in ("infrastructure", "deploy-bicep"):
                stages = expand_stages(f"pipelines/{pipeline}.yaml", {"environmentName": "DEV"}, branch)
                classic, = [stage for stage in stages if stage["stage"] == "DeployClassic"]
                self.assertEqual(["SND", "LowerEnvs"], [variable["group"] for variable in classic["variables"]
                                                         if "group" in variable])
                self.assertEqual(["/pipelines/vars/common.yaml", "/pipelines/vars/snd.yaml"],
                                 [variable["template"] for variable in classic["variables"] if "template" in variable])
                values = {variable["name"]: variable["value"] for variable in classic["variables"] if "name" in variable}
                for suffix in ("Id", "Name"):
                    self.assertEqual("$[ stageDependencies.ValidateAccessContract.ValidateGroups.outputs['AccessContract.sqlAdminGroup" + suffix + "'] ]",
                                     values["parameterSqlAdminGroup" + suffix])
                output_task, = [task for task in steps(classic) if task.get("name") == "ClassicOutputs"]
                self.assertEqual("DEV", output_task["env"]["ADO_GROUP_NAME"])
                self.assertEqual("$(classicSubscriptionId)", output_task["env"]["SUBSCRIPTION_ID"])
                self.assertEqual("$(classicResourceGroupName)", output_task["env"]["RESOURCE_GROUP"])

    def test_access_contract_exports_modern_sql_group_only_after_successful_validation(self):
        stage, = expand_stages("pipelines/stages/validate-access-contract.yaml", {"environmentName": "DEV"})
        job, = stage["jobs"]
        task, = [task for task in job["steps"] if task.get("name") == "AccessContract"]
        self.assertNotIn("condition", task)
        environment = {**os.environ,
                       "ACCESS_SQL_ADMINS_GROUP_ID": "11111111-1111-4111-8111-111111111111",
                       "ACCESS_SQL_ADMINS_GROUP_NAME": "SQL%0A%AZP25\r\nadmin group",
                       "ACCESS_ACR_PULL_GROUP_ID": "22222222-2222-4222-8222-222222222222",
                       "ACCESS_CERTIFICATE_READERS_GROUP_ID": "33333333-3333-4333-8333-333333333333"}
        success = subprocess.run(["bash", "-c", task["script"]], cwd=ROOT, env=environment,
                                 text=True, capture_output=True, timeout=10)
        self.assertEqual(0, success.returncode, success.stderr)
        self.assertIn("##vso[task.setvariable variable=sqlAdminGroupId;isOutput=true]" + environment["ACCESS_SQL_ADMINS_GROUP_ID"], success.stdout)
        self.assertIn("##vso[task.setvariable variable=sqlAdminGroupName;isOutput=true]SQL%AZP250A%AZP25AZP25%0D%0Aadmin group", success.stdout)
        failure = subprocess.run(["bash", "-c", task["script"]], cwd=ROOT,
                                 env={**environment, "ACCESS_SQL_ADMINS_GROUP_ID": "invalid"},
                                 text=True, capture_output=True, timeout=10)
        self.assertNotEqual(0, failure.returncode)
        self.assertNotIn("##vso[", failure.stdout + failure.stderr)

    def test_standalone_platform_retains_library_variable_fallback(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            for branch in ("refs/heads/main", "refs/heads/consolidate"):
                stages = expand_stages("pipelines/infra-platform.yaml", {"environmentName": environment}, branch)
                stage = stages[-1]
                self.assertEqual("PrivateLink", stage["stage"])
                self.assertIn({"group": environment}, stage["variables"])
                self.assertNotIn("dependsOn", stage)
                self.assertFalse(any("stageDependencies" in str(variable) for variable in stage["variables"]))

    def test_runtime_parameter_scripts_write_valid_relative_paths_and_correct_values(self):
        runtime = {"resource-group": "10-resource-group", "acr": "25-acr", "classic": "30-classic",
                   "infra": "40-infra", "privatelink": "50-privatelink"}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            shutil.copytree(ROOT / "bicep", directory / "bicep")
            for environment in ("DEV", "TST", "PRE", "PRD"):
                for component, filename in runtime.items():
                    if component == "acr" and environment == "TST":
                        continue
                    with self.subTest(environment=environment, component=component):
                        classic = "SND" if environment == "DEV" else environment
                        stage, = expand_stages(f"pipelines/stages/deploy-bicep-{component}.yaml", {
                            "environmentName": environment, "classicEnvironmentName": classic})
                        task, = [task for task in steps(stage) if task.get("name") == "GenerateBicepParams"]
                        script = task["inputs"]["script"]
                        macros = {name: "fixture-" + name for name in re.findall(r"\$\(([^)]+)\)", script)}
                        macros["Build.SourcesDirectory"] = str(directory)
                        macros["parameterSqlAdminGroupId"] = "modern-sql-admin-id"
                        macros["parameterSqlAdminGroupName"] = "modern-sql-admin-name"
                        macros["qaAutomationServiceConnectionPrincipalId"] = "qa-id" if environment == "TST" else ""
                        script = re.sub(r"\$\(([^)]+)\)", lambda match: macros[match[1]], script)
                        result = subprocess.run(["bash", "-c", script], cwd=directory, text=True,
                                                capture_output=True, timeout=10)
                        self.assertEqual(0, result.returncode, result.stderr)
                        generated = directory / "bicep" / (filename + "-runtime.bicepparam")
                        self.assertTrue(generated.is_file(), script)
                        content = generated.read_text()
                        self.assertNotIn("$(", content)
                        self.assertNotIn("${{", content)
                        paths = re.findall(r"^(?:using|extends) '([^']+)'$", content, re.MULTILINE)
                        self.assertEqual([filename + ".bicep", f"envs/{classic.lower() if component == 'classic' else environment.lower()}/{filename}.bicepparam"], paths)
                        for path in paths:
                            self.assertTrue((generated.parent / path).is_file(), path)
                        if component == "classic":
                            self.assertIn("id: 'modern-sql-admin-id'", content)
                            self.assertIn("name: 'modern-sql-admin-name'", content)
                        if component == "infra":
                            self.assertIn("param qaAutomationPrincipalObjectId = '" + ("qa-id" if environment == "TST" else "") + "'", content)
                            for prefix in ("aksApiServer", "aksSystemNodes", "aksUserNodes", "appGatewayForContainers", "privateEndpoints"):
                                self.assertRegex(content, prefix + r": \{\s+id: 'fixture-" + prefix + r"SubnetId'\s+name: 'fixture-" + prefix + r"SubnetName'")
                        if component in ("acr", "privatelink"):
                            self.assertRegex(content, r"privateEndpoints: \{\s+id: 'fixture-privateEndpointsSubnetId'\s+name: 'fixture-privateEndpointsSubnetName'")
                        artifact, = [task for task in steps(stage) if task.get("task") == "PublishPipelineArtifact@1"]
                        self.assertEqual(f"$(Build.SourcesDirectory)/bicep/{filename}-runtime.bicepparam", artifact["inputs"]["targetPath"])
                        self.assertEqual("bicepparam-" + component, artifact["inputs"]["artifactName"])


class AutomaticDevTriggerTests(unittest.TestCase):
    def test_only_infrastructure_auto_deploys_dev_for_relevant_main_changes(self):
        pipeline = load("pipelines/infrastructure.yaml")
        trigger = pipeline["trigger"]
        self.assertEqual({"include": ["main"]}, trigger["branches"])
        self.assertIs(True, trigger["batch"])
        defaults = parameters(pipeline, {})
        self.assertEqual("DEV", defaults["environmentName"])
        self.assertIs(True, defaults["includePlatform"])
        self.assertIs(False, defaults["establishPeering"])

        def matches(path, patterns):
            return any(fnmatch.fnmatchcase(path, pattern) if "**" in pattern
                       else PurePosixPath(path).match(pattern) for pattern in patterns)

        def triggers(path):
            return matches(path, trigger["paths"]["include"]) and not matches(path, trigger["paths"].get("exclude", []))

        template_sources = set()
        expand_stages("pipelines/infrastructure.yaml", sources=template_sources)
        # Optional peering and platform imports must also trigger a DEV run when changed.
        template_sources.update(path.relative_to(ROOT).as_posix()
                                for path in (ROOT / "pipelines/jobs/infrastructure").glob("*.yaml"))
        sources = sorted(template_sources) + ["bicep/40-infra.bicep", "bicep/modules/aks.bicep", "bicep/files/PAsubca.crt",
                    "bicep/default-tags.json", "bicep/bicepconfig.json",
                    "bicep/envs/dev/40-infra.bicepparam", "bicep/envs/snd/30-classic.bicepparam",
                    "pipelines/vars/common.yaml", "pipelines/vars/dev.yaml", "pipelines/vars/snd.yaml",
                    "scripts/pipeline/sync-deployment-outputs.py", "scripts/pipeline/validate-access-contract.py",
                    "scripts/pipeline/add-principal-to-group.sh", "scripts/pipeline/run-hooks.sh",
                    "scripts/hooks/10-common.sh", "scripts/hooks/dev/20-dev.sh"]
        for path in sources:
            with self.subTest(path=path):
                self.assertTrue(triggers(path), path)
        for path in ["README.md", "pipelines/templates/java-template.yaml", "helm-charts/webapp/Chart.yaml",
                     "scripts/pipeline/sync-deployment-outputs.test.py", "scripts/hooks/tst/10-hook.sh",
                     "pipelines/vars/tst.yaml", "pipelines/vars/pre.yaml", "pipelines/vars/prd.yaml",
                     "bicep/envs/tst/40-infra.bicepparam", "bicep/envs/pre/40-infra.bicepparam",
                     "bicep/envs/prd/40-infra.bicepparam"]:
            with self.subTest(path=path):
                self.assertFalse(triggers(path), path)
        for name in ("deploy-bicep", "infra-permissions", "private-endpoint-dns-records"):
            legacy = load(f"pipelines/{name}.yaml")
            self.assertEqual("none", legacy["trigger"])
            self.assertEqual(["main"], legacy["pr"]["branches"]["include"])
        self.assertEqual("none", load("pipelines/infra-platform.yaml")["trigger"])


if __name__ == "__main__":
    unittest.main()
