"""Exercise release creation against disposable local Git repositories.

The real release script fetches and pushes only to a temporary bare origin.
No GitHub, Azure credentials, pipeline run or infrastructure deployment is used.
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

    def run_release(self, version="18.9", source_ref="refs/heads/main", source_sha=None, **overrides):
        environment = {
            **self.environment,
            "VERSION": version,
            "BRANCH_PREFIX": "RELEASE/",
            "SOURCE_REF": source_ref,
            "SOURCE_SHA": source_sha or self.base,
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
        major, minor, _ = version.split(".")
        self.assertEqual({
            "schemaVersion": 1,
            "version": version,
            "tag": version,
            "releaseBranch": f"RELEASE/{major}.{minor}.x",
            "infraCommit": commit,
            "createReleaseRunId": 123,
            "createReleasePipelineId": 456,
        }, json.loads(self.metadata.read_text()))

    def test_pipeline_runs_for_release_branch_changes_and_publishes_exact_metadata(self):
        pipeline = yaml.safe_load((ROOT / "release-refs-pipeline.yaml").read_text())
        self.assertEqual(["RELEASE/*"], pipeline["trigger"]["branches"]["include"])
        self.assertEqual(["*"], pipeline["trigger"]["tags"]["exclude"])
        self.assertIs(True, pipeline["trigger"]["batch"])
        self.assertEqual("none", pipeline["pr"])
        job, = pipeline["stages"][0]["jobs"]
        checkout, = [step for step in job["steps"] if step.get("checkout") == "self"]
        self.assertIs(True, checkout["persistCredentials"])
        self.assertEqual(0, checkout["fetchDepth"])
        creator, = [step for step in job["steps"]
                    if "create-release-refs.py" in str(step.get("inputs", {}))]
        self.assertEqual("$(Build.SourceBranch)", creator["env"]["SOURCE_REF"])
        self.assertEqual("$(Build.SourceVersion)", creator["env"]["SOURCE_SHA"])
        publish, = [step for step in job["steps"] if step.get("artifact") == "release-metadata"]
        self.assertEqual("$(Build.ArtifactStagingDirectory)/release-metadata", publish["publish"])

    def test_initial_release_uses_latest_main_and_creates_branch_and_annotated_tag(self):
        latest = self.commit("Merged after the build was queued")
        self.git(self.seed, "push", "origin", "main")
        self.assert_success(self.run_release(source_sha=self.base))
        self.assertEqual(latest, self.git(self.origin, "rev-parse", "refs/heads/RELEASE/18.9.x"))
        self.assert_tag("18.9.0", latest)
        self.assert_metadata("18.9.0", latest)

    def test_existing_release_branch_is_reused_without_resetting_it_to_main(self):
        release_commit = self.commit("Prepared release branch")
        self.git(self.seed, "push", "origin", f"{release_commit}:refs/heads/RELEASE/18.9.x")
        self.assert_success(self.run_release())
        self.assertEqual(release_commit, self.git(self.origin, "rev-parse", "refs/heads/RELEASE/18.9.x"))
        self.assertEqual(self.base, self.git(self.origin, "rev-parse", "refs/heads/main"))
        self.assert_tag("18.9.0", release_commit)
        self.assert_metadata("18.9.0", release_commit)

    def test_ado_checkout_without_a_default_fetch_refspec_can_release_current_main(self):
        self.git(self.checkout, "config", "--unset-all", "remote.origin.fetch")
        latest = self.commit("Merged after checkout")
        self.git(self.seed, "push", "origin", "main")
        self.assert_success(self.run_release())
        self.assert_tag("18.9.0", latest)
        self.assert_metadata("18.9.0", latest)

    def test_patch_uses_numeric_maximum_ignores_other_tags_and_tags_the_build_commit(self):
        self.assert_success(self.run_release())
        for tag in ("18.9.2", "18.9.10", "18.9.011", "18.9.99-rc.1", "18.90.99", "18.9.100.extra"):
            self.git(self.seed, "tag", tag, self.base)
        self.git(self.seed, "push", "origin", "--tags")
        queued = self.commit("Queued release change")
        latest = self.commit("Later release change")
        self.git(self.seed, "push", "origin", f"{latest}:refs/heads/RELEASE/18.9.x")
        self.assert_success(self.run_release("auto", "refs/heads/RELEASE/18.9.x", queued))
        self.assert_tag("18.9.11", queued)
        self.assertEqual(latest, self.git(self.origin, "rev-parse", "refs/heads/RELEASE/18.9.x"))
        self.assert_metadata("18.9.11", queued)

    def test_patch_retry_reuses_its_exact_tag_even_after_another_release_is_published(self):
        self.assert_success(self.run_release())
        patch = self.commit("First patch")
        self.git(self.seed, "push", "origin", f"{patch}:refs/heads/RELEASE/18.9.x")
        self.assert_success(self.run_release("auto", "refs/heads/RELEASE/18.9.x", patch))
        newer = self.commit("Second patch")
        self.git(self.seed, "push", "origin", f"{newer}:refs/heads/RELEASE/18.9.x")
        self.assert_success(self.run_release("auto", "refs/heads/RELEASE/18.9.x", newer))
        before = self.refs()
        self.assert_success(self.run_release("auto", "refs/heads/RELEASE/18.9.x", patch))
        self.assertEqual(before, self.refs())
        self.assert_metadata("18.9.1", patch)
        self.assert_tag("18.9.2", newer)

    def test_initial_version_collision_never_overwrites_the_existing_tag(self):
        self.git(self.seed, "tag", "-a", "18.9.0", self.base, "-m", "Reserved version")
        self.git(self.seed, "push", "origin", "refs/tags/18.9.0")
        before = self.refs()
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_invalid_initial_versions_and_sources_fail_without_creating_refs(self):
        before = self.refs()
        for version in ("", "auto", "18", "18.9.0", "v18.9", "01.9", "18.09", "18.9-rc", "18.9\nwrong"):
            with self.subTest(version=version):
                self.assertNotEqual(0, self.run_release(version).returncode)
                self.assertEqual(before, self.refs())
        for source_ref in ("refs/tags/18.9.0", "refs/pull/42/merge", "main", ""):
            with self.subTest(source_ref=source_ref):
                self.assertNotEqual(0, self.run_release(source_ref=source_ref).returncode)
                self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_invalid_release_branches_and_unavailable_commits_cannot_create_patch_tags(self):
        before = self.refs()
        for source_ref in ("refs/heads/RELEASE/18.9", "refs/heads/RELEASE/18.9.0", "refs/heads/RELEASE/01.9.x"):
            with self.subTest(source_ref=source_ref):
                self.assertNotEqual(0, self.run_release("auto", source_ref).returncode)
                self.assertEqual(before, self.refs())
        self.assertNotEqual(0, self.run_release("auto", "refs/heads/RELEASE/18.9.x", "f" * 40).returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_invalid_metadata_ids_fail_before_any_remote_mutation(self):
        before = self.refs()
        for overrides in ({"RELEASE_RUN_ID": "0"}, {"RELEASE_PIPELINE_ID": "-1"}, {"RELEASE_RUN_ID": "wrong"}):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(0, self.run_release(**overrides).returncode)
                self.assertEqual(before, self.refs())
                self.assertFalse(self.metadata.exists())

    def test_atomic_push_leaves_no_release_branch_when_remote_rejects_the_tag(self):
        hook = self.origin / "hooks/update"
        hook.write_text("#!/bin/sh\ncase \"$1\" in refs/tags/*) exit 1;; esac\nexit 0\n")
        hook.chmod(0o755)
        before = self.refs()
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())

    def test_concurrent_branch_creation_cannot_be_fast_forwarded_by_the_initial_release_push(self):
        latest = self.commit("Main advanced beyond the concurrent branch")
        self.git(self.seed, "push", "origin", "main")
        binary = self.directory / "bin"
        binary.mkdir()
        wrapper = binary / "git"
        marker = self.directory / "concurrent-branch-created"
        real_git = shutil.which("git")
        wrapper.write_text(f"#!{sys.executable}\n" + f'''
import os
from pathlib import Path
import subprocess
import sys

arguments = sys.argv[1:]
marker = Path({str(marker)!r})
if arguments[:1] == ["push"] and "--atomic" in arguments and not marker.exists():
    subprocess.run([{real_git!r}, "--git-dir", {str(self.origin)!r}, "update-ref",
                    "refs/heads/RELEASE/18.9.x", {self.base!r}], check=True)
    marker.write_text("created")
os.execv({real_git!r}, [{real_git!r}, *arguments])
''')
        wrapper.chmod(0o755)
        result = self.run_release(PATH=str(binary) + os.pathsep + self.environment["PATH"])
        self.assertTrue(marker.exists(), result.stdout + result.stderr)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(self.base, self.git(self.origin, "rev-parse", "refs/heads/RELEASE/18.9.x"))
        self.assertEqual(latest, self.git(self.origin, "rev-parse", "refs/heads/main"))
        self.assertEqual("", self.git(self.origin, "tag", "--list", "18.9.0"))
        self.assertFalse(self.metadata.exists())

    def test_rejected_patch_push_can_retry_without_skipping_or_conflicting_with_an_unpushed_tag(self):
        self.assert_success(self.run_release())
        patch = self.commit("Retryable patch")
        self.git(self.seed, "push", "origin", f"{patch}:refs/heads/RELEASE/18.9.x")
        self.metadata.unlink()
        hook = self.origin / "hooks/update"
        hook.write_text("#!/bin/sh\ncase \"$1\" in refs/tags/*) exit 1;; esac\nexit 0\n")
        hook.chmod(0o755)
        before = self.refs()
        result = self.run_release("auto", "refs/heads/RELEASE/18.9.x", patch)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.refs())
        self.assertFalse(self.metadata.exists())
        hook.unlink()
        self.assert_success(self.run_release("auto", "refs/heads/RELEASE/18.9.x", patch))
        self.assert_tag("18.9.1", patch)
        self.assert_metadata("18.9.1", patch)


if __name__ == "__main__":
    unittest.main()
