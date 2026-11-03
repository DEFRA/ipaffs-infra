#!/usr/bin/env python3
"""Protect the preview pipeline's source, scheduling and publication boundaries.

Azure authentication is never used here. Source-validation scripts execute with
fake git/Python commands; the existing local YAML expander handles environment
branches without claiming to emulate Azure DevOps scheduling.
"""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = "pipelines/infrastructure-preview.yaml"
STAGE = "pipelines/stages/preview-infrastructure.yaml"
STEP = "pipelines/steps/preview-infrastructure.yaml"


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
    entries = pipeline_stages({"devBaselineOnly": environment == "DEV", "devAppliedCommit": "a" * 40})
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
    def test_only_successful_main_dev_completion_is_automatic(self):
        pipeline = load(PIPELINE)
        self.assertEqual("none", pipeline["trigger"])
        self.assertEqual("none", pipeline["pr"])
        resource, = pipeline["resources"]["pipelines"]
        self.assertEqual("infrastructure", resource["pipeline"])
        self.assertEqual(r"\Infrastructure\infrastructure", resource["source"])
        self.assertEqual({"branches": {"include": ["refs/heads/main"]}, "tags": ["Environment-DEV"]},
                         resource["trigger"])
        self.assertNotIn("stages", resource["trigger"], "Wait for the entire DEV run to succeed")

    def test_environment_plans_are_serial_and_failures_do_not_hide_later_targets(self):
        pipeline = load(PIPELINE)
        actual = [(entry["parameters"]["environmentName"], entry["parameters"]["dependsOn"])
                  for entry in pipeline_stages() if "template" in entry]
        self.assertEqual([("TST", []), ("PRE", ["Preview_TST"]), ("PRD", ["Preview_PRE"])], actual)
        for environment in ("TST", "PRE", "PRD"):
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
        for environment in ("TST", "PRE", "PRD"):
            job, = environment_stage(environment)["jobs"]
            self.assertEqual("WhatIf", job["job"])
            self.assertEqual({"checkout": "self", "clean": True}, job["steps"][0])
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
        for environment in ("TST", "PRE", "PRD"):
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
                           "DEV_APPLIED_COMMIT": "a" * 40 if environment_name == "DEV" else "",
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
        for environment in ("TST", "PRE", "PRD"):
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

    def test_dev_baseline_is_explicit_and_uses_the_deployed_modern_classic_scopes(self):
        pipeline = load(PIPELINE)
        defaults = TEMPLATES.parameters(pipeline, {})
        self.assertFalse(defaults["devBaselineOnly"])
        self.assertEqual("", defaults["devAppliedCommit"])
        entries = pipeline_stages({"devBaselineOnly": True, "devAppliedCommit": "b" * 40})
        self.assertEqual(1, len(entries), "DEV-only mode must not queue release environments or their fixed comparison")
        self.assertEqual("DEV", entries[0]["parameters"]["environmentName"])
        self.assertEqual("b" * 40, entries[0]["parameters"]["appliedCommit"])
        stage = environment_stage("DEV")
        self.assertEqual(["Common", "LowerEnvs", "DEV"], [item["group"] for item in stage["variables"] if "group" in item])
        self.assertEqual([""], [item["value"] for item in stage["variables"] if item.get("name") == "qaAutomationServiceConnectionPrincipalId"])
        job, = stage["jobs"]
        self.assertEqual({"checkout": "self", "clean": True, "fetchDepth": 0}, job["steps"][0])
        modern, classic = [step for step in job["steps"] if step.get("task") == "AzureCLI@2"]
        self.assertEqual("ADO-DefraGovUK-AZR-IMP-DEV1", modern["inputs"]["azureSubscription"])
        self.assertEqual("ADO-DefraGovUK-AZR-IMP-SND1", classic["inputs"]["azureSubscription"])
        self.assertEqual("a" * 40, job["steps"][1]["env"]["DEV_APPLIED_COMMIT"])

    def test_dev_baseline_rejects_missing_or_changed_applied_inputs_before_authentication(self):
        for overrides in ({"DEV_APPLIED_COMMIT": ""}, {"DEV_APPLIED_COMMIT": "main"},
                          {"DEV_APPLIED_COMMIT": "a" * 39}, {"DEV_APPLIED_COMMIT": "$(bad)"},
                          {"FIXTURE_DIFF_STATUS": "1"}, {"FIXTURE_DIFF_STATUS": "128"}):
            with self.subTest(overrides=overrides):
                result, initialised, evidence = self.source_validation(
                    {"BUILD_REASON": "Manual", **overrides}, "DEV", with_evidence=True)
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(initialised)
                self.assertIsNone(evidence)
                self.assertNotIn("task.setvariable variable=PreviewInputsReady", result.stdout)
        result, initialised, evidence = self.source_validation({"BUILD_REASON": "Manual"}, "DEV", with_evidence=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(initialised)
        self.assertEqual({"appliedCommit": "a" * 40, "previewCommit": "a" * 40,
                          "deploymentInputsUnchanged": True,
                          "comparedPaths": ["bicep", "pipelines/vars", "scripts/pipeline/infrastructure_parameters.py"]}, evidence)

    def test_dev_baseline_compares_the_applied_git_tree_including_every_parameter_source(self):
        job, = environment_stage("DEV")["jobs"]
        script = job["steps"][1]["inputs"]["script"]
        paths = ["bicep/main.bicep", "pipelines/vars/dev.yaml",
                 "scripts/pipeline/infrastructure_parameters.py", "scripts/pipeline/report.py"]
        for changed in paths:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                commands = root / "bin"
                commands.mkdir()
                python = commands / "python3"
                python.write_text('#!/bin/sh\n'
                                  f'if [ "$1" = - ]; then exec {shlex.quote(sys.executable)} "$@"; fi\n'
                                  'touch "$FIXTURE_INITIALISED"\n')
                python.chmod(0o755)
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
                environment = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                               "BUILD_REASON": "Manual", "BUILD_SOURCEVERSION": head,
                               "BUILD_SOURCEBRANCH": "refs/heads/preview", "BUILD_BUILDID": "123",
                               "PLAN_ENVIRONMENT": "DEV", "DEV_APPLIED_COMMIT": applied,
                               "PLAN_OUTPUT_DIR": str(root / "report"), "PLAN_STATE_DIR": str(root / "private"),
                               "FIXTURE_INITIALISED": str(root / "initialised")}
                result = subprocess.run(["bash", "-c", script], cwd=root, env=environment,
                                        capture_output=True, text=True, timeout=10)
                allowed = changed == "scripts/pipeline/report.py"
                self.assertEqual(0 if allowed else 1, result.returncode, result.stderr)
                self.assertEqual(allowed, (root / "initialised").exists())
                self.assertEqual(allowed, (root / "report" / "baseline-evidence.json").exists())

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
        for environment in ("TST", "PRE", "PRD"):
            variables = environment_stage(environment)["variables"]
            self.assertEqual(["Common", "LowerEnvs" if environment == "TST" else "HigherEnvs", environment],
                             [item["group"] for item in variables if "group" in item])
            qa = [item["value"] for item in variables if item.get("name") == "qaAutomationServiceConnectionPrincipalId"]
            self.assertEqual([] if environment == "TST" else [""], qa)

    def test_only_sanitised_reports_are_published_and_private_state_is_cleaned(self):
        for environment in ("TST", "PRE", "PRD"):
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

    def test_overview_survives_failed_stages_and_has_no_stale_downloads(self):
        stage = pipeline_stages()[-1]
        self.assertEqual(["Preview_TST", "Preview_PRE", "Preview_PRD"], stage["dependsOn"])
        self.assertEqual("always()", stage["condition"])
        job, = stage["jobs"]
        self.assertEqual("always()", job["condition"])
        self.assertEqual({"clean": "all"}, job["workspace"])
        download, = [step for step in job["steps"] if step.get("task") == "DownloadPipelineArtifact@2"]
        self.assertTrue(download["continueOnError"])
        # This separate run contains only the three sanitised environment reports.
        self.assertEqual("**", download["inputs"]["itemPattern"])
        combine, = [step for step in job["steps"] if "--combine" in step.get("inputs", {}).get("script", "")]
        self.assertEqual("always()", combine["condition"])
        self.assertIn('--combine "$(Pipeline.Workspace)/plans"', combine["inputs"]["script"])
        self.assertIn("--azure-pipelines", combine["inputs"]["script"])
        self.assertNotIn("continueOnError", combine, "Missing or failed reports must still fail")
        publish, = [step for step in job["steps"] if step.get("task") == "PublishPipelineArtifact@1"]
        self.assertEqual("always()", publish["condition"])
        self.assertEqual("infrastructure-preview", publish["inputs"]["artifactName"])


if __name__ == "__main__":
    unittest.main()
