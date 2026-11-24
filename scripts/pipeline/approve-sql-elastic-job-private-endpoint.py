#!/usr/bin/env python3
"""Approve the SQL server connection created for one Elastic Job Agent endpoint."""

import argparse
import json
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit


API_VERSION = "2025-01-01"
DEPLOYMENT_API_VERSION = "2025-04-01"
DISCOVERY_TIMEOUT_SECONDS = 600
POLL_ATTEMPTS = 24
POLL_INTERVAL_SECONDS = 5
SUBSCRIPTION_ID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
RESOURCE_NAME = r"(?!\.{1,2}(?:/|$))[a-z0-9_.()-]+"
NETWORK_ENDPOINT_ID = re.compile(
    rf"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_NAME}"
    rf"/providers/Microsoft\.Network/privateEndpoints/{RESOURCE_NAME}",
    re.IGNORECASE,
)
NOT_FOUND = re.compile(
    r"^ERROR:\s*(?:Not Found\b|\((?:ResourceNotFound|DeploymentNotFound|JobPrivateEndpointNotFound)\))",
    re.I,
)


class ApprovalError(Exception):
    """An error safe to show in the pipeline log."""


def run_az(arguments, subscription, operation, *, read_json=False, allow_not_found=False, timeout=30):
    output = "json" if read_json else "none"
    try:
        result = subprocess.run(
            ["az", *arguments, "--subscription", subscription, "--only-show-errors", "--output", output],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        raise ApprovalError(f"{operation}: Azure CLI could not complete the request.") from None
    if result.returncode:
        if allow_not_found and NOT_FOUND.match(result.stderr):
            return None
        raise ApprovalError(f"{operation} failed (Azure CLI exit {result.returncode}).")
    if read_json:
        try:
            payload = json.loads(result.stdout)
        except ValueError:
            raise ApprovalError(f"{operation}: Azure CLI returned invalid JSON.") from None
        if not isinstance(payload, dict):
            raise ApprovalError(f"{operation}: expected a JSON object.")
        return payload
    return None


def get_deployment_target(deployment_id, subscription):
    deployment = run_az(
        ["rest", "--method", "get", "--url", f"{deployment_id}?api-version={DEPLOYMENT_API_VERSION}"],
        subscription, "Read Classic deployment", read_json=True, allow_not_found=True,
    )
    if deployment is None:
        return None
    returned_id = deployment.get("id")
    if not isinstance(returned_id, str) or returned_id.casefold() != deployment_id.casefold():
        raise ApprovalError("Azure returned a different Classic deployment.")
    properties = deployment.get("properties")
    state = properties.get("provisioningState") if isinstance(properties, dict) else None
    if state in ("Failed", "Canceled", "Deleting", "Deleted"):
        raise ApprovalError(f"Classic deployment entered {state} while waiting for private endpoint approval.")
    if state not in ("NotSpecified", "Accepted", "Creating", "Created", "Ready", "Running", "Updating", "Succeeded"):
        raise ApprovalError("Azure returned an unexpected Classic deployment state.")

    parameters = properties.get("parameters")
    job_parameter = parameters.get("sejParams") if isinstance(parameters, dict) else None
    settings = job_parameter.get("value") if isinstance(job_parameter, dict) else None
    if settings is None and state != "Succeeded":
        return None
    sql_server = settings.get("sqlServerName") if isinstance(settings, dict) else None
    job_agent = settings.get("jobAgentName") if isinstance(settings, dict) else None
    if not all(isinstance(value, str) and re.fullmatch(RESOURCE_NAME, value, re.I)
               for value in (sql_server, job_agent)):
        raise ApprovalError("The Classic deployment does not contain valid SQL server and Elastic Job Agent parameters.")

    group_id = deployment_id.split("/providers/", 1)[0]
    server_id = f"{group_id}/providers/Microsoft.Sql/servers/{sql_server}"
    # The child endpoint name in Bicep is toLower(jobAgent.name).
    endpoint_id = f"{server_id}/jobAgents/{job_agent}/privateEndpoints/{job_agent.lower()}"
    return server_id, endpoint_id


def check_deployment_target(deployment_id, subscription, expected):
    current = get_deployment_target(deployment_id, subscription)
    if current is not None and expected is not None:
        if current[1].casefold() != expected[1].casefold():
            raise ApprovalError("The Elastic Job Agent private endpoint parameters changed during the Classic deployment.")
    return current


def get_managed_endpoint_id(endpoint_id, server_id, subscription):
    endpoint = run_az(
        ["rest", "--method", "get", "--url", f"{endpoint_id}?api-version={API_VERSION}"],
        subscription, "Read Elastic Job Agent private endpoint", read_json=True, allow_not_found=True,
    )
    if endpoint is None:
        return None
    properties = endpoint.get("properties")
    returned_id = endpoint.get("id")
    target_id = properties.get("targetServerAzureResourceId") if isinstance(properties, dict) else None
    if not isinstance(returned_id, str) or returned_id.casefold() != endpoint_id.casefold():
        raise ApprovalError("Azure returned a different Elastic Job Agent private endpoint.")
    if not isinstance(target_id, str) or target_id.casefold() != server_id.casefold():
        raise ApprovalError("The Elastic Job Agent private endpoint targets a different SQL server.")
    managed_id = properties.get("privateEndpointId")
    if managed_id in (None, ""):
        return None
    if not isinstance(managed_id, str) or not (
        NETWORK_ENDPOINT_ID.fullmatch(managed_id) or re.fullmatch(RESOURCE_NAME, managed_id, re.I)
    ):
        raise ApprovalError("Azure returned an invalid managed private endpoint ID.")
    return managed_id.casefold()


def continuation_url(link, collection):
    if not isinstance(link, str):
        raise ApprovalError("Azure returned an invalid SQL connection continuation link.")
    try:
        parsed = urlsplit(link)
    except ValueError:
        raise ApprovalError("Azure returned an invalid SQL connection continuation link.") from None
    if (
        (parsed.scheme, parsed.netloc.casefold()) not in (("https", "management.azure.com"), ("", ""))
        or parsed.path.casefold() != collection.casefold()
        or parsed.fragment
        or not parsed.query
    ):
        raise ApprovalError("Azure returned a SQL connection continuation link outside the target server.")
    return f"{collection}?{parsed.query}"


def find_connection(server_id, managed_id, subscription):
    collection = f"{server_id}/privateEndpointConnections"
    url = f"{collection}?api-version={API_VERSION}"
    visited = set()
    matching = []
    while url:
        if url in visited:
            raise ApprovalError("Azure repeated a SQL connection continuation link.")
        visited.add(url)
        page = run_az(["rest", "--method", "get", "--url", url], subscription,
                      "Read target SQL server private endpoint connections", read_json=True)
        if not isinstance(page.get("value"), list):
            raise ApprovalError("Azure did not return a list of SQL private endpoint connections.")
        for connection in page["value"]:
            properties = connection.get("properties") if isinstance(connection, dict) else None
            if not isinstance(properties, dict):
                raise ApprovalError("Azure returned an invalid SQL private endpoint connection.")
            private_endpoint = properties.get("privateEndpoint")
            endpoint_id = private_endpoint.get("id") if isinstance(private_endpoint, dict) else None
            if not isinstance(endpoint_id, str) or not NETWORK_ENDPOINT_ID.fullmatch(endpoint_id):
                continue
            key = endpoint_id if managed_id.startswith("/") else endpoint_id.rsplit("/", 1)[-1]
            if key.casefold() == managed_id:
                matching.append(connection)
        link = page.get("nextLink")
        url = continuation_url(link, collection) if link else None

    if len(matching) > 1:
        raise ApprovalError("More than one SQL connection matches the managed private endpoint ID.")
    if not matching:
        return None
    connection = matching[0]
    connection_id = connection.get("id")
    state = connection["properties"].get("privateLinkServiceConnectionState")
    status = state.get("status") if isinstance(state, dict) else None
    if not isinstance(connection_id, str) or not re.fullmatch(
        rf"{re.escape(collection)}/{RESOURCE_NAME}", connection_id, re.I
    ):
        raise ApprovalError("The matching private endpoint connection is outside the target SQL server.")
    if status not in ("Pending", "Approved"):
        raise ApprovalError("The matching SQL connection is neither Pending nor Approved.")
    provisioning = connection["properties"].get("provisioningState")
    if provisioning not in (None, "Ready", "Succeeded", "Approving"):
        raise ApprovalError("The matching SQL connection is in an unexpected provisioning state.")
    return connection_id, status, provisioning


def request_approval(connection_id, server_id, managed_id, subscription):
    body = {"properties": {"privateLinkServiceConnectionState": {
        "status": "Approved",
        "description": "Approved by the IPAFFS Classic deployment",
    }}}
    try:
        run_az(
            ["rest", "--method", "put", "--url", f"{connection_id}?api-version={API_VERSION}",
             "--body", json.dumps(body)],
            subscription, "Approve SQL private endpoint connection", timeout=120,
        )
    except ApprovalError as approval_error:
        # Another operator may have approved the connection after our read.
        try:
            current = find_connection(server_id, managed_id, subscription)
        except ApprovalError:
            raise approval_error from None
        if current is None or current[0].casefold() != connection_id.casefold():
            raise
        _, status, provisioning = current
        if status != "Approved" and provisioning != "Approving":
            raise


def verify_approval(connection_id, target, managed_id, subscription, deployment_id):
    server_id, _ = target
    for attempt in range(POLL_ATTEMPTS):
        current = check_deployment_target(deployment_id, subscription, target)
        connection = find_connection(server_id, managed_id, subscription) if current is not None else None
        if connection is not None:
            current_id, status, provisioning = connection
            if current_id.casefold() != connection_id.casefold():
                raise ApprovalError("The matching SQL connection changed after approval was requested.")
            if status == "Approved" and provisioning != "Approving":
                return
        if attempt + 1 < POLL_ATTEMPTS:
            time.sleep(POLL_INTERVAL_SECONDS)
    raise ApprovalError("Timed out waiting for the SQL private endpoint connection to show Approved.")


def approve(deployment_name, resource_group, subscription):
    if not re.fullmatch(SUBSCRIPTION_ID, subscription, re.I):
        raise ApprovalError("Expected a Classic subscription ID.")
    if not all(re.fullmatch(RESOURCE_NAME, value, re.I) for value in (deployment_name, resource_group)):
        raise ApprovalError("Expected a Classic deployment name and resource group.")
    deployment_id = (f"/subscriptions/{subscription}/resourceGroups/{resource_group}"
                     f"/providers/Microsoft.Resources/deployments/{deployment_name}")
    target = None
    managed_id = None
    deadline = time.monotonic() + DISCOVERY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        current = check_deployment_target(deployment_id, subscription, target)
        if current is not None:
            target = current
            server_id, endpoint_id = target
            if managed_id is None:
                managed_id = get_managed_endpoint_id(endpoint_id, server_id, subscription)
            if managed_id is not None:
                connection = find_connection(server_id, managed_id, subscription)
                if connection is not None:
                    connection_id, status, provisioning = connection
                    if provisioning != "Approving":
                        break
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(POLL_INTERVAL_SECONDS, remaining))
    else:
        raise ApprovalError("Timed out waiting for the SQL connection for the Elastic Job Agent private endpoint.")

    if status == "Pending":
        request_approval(connection_id, server_id, managed_id, subscription)
        verify_approval(connection_id, target, managed_id, subscription, deployment_id)
    print(f"SQL Elastic Job Agent private endpoint connection approved: {connection_id}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment-name", required=True)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--subscription", required=True)
    args = parser.parse_args()
    try:
        approve(args.deployment_name, args.resource_group, args.subscription)
    except ApprovalError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
