#!/usr/bin/env python3
"""Render the runtime Bicep parameters shared by deployment and release previews.

Values enter through an explicit environment-variable allowlist, rather than being
interpolated into shell scripts. This module never prints parameter values.
"""

import argparse
import os
from pathlib import Path
import re
import sys


COMPONENTS = {
    "resource-group": "10-resource-group",
    "network": "20-network",
    "acr": "25-acr",
    "classic": "30-classic",
    "infra": "40-infra",
    "infra-to-classic": "45-infra-to-classic",
    "privatelink": "50-privatelink",
}

ENVIRONMENT_VARIABLES = {
    "acrPullGroupId": "BICEP_ACR_PULL_GROUP_ID",
    "acrPullGroupName": "BICEP_ACR_PULL_GROUP_NAME",
    "parameterSqlAdminGroupId": "BICEP_PARAMETER_SQL_ADMIN_GROUP_ID",
    "parameterSqlAdminGroupName": "BICEP_PARAMETER_SQL_ADMIN_GROUP_NAME",
    "qaAutomationServiceConnectionPrincipalId": "BICEP_QA_AUTOMATION_SERVICE_CONNECTION_PRINCIPAL_ID",
    "classicRedisResourceId": "BICEP_CLASSIC_REDIS_RESOURCE_ID",
    "classicSearchServiceResourceId": "BICEP_CLASSIC_SEARCH_SERVICE_RESOURCE_ID",
    "classicServiceBusNamespaceResourceId": "BICEP_CLASSIC_SERVICE_BUS_NAMESPACE_RESOURCE_ID",
    "classicSqlServerResourceId": "BICEP_CLASSIC_SQL_SERVER_RESOURCE_ID",
    "sqlAdminGroupId": "BICEP_SQL_ADMIN_GROUP_ID",
    "sqlAdminGroupName": "BICEP_SQL_ADMIN_GROUP_NAME",
    "aksApiServerSubnetId": "BICEP_AKS_API_SERVER_SUBNET_ID",
    "aksApiServerSubnetName": "BICEP_AKS_API_SERVER_SUBNET_NAME",
    "aksSystemNodesSubnetId": "BICEP_AKS_SYSTEM_NODES_SUBNET_ID",
    "aksSystemNodesSubnetName": "BICEP_AKS_SYSTEM_NODES_SUBNET_NAME",
    "aksUserNodesSubnetId": "BICEP_AKS_USER_NODES_SUBNET_ID",
    "aksUserNodesSubnetName": "BICEP_AKS_USER_NODES_SUBNET_NAME",
    "appGatewayForContainersSubnetId": "BICEP_APP_GATEWAY_FOR_CONTAINERS_SUBNET_ID",
    "appGatewayForContainersSubnetName": "BICEP_APP_GATEWAY_FOR_CONTAINERS_SUBNET_NAME",
    "privateEndpointsSubnetId": "BICEP_PRIVATE_ENDPOINTS_SUBNET_ID",
    "privateEndpointsSubnetName": "BICEP_PRIVATE_ENDPOINTS_SUBNET_NAME",
    "tenantId": "BICEP_TENANT_ID",
    "serviceConnectionPrincipalId": "BICEP_SERVICE_CONNECTION_PRINCIPAL_ID",
    "grafanaManagedIdentityPrincipalId": "BICEP_GRAFANA_MANAGED_IDENTITY_PRINCIPAL_ID",
}

SUBNETS = ("aksApiServer", "aksSystemNodes", "aksUserNodes",
           "appGatewayForContainers", "privateEndpoints")
ENVIRONMENTS = ("DEV", "TST", "PRE", "PRD")


def _value(values, name, allow_empty=False):
    value = values.get(name)
    if value is None and allow_empty:
        return ""
    if not isinstance(value, str) or (not value.strip() and not allow_empty):
        raise ValueError(f"Missing required infrastructure parameter: {name}")
    if re.search(r"\$\([^)]*\)|\$\{\{|\$\[", value):
        raise ValueError(f"Unresolved pipeline variable for infrastructure parameter: {name}")
    if any(ord(character) < 32 and character not in "\r\n\t" for character in value):
        raise ValueError(f"Unsupported control character in infrastructure parameter: {name}")
    return value


def _quote(value):
    value = (value.replace("\\", "\\\\").replace("'", "\\'")
             .replace("${", "\\${").replace("\r", "\\r")
             .replace("\n", "\\n").replace("\t", "\\t"))
    return "'" + value + "'"


