#!/usr/bin/env python3
"""Create an explicitly numbered annotated infrastructure tag from remote main.

Inputs are supplied by release-refs-pipeline.yaml. Remote refs determine the
source and collisions; release numbers are never calculated automatically.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


VERSION = re.compile(r"[1-9][0-9]*")
COMMIT = re.compile(r"[0-9a-f]{40}")


def git(*arguments, input=None):
    result = subprocess.run(["git", *arguments], input=input, text=True, capture_output=True)
    if result.returncode:
        # A provider error can echo an authenticated origin URL. Keep credentials
        # out of build logs while retaining the failed operation and exit status.
        raise RuntimeError(f"Git {arguments[0]} failed (exit {result.returncode}); check repository access and ref conflicts before retrying.")
    return result.stdout.strip()


def positive_id(name):
    value = os.environ.get(name, "")
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


def available_commit(commit):
    # The queued checkout may be older than remote main. Fetch the chosen tip
    # explicitly if the earlier branch fetch did not include it.
    if not COMMIT.fullmatch(commit):
        raise ValueError("Release source did not resolve to a full commit SHA")
    result = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"],
                            capture_output=True, text=True)
    if result.returncode:
        git("fetch", "--no-tags", "origin", commit)
    resolved = git("rev-parse", "--verify", f"{commit}^{{commit}}")
    if not COMMIT.fullmatch(resolved):
        raise ValueError("Release source did not resolve to a full commit SHA")
    return resolved


def annotated_tag(version, commit):
    name = os.environ.get("REQUESTED_FOR_NAME") or "IPAFFS CI Bot"
    email = os.environ.get("REQUESTED_FOR_EMAIL") or "ipaffs-ci-bot@defra.gov.uk"
    identity = git("-c", f"user.name={name}", "-c", f"user.email={email}",
                   "var", "GIT_COMMITTER_IDENT")
    # Make the annotated object without a named local tag. A rejected push must
    # not leave a local ref that prevents a later retry from calculating again.
    content = f"object {commit}\ntype commit\ntag {version}\ntagger {identity}\n\nRelease {version}\n"
    return git("mktag", input=content)


def main():
    version = os.environ.get("VERSION", "")
    if not VERSION.fullmatch(version):
        raise ValueError("Version must be an explicit positive integer without leading zeroes, for example: 1")
    if os.environ.get("SOURCE_REF", "") != "refs/heads/main":
        raise ValueError("Create Release must run from refs/heads/main")

    run_id = positive_id("RELEASE_RUN_ID")
    pipeline_id = positive_id("RELEASE_PIPELINE_ID")
    metadata_file = os.environ.get("RELEASE_METADATA_FILE", "")
    if not metadata_file:
        raise ValueError("RELEASE_METADATA_FILE is required")
    metadata_path = Path(metadata_file)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)

    # ADO's GitHub checkout may omit remote.origin.fetch. Supply it explicitly;
    # only remote-tracking refs are refreshed. Tags are checked directly on origin.
    git("fetch", "--prune", "--no-tags", "origin", "+refs/heads/*:refs/remotes/origin/*")
    refs = dict(line.split("\t", 1)[::-1] for line in git("ls-remote", "--heads", "--tags", "origin").splitlines())
    if f"refs/tags/{version}" in refs:
        raise ValueError(f"Tag '{version}' already exists. Choose a different release number.")
    source_sha = refs.get("refs/heads/main")
    if not source_sha:
        raise ValueError("Trunk branch refs/heads/main was not found on origin")
    source_sha = available_commit(source_sha)
    tag_object = annotated_tag(version, source_sha)
    # No force or branch writes: Git rejects a competing run that claims the tag.
    git("push", "origin", f"{tag_object}:refs/tags/{version}")
    print(f"Created tag '{version}' at {source_sha}")

    metadata = {
        "schemaVersion": 1,
        "version": version,
        "tag": version,
        "releaseBranch": "main",
        "infraCommit": source_sha,
        "createReleaseRunId": run_id,
        "createReleasePipelineId": pipeline_id,
    }
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
