#!/usr/bin/env python3
"""Plan and delete an ordered allowlist of Classic Azure resources."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.parse import parse_qsl, urlencode, urlsplit
from urllib.request import Request, urlopen


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
UNCODED_NOT_FOUND = re.compile(r"Operation returned an invalid status 'Not Found'")
# App Service has answered an uncoded 404 for over a minute while it deletes a plan.
UNCODED_NOT_FOUND_ATTEMPTS = 60
VERIFY_ATTEMPTS = 6
VERIFY_INTERVAL = 10
THROTTLE_ATTEMPTS = 6
THROTTLE_INTERVAL = 60
THROTTLED = re.compile(r"Too Many Requests|\"Code\":\s*\"429\"|\(429\)")
APP_SITE = "microsoft.web/sites"
APP_SLOT = "microsoft.web/sites/slots"
APP_PLAN = "microsoft.web/serverfarms"
AUTOSCALE_SETTING = "microsoft.insights/autoscalesettings"
AUTOSCALE_API = "2022-10-01"
APP_SERVICE_TYPES = {APP_SITE, APP_SLOT}
APP_SERVICE_API = "2025-05-01"
SUBNET_TYPE = "microsoft.network/virtualnetworks/subnets"
SIGN_IN_INTERVAL = 30 * 60
OIDC_API = "7.1"
OIDC_VARIABLES = (
    "SYSTEM_OIDCREQUESTURI", "SYSTEM_ACCESSTOKEN", "AZURESUBSCRIPTION_SERVICE_CONNECTION_ID",
    "AZURESUBSCRIPTION_CLIENT_ID", "AZURESUBSCRIPTION_TENANT_ID",
)


class DecommissionError(Exception):
    pass


class PipelineSignIn:
    """Keeps the Azure CLI signed in for jobs that run longer than an hour.

    AzureCLI@2 signs in once with a short-lived federated token. When the CLI's
    access token expires it cannot renew it (AADSTS700024), so a long delete
    fails part way through. Fetch a fresh token from the pipeline's OIDC
    endpoint and sign in again well before that happens. Outside a pipeline
    (no SYSTEM_OIDCREQUESTURI) the CLI's own sign-in is used unchanged.
    """

    def __init__(self, environ=None, clock=time.monotonic):
        environ = os.environ if environ is None else environ
        self.enabled = bool(environ.get("SYSTEM_OIDCREQUESTURI"))
        self.clock = clock
        self.signed_in_at = None
        if self.enabled:
            missing = [name for name in OIDC_VARIABLES if not environ.get(name)]
            if missing:
                raise DecommissionError(
                    "Cannot renew the Azure sign-in: set " + ", ".join(missing)
                    + " (map SYSTEM_ACCESSTOKEN from $(System.AccessToken))")
            self.values = {name: environ[name] for name in OIDC_VARIABLES}

    def federated_token(self):
        query = urlencode({"api-version": OIDC_API,
                           "serviceConnectionId": self.values["AZURESUBSCRIPTION_SERVICE_CONNECTION_ID"]})
        request = Request(
            f"{self.values['SYSTEM_OIDCREQUESTURI']}?{query}", data=b"", method="POST",
            headers={"Authorization": f"Bearer {self.values['SYSTEM_ACCESSTOKEN']}",
                     "Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=60) as response:
                token = json.load(response).get("oidcToken")
        except (URLError, OSError, ValueError, AttributeError) as exc:
            raise DecommissionError(f"Request a pipeline OIDC token: {exc}") from exc
        if not isinstance(token, str) or not token:
            raise DecommissionError("Request a pipeline OIDC token: no token returned")
        return token

    def renew_if_due(self):
        if not self.enabled:
            return
        now = self.clock()
        if self.signed_in_at is not None and now - self.signed_in_at < SIGN_IN_INTERVAL:
            return
        operation = "Renew the Azure CLI sign-in"
        result = run_az([
            "login", "--service-principal", "--username", self.values["AZURESUBSCRIPTION_CLIENT_ID"],
            "--tenant", self.values["AZURESUBSCRIPTION_TENANT_ID"], "--federated-token", self.federated_token(),
            "--allow-no-subscriptions", "--output", "none", "--only-show-errors",
        ], operation)
        require_success(result, operation)
        self.signed_in_at = now
        print("Renewed the Azure CLI sign-in", flush=True)


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


def read_resource(resource_id, subscription, *, require_stopped=False):
    operation = f"Check {resource_id}"
    query = "{id:id,state:properties.state,subnetId:properties.virtualNetworkSubnetId}" if require_stopped else "id"
    output = "json" if require_stopped else "tsv"
    for attempt in range(UNCODED_NOT_FOUND_ATTEMPTS):
        if attempt:
            print(f"{operation}: Azure answered 404 with no error code, checking again in "
                  f"{VERIFY_INTERVAL}s ({attempt}/{UNCODED_NOT_FOUND_ATTEMPTS - 1})", flush=True)
            time.sleep(VERIFY_INTERVAL)
        result = run_az([
            "resource", "show", "--ids", resource_id, "--subscription", subscription,
            "--query", query, "--output", output, "--only-show-errors",
        ], operation)
        # A resource part way through deletion can briefly answer 404 with no
        # error code. Ask again until Azure gives a definite answer.
        if not (result.returncode and UNCODED_NOT_FOUND.search(result.stderr)
                and not ABSENT_ERROR.search(result.stderr)):
            break
    # The CLI exits with status 3 on an HTTP 404. Require a resource
    # absence code too, since provider discovery can itself return 404.
    if result.returncode == 3 and ABSENT_ERROR.search(result.stderr):
        return None
    if require_stopped:
        resource = read_azure_json(result, operation)
    else:
        require_success(result, operation)
        resource = {"id": result.stdout.strip()}
    returned_id = resource.get("id") if isinstance(resource, dict) else None
    if not isinstance(returned_id, str) or returned_id.lower() != resource_id.lower():
        raise DecommissionError(f"{operation}: Azure CLI did not return the requested resource ID")
    if require_stopped and resource.get("state") != "Stopped":
        raise DecommissionError(f"{operation}: App Service or slot must be Stopped (state: {resource.get('state')!r})")
    return resource


def resource_exists(resource_id, subscription):
    return read_resource(resource_id, subscription) is not None


def is_scoped_id(resource_id, subscription, kind, segments):
    match = RESOURCE_ID.fullmatch(resource_id) if isinstance(resource_id, str) else None
    return (match and match["subscription"].lower() == subscription
            and len(resource_id.split("/")) == segments and resource_type(resource_id).lower() == kind)


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


def inspect_app_service(resource_id, subscription, kind, earlier_present=None):
    target = app_service_target(resource_id, kind)
    app = read_resource(resource_id, subscription, require_stopped=True)
    if app is None:
        return False, None

    operation = f"Check App Service VNet integrations for {resource_id}"
    result = run_az([
        "webapp", "vnet-integration", "list", *target, "--subscription", subscription,
        "--query", "[].{subnetId:vnetResourceId,certThumbprint:certThumbprint}",
        "--output", "json", "--only-show-errors",
    ], operation)
    integrations = read_azure_json(result, operation)
    if not isinstance(integrations, list):
        raise DecommissionError(f"{operation}: Azure did not return a VNet integration list")
    if "subnetId" not in app:
        raise DecommissionError(f"{operation}: Azure did not return the regional subnet property")
    subnet_id = None
    if integrations:
        integration = integrations[0]
        if len(integrations) != 1 or not isinstance(integration, dict):
            raise DecommissionError(f"{operation}: expected one regional VNet integration")
        subnet_id = integration.get("subnetId")
        if (not is_scoped_id(subnet_id, subscription, SUBNET_TYPE, 11)
                or integration.get("certThumbprint") not in (None, "")
                or not isinstance(app["subnetId"], str) or app["subnetId"].lower() != subnet_id.lower()):
            raise DecommissionError(f"{operation}: native integration does not match an exact regional subnet")
    elif app["subnetId"] not in (None, ""):
        raise DecommissionError(f"{operation}: Azure subnet property disagrees with the native integration list")

    if kind == APP_SITE:
        verify_app_slots(resource_id, subscription, target, earlier_present)
    return True, subnet_id


def next_plan_page(link, collection, operation):
    try:
        if not isinstance(link, str) or any(char.isspace() or char == "\\" for char in link):
            raise ValueError("invalid URL")
        parsed = urlsplit(link)
        pairs = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=3)
    except ValueError as exc:
        raise DecommissionError(f"{operation}: Azure returned an invalid continuation link") from exc
    query = dict(pairs)
    if (parsed.path.lower() != collection.lower() or parsed.fragment or parsed.username or parsed.password
            or (parsed.netloc and parsed.scheme != "https") or (parsed.scheme and not parsed.netloc)
            or len(query) != len(pairs) or query.keys() - {"api-version", "$skipToken", "$top"}
            or query.get("api-version", APP_SERVICE_API) != APP_SERVICE_API or not query.get("$skipToken")
            or ("$top" in query and not re.fullmatch(r"[1-9][0-9]*", query["$top"]))):
        raise DecommissionError(f"{operation}: Azure returned an unexpected continuation link")
    # Keep every request on the original collection and configured ARM endpoint.
    query["api-version"] = APP_SERVICE_API
    return f"{collection}?{urlencode(sorted(query.items()))}"


def verify_plan_members(resource_id, subscription, earlier_present=None):
    operation = f"Check App Service plan membership for {resource_id}"
    if not is_scoped_id(resource_id, subscription, APP_PLAN, 9):
        raise DecommissionError(f"{operation}: expected a direct App Service plan ID")
    collection = f"{resource_id}/sites"
    url = f"{collection}?api-version={APP_SERVICE_API}"
    visited = set()
    while url:
        if url in visited:
            raise DecommissionError(f"{operation}: Azure repeated a continuation link")
        visited.add(url)
        result = run_az([
            "rest", "--method", "get", "--url", url, "--subscription", subscription,
            "--query", "{value:map(&{id:id},value),nextLink:nextLink}",
            "--output", "json", "--only-show-errors",
        ], operation)
        page = read_azure_json(result, operation)
        if not isinstance(page, dict) or not isinstance(page.get("value"), list) or "nextLink" not in page:
            raise DecommissionError(f"{operation}: Azure did not return a membership list")
        for member in page["value"]:
            member_id = member.get("id") if isinstance(member, dict) else None
            if not is_scoped_id(member_id, subscription, APP_SITE, 9):
                raise DecommissionError(f"{operation}: Azure returned an invalid member ID")
            if earlier_present is None:
                raise DecommissionError(f"{operation}: plan must be empty before deletion; found {member_id}")
            if member_id.lower() not in earlier_present:
                raise DecommissionError(f"{operation}: app must be present and listed earlier: {member_id}")
            print(f"{resource_id} has an app listed earlier: {member_id}", flush=True)
        link = page.get("nextLink")
        url = next_plan_page(link, collection, operation) if link is not None else None


def read_autoscale_setting(resource_id, subscription):
    operation = f"Check autoscale setting {resource_id}"
    result = run_az([
        "resource", "show", "--ids", resource_id, "--subscription", subscription,
        "--query", "{id:id,enabled:properties.enabled,target:properties.targetResourceUri,profiles:properties.profiles}",
        "--output", "json", "--only-show-errors",
    ], operation)
    if result.returncode == 3 and ABSENT_ERROR.search(result.stderr):
        return None
    setting = read_azure_json(result, operation)
    returned_id = setting.get("id") if isinstance(setting, dict) else None
    if not isinstance(returned_id, str) or returned_id.lower() != resource_id.lower():
        raise DecommissionError(f"{operation}: Azure CLI did not return the requested resource ID")
    if type(setting.get("enabled")) is not bool:
        raise DecommissionError(f"{operation}: Azure did not return a boolean enabled state")
    target = setting.get("target")
    if not is_scoped_id(target, subscription, APP_PLAN, 9):
        raise DecommissionError(f"{operation}: target must be an App Service plan in the same subscription")
    return setting


def autoscale_disable_body(resource_id, setting):
    profiles = setting.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        raise DecommissionError(f"Check autoscale setting {resource_id}: Azure did not return its scaling profiles")
    # The Monitor PATCH requires profiles even when only enabled changes.
    return json.dumps({"properties": {"enabled": False, "profiles": profiles}})


def require_absent_autoscale_target(resource_id, target, subscription):
    if resource_exists(target, subscription):
        raise DecommissionError(f"Check autoscale setting {resource_id}: target plan still exists: {target}")


def read_autoscale_for_delete(resource_id, target, subscription):
    setting = read_autoscale_setting(resource_id, subscription)
    if setting is not None:
        if setting["target"].lower() != target.lower():
            raise DecommissionError(f"Autoscale target changed after the plan: {resource_id}. Run a new plan.")
        require_absent_autoscale_target(resource_id, target, subscription)
    return setting


def prepare_autoscale_delete(resource_id, target, disable_after_plan, subscription):
    setting = read_autoscale_for_delete(resource_id, target, subscription)
    if setting is None:
        return False
    if setting["enabled"]:
        if not disable_after_plan:
            raise DecommissionError(f"{resource_id}: only disabled autoscale settings can be deleted")
        operation = f"Disable autoscale setting {resource_id}"
        print(operation, flush=True)
        result = run_az([
            "rest", "--method", "patch", "--url", f"{resource_id}?api-version={AUTOSCALE_API}",
            "--body", autoscale_disable_body(resource_id, setting), "--subscription", subscription,
            "--output", "none", "--only-show-errors",
        ], operation)
        require_success(result, operation)
        setting = read_autoscale_for_delete(resource_id, target, subscription)
        if setting is None:
            return False
        if setting["enabled"]:
            raise DecommissionError(f"{operation}: autoscale setting is still enabled")
    return True


def resource_states(resources, subscription, plan, sign_in, skipped):
    states = []
    earlier_present = set()
    earlier_plans = set()
    failures = 0
    for resource_id in resources:
        kind = resource_type(resource_id)
        kind_key = kind.lower()
        if resource_id.lower() in skipped:
            # A later autoscale rule still uses the target's position in the approved list.
            if kind_key == APP_PLAN:
                earlier_plans.add(resource_id.lower())
            continue

        sign_in.renew_if_due()
        entry = {"id": resource_id}
        try:
            if kind_key in APP_SERVICE_TYPES:
                exists, subnet_id = inspect_app_service(resource_id, subscription, kind_key, earlier_present)
                entry["subnetId"] = subnet_id
                if plan and subnet_id:
                    print(f"{resource_id} will disconnect from {subnet_id} before deletion", flush=True)
            elif kind_key == AUTOSCALE_SETTING:
                setting = read_autoscale_setting(resource_id, subscription)
                exists = setting is not None
                if exists:
                    target = setting["target"]
                    disable_after_plan = target.lower() in earlier_plans
                    if disable_after_plan:
                        if target.lower() in skipped:
                            require_absent_autoscale_target(resource_id, target, subscription)
                        if setting["enabled"]:
                            autoscale_disable_body(resource_id, setting)
                        if plan:
                            print(f"{resource_id} will be disabled if enabled and deleted after "
                                  f"its target plan is confirmed absent: {target}", flush=True)
                    else:
                        if setting["enabled"]:
                            raise DecommissionError(
                                f"{resource_id}: only disabled autoscale settings can be deleted "
                                "unless their target plan is listed earlier")
                        require_absent_autoscale_target(resource_id, target, subscription)
                        if plan:
                            print(f"{resource_id} is disabled and its target plan is absent: {target}", flush=True)
                    entry.update(targetPlanId=target, disableAfterPlan=disable_after_plan)
            else:
                exists = resource_exists(resource_id, subscription)
            if kind_key == APP_PLAN:
                if exists:
                    verify_plan_members(resource_id, subscription, earlier_present)
                earlier_plans.add(resource_id.lower())
        except DecommissionError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            failures += 1
            continue
        entry["exists"] = exists
        states.append(entry)
        if exists:
            earlier_present.add(resource_id.lower())
        if plan:
            state = "exists" if exists else "already gone"
            print(f"{state}\t{kind}\t{resource_id}", flush=True)
    if plan or failures:
        exists_count = sum(entry["exists"] for entry in states)
        print(f"Summary: {len(resources) - len(skipped)} listed, {exists_count} exist, "
              f"{len(states) - exists_count} already gone, {failures} checks failed", flush=True)
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
    for entry in entries:
        resource_id = entry["id"]
        kind = resource_type(resource_id).lower()
        if kind in APP_SERVICE_TYPES:
            subnet_id = entry.get("subnetId")
            if ("subnetId" not in entry or (subnet_id is not None and
                    (not entry["exists"] or not is_scoped_id(subnet_id, subscription, SUBNET_TYPE, 11)))):
                raise DecommissionError(f"Plan lacks a valid subnet decision for {resource_id}")
        if kind == AUTOSCALE_SETTING and entry["exists"] and (
                not is_scoped_id(entry.get("targetPlanId"), subscription, APP_PLAN, 9)
                or type(entry.get("disableAfterPlan")) is not bool):
            raise DecommissionError(f"Plan lacks a valid autoscale decision for {resource_id}")
    return entries


def verify_approved_subnet(resource_id, subnet_id, approved_subnet):
    # An already-disconnected app can finish deletion on retry. Any connection
    # still present must be the exact subnet reviewed in the approved plan.
    if subnet_id is not None and (approved_subnet is None or subnet_id.lower() != approved_subnet.lower()):
        raise DecommissionError(f"VNet integration changed after the plan: {resource_id}. Run a new plan.")


def verify_skipped_descendants(resource_id, descendants, subscription):
    # Deleting a parent can also delete its children, even if we skip their IDs.
    for descendant in descendants:
        if resource_exists(descendant, subscription):
            raise DecommissionError(
                f"Resource appeared after the plan: {descendant}. "
                f"Deleting {resource_id} could remove it. Run a new plan.")


def delete_resource(entry, subscription, skipped_descendants):
    resource_id = entry["id"]
    operation = f"Delete {resource_id}"
    kind = resource_type(resource_id).lower()
    if kind in APP_SERVICE_TYPES:
        exists, subnet_id = inspect_app_service(resource_id, subscription, kind)
        if not exists:
            print(f"Already deleted {resource_id}", flush=True)
            return False
        verify_approved_subnet(resource_id, subnet_id, entry["subnetId"])
        target = app_service_target(resource_id, kind)
        if subnet_id:
            disconnect = f"Disconnect {resource_id} from {subnet_id}"
            print(disconnect, flush=True)
            result = run_az([
                "webapp", "vnet-integration", "remove", *target, "--subscription", subscription,
                "--output", "none", "--only-show-errors",
            ], disconnect)
            require_success(result, disconnect)
            exists, remaining_subnet = inspect_app_service(resource_id, subscription, kind)
            if not exists:
                print(f"Already deleted {resource_id}", flush=True)
                return False
            if remaining_subnet is not None:
                raise DecommissionError(f"{disconnect}: VNet integration still present")
        # Generic ARM deletion can delete the hosting plan when it becomes
        # empty. Pass the slot explicitly so the CLI targets the slot endpoint.
        command = ["webapp", "delete", *target, "--keep-empty-plan", "--keep-metrics"]
    else:
        if kind == APP_PLAN:
            if not resource_exists(resource_id, subscription):
                print(f"Already deleted {resource_id}", flush=True)
                return False
            verify_plan_members(resource_id, subscription)
        if kind == AUTOSCALE_SETTING and not prepare_autoscale_delete(
                resource_id, entry["targetPlanId"], entry["disableAfterPlan"], subscription):
            print(f"Already deleted {resource_id}", flush=True)
            return False
        command = ["resource", "delete", "--ids", resource_id]

    print(f"Deleting {resource_id}", flush=True)
    for attempt in range(1, THROTTLE_ATTEMPTS + 1):
        verify_skipped_descendants(resource_id, skipped_descendants, subscription)
        # Azure CLI waits for the operation by default. Verbose output preserves
        # the provider's error when the CLI wraps a rejected delete.
        result = run_az([
            *command, "--subscription", subscription, "--output", "none", "--verbose",
        ], operation, timeout=1800)
        # App Service answers 429 while it still holds a lock on a plan whose
        # apps were just deleted. Wait and try again rather than fail the run.
        if not result.returncode or not THROTTLED.search(result.stderr) or attempt == THROTTLE_ATTEMPTS:
            break
        print(f"{operation}: Azure is busy (429), retrying in {THROTTLE_INTERVAL}s "
              f"({attempt}/{THROTTLE_ATTEMPTS - 1})", flush=True)
        time.sleep(THROTTLE_INTERVAL)
        # Azure sometimes completes the rejected delete anyway.
        if not resource_exists(resource_id, subscription):
            print(f"Verified deleted {resource_id}", flush=True)
            return True
        if kind == APP_PLAN:
            verify_plan_members(resource_id, subscription)
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
    is_plan = args.mode == "plan"
    approved = {}
    if not is_plan:
        approved = {entry["id"]: entry for entry in read_plan(args.plan_file, resources, subscription)}
    skipped = {resource_id.lower(): resource_id for resource_id, entry in approved.items() if not entry["exists"]}

    # Renew once up front so a missing OIDC permission fails before any change.
    sign_in = PipelineSignIn()
    sign_in.renew_if_due()
    verify_subscription(subscription)
    if not is_plan:
        print(f"Rechecking {len(resources) - len(skipped)} resources marked present in the approved plan. "
              f"Skipping {len(skipped)} absent entries as deletion targets.", flush=True)
    states = resource_states(resources, subscription, is_plan, sign_in, skipped)
    if is_plan:
        if args.plan_file:
            plan = {
                "subscriptionId": subscription,
                "resources": states,
            }
            args.plan_file.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        return

    skipped_descendants = {}
    for current in states:
        resource_id = current["id"]
        planned = approved[resource_id]
        verify_approved_subnet(resource_id, current.get("subnetId"), planned.get("subnetId"))
        if "targetPlanId" in current and (
                current["targetPlanId"].lower() != planned["targetPlanId"].lower()
                or current["disableAfterPlan"] != planned["disableAfterPlan"]):
            raise DecommissionError(f"Autoscale target changed after the plan: {resource_id}. Run a new plan.")
        if current["exists"]:
            prefix = resource_id.lower() + "/"
            descendants = [target for key, target in skipped.items() if key.startswith(prefix)]
            verify_skipped_descendants(resource_id, descendants, subscription)
            skipped_descendants[resource_id] = descendants

    deleted = 0
    for current in states:
        if current["exists"]:
            sign_in.renew_if_due()
            deleted += delete_resource(current, subscription, skipped_descendants[current["id"]])
    print(f"Summary: {len(resources)} listed, {deleted} deleted, "
          f"{len(states) - deleted} already deleted, {len(skipped)} absent in approved plan and skipped", flush=True)


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
