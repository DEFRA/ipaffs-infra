#!/usr/bin/env python3
"""Validate a QA target and write non-secret overrides for the runner container."""

import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


FEATURE_URLS = (
    "B2B_BASE_URL",
    "B2C_BASE_URL",
    "SOAP_BASE_URL",
    "OPEN_ID_TOKEN_URL",
    "BIP_BASE_URL",
    "NOTIFICATION_BASE_URL",
)
URL_OVERRIDES = (*FEATURE_URLS, "RISK_ENGINE_BASE_URL")


def resolve_target(environ):
    environment = environ.get("QA_ENVIRONMENT", "").strip().lower()
    if environment not in ("dev", "tst"):
        raise ValueError("QA_ENVIRONMENT must be DEV or TST")
    feature = environ.get("QA_FEATURE_NAMESPACE", "false").lower() == "true"
    namespace = environ.get("QA_TARGET_NAMESPACE", "").strip() or environment
    if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]{0,61}[a-z0-9])?", namespace):
        raise ValueError("Target namespace must be a valid Kubernetes namespace")
    if feature and (
        environment != "dev"
        or namespace in ("dev", "tst", "pre", "prd")
        or len(namespace) > 34
    ):
        raise ValueError("FTR requires DEV settings and a noncanonical namespace of at most 34 characters")

    overrides = {}
    for name in URL_OVERRIDES:
        value = environ.get(name, "").strip()
        if not value:
            if feature and name in FEATURE_URLS:
                raise ValueError(f"{name} is required for FTR")
            continue
        try:
            url = urlsplit(value)
            valid = (
                url.scheme in ("http", "https")
                and url.hostname
                and not url.username
                and not url.password
                and not url.query
                and not url.fragment
                and not re.search(r"\s", value)
            )
            # Accessing port also checks malformed or out-of-range port numbers.
            url.port
        except ValueError:
            valid = False
        if not valid:
            raise ValueError(f"{name} must be an HTTP(S) URL without credentials, query or fragment")
        if name in ("B2B_BASE_URL", "B2C_BASE_URL") and url.path not in ("", "/"):
            raise ValueError(f"{name} must be an origin without an application path")
        overrides[name] = value
    return environment, namespace, feature, overrides


def main():
    environment, namespace, feature, overrides = resolve_target(os.environ)
    destination = Path(sys.argv[1])
    destination.write_text("\n".join(f"{name}={value}" for name, value in {
        "ENV": environment,
        **overrides,
    }.items()) + "\n")
    print(f"QA target: {'FTR' if feature else environment.upper()} / {namespace}")
    print(f"##vso[task.setvariable variable=qaTargetNamespace]{namespace}")


if __name__ == "__main__":
    main()
