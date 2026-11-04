#!/usr/bin/env python3
"""Protect the preview pipeline's source, scheduling and publication boundaries.

Azure authentication is never used here. Source-validation scripts execute with
fake git/Python commands; the existing local YAML expander handles environment
branches without claiming to emulate Azure DevOps scheduling.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = "pipelines/infrastructure-preview.yaml"
STAGE = "pipelines/stages/preview-infrastructure.yaml"
STEP = "pipelines/steps/preview-infrastructure.yaml"
PROTECTED_PATHS = [
    "bicep", "pipelines/vars", "pipelines/infrastructure.yaml",
    "pipelines/stages/deploy-bicep-resource-group.yaml",
    "pipelines/stages/deploy-bicep-network.yaml",
    "pipelines/stages/deploy-bicep-acr.yaml",
    "pipelines/stages/deploy-bicep-classic.yaml",
    "pipelines/stages/deploy-bicep-infra.yaml",
    "pipelines/stages/deploy-bicep-privatelink.yaml",
    "scripts/pipeline/infrastructure_parameters.py",
    "scripts/pipeline/ensure-bicep-version.sh",
]
DEPLOYMENT_TASKS = {
    "DeployResourceGroup": "Deploy - ResourceGroup",
    "DeployNetwork": "Deploy - Network",
    "DeployACR": "Deploy - ACR",
    "DeployClassic": "Deploy - Classic",
    "DeployInfrastructure": "Deploy - Infrastructure",
    "PrivateLink": "Deploy - PrivateLink",
}


def module(name, filename):
    specification = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(result)
    return result


TEMPLATES = module("consolidated_preview_test_helpers", "consolidated-bicep-jobs.test.py")
PARAMETERS = module("preview_parameter_contract", "infrastructure_parameters.py")


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def pipeline_stages(overrides=None):
    document = load(PIPELINE)
    return TEMPLATES.expand(document["stages"], {
        "parameters": TEMPLATES.parameters(document, overrides or {})})


def environment_stage(environment):
    document = load(STAGE)
    entries = pipeline_stages()
    entry, = [entry for entry in entries
              if entry.get("parameters", {}).get("environmentName") == environment]
    context = {"parameters": TEMPLATES.parameters(document, entry["parameters"])}
    stage, = TEMPLATES.expand(document["stages"], context)
    for job in stage["jobs"]:
        steps = []
        for step in job["steps"]:
            if "template" in step:
                template = load(step["template"].lstrip("/"))
                steps.extend(TEMPLATES.expand(template["steps"], {
                    "parameters": TEMPLATES.parameters(template, step["parameters"])}))
            else:
                steps.append(step)
        job["steps"] = steps
    return stage


def nested_keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from nested_keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from nested_keys(item)


class InfrastructurePreviewPipelineTests(unittest.TestCase):
    def test_owned_nsg_compilation_uses_the_verified_compiler_before_azure_operations(self):
        network_stage, = load("pipelines/stages/deploy-bicep-network.yaml")["stages"]
        steps = network_stage["jobs"][0]["strategy"]["runOnce"]["deploy"]["steps"]
        for name in ("WhatIf - Network", "Deploy - Network"):
            task, = [step for step in steps if step.get("displayName") == name]
            self.assertEqual("false", task["env"]["AZURE_BICEP_USE_BINARY_FROM_PATH"])
            script = task["inputs"]["inlineScript"]
            self.assertTrue(script.startswith("set -euo pipefail\n"))
            self.assertLess(script.index("ensure-bicep-version.sh"), script.index("az deployment"))
        for environment in ("DEV", "TST", "PRE", "PRD"):
            for task in environment_stage(environment)["jobs"][0]["steps"]:
                if task.get("task") == "AzureCLI@2":
                    self.assertEqual("false", task["env"]["AZURE_BICEP_USE_BINARY_FROM_PATH"])
                    script = task["inputs"]["inlineScript"]
                    self.assertLess(script.index("ensure-bicep-version.sh"), script.index("plan-infrastructure.py"))

    def test_only_successful_main_dev_completion_is_automatic(self):
        pipeline = load(PIPELINE)
        self.assertEqual("none", pipeline["trigger"])
        self.assertEqual("none", pipeline["pr"])
        resource, = pipeline["resources"]["pipelines"]
        self.assertEqual("infrastructure", resource["pipeline"])
        self.assertEqual("refs/heads/main", resource["branch"])
        self.assertEqual(["Environment-DEV"], resource["tags"])
        self.assertEqual(r"\Infrastructure\infrastructure", resource["source"])
        self.assertEqual({"branches": {"include": ["refs/heads/main"]}, "tags": ["Environment-DEV"]},
                         resource["trigger"])
        self.assertNotIn("stages", resource["trigger"], "Wait for the entire DEV run to succeed")

    def test_environment_plans_are_independent_and_failures_do_not_hide_other_targets(self):
        pipeline = load(PIPELINE)
        actual = [(entry["parameters"]["environmentName"], entry["parameters"]["dependsOn"])
                  for entry in pipeline_stages() if "template" in entry]
        self.assertEqual([("DEV", []), ("TST", []), ("PRE", []), ("PRD", [])], actual)
        for environment in ("DEV", "TST", "PRE", "PRD"):
            with self.subTest(environment=environment):
                stage = environment_stage(environment)
                self.assertEqual("not(canceled())", stage["condition"])
                job, = stage["jobs"]
                self.assertEqual(150, job["timeoutInMinutes"])
                self.assertEqual(5, job["cancelTimeoutInMinutes"])
                scopes = [step for step in job["steps"] if step.get("task") == "AzureCLI@2"]
                self.assertEqual(2, len(scopes))
                self.assertIn("--scope modern", scopes[0]["inputs"]["inlineScript"])
                self.assertIn("--scope classic", scopes[1]["inputs"]["inlineScript"])
                for step in scopes:
                    self.assertEqual("and(not(canceled()), eq(variables['PreviewInputsReady'], 'true'))", step["condition"])
                    self.assertNotIn("continueOnError", step, "Failed plans must fail the environment")

    def test_only_ordinary_jobs_and_readonly_runner_are_used(self):
        documents = [load(PIPELINE), load(STAGE), load(STEP)]
        for document in documents:
            self.assertNotIn("deployment", set(nested_keys(document)))
            self.assertNotIn("environment", set(nested_keys(document)))
        for environment in ("DEV", "TST", "PRE", "PRD"):
            job, = environment_stage(environment)["jobs"]
            self.assertEqual("WhatIf", job["job"])
            self.assertEqual({"checkout": "self", "clean": True, **({"fetchDepth": 0} if environment == "DEV" else {})}, job["steps"][0])
            for step in job["steps"]:
                if step.get("task") != "AzureCLI@2":
                    continue
                script = step["inputs"]["inlineScript"]
                self.assertIn("python3 scripts/pipeline/plan-infrastructure.py", script)
                self.assertNotIn("az ", script)
                self.assertNotIn("set -x", script)
                self.assertNotIn("sync-deployment-outputs", script)
                self.assertNotIn("run-hooks", script)

    def test_source_is_verified_and_pending_reports_initialised_before_authentication(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            with self.subTest(environment=environment):
                job, = environment_stage(environment)["jobs"]
                self.assertEqual(["false"], [variable["value"] for variable in environment_stage(environment)["variables"]
                                              if variable.get("name") == "PreviewInputsReady"])
                steps = job["steps"]
                initialise, = [step for step in steps if "Verify source" in step.get("displayName", "")]
                self.assertEqual(1, steps.index(initialise))
                self.assertTrue(all(steps.index(initialise) < index for index, step in enumerate(steps)
                                    if step.get("task") == "AzureCLI@2"))
                script = initialise["inputs"]["script"]
                self.assertIn('"$(git rev-parse HEAD)" != "$BUILD_SOURCEVERSION"', script)
                self.assertIn('"$SOURCE_PIPELINE_COMMIT" != "$BUILD_SOURCEVERSION"', script)
                self.assertIn('"$SOURCE_PIPELINE_BRANCH" != refs/heads/main', script)
                self.assertIn('"$BUILD_SOURCEBRANCH" != refs/heads/main', script)
                self.assertIn("--initialize", script)
                cleanup = 'rm -rf -- "$PLAN_OUTPUT_DIR" "$PLAN_STATE_DIR"'
                self.assertIn(cleanup, script)
                self.assertLess(script.index(cleanup), script.index('mkdir -p "$PLAN_OUTPUT_DIR"'))
                self.assertLess(script.index(cleanup), script.index("git rev-parse HEAD"))
                self.assertLess(script.index("--initialize"), script.index("task.setvariable variable=PreviewInputsReady"))
                self.assertEqual("$(resources.pipeline.infrastructure.sourceCommit)", initialise["env"]["SOURCE_PIPELINE_COMMIT"])
                self.assertEqual("$(resources.pipeline.infrastructure.sourceBranch)", initialise["env"]["SOURCE_PIPELINE_BRANCH"])

    def source_validation(self, overrides=None, environment_name="TST", with_evidence=False):
        job, = environment_stage(environment_name)["jobs"]
        step = job["steps"][1]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root / "bin"
            commands.mkdir()
            for directory, filename in (("report", "stale.txt"), ("private", "state.json")):
                stale = root / directory
                stale.mkdir()
                (stale / filename).write_text("stale data from an earlier attempt")
            for name, content in {
                "git": ('#!/bin/sh\n'
                        'test ! -e "$PLAN_OUTPUT_DIR/stale.txt" && test ! -e "$PLAN_STATE_DIR/state.json" || exit 99\n'
                        'if [ "$1" = diff ]; then exit "${FIXTURE_DIFF_STATUS:-0}"; fi\n'
                        'printf "%s\\n" "$FIXTURE_HEAD"\n'),
                "python3": ('#!/bin/sh\n'
                            f'if [ "$1" = - ]; then exec {shlex.quote(sys.executable)} "$@"; fi\n'
                            'touch "$FIXTURE_INITIALISED"\nexit "${FIXTURE_INIT_STATUS:-0}"\n'),
            }.items():
                executable = commands / name
                executable.write_text(content)
                executable.chmod(0o755)
            environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                           "BUILD_REASON": "ResourceTrigger", "BUILD_SOURCEVERSION": "a" * 40,
                           "BUILD_SOURCEBRANCH": "refs/heads/main", "BUILD_BUILDID": "123",
                           "FIXTURE_HEAD": "a" * 40, "SOURCE_PIPELINE_COMMIT": "a" * 40,
                           "SOURCE_PIPELINE_BRANCH": "refs/heads/main", "PLAN_OUTPUT_DIR": str(root / "report"),
                           "PLAN_STATE_DIR": str(root / "private"), "FIXTURE_INITIALISED": str(root / "initialised"),
                           "PLAN_ENVIRONMENT": environment_name,
                           **(overrides or {})}
            result = subprocess.run(["bash", "-c", step["inputs"]["script"]], env=environment,
                                    capture_output=True, text=True, timeout=10)
            if with_evidence:
                evidence = root / "report" / "baseline-evidence.json"
                return result, (root / "initialised").exists(), json.loads(evidence.read_text()) if evidence.exists() else None
            return result, (root / "initialised").exists()

    def test_matching_completion_source_unlocks_only_readonly_preview_tasks(self):
        result, initialised = self.source_validation()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(initialised)
        self.assertIn("task.setvariable variable=PreviewInputsReady]true", result.stdout)
        # Manual previews verify their checkout without borrowing an unrelated DEV run.
        result, initialised = self.source_validation({"BUILD_REASON": "Manual", "SOURCE_PIPELINE_COMMIT": ""})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(initialised)

    def test_source_mismatches_never_unlock_authenticated_preview_tasks(self):
        for overrides in ({"FIXTURE_HEAD": "b" * 40}, {"SOURCE_PIPELINE_COMMIT": "b" * 40},
                          {"SOURCE_PIPELINE_BRANCH": "refs/heads/feature"},
                          {"BUILD_SOURCEBRANCH": "refs/heads/feature"},
                          {"SOURCE_PIPELINE_COMMIT": "$(unresolved)"}):
            with self.subTest(overrides=overrides):
                result, initialised = self.source_validation(overrides)
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(initialised)
                self.assertNotIn("task.setvariable variable=PreviewInputsReady", result.stdout)
        result, initialised = self.source_validation({"FIXTURE_INIT_STATUS": "1"})
        self.assertNotEqual(0, result.returncode)
        self.assertTrue(initialised)
        self.assertNotIn("task.setvariable variable=PreviewInputsReady", result.stdout)

    def test_both_scopes_share_environment_source_and_separate_authentication(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            with self.subTest(environment=environment):
                job, = environment_stage(environment)["jobs"]
                modern, classic = [step for step in job["steps"] if step.get("task") == "AzureCLI@2"]
                configured = load(f"pipelines/vars/{environment.lower()}.yaml")["variables"]
                for step, key in ((modern, "serviceConnection"), (classic, "classicServiceConnection")):
                    connection = step["inputs"]["azureSubscription"]
                    self.assertEqual(configured[key], connection)
                    self.assertTrue(connection.startswith("ADO-"))
                    self.assertNotIn("$", connection,
                                     "Azure must authorise a concrete endpoint before any job starts")
                self.assertEqual(modern["env"], classic["env"])
                scripts = [step["inputs"]["inlineScript"] for step in (modern, classic)]
                self.assertEqual(scripts[0].replace("--scope modern", "--scope classic"), scripts[1])
                for script in scripts:
                    for argument in (f"--environment {environment}", '--commit "$BUILD_SOURCEVERSION"',
                                     '--source-ref "$BUILD_SOURCEBRANCH"', '--build-id "$BUILD_BUILDID"',
                                     f'--state-dir "$(Agent.TempDirectory)/infrastructure-preview-{environment}"',
                                     f'--output-dir "$(Build.ArtifactStagingDirectory)/infrastructure-plan-{environment}"'):
                        self.assertIn(argument, script)

    def test_dev_baseline_is_always_run_with_the_deployed_modern_classic_scopes(self):
        pipeline = load(PIPELINE)
        self.assertNotIn("parameters", pipeline, "DEV baseline must not require an option or declared applied SHA")
        entries = pipeline_stages()
        self.assertEqual(["DEV", "TST", "PRE", "PRD"],
                         [entry["parameters"]["environmentName"] for entry in entries if "template" in entry])
        stage = environment_stage("DEV")
        self.assertEqual(["Common", "LowerEnvs", "DEV"], [item["group"] for item in stage["variables"] if "group" in item])
        self.assertEqual([""], [item["value"] for item in stage["variables"] if item.get("name") == "qaAutomationServiceConnectionPrincipalId"])
        job, = stage["jobs"]
        self.assertEqual({"checkout": "self", "clean": True, "fetchDepth": 0}, job["steps"][0])
        modern, classic = [step for step in job["steps"] if step.get("task") == "AzureCLI@2"]
        self.assertEqual("ADO-DefraGovUK-AZR-IMP-DEV1", modern["inputs"]["azureSubscription"])
        self.assertEqual("ADO-DefraGovUK-AZR-IMP-SND1", classic["inputs"]["azureSubscription"])
        step, = [step for step in job["steps"] if "Verify successful DEV apply" in step.get("displayName", "")]
        self.assertEqual("$(resources.pipeline.infrastructure.runID)", step["env"]["SOURCE_PIPELINE_RUN_ID"])
        self.assertEqual("$(resources.pipeline.infrastructure.pipelineID)", step["env"]["SOURCE_PIPELINE_ID"])
        self.assertEqual("$(resources.pipeline.infrastructure.sourceCommit)", step["env"]["SOURCE_PIPELINE_COMMIT"])
        self.assertEqual("$(System.AccessToken)", step["env"]["SYSTEM_ACCESS_TOKEN"])
        self.assertLess(job["steps"].index(step), job["steps"].index(modern))
        self.assertNotIn("set -x", step["inputs"]["script"])

    def baseline_evidence(self, build_overrides=None, environment_overrides=None, git_statuses=(0, 0),
                          lookup_error=None, real_git=False, timeline_mutation=None, timeline_error=None):
        job, = environment_stage("DEV")["jobs"]
        step, = [step for step in job["steps"] if "Verify successful DEV apply" in step.get("displayName", "")]
        script = step["inputs"]["script"].split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        build = {"id": 123, "definition": {"id": 9217}, "status": "completed", "result": "succeeded",
                 "sourceBranch": "refs/heads/main", "sourceVersion": "a" * 40, "tags": ["Environment-DEV"],
                 "finishTime": "2026-11-04T10:00:00Z", **(build_overrides or {})}
        records = []
        for identifier, task_name in DEPLOYMENT_TASKS.items():
            for suffix, record_type, name, parent in (
                    ("stage", "Stage", identifier, None),
                    ("phase", "Phase", "Run Bicep", f"{identifier}-stage"),
                    ("job", "Job", "Run Bicep", f"{identifier}-phase"),
                    ("task", "Task", task_name, f"{identifier}-job")):
                records.append({"id": f"{identifier}-{suffix}", "parentId": parent,
                                "identifier": identifier if record_type == "Stage" else None,
                                "type": record_type, "name": name, "state": "completed", "result": "succeeded"})
        if timeline_mutation:
            timeline_mutation(records)
        def response(request, timeout):
            if "/timeline?" in request.full_url:
                if timeline_error:
                    raise timeline_error
                return io.StringIO(json.dumps({"records": records}))
            if lookup_error:
                raise lookup_error
            return io.StringIO(json.dumps(build))
        with tempfile.TemporaryDirectory() as temporary:
            environment = {**os.environ, "BUILD_SOURCEVERSION": "a" * 40, "BUILD_BUILDID": "456",
                           "SOURCE_PIPELINE_RUN_ID": "123", "SOURCE_PIPELINE_ID": "9217",
                           "SOURCE_PIPELINE_COMMIT": "a" * 40, "SOURCE_PIPELINE_BRANCH": "refs/heads/main",
                           "SYSTEM_ACCESS_TOKEN": "secret-test-token", "PLAN_OUTPUT_DIR": temporary,
                           **(environment_overrides or {})}
            stream = io.StringIO()
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch("urllib.request.urlopen", side_effect=response) as lookup, \
                    contextlib.redirect_stdout(stream):
                if real_git:
                    exec(compile(script, "<DEV baseline evidence>", "exec"), {})
                    commands = []
                else:
                    with mock.patch("subprocess.run", side_effect=[subprocess.CompletedProcess([], code)
                                                                  for code in git_statuses]) as git:
                        exec(compile(script, "<DEV baseline evidence>", "exec"), {})
                    commands = [call.args[0] for call in git.call_args_list]
            evidence = json.loads((Path(temporary) / "baseline-evidence.json").read_text())
            self.assertNotIn("secret-test-token", json.dumps(evidence) + stream.getvalue())
            for call in lookup.call_args_list:
                request = call.args[0]
                self.assertIn(request.full_url, {
                    "https://dev.azure.com/defragovuk/DEFRA-EUTD-IPAFFS/_apis/build/builds/123?api-version=7.1",
                    "https://dev.azure.com/defragovuk/DEFRA-EUTD-IPAFFS/_apis/build/builds/123/timeline?api-version=7.1",
                })
                self.assertEqual("Bearer secret-test-token", request.get_header("Authorization"))
            return evidence, stream.getvalue(), commands

    def test_dev_baseline_requires_a_verified_successful_main_dev_source_run(self):
        evidence, warning, commands = self.baseline_evidence()
        self.assertEqual("usable", evidence["status"])
        self.assertEqual("VERIFIED_SUCCESSFUL_DEV_APPLY", evidence["reasonCode"])
        self.assertEqual("a" * 40, evidence["appliedCommit"])
        self.assertEqual(123, evidence["appliedBuildId"])
        self.assertEqual(9217, evidence["appliedPipelineId"])
        self.assertEqual("refs/heads/main", evidence["appliedBranch"])
        self.assertEqual("a" * 40, evidence["previewCommit"])
        self.assertEqual("456", evidence["previewBuildId"])
        self.assertTrue(evidence["sourceVerified"])
        self.assertTrue(evidence["sourceDeploymentVerified"])
        self.assertEqual(list(DEPLOYMENT_TASKS), evidence["sourceDeploymentStages"])
        self.assertTrue(evidence["deploymentInputsUnchanged"])
        self.assertIn("+00:00", evidence["verifiedAt"])
        self.assertEqual("", warning)
        self.assertEqual([["git", "cat-file", "-e", "a" * 40 + "^{commit}"],
                          ["git", "diff", "--quiet", "a" * 40, "HEAD", "--", *PROTECTED_PATHS]], commands)

    def test_unusable_source_provenance_is_published_without_stopping_any_plans(self):
        cases = [({"result": "failed"}, {}, "SOURCE_RUN_NOT_SUCCESSFUL"),
                 ({"status": "inProgress"}, {}, "SOURCE_RUN_NOT_SUCCESSFUL"),
                 ({"sourceBranch": "refs/heads/feature"}, {}, "SOURCE_RUN_NOT_MAIN"),
                 ({"tags": []}, {}, "SOURCE_RUN_NOT_DEV"),
                 ({"tags": None}, {}, "SOURCE_RUN_NOT_DEV"),
                 ({"definition": {"id": 99}}, {}, "SOURCE_PIPELINE_MISMATCH"),
                 ({"sourceVersion": "b" * 40}, {}, "SOURCE_METADATA_MISMATCH"),
                 ({"id": 999}, {}, "SOURCE_METADATA_MISMATCH"),
                 ({}, {"SOURCE_PIPELINE_RUN_ID": "$(unresolved)"}, "SOURCE_RUN_UNAVAILABLE"),
                 ({}, {"SOURCE_PIPELINE_COMMIT": "main"}, "SOURCE_COMMIT_INVALID"),
                 ({}, {"SOURCE_PIPELINE_ID": "99"}, "SOURCE_PIPELINE_MISMATCH"),
                 ({}, {"SOURCE_PIPELINE_BRANCH": "refs/heads/feature"}, "SOURCE_RUN_NOT_MAIN"),
                 ({}, {"SYSTEM_ACCESS_TOKEN": ""}, "SOURCE_TOKEN_UNAVAILABLE"),
                 ({}, {"BUILD_BUILDID": "$(bad)"}, "PREVIEW_BUILD_ID_INVALID")]
        for build, environment, reason in cases:
            with self.subTest(reason=reason, build=build, environment=environment):
                evidence, warning, commands = self.baseline_evidence(build, environment)
                self.assertEqual("unusable", evidence["status"])
                self.assertEqual(reason, evidence["reasonCode"])
                self.assertFalse(evidence["sourceVerified"])
                self.assertFalse(evidence["deploymentInputsUnchanged"])
                self.assertIsNone(evidence["appliedCommit"])
                self.assertEqual([], commands)
                self.assertIn("All environment plans will still run", warning)
        evidence, _, _ = self.baseline_evidence(lookup_error=RuntimeError("private response"))
        self.assertEqual("SOURCE_LOOKUP_FAILED", evidence["reasonCode"])
        result, initialised = self.source_validation({"BUILD_REASON": "Manual", "SOURCE_PIPELINE_COMMIT": ""}, "DEV")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(initialised, "Unavailable baseline evidence must not gate DEV's read-only plan")

    def test_baseline_requires_every_deployment_to_run_successfully_under_its_stage(self):
        def missing(records):
            records[:] = [record for record in records if not record["id"].startswith("PrivateLink-")]
        def skipped_stage(records):
            next(record for record in records if record["id"] == "PrivateLink-stage")["result"] = "skipped"
        def skipped_task(records):
            next(record for record in records if record["id"] == "DeployNetwork-task")["result"] = "skipped"
        def failed_task(records):
            next(record for record in records if record["id"] == "DeployACR-task")["result"] = "failed"
        def wrong_parent(records):
            next(record for record in records if record["id"] == "DeployClassic-task")["parentId"] = "PrivateLink-job"
        def cyclic_parent(records):
            next(record for record in records if record["id"] == "DeployClassic-job")["parentId"] = "DeployClassic-job"
        def duplicate(records):
            records.append(dict(records[0]))
        for mutate in (missing, skipped_stage, skipped_task, failed_task, wrong_parent, cyclic_parent, duplicate):
            with self.subTest(case=mutate.__name__):
                evidence, warning, commands = self.baseline_evidence(timeline_mutation=mutate)
                self.assertEqual("unusable", evidence["status"])
                self.assertEqual("SOURCE_DEPLOYMENTS_NOT_VERIFIED", evidence["reasonCode"])
                self.assertFalse(evidence["sourceDeploymentVerified"])
                self.assertEqual([], evidence["sourceDeploymentStages"])
                self.assertEqual([], commands)
                self.assertIn("All environment plans will still run", warning)
        evidence, _, _ = self.baseline_evidence(timeline_error=RuntimeError("private timeline error"))
        self.assertEqual("SOURCE_TIMELINE_LOOKUP_FAILED", evidence["reasonCode"])

    def test_source_proof_is_tied_to_the_current_deployment_stage_task_names(self):
        entrypoint = load("pipelines/infrastructure.yaml")
        entries = TEMPLATES.expand(entrypoint["stages"], {
            "parameters": TEMPLATES.parameters(entrypoint, {"environmentName": "DEV", "includePlatform": True}),
            "variables": {"Build.SourceBranch": "refs/heads/main"},
        })
        stage_files = [path for path in PROTECTED_PATHS if path.startswith("pipelines/stages/deploy-bicep-")]
        self.assertEqual(stage_files,
                         ["pipelines/" + entry["template"] for entry in entries
                          if entry.get("template", "").startswith("stages/deploy-bicep-")])
        self.assertEqual(set(PARAMETERS.COMPONENTS),
                         {Path(path).stem.removeprefix("deploy-bicep-") for path in stage_files})
        for stage_file in stage_files:
            stage, = TEMPLATES.expand_stages(stage_file, {
                "environmentName": "DEV", "classicEnvironmentName": "SND"})
            self.assertIn(stage["stage"], DEPLOYMENT_TASKS)
            deployment, = stage["jobs"]
            steps = deployment["strategy"]["runOnce"]["deploy"]["steps"]
            task, = [step for step in steps if step.get("displayName") == DEPLOYMENT_TASKS[stage["stage"]]]
            self.assertEqual("AzureCLI@2", task["task"])
            self.assertIn("az deployment ", task["inputs"]["inlineScript"])
            self.assertIn(" create ", task["inputs"]["inlineScript"])

    def test_unavailable_or_changed_applied_tree_disables_only_the_comparison(self):
        for statuses, reason in (((128,), "APPLIED_COMMIT_UNAVAILABLE"),
                                 ((0, 1), "DEPLOYMENT_INPUTS_CHANGED"),
                                 ((0, 128), "DEPLOYMENT_INPUT_COMPARISON_FAILED")):
            with self.subTest(statuses=statuses):
                evidence, warning, _ = self.baseline_evidence(git_statuses=statuses)
                self.assertEqual("unusable", evidence["status"])
                self.assertEqual(reason, evidence["reasonCode"])
                self.assertTrue(evidence["sourceVerified"])
                self.assertFalse(evidence["deploymentInputsUnchanged"])
                self.assertIn("All environment plans will still run", warning)

    def test_dev_baseline_compares_the_applied_git_tree_including_every_parameter_source(self):
        paths = ["bicep/main.bicep", "pipelines/vars/dev.yaml", *PROTECTED_PATHS[2:], "scripts/pipeline/report.py"]
        for changed in paths:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                def git(*arguments):
                    return subprocess.check_output(["git", "-c", "user.name=Fixture", "-c",
                                                    "user.email=fixture@example.invalid", *arguments],
                                                   cwd=root, text=True).strip()
                git("init", "-q")
                for path in paths:
                    target = root / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("applied content\n")
                git("add", *paths)
                git("commit", "-qm", "Applied inputs")
                applied = git("rev-parse", "HEAD")
                (root / changed).write_text("changed content\n")
                git("add", changed)
                git("commit", "-qm", "Preview changes")
                head = git("rev-parse", "HEAD")
                previous = Path.cwd()
                try:
                    os.chdir(root)
                    evidence, _, _ = self.baseline_evidence(
                        {"sourceVersion": applied},
                        {"SOURCE_PIPELINE_COMMIT": applied, "BUILD_SOURCEVERSION": head}, real_git=True)
                finally:
                    os.chdir(previous)
                allowed = changed == "scripts/pipeline/report.py"
                self.assertEqual("usable" if allowed else "unusable", evidence["status"])
                self.assertEqual(allowed, evidence["deploymentInputsUnchanged"])
                self.assertEqual(applied, evidence["appliedCommit"])
                self.assertEqual(head, evidence["previewCommit"])

    def test_shared_parameter_allowlist_and_environment_scopes_are_explicit(self):
        task, = load(STEP)["steps"]
        mapping = task["env"]
        self.assertEqual(set(PARAMETERS.ENVIRONMENT_VARIABLES.values()), {key for key in mapping if key.startswith("BICEP_")})
        for name, variable in PARAMETERS.ENVIRONMENT_VARIABLES.items():
            expected = {"parameterSqlAdminGroupId": "sqlAdminGroupId",
                        "parameterSqlAdminGroupName": "sqlAdminGroupName"}.get(name, name)
            self.assertEqual(f"$({expected})", mapping[variable])
        for key, value in {"PLATFORM_SUBSCRIPTION_ID": "subscriptionId",
                           "PLATFORM_CLASSIC_SUBSCRIPTION_ID": "classicSubscriptionId",
                           "PLATFORM_RESOURCE_GROUP": "resourceGroupName",
                           "PLATFORM_CLASSIC_RESOURCE_GROUP": "classicResourceGroupName",
                           "PLATFORM_LOCATION": "location"}.items():
            self.assertEqual(f"$({value})", mapping[key])
        for environment in ("DEV", "TST", "PRE", "PRD"):
            variables = environment_stage(environment)["variables"]
            self.assertEqual(["Common", "LowerEnvs" if environment in ("DEV", "TST") else "HigherEnvs", environment],
                             [item["group"] for item in variables if "group" in item])
            qa = [item["value"] for item in variables if item.get("name") == "qaAutomationServiceConnectionPrincipalId"]
            self.assertEqual([] if environment == "TST" else [""], qa)

    def test_only_sanitised_reports_are_published_and_private_state_is_cleaned(self):
        for environment in ("DEV", "TST", "PRE", "PRD"):
            job, = environment_stage(environment)["jobs"]
            publish, = [step for step in job["steps"] if step.get("task") == "PublishPipelineArtifact@1"]
            self.assertEqual("always()", publish["condition"])
            self.assertEqual({"artifactName": f"infrastructure-plan-{environment}",
                              "targetPath": f"$(Build.ArtifactStagingDirectory)/infrastructure-plan-{environment}"}, publish["inputs"])
            cleanup = job["steps"][-1]
            self.assertEqual("always()", cleanup["condition"])
            self.assertEqual(f"$(Agent.TempDirectory)/infrastructure-preview-{environment}", cleanup["env"]["PLAN_STATE_DIR"])
            self.assertIn('rm -rf -- "$PLAN_STATE_DIR"', cleanup["inputs"]["script"])
            self.assertGreater(job["steps"].index(cleanup), job["steps"].index(publish))
            self.assertNotIn("Agent.TempDirectory", publish["inputs"]["targetPath"])
            self.assertFalse(any("task.uploadsummary" in step.get("inputs", {}).get("script", "")
                                 for step in job["steps"]), "Only the classified combined report should be attached to Azure")

    def test_overview_survives_failed_stages_and_has_no_stale_downloads(self):
        stage = pipeline_stages()[-1]
        self.assertEqual(["Preview_DEV", "Preview_TST", "Preview_PRE", "Preview_PRD"], stage["dependsOn"])
        self.assertEqual("always()", stage["condition"])
        job, = stage["jobs"]
        self.assertEqual("always()", job["condition"])
        self.assertEqual({"clean": "all"}, job["workspace"])
        download, = [step for step in job["steps"] if step.get("task") == "DownloadPipelineArtifact@2"]
        self.assertTrue(download["continueOnError"])
        # This separate run contains only the four sanitised environment reports.
        self.assertEqual("**", download["inputs"]["itemPattern"])
        combine, = [step for step in job["steps"] if "--combine" in step.get("inputs", {}).get("script", "")]
        self.assertEqual("always()", combine["condition"])
        self.assertIn('--combine "$(Pipeline.Workspace)/plans"', combine["inputs"]["script"])
        self.assertIn("--azure-pipelines", combine["inputs"]["script"])
        self.assertNotIn("continueOnError", combine, "Missing or failed reports must still fail")
        attach, = [step for step in job["steps"] if "task.uploadsummary" in step.get("inputs", {}).get("script", "")]
        self.assertEqual("always()", attach["condition"])
        publish, = [step for step in job["steps"] if step.get("task") == "PublishPipelineArtifact@1"]
        self.assertEqual("always()", publish["condition"])
        self.assertEqual("infrastructure-preview", publish["inputs"]["artifactName"])


def load_tests(loader, standard_tests, pattern):
    # This existing CI entry point exercises the compiled ownership boundaries.
    # Install a local compiler only; no Azure login or subscription is involved.
    if not os.environ.get("BICEP_BIN"):
        subprocess.run(["az", "bicep", "install", "--version", "v0.43.8", "--only-show-errors"],
                       check=True, stdout=subprocess.DEVNULL, timeout=180)
        config = Path(os.environ.get("AZURE_CONFIG_DIR", str(Path.home() / ".azure")))
        os.environ["BICEP_BIN"] = str(config / "bin/bicep")
    for stem in PARAMETERS.COMPONENTS.values():
        subprocess.run([os.environ["BICEP_BIN"], "restore", str(ROOT / "bicep" / (stem + ".bicep"))],
                       check=True, timeout=180)
    for name, filename in (("compiler_preparation_contract", "ensure-bicep-version.test.py"),
                           ("network_rule_ownership_contract", "network-security-groups.test.py"),
                           ("sql_maintenance_ownership_contract", "sql-maintenance-ownership.test.py"),
                           ("parameter_overlay_contract", "infrastructure-parameters.test.py")):
        standard_tests.addTests(loader.loadTestsFromModule(module(name, filename)))
    return standard_tests


if __name__ == "__main__":
    unittest.main()