def _object(lines, name, entries):
    lines.append(f"param {name} = {{")
    for key, value in entries.items():
        if isinstance(value, dict):
            lines.append(f"  {key}: {{")
            lines.extend(f"    {field}: {_quote(item)}" for field, item in value.items())
            lines.append("  }")
        else:
            lines.append(f"  {key}: {_quote(value)}")
    lines.append("}")


def render(component, environment, values, classic_environment=None):
    """Return a runtime .bicepparam body with the deployment's exact overlays.

    Classic uses SND for DEV by default. Classic/infra deployment tasks still pass
    tenant/deployment principal via CLI; preview callers can supply those values
    here to obtain a self-contained parameter file instead.
    """
    if component not in COMPONENTS:
        raise ValueError("Unsupported infrastructure component")
    if environment not in ENVIRONMENTS:
        raise ValueError("Unsupported infrastructure environment")
    classic_environment = classic_environment or ("SND" if environment == "DEV" else environment)
    if classic_environment not in (*ENVIRONMENTS, "SND"):
        raise ValueError("Unsupported classic infrastructure environment")
    if component == "acr" and environment == "TST":
        raise ValueError("TST uses the shared DEV ACR and has no ACR deployment")
    filename = COMPONENTS[component]
    source_environment = classic_environment if component == "classic" else environment
    lines = [f"using '{filename}.bicep'",
             f"extends 'envs/{source_environment.lower()}/{filename}.bicepparam'"]
    get = lambda name, **kwargs: _value(values, name, **kwargs)
    if component == "acr":
        _object(lines, "entraGroups", {"acrPull": {
            "id": get("acrPullGroupId"), "name": get("acrPullGroupName")}})
    if component == "classic":
        _object(lines, "entraGroups", {"sqlAdmins": {
            "id": get("parameterSqlAdminGroupId"), "name": get("parameterSqlAdminGroupName")}})
    if component == "infra":
        qa = get("qaAutomationServiceConnectionPrincipalId", allow_empty=environment != "TST")
        lines.append(f"param qaAutomationPrincipalObjectId = {_quote(qa)}")
        _object(lines, "classicResourceIds", {
            "redis": get("classicRedisResourceId"),
            "searchService": get("classicSearchServiceResourceId"),
            "serviceBusNamespace": get("classicServiceBusNamespaceResourceId"),
            "sqlServer": get("classicSqlServerResourceId")})
        _object(lines, "entraGroups", {"sqlAdmins": {
            "id": get("sqlAdminGroupId"), "name": get("sqlAdminGroupName")}})
    if component in ("acr", "infra", "privatelink"):
        prefixes = SUBNETS if component == "infra" else ("privateEndpoints",)
        _object(lines, "subnets", {prefix: {
            "id": get(prefix + "SubnetId"), "name": get(prefix + "SubnetName")}
            for prefix in prefixes})
    if component in ("classic", "infra") and "tenantId" in values:
        lines.append(f"param tenantId = {_quote(get('tenantId'))}")
    if component == "infra" and "serviceConnectionPrincipalId" in values:
        lines.append(f"param deployServicePrincipalObjectId = {_quote(get('serviceConnectionPrincipalId'))}")
    if component == "infra-to-classic":
        lines.append(f"param deployServicePrincipalObjectId = {_quote(get('serviceConnectionPrincipalId'))}")
        lines.append(f"param grafanaManagedIdentityPrincipalId = {_quote(get('grafanaManagedIdentityPrincipalId'))}")
    return "\n".join(lines) + "\n"


def write_parameters(component, environment, values, output_path, classic_environment=None):
    """Validate fully before writing and never log values."""
    content = render(component, environment, values, classic_environment)
    output_path = Path(output_path)
    if not output_path.is_absolute():
        raise ValueError("Infrastructure parameter output path must be absolute")
    output_path.write_text(content, encoding="utf-8")
    return output_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", required=True, choices=COMPONENTS)
    parser.add_argument("--environment", required=True, choices=ENVIRONMENTS)
    parser.add_argument("--classic-environment", choices=(*ENVIRONMENTS, "SND"))
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    values = {name: os.environ[variable] for name, variable in ENVIRONMENT_VARIABLES.items()
              if variable in os.environ}
    try:
        write_parameters(args.component, args.environment, values, args.output, args.classic_environment)
    except (OSError, ValueError) as error:
        # OSError includes file paths, not parameter contents.
        print(f"Cannot generate infrastructure parameters: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
