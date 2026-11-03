#!/usr/bin/env python3
"""Synchronise variable=output mappings from one ARM deployment to one ADO group.

Read the deployment outputs and group once, validate the complete batch, then
write only changed variables. Azure DevOps redacts secret values, so existing
secret variables must be updated rather than compared. Writes remain sequential
and use the CLI's variable commands to preserve unrelated group variables.
Use --emit-output=variable for values required by downstream pipeline stages;
these are published only after the entire synchronisation succeeds.
"""

import json
import os
import re
import subprocess
import sys
import time


class SyncError(Exception):
    """A safe error message that contains no variable values or CLI output."""


REQUIRED_ENV = (
    "ADO_ORG_URL",
    "ADO_PROJECT",
    "ADO_GROUP_NAME",
    "DEPLOYMENT_NAME",
    "RESOURCE_GROUP",
    "SUBSCRIPTION_ID",
)
NAME = re.compile(r"[A-Za-z0-9_.-]+")


def parse_mappings(arguments):
    if not arguments:
        raise SyncError("Supply at least one variable=deploymentOutput mapping.")
    mappings = []
    targets = set()
    for index, argument in enumerate(arguments, start=1):
        parts = argument.split("=")
        if len(parts) != 2 or not all(NAME.fullmatch(part) for part in parts):
            raise SyncError(f"Mapping {index} must be variable=deploymentOutput identifiers.")
        target, source = parts
        if target.lower() in targets:
            raise SyncError(f"Duplicate target variable: {target}.")
        targets.add(target.lower())
        mappings.append((target, source))
    return mappings


def parse_arguments(arguments):
    emit = []
    mapping_arguments = []
    for argument in arguments:
        if argument.startswith("--emit-output="):
            emit.append(argument.removeprefix("--emit-output="))
        else:
            mapping_arguments.append(argument)
    mappings = parse_mappings(mapping_arguments)
    targets = {target.lower(): target for target, _ in mappings}
    if any(not NAME.fullmatch(target) or target.lower() not in targets for target in emit):
        raise SyncError("Each --emit-output must name a mapped target variable.")
    if len({target.lower() for target in emit}) != len(emit):
        raise SyncError("Duplicate --emit-output target.")
    return mappings, [targets[target.lower()] for target in emit]


def escape_logging_value(value):
    return value.replace("%", "%AZP25").replace("\r", "%0D").replace("\n", "%0A")


