#!/usr/bin/env bash
set -euo pipefail

# Execute the template's actual build task with registry and Docker commands mocked.
TEMPLATE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/pipelines/steps/build-container-image.yaml" python3 - <<'PY'
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

TEMPLATE = Path(os.environ["TEMPLATE_PATH"]).read_text()
SCRIPT = textwrap.dedent(TEMPLATE.split("      inlineScript: |\n", 1)[1])

MOCK = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ["CALL_LOG"])
with log.open("a") as handle:
    handle.write(json.dumps([Path(sys.argv[0]).name] + args) + "\n")
if Path(sys.argv[0]).name == "docker":
    sys.exit(0)
state_file = Path(os.environ["MOCK_STATE"])
state = json.loads(state_file.read_text())
mode = os.environ.get("MOCK_MODE", "normal")
def option(name):
    return args[args.index(name) + 1]
def query_value():
    return re.fullmatch(r"\[\?@ == '([^']+)'\]", option("--query")).group(1)
def save(image):
    if image not in state["images"]:
        state["images"].append(image)
    state_file.write_text(json.dumps(state))
if args[:2] == ["account", "show"]:
    print("subscription-from-acr-connection")
elif args[:3] == ["acr", "repository", "list"]:
    if mode == "auth-failure":
        print("Registry access denied", file=sys.stderr)
        sys.exit(1)
    if mode == "registry-failure":
        print("Registry unavailable", file=sys.stderr)
        sys.exit(1)
    repository = query_value()
    if any(image.rsplit(":", 1)[0] == repository for image in state["images"]):
        print(repository)
elif args[:3] == ["acr", "repository", "show-tags"]:
    if mode == "tag-failure":
        print("Tag access denied", file=sys.stderr)
        sys.exit(1)
    repository, tag = option("--repository"), query_value()
    if repository + ":" + tag in state["images"]:
        print(tag)
elif args[:2] == ["acr", "import"]:
    image = option("--image")
    if mode == "import-failure":
        sys.exit(1)
    if mode != "unverified-import":
        save(image)
    if mode == "concurrent-import":
        sys.exit(1)
elif args[:2] == ["acr", "login"]:
    pass
else:
    print("Unexpected mock command", file=sys.stderr)
    sys.exit(99)
