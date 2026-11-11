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
POLL_ATTEMPTS = 24
POLL_INTERVAL_SECONDS = 5
SUBSCRIPTION_ID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
RESOURCE_NAME = r"[a-z0-9_.()-]+"
SQL_SERVER_ID = (
    rf"/subscriptions/(?P<subscription>{SUBSCRIPTION_ID})/resourceGroups/{RESOURCE_NAME}"
    rf"/providers/Microsoft\.Sql/servers/{RESOURCE_NAME}"
)
JOB_ENDPOINT_ID = re.compile(
    rf"(?P<server>{SQL_SERVER_ID})/jobAgents/{RESOURCE_NAME}/privateEndpoints/{RESOURCE_NAME}",
    re.IGNORECASE,
)
NETWORK_ENDPOINT_ID = re.compile(
    rf"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_NAME}"
    rf"/providers/Microsoft\.Network/privateEndpoints/{RESOURCE_NAME}",
    re.IGNORECASE,
)
NOT_FOUND = re.compile(r"^ERROR:\s*(?:Not Found\b|\((?:ResourceNotFound|JobPrivateEndpointNotFound)\))", re.I)


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


def verify_approval(connection_id, server_id, managed_id, subscription):
    for attempt in range(POLL_ATTEMPTS):
        connection = find_connection(server_id, managed_id, subscription)
        if connection is not None:
            current_id, status, provisioning = connection
            if current_id.casefold() != connection_id.casefold():
                raise ApprovalError("The matching SQL connection changed after approval was requested.")
            if status == "Approved" and provisioning != "Approving":
                return
        if attempt + 1 < POLL_ATTEMPTS:
            time.sleep(POLL_INTERVAL_SECONDS)
    raise ApprovalError("Timed out waiting for the SQL private endpoint connection to show Approved.")


def approve(endpoint_id, subscription):
    endpoint_scope = JOB_ENDPOINT_ID.fullmatch(endpoint_id)
    if not endpoint_scope or endpoint_scope["subscription"].casefold() != subscription.casefold():
        raise ApprovalError("Expected a SQL Elastic Job Agent private endpoint in the Classic subscription.")
    server_id = endpoint_scope["server"]
    managed_id = None
    for attempt in range(POLL_ATTEMPTS):
        if managed_id is None:
            managed_id = get_managed_endpoint_id(endpoint_id, server_id, subscription)
        if managed_id is not None:
            connection = find_connection(server_id, managed_id, subscription)
            if connection is not None:
                connection_id, status, provisioning = connection
                if provisioning != "Approving":
                    break
        if attempt + 1 < POLL_ATTEMPTS:
            time.sleep(POLL_INTERVAL_SECONDS)
    else:
        raise ApprovalError("Timed out waiting for the SQL connection for the Elastic Job Agent private endpoint.")

    if status == "Pending":
        request_approval(connection_id, server_id, managed_id, subscription)
        verify_approval(connection_id, server_id, managed_id, subscription)
    print(f"SQL Elastic Job Agent private endpoint connection approved: {connection_id}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint-resource-id", required=True)
    parser.add_argument("--subscription", required=True)
    args = parser.parse_args()
    try:
        approve(args.endpoint_resource_id, args.subscription)
    except ApprovalError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