def run_az(arguments, environ, operation, read_json=False):
    """Capture all CLI output; errors can contain output values or credentials."""
    try:
        result = subprocess.run(
            ["az", *arguments, "--only-show-errors"],
            env=environ,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except (OSError, UnicodeError):
        raise SyncError(f"{operation}: could not execute Azure CLI.") from None
    if result.returncode:
        raise SyncError(f"{operation} failed (exit {result.returncode}).")
    if read_json:
        try:
            return json.loads(result.stdout)
        except (ValueError, UnicodeError):
            raise SyncError(f"{operation}: Azure CLI returned invalid JSON.") from None


def read_group(environ, ado_arguments):
    groups = run_az(
        ["pipelines", "variable-group", "list", *ado_arguments,
         "--group-name", environ["ADO_GROUP_NAME"], "--output", "json"],
        environ,
        "Read variable group",
        read_json=True,
    )
    if not isinstance(groups, list) or any(
        not isinstance(group, dict) or not isinstance(group.get("name"), str)
        for group in groups
    ):
        raise SyncError("Read variable group: expected a list of named groups.")
    matches = [
        group for group in groups
        if group["name"].lower() == environ["ADO_GROUP_NAME"].lower()
    ]
    if len(matches) != 1:
        raise SyncError("Read variable group: expected exactly one exact name match.")
    group = matches[0]
    group_id = group.get("id")
    if isinstance(group_id, bool) or not isinstance(group_id, (int, str)) or not re.fullmatch(
        r"[1-9][0-9]*", str(group_id)
    ):
        raise SyncError("Read variable group: invalid group ID.")
    if group.get("type", "Vsts") != "Vsts":
        raise SyncError("Read variable group: only Vsts variable groups can be updated.")
    # Group list includes variables; if a response omits them, fetch once here
    # rather than once per output.
    variables = group.get("variables")
    if variables is None:
        variables = run_az(
            ["pipelines", "variable-group", "variable", "list", *ado_arguments,
             "--id", str(group_id), "--output", "json"],
            environ,
            "Read group variables",
            read_json=True,
        )
    if not isinstance(variables, dict):
        raise SyncError("Read group variables: expected an object.")
    by_name = {}
    for name, variable in variables.items():
        if not isinstance(name, str) or not NAME.fullmatch(name) or not isinstance(variable, dict):
            raise SyncError("Read group variables: invalid variable metadata.")
        if name.lower() in by_name:
            raise SyncError("Read group variables: duplicate names ignoring case.")
        if variable.get("isSecret") is not None and not isinstance(variable["isSecret"], bool):
            raise SyncError("Read group variables: invalid secret metadata.")
        value = variable.get("value")
        if value is not None and not isinstance(value, str):
            raise SyncError("Read group variables: invalid variable value type.")
        by_name[name.lower()] = (name, variable)
    return str(group_id), by_name


def sync(mappings, environ, counts, emit=()):
    for name in REQUIRED_ENV:
        if not environ.get(name, "").strip():
            raise SyncError(f"Required environment variable is missing: {name}.")
    outputs = run_az(
        ["deployment", "group", "show", "--name", environ["DEPLOYMENT_NAME"],
         "--subscription", environ["SUBSCRIPTION_ID"],
         "--resource-group", environ["RESOURCE_GROUP"],
         "--query", "properties.outputs", "--output", "json"],
        environ,
        "Read deployment outputs",
        read_json=True,
    )
    if not isinstance(outputs, dict):
        raise SyncError("Read deployment outputs: expected an object.")
    values = []
    for target, source in mappings:
        output = outputs.get(source)
        value = output.get("value") if isinstance(output, dict) else None
        if not isinstance(value, str) or not value.strip() or "\0" in value:
            raise SyncError(f"Output {source} for variable {target} must be a nonblank string.")
        values.append((target, value))

    ado_arguments = ["--org", environ["ADO_ORG_URL"], "--project", environ["ADO_PROJECT"]]
    group_id, existing = read_group(environ, ado_arguments)
    for target, value in values:
        current = existing.get(target.lower())
        if current:
            name, metadata = current
            secret = metadata.get("isSecret") is True
            if not secret and metadata.get("value") == value:
                counts["unchanged"] += 1
                continue
            action = "update"
        else:
            name, secret, action = target, False, "create"
        arguments = [
            "pipelines", "variable-group", "variable", action, *ado_arguments,
            "--id", group_id, "--name", name, "--output", "none",
        ]
        command_env = environ
        if secret:
            # The extension reads this value without exposing it in argv. It
            # redacts secrets when reading, so they cannot be compared above.
            command_env = dict(environ)
            command_env[f"AZURE_DEVOPS_EXT_PIPELINE_VAR_{name}"] = value
            arguments.extend(["--secret", "true", "--prompt-value", "true"])
        else:
            arguments.append(f"--value={value}")
            if action == "create":
                arguments.extend(["--secret", "false"])
        try:
            run_az(arguments, command_env, f"{action.capitalize()} variable {name}")
        except SyncError:
            counts["failed"] += 1
            raise
        counts["updated" if action == "update" else "created"] += 1

    # Publish only after every requested write succeeds. An unchanged value is
    # still needed by consumers in this run. Other values stay out of the log.
    values_by_target = dict(values)
    for target in emit:
        current = existing.get(target.lower())
        secret = current is not None and current[1].get("isSecret") is True
        properties = f"variable={target};isOutput=true"
        if secret:
            properties += ";issecret=true"
        print(f"##vso[task.setvariable {properties}]{escape_logging_value(values_by_target[target])}")


def main(argv=None, environ=None):
    arguments = sys.argv[1:] if argv is None else argv
    environ = dict(os.environ if environ is None else environ)
    started = time.monotonic()
    counts = dict(requested=len(arguments), updated=0, created=0, unchanged=0, failed=0)
    try:
        mappings, emit = parse_arguments(arguments)
        counts["requested"] = len(mappings)
        sync(mappings, environ, counts, emit)
        return 0
    except SyncError as error:
        print(f"Deployment output sync failed: {error}", file=sys.stderr)
        return 1
    finally:
        summary = " ".join(f"{name}={value}" for name, value in counts.items())
        print(f"Deployment output sync: {summary} elapsed={time.monotonic() - started:.2f}s")


if __name__ == "__main__":
    sys.exit(main())