'''


class ContainerBuildTests(unittest.TestCase):
    def run_build(self, dockerfile, images=(), mode="normal", env=None):
        self.temp = tempfile.TemporaryDirectory(prefix="ipaffs-base-import-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "Dockerfile").write_text(dockerfile)
        mock_bin = root / "bin"
        mock_bin.mkdir()
        for name in ("az", "docker"):
            executable = mock_bin / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        state = root / "state.json"
        state.write_text(json.dumps({"images": list(images)}))
        log = root / "calls.jsonl"
        script = SCRIPT.replace("${{ parameters.imageName }}", "test-service")
        script = script.replace("${{ parameters.dockerFile }}", "Dockerfile")
        script = script.replace("${{ parameters.directory }}", ".")
        values = dict(os.environ)
        values.update({
            "PATH": str(mock_bin) + os.pathsep + values["PATH"],
            "CALL_LOG": str(log), "MOCK_STATE": str(state), "MOCK_MODE": mode,
            "ACR_NAME_PARAMETER": " ", "ACR_SUBSCRIPTION_NAME_PARAMETER": " ",
            "TAG_NAME_PARAMETER": " ", "ACR_NAME_DEFAULT": "devimpinfac1401",
            "TAG_NAME_DEFAULT": "123.4", "DOCKER_FILE_PARAMETER": "Dockerfile",
            "DOCKER_HUB_USER": "mock-docker-user", "DOCKER_HUB_TOKEN": "mock-secret-token",
        })
        values.update(env or {})
        result = subprocess.run(["bash", "-c", script], cwd=root, env=values, text=True, capture_output=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertNotIn("mock-secret-token", result.stdout + result.stderr)
        self.assertNotIn("mock-docker-user", result.stdout + result.stderr)
        return result, calls, root

    def imports(self, calls):
        return [call for call in calls if call[:3] == ["az", "acr", "import"]]

    def test_three_actual_dockerfile_patterns_import_the_required_base(self):
        fixtures = [
            ("ARG IMAGE_ACR=docker.io\nFROM ${IMAGE_ACR}/defradigital/java:jre-21 AS builder\n", "defradigital/java:jre-21"),
            ("ARG IMAGE_ACR=docker.io\nARG IMAGE_REPOSITORY=defradigital/node\nARG IMAGE_TAG=latest-24\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG} AS production\n", "defradigital/node:latest-24"),
            ("ARG IMAGE_ACR=docker.io\nARG IMAGE_REPOSITORY=liquibase/liquibase\nARG IMAGE_TAG=4.33.0\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG}\n", "liquibase/liquibase:4.33.0"),
        ]
        for fixture, image in fixtures:
            with self.subTest(image=image):
                result, calls, _ = self.run_build(fixture)
                self.assertEqual(0, result.returncode, result.stderr)
                imports = self.imports(calls)
                self.assertEqual(1, len(imports))
                self.assertIn("docker.io/" + image, imports[0])
                self.assertIn(image, imports[0])
                self.assertNotIn("--force", imports[0])
                self.assertNotIn("--verbose", imports[0])
                build = next(call for call in calls if call[:2] == ["docker", "build"])
                self.assertEqual("IMAGE_ACR=devimpinfac1401.azurecr.io", build[-1])
                self.assertIn("test-service:123.4", build)
                self.assertEqual(["docker", "push", "devimpinfac1401.azurecr.io/ipaffs/test-service:123.4"], calls[-1])
                self.assertLess(calls.index(imports[0]), calls.index(build))

    def test_existing_tag_skips_import_without_dockerhub_credentials(self):
        result, calls, _ = self.run_build("ARG IMAGE_ACR=docker.io\nFROM $IMAGE_ACR/defradigital/java:jre-21\n", images=["defradigital/java:jre-21"], env={"DOCKER_HUB_USER": "", "DOCKER_HUB_TOKEN": ""})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.imports(calls))
        self.assertIn("already exists", result.stdout)

    def test_existing_repository_missing_tag_imports_new_dockerfile_version(self):
        result, calls, _ = self.run_build("ARG IMAGE_ACR=docker.io\nARG IMAGE_REPOSITORY=liquibase/liquibase\nARG IMAGE_TAG=4.34.0\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG}\n", images=["liquibase/liquibase:4.33.0"])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("liquibase/liquibase:4.34.0", self.imports(calls)[0])

    def test_fixed_public_bases_do_not_import_or_require_credentials(self):
        for base in ("eclipse-temurin:21-jre", "defradigital/node:latest-18", "liquibase/liquibase:5.0.4"):
            with self.subTest(base=base):
                result, calls, _ = self.run_build("ARG IMAGE_ACR=docker.io\nFROM " + base + "\n", env={"DOCKER_HUB_USER": "", "DOCKER_HUB_TOKEN": ""})
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual([], self.imports(calls))
                self.assertFalse(any(call[:3] == ["az", "acr", "repository"] for call in calls))

    def test_access_failures_are_not_treated_as_missing_tags(self):
        for mode in ("auth-failure", "registry-failure", "tag-failure"):
            with self.subTest(mode=mode):
                result, calls, _ = self.run_build("ARG IMAGE_ACR=docker.io\nFROM ${IMAGE_ACR}/defradigital/java:jre-21\n", images=["defradigital/java:jre-21"], mode=mode)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.imports(calls))
                self.assertFalse(any(call[0] == "docker" for call in calls))
                self.assertIn("refusing to import", result.stderr)

    def test_malformed_active_defaults_fail_before_any_azure_operation(self):
        fixtures = [
            "ARG IMAGE_REPOSITORY\nARG IMAGE_TAG=jre-21\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG}\n",
            "ARG IMAGE_REPOSITORY=defradigital/java\nARG IMAGE_TAG=$(touch marker)\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG}\n",
            "ARG IMAGE_REPOSITORY=defradigital/java\nARG IMAGE_TAG=;false\nFROM ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG}\n",
            "FROM ${IMAGE_ACR}/${OTHER_REPO}:latest\n",
            "FROM ${IMAGE_ACR:-docker.io}/defradigital/java:jre-21\n",
        ]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                result, calls, root = self.run_build(fixture)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], calls)
                self.assertIn("Unsupported IMAGE_ACR base", result.stderr)
                self.assertFalse((root / "marker").exists())

    def test_registry_connection_default_and_explicit_overrides(self):
        self.assertIn("azureSubscription: $(acrGroupsServiceConnection)", TEMPLATE)
        self.assertNotIn("azureSubscription: $(serviceConnection)", TEMPLATE)
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n")
        self.assertEqual(0, result.returncode, result.stderr)
        for call in calls:
            if call[:2] == ["az", "acr"]:
                self.assertIn("subscription-from-acr-connection", call)
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n", env={"ACR_NAME_PARAMETER": "overrideacr", "ACR_SUBSCRIPTION_NAME_PARAMETER": "override-subscription", "TAG_NAME_PARAMETER": "override-tag"})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any(call[:3] == ["az", "account", "show"] for call in calls))
        for call in calls:
            if call[:2] == ["az", "acr"]:
                self.assertIn("overrideacr", call)
                self.assertIn("override-subscription", call)
        self.assertEqual(["docker", "push", "overrideacr.azurecr.io/ipaffs/test-service:override-tag"], calls[-1])

    def test_import_failure_stops_build(self):
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n", mode="import-failure")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(1, len(self.imports(calls)))
        self.assertFalse(any(call[0] == "docker" for call in calls))
        self.assertIn("no verified tag", result.stderr)

    def test_successful_import_requires_readback(self):
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n", mode="unverified-import")
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any(call[0] == "docker" for call in calls))
        self.assertIn("could not be verified", result.stderr)

    def test_concurrent_import_conflict_accepts_verified_tag(self):
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n", mode="concurrent-import")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(self.imports(calls)))
        self.assertIn("published by another build", result.stdout)

    def test_multistage_deduplicates_and_ignores_stage_local_arg_defaults(self):
        result, calls, _ = self.run_build("ARG IMAGE_REPOSITORY='defradigital/java'\nARG IMAGE_TAG=jre-21\nFROM --platform=linux/amd64 ${IMAGE_ACR}/${IMAGE_REPOSITORY}:${IMAGE_TAG} AS build\nARG IMAGE_TAG=bad\nFROM ${IMAGE_ACR}/defradigital/java:jre-21 AS runtime\nFROM runtime AS final\n")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, len(self.imports(calls)))

    def test_missing_credentials_stop_required_import(self):
        result, calls, _ = self.run_build("FROM ${IMAGE_ACR}/defradigital/java:jre-21\n", env={"DOCKER_HUB_TOKEN": "$(dockerHubToken)"})
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.imports(calls))
        self.assertFalse(any(call[0] == "docker" for call in calls))
        self.assertIn("credentials are required", result.stderr)


unittest.main(verbosity=2)
PY
