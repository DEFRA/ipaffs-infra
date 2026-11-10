#!/usr/bin/env python3
"""Preview an immutable infrastructure revision without invoking any apply commands.

Raw parameters and ARM responses live only in the private state directory. Only
the report module's sanitised plan.json and summary.md are published.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

from infrastructure_parameters import (COMPONENTS, ENVIRONMENT_VARIABLES, SUBNETS, render,
                                       validate_existing_network_security_group_names)
from infrastructure_plan_report import write_environment_report


ROOT = Path(__file__).resolve().parents[2]
LABELS = {"resource-group": "Resource group", "network": "Network", "acr": "Container registry",
          "classic": "Classic services", "infra": "Infrastructure", "privatelink": "Private Link"}
SCOPES = {"modern": ("resource-group", "network", "acr", "infra", "privatelink"),
          "classic": ("classic",)}


class PlanError(Exception):
    """Only fixed error codes, never Azure/parameter contents, leave the runner."""


def az_json(arguments, timeout=900):
    # There is deliberately no generic shell/command option. Keep this allowlist
    # narrower than the credentials: accidentally adding an apply fails closed.
    allowed = (arguments[:1] == ["version"] or
               arguments[:2] == ["bicep", "build-params"] or
               (len(arguments) == 9 and arguments[:4] == ["network", "nsg", "list", "--subscription"]
                and arguments[5] == "--resource-group" and arguments[7:] == ["--query", "[].name"]) or
               arguments[:3] in (["deployment", "group", "what-if"],
                                 ["deployment", "sub", "what-if"]))
    if not allowed:
        raise PlanError("COMMAND_NOT_ALLOWED")
    try:
        result = subprocess.run(["az", *arguments, "--only-show-errors", "--output", "json"],
                                cwd=ROOT, capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise PlanError("AZURE_COMMAND_FAILED")
        return json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        raise PlanError("AZURE_RESPONSE_UNAVAILABLE") from None


def required(environ, name):
    value = environ.get(name, "").strip()
    if not value or "$" in value or any(ord(c) < 32 for c in value):
        raise PlanError("MISSING_INPUT")
    return value


def resource_id(subscription, group, kind, name):
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.()-]+", name):
        raise PlanError("UNRESOLVED_RESOURCE_NAME")
    return f"/subscriptions/{subscription}/resourceGroups/{group}/providers/{kind}/{name}"


def parameter_values(environ):
    values = {name: environ[variable] for name, variable in ENVIRONMENT_VARIABLES.items()
              if variable in environ}
    values.setdefault("parameterSqlAdminGroupId", values.get("sqlAdminGroupId", ""))
    values.setdefault("parameterSqlAdminGroupName", values.get("sqlAdminGroupName", ""))
    return values


def compile_parameters(component, environment, values, private_dir):
    # Runtime .bicepparam files must sit beside their using/extends targets. A
    # unique, private file avoids rewriting a deployment's parameter artifact.
    descriptor, filename = tempfile.mkstemp(prefix=".preview-", suffix=".bicepparam", dir=ROOT / "bicep")
    path = Path(filename)
    try:
        os.chmod(path, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(render(component, environment, values))
        compiled = az_json(["bicep", "build-params", "--file", str(path), "--stdout"], timeout=120)
        parameters = json.loads(compiled["parametersJson"])
        template = json.loads(compiled["templateJson"])
        template_path, parameter_path = private_dir / f"{component}.template.json", private_dir / f"{component}.parameters.json"
        for destination, content in ((template_path, template), (parameter_path, parameters)):
            destination.write_text(json.dumps(content), encoding="utf-8")
            destination.chmod(0o600)
        return parameters["parameters"], template_path, parameter_path
    except (ValueError, KeyError, TypeError):
        raise PlanError("PARAMETER_RESOLUTION_FAILED") from None
    finally:
        path.unlink(missing_ok=True)


def value(parameters, name):
    try:
        return parameters[name]["value"]
    except (KeyError, TypeError):
        raise PlanError("PARAMETER_RESOLUTION_FAILED") from None


def desired_inputs(environment, values, environ, private_dir):
    """Use proposed names/IDs rather than silently planning against old subnets."""
    updated = dict(values)
    subscription = required(environ, "PLATFORM_SUBSCRIPTION_ID")
    group = required(environ, "PLATFORM_RESOURCE_GROUP")
    network, _, _ = compile_parameters("network", environment, updated, private_dir)
    vnet, subnet_names = value(network, "vnetParams"), value(network, "subnetNames")
    try:
        vnet_id = resource_id(subscription, group, "Microsoft.Network/virtualNetworks", vnet["name"])
        declared = {subnet["name"] for subnet in vnet["subnets"]}
        for prefix in SUBNETS:
            name = subnet_names[prefix]
            if name not in declared or not re.fullmatch(r"[A-Za-z0-9_.()-]+", name):
                raise PlanError("UNRESOLVED_SUBNET")
            updated[prefix + "SubnetName"] = name
            updated[prefix + "SubnetId"] = vnet_id + "/subnets/" + name
    except (KeyError, TypeError):
        raise PlanError("PARAMETER_RESOLUTION_FAILED") from None
    return updated


def scope_for(component, environ):
    classic = component in SCOPES["classic"]
    subscription = required(environ, "PLATFORM_CLASSIC_SUBSCRIPTION_ID" if classic else "PLATFORM_SUBSCRIPTION_ID")
    try:
        uuid.UUID(subscription)
    except ValueError:
        raise PlanError("INVALID_SUBSCRIPTION") from None
    if component == "resource-group":
        return {"kind": "subscription", "subscriptionId": subscription,
                "location": required(environ, "PLATFORM_LOCATION")}
    return {"kind": "resourceGroup", "subscriptionId": subscription,
            "resourceGroup": required(environ, "PLATFORM_CLASSIC_RESOURCE_GROUP" if classic else "PLATFORM_RESOURCE_GROUP")}


def preview(component, environment, values, environ, private_dir, build_id):
    scope = scope_for(component, environ)
    if component == "network":
        # A fresh, names-only read controls parent bootstrap in this actual plan.
        # Compile-only desired_inputs deliberately does not read Modern resources,
        # so Classic credentials need no cross-subscription NSG access.
        names = az_json(["network", "nsg", "list", "--subscription", scope["subscriptionId"],
                         "--resource-group", scope["resourceGroup"], "--query", "[].name"], timeout=60)
        try:
            names = validate_existing_network_security_group_names(names)
        except ValueError:
            raise PlanError("INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES") from None
        values = {**values, "existingNetworkSecurityGroupNames": names}
    _, template, parameters = compile_parameters(component, environment, values, private_dir)
    arguments = ["deployment", "sub" if scope["kind"] == "subscription" else "group", "what-if",
                 "--subscription", scope["subscriptionId"], "--name", f"Preview-{component}-{build_id}",
                 "--template-file", str(template), "--parameters", "@" + str(parameters),
                 "--no-pretty-print", "--result-format", "FullResourcePayloads"]
    arguments += (["--location", scope["location"]] if scope["kind"] == "subscription"
                  else ["--resource-group", scope["resourceGroup"]])
    result = az_json(arguments)
    if (not isinstance(result, dict) or result.get("status") != "Succeeded"
            or not isinstance(result.get("changes"), list)
            or not all(isinstance(change, dict) for change in result["changes"])):
        raise PlanError("WHAT_IF_INCOMPLETE")
    digest = hashlib.sha256(template.read_bytes() + parameters.read_bytes()).hexdigest()
    return {"name": component, "label": LABELS[component], "scope": scope,
            "status": "complete", "result": result, "inputDigest": digest}


def initial_state(args):
    return {"metadata": {"environment": args.environment, "commit": args.commit,
                         "sourceRef": args.source_ref, "buildId": args.build_id,
                         "generatedAt": datetime.now(timezone.utc).isoformat(),
                         "parameterSource": "Candidate repository parameters, derived desired resource IDs, and current Library identity contract"},
            "components": [{"name": name, "label": LABELS[name], "status": "not-applicable" if name == "acr" and args.environment == "TST" else "blocked",
                            "errorCode": "NOT_RUN", "scope": "Not evaluated"} for name in COMPONENTS]}


def publish(state, args):
    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.state_dir.chmod(0o700)
    path = args.state_dir / "state.json"
    path.write_text(json.dumps(state), encoding="utf-8")
    path.chmod(0o600)
    write_environment_report(args.output_dir, state["metadata"], state["components"])


def run(args, environ):
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", args.commit) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", args.build_id):
        raise PlanError("INVALID_SOURCE_IDENTITY")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if head.lower() != args.commit.lower():
        raise PlanError("SOURCE_COMMIT_MISMATCH")
    if not args.state_dir.is_absolute() or not args.output_dir.is_absolute():
        raise PlanError("INVALID_OUTPUT_DIRECTORY")
    args.state_dir, args.output_dir = args.state_dir.resolve(), args.output_dir.resolve()
    # Never allow raw state or generated credentials/parameters into artifacts.
    if args.state_dir == args.output_dir or args.output_dir in args.state_dir.parents or args.state_dir in args.output_dir.parents:
        raise PlanError("PRIVATE_STATE_OVERLAPS_REPORT")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    state_path = args.state_dir / "state.json"
    state = initial_state(args) if args.initialize or not state_path.exists() else json.loads(state_path.read_text())
    if any(state["metadata"][key] != expected for key, expected in (
        ("environment", args.environment), ("commit", args.commit), ("sourceRef", args.source_ref), ("buildId", args.build_id))):
        raise PlanError("PREVIEW_STATE_MISMATCH")
    publish(state, args)
    if args.initialize:
        return 0
    selected = SCOPES[args.scope]
    # A retried scope must not publish a previous attempt's results.
    for index, item in enumerate(state["components"]):
        if item["name"] in selected and item["status"] != "not-applicable":
            state["components"][index] = {"name": item["name"], "label": LABELS[item["name"]],
                                          "status": "blocked", "errorCode": "NOT_RUN", "scope": "Not evaluated"}
    publish(state, args)
    values = parameter_values(environ)
    if args.environment != "TST":
        values["qaAutomationServiceConnectionPrincipalId"] = ""
    try:
        version = az_json(["version"], timeout=30)["azure-cli"]
        # 2.75 exposes incomplete-analysis diagnostics. Keep ARM's default full
        # validation: --validation-level was introduced only in CLI 2.76.
        if tuple(int(number) for number in version.split(".")[:2]) < (2, 75):
            raise PlanError("AZURE_CLI_TOO_OLD")
        values = desired_inputs(args.environment, values, environ, args.state_dir)
    except (PlanError, KeyError, ValueError, TypeError) as error:
        code = str(error) if isinstance(error, PlanError) else "PARAMETER_RESOLUTION_FAILED"
        for item in state["components"]:
            if item["name"] in selected and item["status"] != "not-applicable":
                item.update(status="blocked", errorCode=code)
        publish(state, args)
        return 1
    failed = False
    for component in selected:
        index = next(index for index, item in enumerate(state["components"]) if item["name"] == component)
        if state["components"][index]["status"] == "not-applicable":
            continue
        try:
            state["components"][index] = preview(component, args.environment, values, environ, args.state_dir, args.build_id)
        except (PlanError, ValueError, OSError) as error:
            failed = True
            code = str(error) if isinstance(error, PlanError) else "PARAMETER_RESOLUTION_FAILED"
            state["components"][index].update(status="failed", errorCode=code)
        publish(state, args)
        print(f"{args.environment} {LABELS[component]}: {state['components'][index]['status']}")
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True, choices=("DEV", "TST", "PRE", "PRD"))
    parser.add_argument("--scope", choices=SCOPES)
    parser.add_argument("--initialize", action="store_true")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--build-id", required=True)
    args = parser.parse_args()
    if not args.initialize and not args.scope:
        parser.error("--scope is required unless --initialize is used")
    os.umask(0o077)
    try:
        return run(args, os.environ)
    except (PlanError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, PlanError) else "PREVIEW_FAILED"
        print(f"Infrastructure preview could not complete: {code}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
