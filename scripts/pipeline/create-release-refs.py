#!/usr/bin/env python3
"""Create infrastructure release branches and annotated version tags.

Inputs are supplied by release-refs-pipeline.yaml. Remote refs determine the
version so a retried job cannot mistake a local, unpushed tag for a release.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
RELEASE_BRANCH = re.compile(r"RELEASE/(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.x")
TAG = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
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
    # ADO may fetch only the queued source branch. Fetch the chosen remote tip
    # explicitly when cutting a release from a different checkout.
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
    version = os.environ.get("VERSION", "auto").strip()
    source_ref = os.environ.get("SOURCE_REF", "").strip()
    source_sha = os.environ.get("SOURCE_SHA", "").strip()
    if os.environ.get("BRANCH_PREFIX", "RELEASE/") != "RELEASE/":
        raise ValueError("Release branch prefix must be RELEASE/")
    if not source_ref.startswith("refs/heads/"):
        raise ValueError("Create Release must run from a branch, not a tag or pull request ref")

    branch = source_ref.removeprefix("refs/heads/")
    git("check-ref-format", "--branch", branch)
    patch_release = branch.startswith("RELEASE/")
    match = RELEASE_BRANCH.fullmatch(branch) if patch_release else VERSION.fullmatch(version)
    if not match:
        if patch_release:
            raise ValueError("Release branch must match RELEASE/<major>.<minor>.x")
        raise ValueError("Version must identify a major and minor release, for example: 18.9")
    major, minor = match.groups()
    if patch_release and not COMMIT.fullmatch(source_sha):
        raise ValueError("Build source commit must be a full commit SHA")

    run_id = positive_id("RELEASE_RUN_ID")
    pipeline_id = positive_id("RELEASE_PIPELINE_ID")
    metadata_file = os.environ.get("RELEASE_METADATA_FILE", "")
    if not metadata_file:
        raise ValueError("RELEASE_METADATA_FILE is required")
    metadata_path = Path(metadata_file)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)

    # ADO's GitHub checkout may omit remote.origin.fetch. Supply it explicitly;
    # only remote-tracking refs are refreshed, never local release branches.
    git("fetch", "--prune", "--tags", "origin", "+refs/heads/*:refs/remotes/origin/*")
    refs = dict(line.split("\t", 1)[::-1] for line in git("ls-remote", "--heads", "--tags", "origin").splitlines())
    tags = {}
    for reference, commit in refs.items():
        if not reference.startswith("refs/tags/") or reference.endswith("^{}"):
            continue
        tag = reference.removeprefix("refs/tags/")
        tag_match = TAG.fullmatch(tag)
        if tag_match and tag_match.groups()[:2] == (major, minor):
            tags[tag] = (int(tag_match[3]), refs.get(reference + "^{}", commit))

    if patch_release:
        source_sha = available_commit(source_sha)
        existing = [(patch, tag) for tag, (patch, commit) in tags.items() if commit == source_sha]
        if existing:
            version = max(existing)[1]
            print(f"Commit {source_sha} is already tagged '{version}'. No patch tag is required.")
        else:
            patch = max((patch for patch, _ in tags.values()), default=-1) + 1
            version = f"{major}.{minor}.{patch}"
            tag_object = annotated_tag(version, source_sha)
            # No force: Git rejects a competing run that has claimed this tag.
            git("push", "origin", f"{tag_object}:refs/tags/{version}")
            print(f"Created patch tag '{version}' at {source_sha}")
    else:
        version = f"{major}.{minor}.0"
        branch = f"RELEASE/{major}.{minor}.x"
        if version in tags:
            raise ValueError(f"Tag '{version}' already exists. Choose a new major/minor version.")
        existing_branch = refs.get(f"refs/heads/{branch}")
        source_sha = existing_branch or refs.get("refs/heads/main")
        if not source_sha:
            raise ValueError("Trunk branch refs/heads/main was not found on origin")
        source_sha = available_commit(source_sha)
        tag_object = annotated_tag(version, source_sha)
        if existing_branch:
            git("push", "origin", f"{tag_object}:refs/tags/{version}")
            print(f"Reused existing release branch '{branch}'")
        else:
            # Empty expected value is a create-only compare-and-swap: even an
            # ancestor branch created concurrently must not be fast-forwarded.
            # The lease applies only to this absent branch; the tag is unforced.
            git("push", "--atomic", f"--force-with-lease=refs/heads/{branch}:",
                "origin", f"{source_sha}:refs/heads/{branch}",
                f"{tag_object}:refs/tags/{version}")
            print(f"Created branch '{branch}' at {source_sha}")
        print(f"Created tag '{version}' at {source_sha}")

    metadata = {
        "schemaVersion": 1,
        "version": version,
        "tag": version,
        "releaseBranch": branch,
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
