#!/usr/bin/env python3
"""Review or refresh only the classic Service Bus namespace Library contract."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


VARIABLE_NAMES = (
    "classicServiceBusNamespaceName",
    "classicServiceBusNamespaceResourceId",
)
ENVIRONMENTS = {"DEV": "snd", "TST": "tst", "PRE": "pre", "PRD": "prd"}
REPAIR_BRANCH = "refs/heads/codex/refresh-classic-monitoring-outputs"
REPAIR_ENVIRONMENT = "PRE"
REPAIR_SUBSCRIPTION = "81ca326e-6270-418a-b764-e02a4ca60457"
REPAIR_RESOURCE_GROUP = "PREIMPINFRGP001"
REPAIR_NAMESPACE = "PREIMPINFSBS003"


def run_az(arguments):
    """Capture CLI output without logging unrelated Library values or credentials."""
    result = subprocess.run(
        ["az", *arguments, "--only-show-errors"],
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise ValueError(f"Azure CLI operation failed: {' '.join(arguments[:3])}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def required(values, name):
    value = values.get(name, "").strip()
    if not value or "$(" in value:
        raise ValueError(f"{name} must be supplied by the existing environment contract")
    return value


def desired_namespace(environment, repo_root, run):
    parameter_file = repo_root / "bicep" / "envs" / ENVIRONMENTS[environment] / "30-classic.bicepparam"
    with tempfile.TemporaryDirectory(prefix="classic-monitoring-params-") as directory:
        compiled = Path(directory) / "parameters.json"
        run(["bicep", "build-params", "--file", str(parameter_file), "--outfile", str(compiled)])
        with compiled.open(encoding="utf-8") as handle:
            parameters = json.load(handle)
    namespace = parameters.get("parameters", {}).get("serviceBusParams", {}).get("value", {}).get("namespaceName")
    if not isinstance(namespace, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]", namespace):
        raise ValueError("Compiled classic parameters must contain a valid serviceBusParams.namespaceName")
    return namespace


def markdown(value):
    return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ").replace("`", "'")


def summary_text(environment, mode, old, desired, applied=False):
    status = "Applied and read back" if applied else (
        "Apply requested; writes and readback have not completed. If this run failed, review the current values before retrying"
        if mode == "apply" else "Plan only; no changes applied"
    )
    lines = [f"# {environment}: classic monitoring outputs", "", status + ".", ""]
    changed = [name for name in VARIABLE_NAMES if old[name] != desired[name]]
    if changed:
        lines += ["| Library variable | Current value | Proposed value |", "| --- | --- | --- |"]
        lines += [f"| {name} | `{markdown(old[name])}` | `{markdown(desired[name])}` |" for name in changed]
    else:
        lines.append("Both Library outputs already match the configured, existing namespace.")
    lines += ["", f"Validated namespace: `{markdown(desired[VARIABLE_NAMES[1]])}`.", "",
              "Only the two existing Service Bus Library outputs are in scope. No Azure deployment or role assignment is performed.", ""]
    return "\n".join(lines)


def refresh(environment, mode, summary, repo_root, values=None, run=run_az):
    values = os.environ if values is None else values
    if environment not in ENVIRONMENTS or mode not in ("plan", "apply"):
        raise ValueError("Unsupported environment or mode")
    # Enforce the write boundary here, even when the script is invoked outside YAML.
    if mode == "apply" and (
        environment != REPAIR_ENVIRONMENT
        or values.get("BUILD_SOURCEBRANCH") != REPAIR_BRANCH
        or values.get("BUILD_REASON") != "Manual"
    ):
        raise ValueError(f"Apply requires an explicitly requested manual {REPAIR_ENVIRONMENT} run from {REPAIR_BRANCH}")

    subscription = required(values, "CLASSIC_SUBSCRIPTION_ID")
    try:
        if uuid.UUID(subscription).int == 0:
            raise ValueError()
    except ValueError as error:
        raise ValueError("CLASSIC_SUBSCRIPTION_ID must be a non-nil subscription UUID") from error
    resource_group = required(values, "CLASSIC_RESOURCE_GROUP")
    if not re.fullmatch(r"[A-Za-z0-9_.()-]{1,90}", resource_group):
        raise ValueError("CLASSIC_RESOURCE_GROUP must be a resource group name")
    if mode == "apply" and (
        subscription.casefold() != REPAIR_SUBSCRIPTION
        or resource_group.casefold() != REPAIR_RESOURCE_GROUP.casefold()
    ):
        raise ValueError("Apply is restricted to the reviewed PRE classic subscription and resource group")
    organization = required(values, "ADO_ORG_URL")
    project = required(values, "ADO_PROJECT")
    required(values, "AZURE_DEVOPS_EXT_PAT")

    namespace = desired_namespace(environment, Path(repo_root), run)
    if mode == "apply" and namespace != REPAIR_NAMESPACE:
        raise ValueError(f"Apply is restricted to the reviewed namespace {REPAIR_NAMESPACE}; rerun plan and review source changes")
    expected_id = (
        f"/subscriptions/{subscription}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.ServiceBus/namespaces/{namespace}"
    )
    resource = run([
        "resource", "show", "--subscription", subscription, "--ids", expected_id,
        "--api-version", "2024-01-01", "--query", "{id:id,name:name,type:type}", "--output", "json",
    ])
    if not isinstance(resource, dict) or any(
        str(resource.get(key, "")).casefold() != expected.casefold()
        for key, expected in (("id", expected_id), ("name", namespace), ("type", "Microsoft.ServiceBus/namespaces"))
    ):
        raise ValueError("Configured namespace is missing or its live ARM ID does not match the classic subscription/resource group")

    common = ["--org", organization, "--project", project]
    groups = run([
        "pipelines", "variable-group", "list", *common, "--group-name", environment,
        "--query", "[].{id:id,name:name,type:type}", "--output", "json",
    ])
    groups = [group for group in groups or [] if group.get("name") == environment]
    if len(groups) != 1 or groups[0].get("type") != "Vsts" or not isinstance(groups[0].get("id"), int):
        raise ValueError(f"Require exactly one existing writable Library variable group named {environment}")
    group_id = str(groups[0]["id"])
    query = "{" + ",".join(f"{name}:{name}" for name in VARIABLE_NAMES) + "}"

    def read_variables():
        selected = run([
            "pipelines", "variable-group", "variable", "list", *common, "--group-id", group_id,
            "--query", query, "--output", "json",
        ])
        if not isinstance(selected, dict):
            raise ValueError("Unable to read the two existing Library outputs")
        result = {}
        for name in VARIABLE_NAMES:
            variable = selected.get(name)
            if not isinstance(variable, dict) or variable.get("isSecret") is True or not isinstance(variable.get("value"), str):
                raise ValueError(f"Existing non-secret Library variable {name} is required; no variables will be created")
            result[name] = variable["value"]
        return result

    old = read_variables()
    desired = {VARIABLE_NAMES[0]: namespace, VARIABLE_NAMES[1]: resource["id"]}
    summary = Path(summary)
    summary.parent.mkdir(parents=True, exist_ok=True)
    summary.write_text(summary_text(environment, mode, old, desired), encoding="utf-8")
    if mode == "apply":
        for name in VARIABLE_NAMES:
            if old[name] != desired[name]:
                run([
                    "pipelines", "variable-group", "variable", "update", *common, "--group-id", group_id,
                    "--name", name, "--value", desired[name], "--output", "none",
                ])
        if read_variables() != desired:
            raise ValueError("Library readback did not match the two intended outputs; review before rerunning")
        summary.write_text(summary_text(environment, mode, old, desired, applied=True), encoding="utf-8")
    print(summary.read_text(encoding="utf-8"))
    return desired


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=ENVIRONMENTS, required=True)
    parser.add_argument("--mode", choices=("plan", "apply"), default="plan")
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    try:
        refresh(args.environment, args.mode, args.summary, Path(__file__).resolve().parents[2])
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"Classic monitoring outputs were not verified: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
