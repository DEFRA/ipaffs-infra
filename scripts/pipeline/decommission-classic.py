#!/usr/bin/env python3
"""Plan and delete an ordered allowlist of Classic Azure resources."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time


GUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
PROVIDER = r"[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+"
NAME = r"(?!\.{1,2}(?:/|$))[a-z0-9_.()-]+"
TYPE_AND_NAME = rf"/(?!providers/)[a-z][a-z0-9]*/{NAME}"
RESOURCE_ID = re.compile(
    rf"/subscriptions/(?P<subscription>{GUID})/resourceGroups/{NAME}"
    rf"/providers/{PROVIDER}(?:{TYPE_AND_NAME})+"
    rf"(?:/providers/{PROVIDER}(?:{TYPE_AND_NAME})+)*",
    re.IGNORECASE | re.ASCII,
)
ABSENT_CODES = r"ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|NotFound"
ABSENT_ERROR = re.compile(rf"^ERROR: \(({ABSENT_CODES})\)(?: |$)", re.MULTILINE)
ABSENT_DELETE_DETAIL = re.compile(rf"^INFO: \(({ABSENT_CODES})\)(?: |$)", re.MULTILINE)
VERIFY_ATTEMPTS = 6
VERIFY_INTERVAL = 10
APP_SITE = "microsoft.web/sites"
APP_SLOT = "microsoft.web/sites/slots"
APP_SERVICE_TYPES = {APP_SITE, APP_SLOT}


class DecommissionError(Exception):
    pass


def read_resources(path, subscription):
    resources = []
    seen = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        resource_id = line.strip()
        if not resource_id or resource_id.startswith("#"):
            continue
        match = RESOURCE_ID.fullmatch(resource_id)
        if not match:
            raise DecommissionError(f"{path}:{number}: expected a full resource ID scoped to a resource group")
        if match["subscription"].lower() != subscription:
            raise DecommissionError(f"{path}:{number}: resource belongs to a different subscription")
        key = resource_id.lower()
        if key in seen:
            raise DecommissionError(f"{path}:{number}: duplicate resource ID {resource_id}")
        seen.add(key)
        resources.append(resource_id)
    return resources


def resource_type(resource_id):
    # Extension resources have a provider of their own. A resource name may
    # also be "providers", so only inspect the type positions.
    parts = resource_id.split("/")
    provider = max(index for index in range(5, len(parts), 2) if parts[index].lower() == "providers")
    return "/".join([parts[provider + 1], *parts[provider + 2::2]])


def run_az(arguments, operation, timeout=120):
    try:
        return subprocess.run(["az", *arguments], text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise DecommissionError(f"{operation}: Azure CLI timed out after {timeout}s") from exc
    except OSError as exc:
        raise DecommissionError(f"{operation}: could not run Azure CLI: {exc}") from exc


def require_success(result, operation):
    if result.returncode:
        detail = result.stderr.strip() or f"Azure CLI exited with status {result.returncode}"
        raise DecommissionError(f"{operation}: {detail}")


def read_azure_json(result, operation):
    require_success(result, operation)
    try:
        return json.loads(result.stdout)
    except ValueError as exc:
        raise DecommissionError(f"{operation}: Azure CLI returned invalid JSON") from exc


def verify_subscription(subscription):
    operation = f"Verify subscription {subscription}"
    result = run_az([
        "account", "show", "--subscription", subscription, "--query", "id", "--output", "tsv",
        "--only-show-errors",
    ], operation)
    require_success(result, operation)
    if result.stdout.strip().lower() != subscription:
        raise DecommissionError(f"{operation}: Azure CLI returned a different subscription")


def resource_exists(resource_id, subscription, *, require_stopped=False):
    operation = f"Check {resource_id}"
    query = "{id:id,state:properties.state}" if require_stopped else "id"
    output = "json" if require_stopped else "tsv"
    result = run_az([
        "resource", "show", "--ids", resource_id, "--subscription", subscription,
        "--query", query, "--output", output, "--only-show-errors",
    ], operation)
    # The CLI exits with status 3 on an HTTP 404. Require a resource
    # absence code too, since provider discovery can itself return 404.
    if result.returncode == 3 and ABSENT_ERROR.search(result.stderr):
        return False
    if require_stopped:
        app = read_azure_json(result, operation)
        returned_id = app.get("id") if isinstance(app, dict) else None
    else:
        require_success(result, operation)
        returned_id = result.stdout.strip()
    if not isinstance(returned_id, str) or returned_id.lower() != resource_id.lower():
        raise DecommissionError(f"{operation}: Azure CLI did not return the requested resource ID")
    if require_stopped and app.get("state") != "Stopped":
        raise DecommissionError(f"{operation}: App Service or slot must be Stopped (state: {app.get('state')!r})")
    return True


def app_service_target(resource_id, kind):
    parts = resource_id.split("/")
    if len(parts) != (11 if kind == APP_SLOT else 9):
        raise DecommissionError(f"Expected a direct App Service resource ID: {resource_id}")
    target = [f"--resource-group={parts[4]}", f"--name={parts[8]}"]
    if kind == APP_SLOT:
        target.append(f"--slot={parts[10]}")
    return target


def verify_app_slots(resource_id, subscription, target, earlier_present):
    operation = f"Check App Service slots for {resource_id}"
    # Azure CLI materializes the SDK's paged collection before applying the query.
    result = run_az([
        "webapp", "deployment", "slot", "list", *target, "--subscription", subscription,
        "--query", "[].{id:id,state:state}", "--output", "json", "--only-show-errors",
    ], operation)
    slots = read_azure_json(result, operation)
    if not isinstance(slots, list):
        raise DecommissionError(f"{operation}: Azure did not return a slot list")

    expected_parent = [resource_id.lower(), "slots"]
    for slot in slots:
        slot_id = slot.get("id") if isinstance(slot, dict) else None
        if (not isinstance(slot_id, str) or not RESOURCE_ID.fullmatch(slot_id)
                or slot_id.lower().rsplit("/", 2)[:2] != expected_parent):
            raise DecommissionError(f"{operation}: Azure returned an invalid slot ID")
        if earlier_present is None:
            raise DecommissionError(f"{operation}: must be empty before deletion; found {slot_id}")
        if slot_id.lower() not in earlier_present:
            raise DecommissionError(f"{operation}: slot must be present and listed earlier: {slot_id}")
        if slot.get("state") != "Stopped":
            raise DecommissionError(f"{operation}: slot must be Stopped: {slot_id}")
        print(f"{resource_id} has a stopped slot listed earlier: {slot_id}", flush=True)


def app_service_exists(resource_id, subscription, kind, earlier_present=None):
    target = app_service_target(resource_id, kind)
    if not resource_exists(resource_id, subscription, require_stopped=True):
        return False

    operation = f"Check App Service VNet integrations for {resource_id}"
    result = run_az([
        "webapp", "vnet-integration", "list", *target, "--subscription", subscription,
        "--output", "json", "--only-show-errors",
    ], operation)
    integrations = read_azure_json(result, operation)
    if not isinstance(integrations, list):
        raise DecommissionError(f"{operation}: Azure did not return a VNet integration list")
    if integrations:
        raise DecommissionError(f"{operation}: disconnect VNet integration before deletion")

    if kind == APP_SITE:
        verify_app_slots(resource_id, subscription, target, earlier_present)
    return True


def verify_orphaned_autoscale(resource_id, subscription):
    operation = f"Check autoscale setting {resource_id}"
    result = run_az([
        "resource", "show", "--ids", resource_id, "--subscription", subscription,
        "--query", "{enabled:properties.enabled,target:properties.targetResourceUri}",
        "--output", "json", "--only-show-errors",
    ], operation)
    setting = read_azure_json(result, operation)
    if not isinstance(setting, dict) or setting.get("enabled") is not False:
        raise DecommissionError(f"{operation}: only disabled autoscale settings can be deleted")
    target = setting.get("target")
    match = RESOURCE_ID.fullmatch(target) if isinstance(target, str) else None
    if (not match or match["subscription"].lower() != subscription
            or len(target.split("/")) != 9 or resource_type(target).lower() != "microsoft.web/serverfarms"):
        raise DecommissionError(f"{operation}: target must be an App Service plan in the same subscription")
    if resource_exists(target, subscription):
        raise DecommissionError(f"{operation}: target plan still exists: {target}")
    print(f"{resource_id} is disabled and its target plan is absent: {target}", flush=True)


def resource_states(resources, subscription, plan):
    states = []
    earlier_present = set()
    failures = 0
    for resource_id in resources:
        kind = resource_type(resource_id)
        kind_key = kind.lower()
        try:
            if kind_key in APP_SERVICE_TYPES:
                exists = app_service_exists(resource_id, subscription, kind_key, earlier_present)
            else:
                exists = resource_exists(resource_id, subscription)
            if exists and kind_key == "microsoft.insights/autoscalesettings":
                verify_orphaned_autoscale(resource_id, subscription)
        except DecommissionError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            failures += 1
            continue
        states.append(exists)
        if exists:
            earlier_present.add(resource_id.lower())
        state = "exists" if exists else ("already gone" if plan else "already deleted")
        print(f"{state}\t{kind}\t{resource_id}", flush=True)
    if plan or failures:
        print(f"Summary: {len(resources)} listed, {sum(states)} exist, "
              f"{states.count(False)} already gone, {failures} checks failed", flush=True)
    if failures:
        raise DecommissionError("Could not verify every listed resource")
    return states


def read_plan(path, resources, subscription):
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise DecommissionError(f"Invalid plan file {path}") from exc
    if not isinstance(plan, dict) or plan.get("subscriptionId") != subscription:
        raise DecommissionError("Plan does not match the expected subscription")
    entries = plan.get("resources")
    if (not isinstance(entries, list) or len(entries) != len(resources)
            or any(not isinstance(entry, dict) or entry.get("id") != resource_id
                   or type(entry.get("exists")) is not bool
                   for entry, resource_id in zip(entries, resources))):
        raise DecommissionError("Plan does not match the ordered resource list")
    return [entry["exists"] for entry in entries]


def delete_resource(resource_id, subscription):
    operation = f"Delete {resource_id}"
    kind = resource_type(resource_id).lower()
    if kind in APP_SERVICE_TYPES:
        if not app_service_exists(resource_id, subscription, kind):
            print(f"Already deleted {resource_id}", flush=True)
            return False
        # Generic ARM deletion can delete the hosting plan when it becomes
        # empty. Pass the slot explicitly so the CLI targets the slot endpoint.
        command = ["webapp", "delete", *app_service_target(resource_id, kind),
                   "--keep-empty-plan", "--keep-metrics"]
    else:
        command = ["resource", "delete", "--ids", resource_id]

    print(f"Deleting {resource_id}", flush=True)
    # Azure CLI waits for the operation by default. Verbose output preserves
    # the provider's error when the CLI wraps a rejected delete.
    result = run_az([
        *command, "--subscription", subscription, "--output", "none", "--verbose",
    ], operation, timeout=1800)
    if result.returncode:
        missing = (result.returncode == 3 and ABSENT_ERROR.search(result.stderr)) or (
            result.returncode == 1
            and "ERROR: Some resources failed to be deleted" in result.stderr
            and ABSENT_DELETE_DETAIL.search(result.stderr)
        )
        if missing and not resource_exists(resource_id, subscription):
            print(f"Already deleted {resource_id}", flush=True)
            return False
        require_success(result, operation)

    for attempt in range(VERIFY_ATTEMPTS):
        if attempt:
            time.sleep(VERIFY_INTERVAL)
        if not resource_exists(resource_id, subscription):
            print(f"Verified deleted {resource_id}", flush=True)
            return True
    raise DecommissionError(f"{operation}: resource still exists after deletion")


def run(args):
    subscription = args.subscription.lower()
    if not re.fullmatch(GUID, subscription) or not subscription.replace("-", "").strip("0"):
        raise DecommissionError("Expected subscription must be a nonzero GUID")
    resources = read_resources(args.list_path, subscription)
    if args.mode == "delete":
        planned = read_plan(args.plan_file, resources, subscription)

    verify_subscription(subscription)
    states = resource_states(resources, subscription, args.mode == "plan")
    if args.mode == "plan":
        if args.plan_file:
            plan = {
                "subscriptionId": subscription,
                "resources": [{"id": resource_id, "exists": exists}
                              for resource_id, exists in zip(resources, states)],
            }
            args.plan_file.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        return

    for resource_id, was_present, is_present in zip(resources, planned, states):
        if is_present and not was_present:
            raise DecommissionError(f"Resource appeared after the plan: {resource_id}. Run a new plan.")

    deleted = 0
    for resource_id, exists in zip(resources, states):
        if exists:
            deleted += delete_resource(resource_id, subscription)
    print(f"Summary: {len(resources)} listed, {deleted} deleted, "
          f"{len(resources) - deleted} already deleted", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["plan", "delete"])
    parser.add_argument("list_path", type=Path)
    parser.add_argument("subscription", help="Expected Azure subscription GUID")
    parser.add_argument("--plan-file", type=Path, help="Plan JSON output or approved input")
    args = parser.parse_args(argv)
    if args.mode == "delete" and not args.plan_file:
        parser.error("delete requires --plan-file")
    try:
        run(args)
    except (DecommissionError, OSError, UnicodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
