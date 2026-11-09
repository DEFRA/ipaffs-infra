"""Exercise manual release tags against disposable local Git origins.

Only temporary file-protocol repositories can be reached by these tests. No
GitHub, Azure credentials, pipeline run or infrastructure deployment is used.
"""

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
SCRIPT = ROOT / "scripts/pipeline/create-release-refs.py"


class ReleaseRefTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.origin = self.directory / "origin.git"
        self.seed = self.directory / "seed"
        self.checkout = self.directory / "build"
        self.metadata = self.directory / "release-metadata/release.json"
        self.environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
        }
        self.command("git", "init", "--bare", "--initial-branch=main", str(self.origin))
        self.command("git", "init", "--initial-branch=main", str(self.seed))
        self.git(self.seed, "config", "user.name", "Release fixture")
        self.git(self.seed, "config", "user.email", "fixture@example.invalid")
        self.git(self.seed, "config", "commit.gpgsign", "false")
        self.git(self.seed, "remote", "add", "origin", str(self.origin))
        self.base = self.commit("Initial infrastructure")
        self.git(self.seed, "push", "origin", "main")
        self.command("git", "clone", str(self.origin), str(self.checkout))

    def command(self, *arguments, cwd=None, check=True):
        return subprocess.run(arguments, cwd=cwd or self.directory, env=self.environment,
                              text=True, capture_output=True, check=check, timeout=20)

    def git(self, directory, *arguments):
        return self.command("git", *arguments, cwd=directory).stdout.strip()

    def commit(self, message):
        tracked = self.seed / "tracked.txt"
        with tracked.open("a") as output:
            output.write(message + "\n")
        self.git(self.seed, "add", "tracked.txt")
        self.git(self.seed, "commit", "-m", message)
        return self.git(self.seed, "rev-parse", "HEAD")

    def refs(self):
        return self.git(self.origin, "for-each-ref", "--format=%(refname) %(objectname)",
                        "refs/heads", "refs/tags")

    def branches(self):
        return self.git(self.origin, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads")

    def run_release(self, version="1", source_ref="refs/heads/main", **overrides):
        environment = {
            **self.environment,
            "VERSION": version,
            "SOURCE_REF": source_ref,
            "REQUESTED_FOR_EMAIL": "requester@example.invalid",
            "REQUESTED_FOR_NAME": "Release requester",
            "RELEASE_METADATA_FILE": str(self.metadata),
            "RELEASE_RUN_ID": "123",
            "RELEASE_PIPELINE_ID": "456",
            **overrides,
        }
        return subprocess.run([sys.executable, str(SCRIPT)], cwd=self.checkout,
                              env=environment, text=True, capture_output=True, timeout=20)

    def assert_success(self, result):
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def assert_tag(self, tag, commit):
        self.assertEqual("tag", self.git(self.origin, "cat-file", "-t", "refs/tags/" + tag))
        self.assertEqual(commit, self.git(self.origin, "rev-parse", "refs/tags/" + tag + "^{commit}"))

    def assert_metadata(self, version, commit):
        self.assertEqual({
            "schemaVersion": 1,
            "version": version,
            "tag": version,
            "releaseBranch": "main",
            "infraCommit": commit,
            "createReleaseRunId": 123,
            "createReleasePipelineId": 456,
        }, json.loads(self.metadata.read_text()))

    def git_wrapper(self, body):
        binary = self.directory / "bin"
        binary.mkdir()
        wrapper = binary / "git"
        real_git = shutil.which("git")
        wrapper.write_text(f"#!{sys.executable}\n" + f'''
import os
from pathlib import Path
import subprocess
import sys

arguments = sys.argv[1:]
{body}
os.execv({real_git!r}, [{real_git!r}, *arguments])
''')
        wrapper.chmod(0o755)
        return str(binary) + os.pathsep + self.environment["PATH"]

    def test_creator_is_manual_only_main_and_publishes_exact_metadata(self):
        pipeline = yaml.safe_load((ROOT / "release-refs-pipeline.yaml").read_text())
        self.assertEqual("none", pipeline["trigger"])
        self.assertEqual("none", pipeline["pr"])
        version, = pipeline["parameters"]
        self.assertEqual("version", version["name"])
        self.assertEqual("string", version["type"])
        self.assertEqual("1", version["default"])
        job, = pipeline["stages"][0]["jobs"]
        checkout, = [step for step in job["steps"] if step.get("checkout") == "self"]
        self.assertIs(True, checkout["persistCredentials"])
        self.assertEqual(0, checkout["fetchDepth"])
        creator, = [step for step in job["steps"]
                    if "create-release-refs.py" in str(step.get("inputs", {}))]
        self.assertEqual("$(Build.SourceBranch)", creator["env"]["SOURCE_REF"])
        self.assertEqual("${{ parameters.version }}", creator["env"]["VERSION"])
        self.assertNotIn("SOURCE_SHA", creator["env"])
        self.assertNotIn("BRANCH_PREFIX", creator["env"])
        publish, = [step for step in job["steps"] if step.get("artifact") == "release-metadata"]
        self.assertEqual("$(Build.ArtifactStagingDirectory)/release-metadata", publish["publish"])

    def test_explicit_integer_tags_latest_remote_main_without_creating_or_moving_branches(self):
        latest = self.commit("Merged after the build was queued")
        self.git(self.seed, "push", "origin", "main")
        before_branches = self.branches()
        self.assertEqual(self.base, self.git(self.checkout, "rev-parse", "HEAD"))
        self.assert_success(self.run_release("2", SOURCE_SHA=self.base))
        self.assertEqual(before_branches, self.branches())
        self.assert_tag("2", latest)
        self.assert_metadata("2", latest)
        self.assertEqual("", self.git(self.checkout, "tag", "--list", "2"))
        tag = self.git(self.origin, "cat-file", "-p", "refs/tags/2")
        self.assertIn("\ntag 2\n", tag)
        self.assertIn("\ntagger Release requester <requester@example.invalid> ", tag)
        self.assertTrue(tag.endswith("Release 2"))

    def test_existing_release_branches_are_neither_selected_nor_mutated(self):
        self.git(self.seed, "push", "origin", f"{self.base}:refs/heads/RELEASE/18.9.x")
        latest = self.commit("Main advanced beyond the former release branch")
        self.git(self.seed, "push", "origin", "main")
        before_branches = self.branches()
        self.assert_success(self.run_release())
        self.assertEqual(before_branches, self.branches())
        self.assert_tag("1", latest)
        self.assert_metadata("1", latest)

    def test_explicit_patch_tags_preserve_the_requested_version_and_use_latest_main(self):
        for tag in ("1", "1.9"):
            self.git(self.seed, "tag", tag, self.base)
        self.git(self.seed, "push", "origin", "--tags")
        latest = self.commit("Main advanced after the previous release")
        self.git(self.seed, "push", "origin", "main")
        before_branches = self.branches()
        versions = ("1.1", "1.10", "42.0")
        for version in versions:
            with self.subTest(version=version):
                self.assert_success(self.run_release(version))
                self.assert_tag(version, latest)
                self.assert_metadata(version, latest)
        self.assertEqual(before_branches, self.branches())
        self.assertEqual({"1", "1.9", *versions}, set(self.git(self.origin, "tag", "--list").splitlines()))
        self.assertEqual(self.base, self.git(self.origin, "rev-parse", "refs/tags/1"))
        self.assertEqual(self.base, self.git(self.origin, "rev-parse", "refs/tags/1.9"))

    def test_ado_checkout_without_a_default_fetch_refspec_can_release_current_main(self):
        self.git(self.checkout, "config", "--unset-all", "remote.origin.fetch")
        latest = self.commit("Merged after checkout")
        self.git(self.seed, "push", "origin", "main")
        self.assert_success(self.run_release())
        self.assert_tag("1", latest)
        self.assert_metadata("1", latest)

    def test_explicit_version_is_not_calculated_from_integer_or_semver_tags(self):
        for tag in ("500", "18.9.99", "18.9.100-rc.1"):
            self.git(self.seed, "tag", tag, self.base)
        self.git(self.seed, "push", "origin", "--tags")
        self.assert_success(self.run_release("2"))
        self.assert_tag("2", self.base)
        self.assert_metadata("2", self.base)
        self.assertEqual("500", self.git(self.origin, "tag", "--list", "500"))
        self.assertEqual("", self.git(self.origin, "tag", "--list", "501"))

    def test_current_remote_tag_collisions_fail_even_for_the_same_commit(self):
        tags = (("7", True), ("8", False), ("7.1", True), ("8.0", False))
        for tag, annotated in tags:
            if annotated:
                self.git(self.seed, "tag", "-a", tag, self.base, "-m", "Reserved version")
            else:
                self.git(self.seed, "tag", tag, self.base)
        self.git(self.seed, "push", "origin", "--tags")
        before = self.refs()
        self.assertEqual("", self.git(self.checkout, "tag", "--list"))
        for version, _ in tags:
            with self.subTest(version=version):
                self.assertNotEqual(0, self.run_release(version).returncode)
                self.assertEqual(before, self.refs())
                self.assertFalse(self.metadata.exists())

    def test_unpublished_local_tag_does_not_claim_the_remote_release_number(self):
        self.git(self.checkout, "tag", "3", self.base)
        latest = self.commit("Current remote main")
        self.git(self.seed, "push", "origin", "main")
        self.assert_success(self.run_release("3"))
        self.assert_tag("3", latest)
        self.assert_metadata("3", latest)
        self.assertEqual(self.base, self.git(self.checkout, "rev-parse", "refs/tags/3"))

    def test_noncanonical_versions_and_nonmain_sources_fail_before_any_git_operation(self):
        trace = self.directory / "git-was-called"
        path = self.git_wrapper(f"Path({str(trace)!r}).write_text('called')")
        before = self.refs()
        versions = ("", "auto", "0", "01", "-1", "+1", "18.9.0", "v1", "1-rc", "1+build",
                    " 1", "1 ", "1\n", "1\nwrong", "١", "１", "0.1", "01.1", "1.01", "1.",
                    ".1", "1.-1", "1.1.1", "1.١", "1.1 ")
        sources = ("refs/heads/feature", "refs/heads/RELEASE/18.9.x", "refs/tags/1",
                   "refs/pull/42/merge", "main", "", " refs/heads/main", "refs/heads/main\n")
        for version in versions:
            with self.subTest(version=version):
                self.assertNotEqual(0, self.run_release(version, PATH=path).returncode)
                self.assertEqual(before, self.refs())
                self.assertFalse(trace.exists())
        for reference in sources:
            with self.subTest(reference=reference):
                self.assertNotEqual(0, self.run_release(source_ref=reference, PATH=path).returncode)
                self.assertEqual(before, self.refs())
                self.assertFalse(trace.exists())
        self.assertFalse(self.metadata.exists())

    def test_old_semver_tag_cannot_be_overwritten_or_used_as_a_release_number(self):
        self.git(self.seed, "tag", "-a", "18.9.0", self.base, "-m", "Old version")
        self.git(self.seed, "push", "origin", "refs/tags/18.9.0")
        before = self.refs()
        result = self.run_release("18.9.0")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_invalid_metadata_ids_or_missing_path_fail_before_any_git_operation(self):
        trace = self.directory / "git-was-called"
        path = self.git_wrapper(f"Path({str(trace)!r}).write_text('called')")
        before = self.refs()
        cases = ({"RELEASE_RUN_ID": "0"}, {"RELEASE_PIPELINE_ID": "-1"},
                 {"RELEASE_RUN_ID": "wrong"}, {"RELEASE_PIPELINE_ID": "1.0"},
                 {"RELEASE_RUN_ID": " 1"}, {"RELEASE_METADATA_FILE": ""})
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.assertNotEqual(0, self.run_release(PATH=path, **overrides).returncode)
                self.assertEqual(before, self.refs())
                self.assertFalse(trace.exists())
                self.assertFalse(self.metadata.exists())

    def test_missing_remote_main_cannot_create_a_tag(self):
        self.git(self.origin, "update-ref", "-d", "refs/heads/main")
        before = self.refs()
        self.assertNotEqual(0, self.run_release().returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_rejected_push_can_retry_without_an_unpublished_named_tag(self):
        hook = self.origin / "hooks/update"
        hook.write_text('#!/bin/sh\ncase "$1" in refs/tags/*) exit 1;; esac\nexit 0\n')
        hook.chmod(0o755)
        before = self.refs()
        result = self.run_release("9")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.refs())
        self.assertEqual("", self.git(self.checkout, "tag", "--list", "9"))
        self.assertFalse(self.metadata.exists())
        hook.unlink()
        self.assert_success(self.run_release("9"))
        self.assert_tag("9", self.base)
        self.assert_metadata("9", self.base)
        self.assertEqual("", self.git(self.checkout, "tag", "--list", "9"))

    def test_a_racing_tag_claim_at_the_same_commit_cannot_be_overwritten(self):
        marker = self.directory / "concurrent-tag-created"
        real_git = shutil.which("git")
        path = self.git_wrapper(f'''
marker = Path({str(marker)!r})
if arguments[:1] == ["push"] and not marker.exists():
    subprocess.run([{real_git!r}, "--git-dir", {str(self.origin)!r}, "update-ref",
                    "refs/tags/10", {self.base!r}], check=True)
    marker.write_text("created")
''')
        before_branches = self.branches()
        result = self.run_release("10", PATH=path)
        self.assertTrue(marker.exists(), result.stdout + result.stderr)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before_branches, self.branches())
        self.assertEqual("commit", self.git(self.origin, "cat-file", "-t", "refs/tags/10"))
        self.assertEqual(self.base, self.git(self.origin, "rev-parse", "refs/tags/10"))
        self.assertEqual("", self.git(self.checkout, "tag", "--list", "10"))
        self.assertFalse(self.metadata.exists())

    def test_git_errors_do_not_print_provider_credentials_or_raw_output(self):
        secret = "PRIVATE-CREDENTIAL-MARKER"
        path = self.git_wrapper(f'''
if arguments[:1] == ["push"]:
    print("https://{secret}@example.invalid/repository", file=sys.stderr)
    print("PRIVATE-PROVIDER-OUTPUT")
    raise SystemExit(19)
''')
        before = self.refs()
        result = self.run_release(PATH=path)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Git push failed (exit 19)", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn("PRIVATE-PROVIDER-OUTPUT", result.stdout + result.stderr)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())


if __name__ == "__main__":
    unittest.main()
