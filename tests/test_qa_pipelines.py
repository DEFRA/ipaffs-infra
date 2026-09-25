"""Exercise QA provenance and the actual pipeline shell without Azure or Docker."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


def pipeline(relative_path):
    return yaml.safe_load((ROOT / relative_path).read_text())


def execution_steps():
    template = pipeline("pipelines/templates/qa-automation.yaml")
    return template["stages"][0]["jobs"][0]["steps"]


class RunContextTests(unittest.TestCase):
    def write_context(self, overrides=None):
        environment = {
            "QA_ENVIRONMENT": "TST",
            "QA_RUN_ID": "301",
            "QA_PIPELINE_ID": "41",
            "QA_BUILD_REASON": "ResourceTrigger",
            "QA_TRIGGER_ALIAS": "deployment",
            "QA_DEPLOYMENT_RUN_ID": "201",
            "QA_DEPLOYMENT_PIPELINE_ID": "31",
            "QA_DEPLOYMENT_SOURCE_REF": "refs/tags/1.2.3",
            "QA_DEPLOYMENT_SOURCE_COMMIT": "a" * 40,
            "QA_TEST_SUITE": "test",
            "QA_TEST_FILTER": " ",
            "QA_IMAGE_TAG": "latest",
            # These are synthetic sentinels, never credentials from the host.
            "SYSTEM_ACCESSTOKEN": "must-not-appear-token",
            "SLACK_QA_CHANNEL_WEBHOOK_URL": "must-not-appear-webhook",
            "QA_UNRECOGNISED_SECRET": "must-not-appear-extra-variable",
        }
        environment.update(overrides or {})
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "nested" / "run.json"
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/pipeline/write-qa-run-context.py"),
                 str(destination)],
                env=environment, text=True, capture_output=True, check=False,
            )
            data = json.loads(destination.read_text()) if destination.exists() else None
        return result, data

    def test_resource_trigger_retains_exact_upstream_identity(self):
        result, data = self.write_context()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["environment"], "TST")
        self.assertEqual(data["qaRunId"], 301)
        self.assertEqual(data["qaPipelineId"], 41)
        self.assertEqual(data["triggerKind"], "deployment")
        self.assertEqual(data["triggeringDeployment"], {
            "runId": 201,
            "pipelineId": 31,
            "sourceRef": "refs/tags/1.2.3",
            "sourceCommit": "a" * 40,
        })
        self.assertFalse(data["deployedVersionVerified"])

    def test_selected_resource_does_not_claim_manual_or_scheduled_causation(self):
        for reason, expected in (("Manual", "manual"), ("Schedule", "scheduled")):
            with self.subTest(reason=reason):
                result, data = self.write_context({"QA_BUILD_REASON": reason})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(data["triggerKind"], expected)
                self.assertIsNone(data["triggeringDeployment"])
                self.assertFalse(data["deployedVersionVerified"])

    def test_other_resource_does_not_claim_deployment_causation(self):
        result, data = self.write_context({"QA_TRIGGER_ALIAS": "qa-image"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["triggerKind"], "other")
        self.assertIsNone(data["triggeringDeployment"])

    def test_incomplete_deployment_identity_fails_without_publishing_context(self):
        missing_values = {
            "QA_DEPLOYMENT_RUN_ID": ("", "0", "-1", "invalid", "$(undefined)"),
            "QA_DEPLOYMENT_PIPELINE_ID": ("", "0", "invalid"),
            "QA_DEPLOYMENT_SOURCE_REF": ("", "$(undefined)"),
            "QA_DEPLOYMENT_SOURCE_COMMIT": ("", "$(undefined)"),
        }
        for key, values in missing_values.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    result, data = self.write_context({key: value})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("missing upstream run metadata", result.stderr)
                    self.assertIsNone(data)

    def test_legacy_manual_run_accepts_unexpanded_optional_resource_macros(self):
        result, data = self.write_context({
            "QA_BUILD_REASON": "Manual",
            "QA_TRIGGER_ALIAS": "$(Resources.TriggeringAlias)",
            "QA_DEPLOYMENT_RUN_ID": "$(resources.pipeline.deployment.runID)",
            "QA_DEPLOYMENT_PIPELINE_ID": "$(resources.pipeline.deployment.pipelineID)",
            "QA_DEPLOYMENT_SOURCE_REF": "$(resources.pipeline.deployment.sourceBranch)",
            "QA_DEPLOYMENT_SOURCE_COMMIT": "$(resources.pipeline.deployment.sourceCommit)",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(data["triggeringDeployment"])
        self.assertNotIn("$(", json.dumps(data))

    def test_filter_records_effective_suite_override(self):
        result, data = self.write_context({
            "QA_TEST_SUITE": "test:a11y", "QA_TEST_FILTER": " @smoke ",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["requestedSuite"], "test:a11y")
        self.assertEqual(data["effectiveSuite"], "test")
        self.assertEqual(data["testFilter"], " @smoke ")

    def test_blank_filter_preserves_requested_suite(self):
        result, data = self.write_context({"QA_TEST_SUITE": "test:a11y"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["effectiveSuite"], "test:a11y")
        self.assertIsNone(data["testFilter"])

    def test_only_allowlisted_metadata_is_written_or_printed(self):
        result, data = self.write_context()
        self.assertEqual(result.returncode, 0, result.stderr)
        emitted = json.dumps(data) + result.stdout + result.stderr
        self.assertNotIn("must-not-appear", emitted)
        self.assertNotIn("SYSTEM_ACCESSTOKEN", emitted)
        self.assertEqual(data["requestedImageTag"], "latest")
        self.assertNotIn("imageDigest", data)


class AutomationExecutionTests(unittest.TestCase):
    """Run the checked-in inlineScript, replacing only Azure pipeline macros."""

    def execute(self, overrides=None):
        step = next(step for step in execution_steps()
                    if step.get("displayName") == "Run Automation Container")
        script = step["inputs"]["inlineScript"]
        macros = {
            "acrLoginServer": "testregistry.azurecr.io",
            "qaAutomationAcrName": "testregistry",
            "qaAutomationSubscriptionName": "test-subscription",
        }
        for name, value in macros.items():
            script = script.replace("$(" + name + ")", value)
        self.assertIsNone(re.search(r"\$\([A-Za-z][A-Za-z0-9.]*\)", script))

        with tempfile.TemporaryDirectory() as directory:
            working_directory = Path(directory)
            bin_directory = working_directory / "bin"
            bin_directory.mkdir()
            invocation_log = working_directory / "commands.jsonl"
            stub = f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
arguments = sys.argv[1:]
with open(os.environ["QA_STUB_LOG"], "a") as stream:
    stream.write(json.dumps({"tool": tool, "arguments": arguments}) + "\\n")
if tool == "az" and arguments[:2] == ["acr", "login"]:
    sys.exit(int(os.environ["QA_STUB_LOGIN_EXIT"]))
if tool == "docker" and arguments[0] == "pull":
    sys.exit(int(os.environ["QA_STUB_PULL_EXIT"]))
if tool == "docker" and arguments[0] == "run":
    sys.exit(int(os.environ["QA_STUB_TEST_EXIT"]))
sys.exit("Unexpected stub invocation")
'''
            for tool in ("az", "docker"):
                executable = bin_directory / tool
                executable.write_text(stub)
                executable.chmod(0o755)
            environment = {
                "PATH": str(bin_directory) + os.pathsep + os.defpath,
                "WORKERS": "8", "IMAGE_TAG": "qa-fixture", "PLAYWRIGHT_TAG": " ",
                "TEST_SUITE": "test", "QA_AUTOMATION_ENV": "tst",
                "QA_STUB_LOG": str(invocation_log), "QA_STUB_LOGIN_EXIT": "0",
                "QA_STUB_PULL_EXIT": "0", "QA_STUB_TEST_EXIT": "0",
            }
            environment.update(overrides or {})
            result = subprocess.run(
                ["/bin/bash", "-c", script], cwd=working_directory,
                env=environment, text=True, capture_output=True, check=False,
            )
            commands = [json.loads(line) for line in invocation_log.read_text().splitlines()]
        return result, commands

    def test_success_runs_the_container_after_login_and_pull(self):
        result, commands = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(command["tool"], command["arguments"][0])
                          for command in commands],
                         [("az", "acr"), ("docker", "pull"), ("docker", "run")])
        arguments = commands[-1]["arguments"]
        self.assertIn("ENV=tst", arguments)
        self.assertIn("testregistry.azurecr.io/ipaffs/qa-automation:qa-fixture", arguments)
        self.assertEqual(arguments[arguments.index("npm"):],
                         ["npm", "test", "--", "--workers=8"])

    def test_failing_tests_fail_the_task(self):
        result, commands = self.execute({"QA_STUB_TEST_EXIT": "17"})
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(commands[-1]["arguments"][0], "run")

    def test_login_failure_stops_before_pull_or_tests(self):
        result, commands = self.execute({"QA_STUB_LOGIN_EXIT": "19"})
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertEqual([command["tool"] for command in commands], ["az"])

    def test_pull_failure_never_runs_a_cached_image(self):
        result, commands = self.execute({"QA_STUB_PULL_EXIT": "23"})
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(commands), 2)
        self.assertEqual(commands[-1]["arguments"][0], "pull")

    def test_supported_suites_use_their_execution_commands(self):
        suites = {
            "test:a11y": "test:a11y", "test:visual": "test:visual",
            "test:visual:update": "test:visual:update", "test:cross-browser": "test:browserstack",
        }
        for suite, command in suites.items():
            with self.subTest(suite=suite):
                result, commands = self.execute({"TEST_SUITE": suite})
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = commands[-1]["arguments"]
                self.assertEqual(arguments[arguments.index("npm"):],
                                 ["npm", "run", command, "--", "--workers=8"])

    def test_filter_overrides_suite_without_splitting_the_filter(self):
        result, commands = self.execute({
            "TEST_SUITE": "test:a11y", "PLAYWRIGHT_TAG": "@smoke|a named test",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = commands[-1]["arguments"]
        self.assertEqual(arguments[arguments.index("npm"):],
                         ["npm", "test", "--", "--grep", "@smoke|a named test", "--workers=8"])

    def test_unknown_suite_fails_without_running_tests(self):
        result, commands = self.execute({"TEST_SUITE": "invalid"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown test suite", result.stderr)
        self.assertFalse(any(command["arguments"][0] == "run" for command in commands))


class PipelineContractTests(unittest.TestCase):
    def test_fixed_environments_have_shared_execution_and_independent_triggers(self):
        for environment in ("DEV", "TST"):
            with self.subTest(environment=environment):
                entry = pipeline(f"pipelines/qa-automation-{environment.lower()}.yaml")
                self.assertNotIn("environmentName", {item["name"] for item in entry["parameters"]})
                self.assertEqual(entry["extends"]["template"], "templates/qa-automation.yaml")
                self.assertEqual(entry["extends"]["parameters"]["environmentName"], environment)
                self.assertEqual(entry["trigger"], "none")
                self.assertEqual(entry["pr"], "none")
                schedule, = entry["schedules"]
                self.assertEqual(schedule["cron"], "0 6 * * 1-5")
                self.assertEqual(schedule["branches"]["include"], ["main"])
                self.assertTrue(schedule["always"])
                resource, = entry["resources"]["pipelines"]
                self.assertEqual(resource["pipeline"], "deployment")
                self.assertEqual(resource["trigger"]["stages"], [f"QA_{environment}_Ready"])

    def test_legacy_execution_survives_but_the_nightly_wrapper_cannot_queue_tests(self):
        legacy = pipeline("pipelines/qa-automation.yaml")
        self.assertIn("environmentName", {item["name"] for item in legacy["parameters"]})
        self.assertEqual(legacy["extends"]["template"], "templates/qa-automation.yaml")
        nightly = pipeline("pipelines/qa-automation-nightly.yaml")
        self.assertNotIn("schedules", nightly)
        self.assertNotIn("resources", nightly)
        self.assertNotIn("az pipelines run", json.dumps(nightly))

    def test_failed_tests_cannot_be_successful_and_evidence_still_publishes(self):
        steps = execution_steps()
        execution = next(step for step in steps
                         if step.get("displayName") == "Run Automation Container")
        self.assertFalse(execution.get("continueOnError", False))
        publishers = [step for step in steps if step.get("task") in
                      ("PublishPipelineArtifact@1", "PublishTestResults@2")]
        self.assertTrue(publishers)
        for publisher in publishers:
            with self.subTest(publisher=publisher["displayName"]):
                self.assertEqual(publisher["condition"], "succeededOrFailed()")
        results = next(step for step in publishers if step["task"] == "PublishTestResults@2")
        for setting in ("failTaskOnFailedTests", "failTaskOnMissingResultsFile",
                        "failTaskOnFailureToPublishResults"):
            self.assertIs(results["inputs"][setting], True)


if __name__ == "__main__":
    unittest.main()
