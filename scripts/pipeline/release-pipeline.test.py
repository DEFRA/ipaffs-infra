"""Exercise release source validation and the expanded promotion contracts locally.

The shared test helper expands this repository's small YAML template subset. It
does not emulate Azure DevOps resource authorization or deployment scheduling.
"""

import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
specification = importlib.util.spec_from_file_location(
    "release_template_helpers", Path(__file__).with_name("consolidated-bicep-jobs.test.py"))
TEMPLATES = importlib.util.module_from_spec(specification)
specification.loader.exec_module(TEMPLATES)


def mappings(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from mappings(value)
    elif isinstance(node, list):
        for value in node:
            yield from mappings(value)


def release_stages(**overrides):
    return TEMPLATES.expand_stages("release-pipeline.yaml", overrides, "refs/tags/42")


def dependency_graph(stages):
    graph, ancestors = {}, {}
    for stage in stages:
        name = stage["stage"]
        dependencies = stage.get("dependsOn", list(graph)[-1:])
        dependencies = [dependencies] if isinstance(dependencies, str) else dependencies
        if not set(dependencies) <= set(graph):
            raise AssertionError(f"{name} has unavailable dependencies: {dependencies}")
        graph[name] = set(dependencies)
        ancestors[name] = set(dependencies)
        for dependency in dependencies:
            ancestors[name].update(ancestors[dependency])
    return graph, ancestors


class ReleasePipelineTests(unittest.TestCase):
    def test_tag_pushes_trigger_source_validation_for_a_named_release(self):
        pipeline = TEMPLATES.load("release-pipeline.yaml")
        self.assertEqual({"exclude": ["*"]}, pipeline["trigger"]["branches"])
        self.assertEqual({"include": ["*"], "exclude": ["ipaffs-infra-pin-*"]}, pipeline["trigger"]["tags"])
        self.assertEqual("none", pipeline["pr"])
        self.assertEqual("$(Build.SourceBranchName)", pipeline["name"])
        self.assertIs(False, pipeline["appendCommitMessageToRunName"])

    def run_validation(self, reference, approval_timeout=None):
        overrides = {} if approval_timeout is None else {"releaseApprovalTimeoutInMinutes": approval_timeout}
        validation, = [stage for stage in release_stages(**overrides) if stage["stage"] == "ValidateTaggedSource"]
        task, = [entry for entry in mappings(validation) if entry.get("task") == "Bash@3"]
        script = task["inputs"]["script"]
        replacements = {"Build.SourceBranch": reference, "Build.SourceBranchName": reference.rsplit("/", 1)[-1]}

        def macros(value):
            return re.sub(r"\$\(([^)]+)\)", lambda match: replacements[match[1]], str(value))

        environment = {**os.environ, **{name: macros(value) for name, value in task.get("env", {}).items()}}
        return subprocess.run(["bash", "-c", macros(script)], cwd=ROOT, env=environment,
                              text=True, capture_output=True, timeout=10)

    def test_validation_accepts_positive_integer_tags_and_rejects_other_refs(self):
        for reference in ("refs/tags/1", "refs/tags/2", "refs/tags/42", "refs/tags/123456789",
                          "refs/tags/99999999999999999999999999999999999999999999999999"):
            with self.subTest(reference=reference):
                result = self.run_validation(reference)
                self.assertEqual(0, result.returncode, result.stderr)
        for reference in ("refs/heads/main", "refs/heads/RELEASE/42", "refs/pull/42/merge",
                          "refs/tags/ipaffs-infra-pin-abc", "refs/tags/0", "refs/tags/01", "refs/tags/00", "refs/tags/-1",
                          "refs/tags/+1", "refs/tags/v1", "refs/tags/1.0.0", "refs/tags/18.9.0",
                          "refs/tags/1e3", "refs/tags/１", "refs/tags/١",
                          "refs/tags/1-rc.1", "refs/tags/1+build", "refs/tags/1/other",
                          "refs/tags/nested/1", "refs/tags/ 1", "refs/tags/1 ",
                          "refs/tags/1\n", "refs/tags/1\n2", "refs/tags/1\t", "1", ""):
            with self.subTest(reference=reference):
                result = self.run_validation(reference)
                self.assertNotEqual(0, result.returncode, result.stdout)

    def test_validation_does_not_execute_text_in_a_tag(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "unexpected"
            for reference in (f"refs/tags/1$(touch '{marker}')", f"refs/tags/1`touch '{marker}'`"):
                with self.subTest(reference=reference):
                    result = self.run_validation(reference)
                    self.assertNotEqual(0, result.returncode)
                    self.assertFalse(marker.exists())

    def test_approval_timeout_is_a_positive_integer_below_the_agentless_job_limit(self):
        for timeout in (1, 60, 43199):
            with self.subTest(timeout=timeout):
                result = self.run_validation("refs/tags/1", timeout)
                self.assertEqual(0, result.returncode, result.stderr)
        for timeout in (0, -1, 43200, 100000, 1.5):
            with self.subTest(timeout=timeout):
                result = self.run_validation("refs/tags/1", timeout)
                self.assertNotEqual(0, result.returncode, result.stdout)

    def test_every_environment_is_serial_and_promotion_gates_cover_all_deployment_stages(self):
        for peering in (False, True):
            for platform in (False, True):
                with self.subTest(peering=peering, platform=platform):
                    stages = release_stages(establishPeering=peering, includePlatform=platform)
                    names = [stage["stage"] for stage in stages]
                    self.assertEqual(len(names), len(set(names)))
                    graph, ancestors = dependency_graph(stages)
                    self.assertEqual("ValidateTaggedSource", names[0])
                    for environment, gate in (("TST", "ValidateTaggedSource"),
                                              ("PRE", "GateToPRE"), ("PRD", "GateToPRD")):
                        prefix = environment + "_"
                        expected = ["ValidateAccessContract", "RunHooks", "DeployResourceGroup", "DeployNetwork"]
                        if peering:
                            expected.append("EstablishPeering")
                        if environment != "TST":
                            expected.append("DeployACR")
                        expected += ["DeployClassic", "DeployInfrastructure", "InfraPermissions", "PrivateLinkDNSRecords"]
                        if platform:
                            expected.append("PrivateLink")
                        expected.append("Complete")
                        self.assertEqual([prefix + suffix for suffix in expected],
                                         [name for name in names if name.startswith(prefix)])
                        previous = gate
                        for name in [prefix + suffix for suffix in expected]:
                            self.assertIn(gate, ancestors[name], name)
                            self.assertIn(previous, ancestors[name], name)
                            self.assertIn("ValidateTaggedSource", ancestors[name], name)
                            previous = name
                    self.assertIn("TST_Complete", graph["GateToPRE"])
                    self.assertIn("PRE_Complete", graph["GateToPRD"])

    def test_approvals_notify_the_requester_and_reject_on_timeout(self):
        pipeline = TEMPLATES.load("release-pipeline.yaml")
        defaults = TEMPLATES.parameters(pipeline, {})
        self.assertEqual(43199, defaults["releaseApprovalTimeoutInMinutes"])
        for stage in release_stages():
            if not stage["stage"].startswith("GateTo"):
                continue
            self.assertIn("succeeded()", stage["condition"])
            job, = stage["jobs"]
            self.assertEqual("server", job["pool"])
            task, = job["steps"]
            self.assertEqual("ManualValidation@0", task["task"])
            self.assertEqual(43200, job["timeoutInMinutes"])
            self.assertGreater(job["timeoutInMinutes"], task["timeoutInMinutes"])
            self.assertEqual(defaults["releaseApprovalTimeoutInMinutes"], task["timeoutInMinutes"])
            self.assertEqual("reject", task["inputs"]["onTimeout"])
            self.assertEqual("$(Build.RequestedForEmail)", task["inputs"]["notifyUsers"])
            self.assertIn("$(Build.SourceBranchName)", task["inputs"]["instructions"])

    def test_artifacts_and_output_imports_are_owned_by_their_environment(self):
        stages = release_stages(establishPeering=True)
        graph, _ = dependency_graph(stages)
        indexed = {stage["stage"]: stage for stage in stages}
        artifacts = []
        for stage in stages:
            name = stage["stage"]
            for item in mappings(stage):
                if item.get("task") == "PublishPipelineArtifact@1":
                    artifact = item["inputs"]["artifactName"]
                    self.assertTrue(artifact.startswith(name[:4]), (name, artifact))
                    artifacts.append(artifact)
            for variable in stage.get("variables", []):
                expression = variable.get("value", "")
                if not isinstance(expression, str) or "stageDependencies." not in expression:
                    continue
                reference = re.fullmatch(r"\$\[ stageDependencies\.(\w+)\.(\w+)\.outputs\['([^']+)'\] \]", expression)
                self.assertIsNotNone(reference, expression)
                producer, job_name, output_name = reference.groups()
                self.assertTrue(producer.startswith(name[:4]), (name, expression))
                self.assertIn(producer, graph[name], (name, expression))
                job, = [job for job in indexed[producer]["jobs"]
                        if job.get("deployment", job.get("job")) == job_name]
                task_name, output_variable = output_name.removeprefix(job_name + ".").split(".")
                task, = [entry for entry in mappings(job) if entry.get("name") == task_name]
                body = task.get("script", task.get("inputs", {}).get("inlineScript", ""))
                self.assertIn(output_variable, body)
        self.assertTrue(artifacts)
        self.assertEqual(len(artifacts), len(set(artifacts)))

    def test_connections_are_resolved_to_the_environment_before_resource_authorization(self):
        for stage in release_stages():
            name = stage["stage"]
            if name[:4] not in ("TST_", "PRE_", "PRD_"):
                continue
            environment = name[:3]
            variables = TEMPLATES.load(f"pipelines/vars/{environment.lower()}.yaml")["variables"]
            for item in mappings(stage):
                if item.get("task") == "AzureCLI@2":
                    connection = item["inputs"]["azureSubscription"]
                    expected = variables["classicServiceConnection" if name.endswith("DeployClassic") else "serviceConnection"]
                    if item.get("name") == "AksKubeletAcrPull":
                        expected = variables["acrGroupsServiceConnection"]
                    self.assertEqual(expected, connection, (name, item.get("name")))
                if "projectServiceConnection" in item:
                    self.assertEqual(variables["serviceConnection"], item["projectServiceConnection"])

    def test_tagged_mutations_require_explicit_opt_in_and_keep_failure_guards(self):
        templates = [f"deploy-bicep-{name}" for name in TEMPLATES.COMPONENTS]
        templates += ["infra-permissions", "private-endpoint-dns-records", "establish-peering"]
        for template in templates:
            path = f"pipelines/stages/{template}.yaml"
            document = TEMPLATES.load(path)
            self.assertIs(False, TEMPLATES.parameters(document, {})["allowTaggedDeployments"])
            for opt_in in (False, True):
                stage, = TEMPLATES.expand_stages(path, {
                    "environmentName": "PRE", "classicEnvironmentName": "PRE",
                    "allowTaggedDeployments": opt_in})
                guards = [entry["condition"] for entry in mappings(stage)
                          if "Build.SourceBranch" in entry.get("condition", "")]
                self.assertTrue(guards, template)
                for guard in guards:
                    for reference in ("refs/heads/main", "refs/heads/feature", "refs/pull/1/merge", "refs/tags/42"):
                        for failed, canceled in ((False, False), (True, False), (False, True)):
                            expected = (reference == "refs/heads/main" or opt_in and reference.startswith("refs/tags/")) and not failed and not canceled
                            self.assertEqual(expected, TEMPLATES.evaluate(guard, {
                                "variables": {"Build.SourceBranch": reference}, "failed": failed, "canceled": canceled}),
                                (template, opt_in, reference, failed, canceled))

    def test_release_composition_enables_every_tagged_mutation_and_hook(self):
        for stage in release_stages(establishPeering=True):
            for entry in mappings(stage):
                guard = entry.get("condition", "")
                if "Build.SourceBranch" in guard:
                    self.assertTrue(TEMPLATES.evaluate(guard, {
                        "variables": {"Build.SourceBranch": "refs/tags/42"}}),
                        (stage["stage"], entry.get("name"), guard))
                if entry.get("name") == "RunHooks":
                    self.assertEqual("false", entry["env"]["DRY_RUN"])

    def test_hooks_retain_dry_run_defaults_and_the_existing_branch_override(self):
        for reference in ("refs/heads/main", "refs/heads/feature", "refs/tags/42"):
            for tagged in (False, True):
                for branch_override in (False, True):
                    stage, = TEMPLATES.expand_stages("pipelines/stages/run-hooks.yaml", {
                        "environmentName": "PRE", "allowTaggedDeployments": tagged,
                        "applyOnBranch": branch_override}, reference)
                    task, = [entry for entry in mappings(stage) if entry.get("name") == "RunHooks"]
                    applies = reference == "refs/heads/main" or branch_override or tagged and reference.startswith("refs/tags/")
                    self.assertEqual(str(not applies).lower(), task["env"]["DRY_RUN"])


if __name__ == "__main__":
    unittest.main()
