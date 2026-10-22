"""Exercise pin migration and pipeline write gating without remote Git access."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/pipeline/update-manifest-infra-ref.sh"
PIPELINE = ROOT / "pipelines/update-manifest-infra-ref.yaml"
NEW_REF = "refs/tags/ipaffs-infra-pin-new"
GUARD = "and(succeeded(), eq(variables['CheckManifestInfraPin.requiresInfraPin'], 'true'))"
LEGACY = """resources:
  repositories:
    - repository: ipaffs-infra
      type: github
      name: DEFRA/ipaffs-infra
      ref: refs/tags/ipaffs-infra-pin-old
    - repository: another
      ref: refs/heads/main
stages: []
"""
LOCAL = """variables:
  - template: /pipelines/vars/common.yaml
stages: []
"""


class ManifestInfraPinTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.manifest = self.directory / "manifest"
        self.manifest.mkdir()
        self.bash = os.environ.get("BASH_BINARY") or shutil.which("bash")
        self.files = [self.manifest / name for name in ("pipeline.yaml", "release-pipeline.yaml")]
        self.write(LEGACY, LEGACY)

    def write(self, dev, release):
        for path, content in zip(self.files, (dev, release)):
            path.write_text(content)

    def run_script(self, *arguments, infra_ref=NEW_REF):
        environment = {**os.environ, "MANIFEST_ROOT": str(self.manifest)}
        environment.pop("INFRA_REF", None)
        if infra_ref is not None:
            environment["INFRA_REF"] = infra_ref
        return subprocess.run([self.bash, str(SCRIPT), *arguments], env=environment,
                              text=True, capture_output=True, timeout=10)

    def test_older_manifest_updates_both_refs_and_preserves_other_resources(self):
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stderr)
        for path in self.files:
            self.assertEqual(LEGACY.replace("refs/tags/ipaffs-infra-pin-old", NEW_REF), path.read_text())

    def test_check_mode_reports_dependency_without_writing_or_needing_a_new_ref(self):
        result = self.run_script("--check", infra_ref=None)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("variable=requiresInfraPin;isOutput=true]true", result.stdout)
        self.assertEqual([LEGACY, LEGACY], [path.read_text() for path in self.files])

    def test_retired_manifest_is_a_successful_no_op_in_both_modes(self):
        self.write(LOCAL, LOCAL)
        for arguments in ((), ("--check",)):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments, infra_ref=None)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("variable=requiresInfraPin;isOutput=true]false", result.stdout)
                self.assertEqual([LOCAL, LOCAL], [path.read_text() for path in self.files])

    def test_mixed_dependency_fails_before_either_entrypoint_is_changed(self):
        for dev, release in ((LEGACY, LOCAL), (LOCAL, LEGACY)):
            self.write(dev, release)
            result = self.run_script()
            self.assertNotEqual(0, result.returncode)
            self.assertIn("refusing a partial pin update", result.stderr)
            self.assertEqual([dev, release], [path.read_text() for path in self.files])

    def test_missing_or_malformed_second_entrypoint_cannot_partially_update_the_first(self):
        variants = [
            None,
            LEGACY.replace("      ref: refs/tags/ipaffs-infra-pin-old\n", ""),
            LEGACY.replace("      ref: refs/tags/ipaffs-infra-pin-old", "      ref:"),
            LEGACY.replace("      ref: refs/tags/ipaffs-infra-pin-old", "      ref: [bad]"),
            LEGACY.replace("      ref: refs/tags/ipaffs-infra-pin-old", "      ref: refs/tags/old\n      ref: refs/tags/duplicate"),
            LEGACY + LEGACY,
            'resources: {repositories: [{repository: ipaffs-infra, ref: refs/tags/old}]}\n',
        ]
        for malformed in variants:
            with self.subTest(malformed=malformed):
                self.files[0].write_text(LEGACY)
                if malformed is None:
                    self.files[1].unlink(missing_ok=True)
                else:
                    self.files[1].write_text(malformed)
                result = self.run_script()
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(LEGACY, self.files[0].read_text())
                if malformed is not None:
                    self.assertEqual(malformed, self.files[1].read_text())

    def test_quoted_aliases_and_trailing_comments_remain_supported(self):
        quoted = LEGACY.replace("repository: ipaffs-infra", 'repository: "ipaffs-infra" # deployment tools')
        self.write(quoted, quoted)
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(quoted.replace("refs/tags/ipaffs-infra-pin-old", NEW_REF), self.files[0].read_text())

    def test_unknown_mode_fails_before_writing(self):
        result = self.run_script("--unexpected")
        self.assertEqual(2, result.returncode)
        self.assertEqual([LEGACY, LEGACY], [path.read_text() for path in self.files])

    def run_pipeline(self):
        """Run its actual Bash bodies with mocked Git and step-output conditions."""
        pipeline = yaml.safe_load(PIPELINE.read_text())
        steps = pipeline["stages"][0]["jobs"][0]["steps"]
        workspace = self.directory / "workspace"
        (workspace / "s").mkdir(parents=True)
        (workspace / "s/ipaffs-infra").symlink_to(ROOT)
        (workspace / "s/ipaffs-manifest").symlink_to(self.manifest)
        binary = self.directory / "bin"
        binary.mkdir()
        log = self.directory / "git.jsonl"
        git = binary / "git"
        git.write_text(f"#!{sys.executable}\n" + '''import json
import os
import sys
with open(os.environ["GIT_LOG"], "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["ls-remote", "--exit-code"] and "--tags" in sys.argv:
    sys.exit(1)
if sys.argv[1:4] == ["diff", "--cached", "--quiet"]:
    sys.exit(1)
''')
        git.chmod(0o755)
        variables = {"Pipeline.Workspace": str(workspace), "Build.SourceVersion": "a" * 40}
        environment = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"], "GIT_LOG": str(log)}
        def expand(value):
            return re.sub(r"\$\(([^)]+)\)", lambda match: variables[match[1]], value).replace(
                "${{ parameters.infraTagPrefix }}", "ipaffs-infra-pin")
        executed = []
        for step in steps:
            if "checkout" in step:
                continue
            condition = step.get("condition")
            if condition:
                self.assertEqual(GUARD, condition)
                if variables.get("CheckManifestInfraPin.requiresInfraPin") != "true":
                    continue
            inputs = step["inputs"]
            command = [self.bash]
            if inputs["targetType"] == "filePath":
                command += [expand(inputs["filePath"])] + inputs.get("arguments", "").split()
            else:
                command += ["-c", inputs["script"]]
            result = subprocess.run(command, cwd=expand(inputs["workingDirectory"]),
                                    env={**environment, **{key: expand(value) for key, value in step.get("env", {}).items()}},
                                    text=True, capture_output=True, timeout=10)
            executed.append(step.get("name", step["displayName"]))
            if result.returncode:
                return result.returncode, executed, log
            for variable, value in re.findall(r"##vso\[task.setvariable variable=(\w+);isOutput=true\](.*)", result.stdout):
                variables[step["name"] + "." + variable] = value
        return 0, executed, log

    def test_pipeline_retirement_stops_before_any_tag_commit_or_push(self):
        self.write(LOCAL, LOCAL)
        status, executed, log = self.run_pipeline()
        self.assertEqual(0, status)
        self.assertEqual(["ResolveManifestBranch", "CheckManifestInfraPin"], executed)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertFalse(any(call[0] in ("tag", "commit", "push") for call in calls))

    def test_pipeline_mixed_state_fails_before_any_tag_commit_or_push(self):
        self.write(LOCAL, LEGACY)
        status, executed, log = self.run_pipeline()
        self.assertNotEqual(0, status)
        self.assertNotIn("ResolveInfraTag", executed)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertFalse(any(call[0] in ("tag", "commit", "push") for call in calls))

    def test_pipeline_legacy_path_keeps_tagging_updating_and_pushing(self):
        status, executed, log = self.run_pipeline()
        self.assertEqual(0, status)
        self.assertEqual(["ResolveManifestBranch", "CheckManifestInfraPin", "ResolveInfraTag",
                          "Update manifest ipaffs-infra refs", "Commit and push manifest ref pin"], executed)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertTrue(any(call[0] == "tag" for call in calls))
        self.assertEqual(2, sum(call[0] == "push" for call in calls))
        for path in self.files:
            self.assertIn("refs/tags/ipaffs-infra-pin-" + "a" * 12, path.read_text())


if __name__ == "__main__":
    unittest.main()
