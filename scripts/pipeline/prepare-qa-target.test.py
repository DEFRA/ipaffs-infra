#!/usr/bin/env python3
"""Check QA target isolation and dotenv transport without accessing an environment."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("qa_target", Path(__file__).with_name("prepare-qa-target.py"))
target = importlib.util.module_from_spec(spec)
spec.loader.exec_module(target)
context_spec = importlib.util.spec_from_file_location("qa_context", Path(__file__).with_name("write-qa-run-context.py"))
qa_context = importlib.util.module_from_spec(context_spec)
context_spec.loader.exec_module(qa_context)


class TargetTests(unittest.TestCase):
    def feature(self):
        return {
            "QA_ENVIRONMENT": "DEV",
            "QA_FEATURE_NAMESPACE": "true",
            "QA_TARGET_NAMESPACE": "imta-21857",
            **{key: f"https://{key.lower().replace('_', '-')}-imta-21857.example.test" for key in target.FEATURE_URLS},
        }

    def test_canonical_environments_keep_defaults(self):
        for environment in ("DEV", "TST"):
            with self.subTest(environment=environment):
                self.assertEqual(
                    target.resolve_target({"QA_ENVIRONMENT": environment}),
                    (environment.lower(), environment.lower(), False, {}),
                )

    def test_feature_uses_dev_settings_and_explicit_endpoints(self):
        environment, namespace, feature, overrides = target.resolve_target(self.feature())
        self.assertEqual((environment, namespace, feature), ("dev", "imta-21857", True))
        self.assertEqual(set(overrides), set(target.FEATURE_URLS))

    def test_feature_requires_every_local_endpoint(self):
        for key in target.FEATURE_URLS:
            values = self.feature()
            values[key] = " "
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                target.resolve_target(values)

    def test_feature_rejects_missing_canonical_or_invalid_namespace(self):
        for namespace in ("", "dev", "tst", "pre", "prd", "Bad_Name", "-start", "a" * 35):
            values = self.feature()
            values["QA_TARGET_NAMESPACE"] = namespace
            with self.subTest(namespace=namespace), self.assertRaises(ValueError):
                target.resolve_target(values)

    def test_feature_rejects_non_dev_credentials(self):
        values = self.feature()
        values["QA_ENVIRONMENT"] = "TST"
        with self.assertRaises(ValueError):
            target.resolve_target(values)

    def test_frontend_urls_cannot_contain_an_application_path(self):
        values = self.feature()
        values["B2B_BASE_URL"] += "/notification/dev"
        with self.assertRaisesRegex(ValueError, "origin without an application path"):
            target.resolve_target(values)

    def test_urls_cannot_inject_dotenv_or_embed_credentials(self):
        for url in ("not a URL", "file:///etc/passwd", "https://user:pass@example.test", "https://example.test?token=secret", "https://example.test/#fragment", "https://example.test\nENV=prd", "https://example.test:99999", "https://example.test/a b"):
            values = self.feature()
            values["B2B_BASE_URL"] = url
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "B2B_BASE_URL"):
                target.resolve_target(values)

    def test_url_paths_and_optional_dev_integration_override(self):
        values = self.feature()
        values["OPEN_ID_TOKEN_URL"] = " https://token.example.test/ad/sign "
        values["NOTIFICATION_BASE_URL"] = "https://notification.example.test/notifications"
        values["RISK_ENGINE_BASE_URL"] = "https://risk.example.test"
        overrides = target.resolve_target(values)[3]
        self.assertEqual(overrides["OPEN_ID_TOKEN_URL"], "https://token.example.test/ad/sign")
        self.assertEqual(overrides["NOTIFICATION_BASE_URL"], values["NOTIFICATION_BASE_URL"])
        self.assertIn("RISK_ENGINE_BASE_URL", overrides)

    def test_cli_writes_only_configuration_and_keeps_secret_values_out(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "target.env"
            values = {**self.feature(), "SECRET_PASSWORD": "must-not-be-written"}
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("prepare-qa-target.py")), str(destination)],
                env=values, capture_output=True, text=True, check=True,
            )
            entries = dict(line.split("=", 1) for line in destination.read_text().splitlines())
            self.assertEqual(entries, {"ENV": "dev", **{key: values[key] for key in target.FEATURE_URLS}})
            self.assertNotIn("must-not-be-written", destination.read_text() + result.stdout)
            self.assertIn("variable=qaTargetNamespace]imta-21857", result.stdout)

    def test_feature_context_does_not_claim_deployment_provenance(self):
        with patch.dict(os.environ, {**self.feature(), "QA_BUILD_REASON": "Manual", "QA_TEST_SUITE": "test"}, clear=True):
            context = qa_context.context()
        self.assertEqual(context["targetKind"], "feature")
        self.assertEqual(context["targetNamespace"], "imta-21857")
        self.assertEqual(set(context["targetUrlOverrides"]), set(target.FEATURE_URLS))
        self.assertIsNone(context["triggeringDeployment"])
        self.assertFalse(context["deployedVersionVerified"])
        json.dumps(context)


if __name__ == "__main__":
    unittest.main()
