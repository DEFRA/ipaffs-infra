#!/usr/bin/env python3
"""Check Classic elastic pool parameters against what Azure allows before What-If.

What-If does not ask the SQL resource provider whether a SKU, maximum size and
per-database limits can be combined, so an invalid change would only fail during
the deployment. This reads sqlPoolsParams from the compiled Bicep parameters and
checks each pool against the regional SQL capabilities API and the live pool:

- the SKU is offered in the pool's region
- maxSizeGiB is a size that SKU supports
- the per-database min/max pair is offered by that SKU
- zone redundancy, licence type and maintenance window are supported
- the pool's used storage fits the new maximum size
- the live database count and each database's maximum size fit the SKU

Pools with keepLiveCapacity check the live SKU and per-database limits, since those
are what the deployment will send.
"""

import argparse
import json
import subprocess
import sys


CAPABILITIES_API_VERSION = "2023-08-01"
UNIT_BYTES = {
    "Megabytes": 1024 ** 2,
    "Gigabytes": 1024 ** 3,
    "Terabytes": 1024 ** 4,
    "Petabytes": 1024 ** 5,
}
GIB = 1024 ** 3


class ValidationError(Exception):
    """An error safe to show in the pipeline log."""


def to_bytes(value):
    try:
        return int(value["limit"] * UNIT_BYTES[value["unit"]])
    except (KeyError, TypeError):
        raise ValidationError("SQL capabilities returned a size in an unexpected format.") from None


def available(entries):
    return [entry for entry in entries or [] if entry.get("status") != "Disabled"]


def size_allowed(size_bytes, ranges):
    for size_range in available(ranges):
        minimum = to_bytes(size_range["minValue"])
        maximum = to_bytes(size_range["maxValue"])
        step = to_bytes(size_range["scaleSize"])
        if minimum <= size_bytes <= maximum and (size_bytes - minimum) % (step or (maximum - minimum + 1)) == 0:
            return True
    return False


def describe_sizes(ranges):
    labels = []
    for size_range in available(ranges):
        minimum = to_bytes(size_range["minValue"]) / GIB
        maximum = to_bytes(size_range["maxValue"]) / GIB
        step = to_bytes(size_range["scaleSize"]) / GIB
        if minimum == maximum:
            labels.append(f"{minimum:g}")
        else:
            labels.append(f"{minimum:g}-{maximum:g} (step {step:g})")
    return ", ".join(labels) + " GiB"


def find_performance_level(capabilities, sku):
    for version in available(capabilities.get("supportedServerVersions")):
        for edition in available(version.get("supportedElasticPoolEditions")):
            for level in available(edition.get("supportedElasticPoolPerformanceLevels")):
                offered = level.get("sku", {})
                if (offered.get("name") == sku.get("name")
                        and offered.get("tier") == sku.get("tier")
                        and offered.get("capacity") == sku.get("capacity")
                        and sku.get("family") in (None, offered.get("family"))):
                    return level
    return None


def validate_pool(pool, capabilities, live):
    """Return the problems with one sqlPoolsParams entry. An empty list means it is valid."""
    name = pool["name"]
    keep_live = pool.get("keepLiveCapacity", False)
    sku = live["sku"] if keep_live else pool["sku"]
    per_database = live["perDatabaseSettings"] if keep_live else pool["perDatabaseSettings"]
    source = " (live, keepLiveCapacity)" if keep_live else ""
    sku_label = f"{sku.get('name')} {sku.get('capacity')}"

    level = find_performance_level(capabilities, sku)
    if level is None:
        return [f"{name}: SKU {sku_label}{source} is not offered in {live['location']}."]

    problems = []
    max_size_bytes = pool["maxSizeGiB"] * GIB
    if not size_allowed(max_size_bytes, level.get("supportedMaxSizes")):
        problems.append(f"{name}: maxSizeGiB {pool['maxSizeGiB']} is not allowed for {sku_label}. "
                        f"Allowed: {describe_sizes(level.get('supportedMaxSizes'))}.")

    per_database_max = float(per_database.get("maxCapacity", 0))
    per_database_min = float(per_database.get("minCapacity", 0))
    max_levels = [entry for entry in available(level.get("supportedPerDatabaseMaxPerformanceLevels"))
                  if float(entry["limit"]) == per_database_max]
    if not max_levels:
        offered = [f"{float(entry['limit']):g}" for entry in
                   available(level.get("supportedPerDatabaseMaxPerformanceLevels"))]
        problems.append(f"{name}: per-database maxCapacity {per_database_max:g}{source} is not allowed for "
                        f"{sku_label}. Allowed: {', '.join(offered)}.")
    elif not any(float(entry["limit"]) == per_database_min
                 for entry in available(max_levels[0].get("supportedPerDatabaseMinPerformanceLevels"))):
        offered = [f"{float(entry['limit']):g}" for entry in
                   available(max_levels[0].get("supportedPerDatabaseMinPerformanceLevels"))]
        problems.append(f"{name}: per-database minCapacity {per_database_min:g}{source} is not allowed with "
                        f"maxCapacity {per_database_max:g}. Allowed: {', '.join(offered)}.")

    if pool.get("zoneRedundant") and not level.get("zoneRedundant"):
        problems.append(f"{name}: zone redundancy is not supported for {sku_label}.")

    licence_types = [entry["name"] for entry in available(level.get("supportedLicenseTypes"))]
    licence = pool.get("licenseType")
    if licence and licence not in licence_types:
        allowed = ", ".join(licence_types) if licence_types else "none (DTU pools take no licence type)"
        problems.append(f"{name}: licenseType {licence} is not allowed for {sku_label}. Allowed: {allowed}.")

    maintenance = [entry["name"] for entry in available(level.get("supportedMaintenanceConfigurations"))
                   if not pool.get("zoneRedundant") or entry.get("zoneRedundant", True)]
    if pool["maintenanceConfigurationName"] not in maintenance:
        problems.append(f"{name}: maintenance configuration {pool['maintenanceConfigurationName']} is not "
                        f"supported for {sku_label}.")

    if live["storageUsedBytes"] > max_size_bytes:
        problems.append(f"{name}: maxSizeGiB {pool['maxSizeGiB']} is below the "
                        f"{live['storageUsedBytes'] / GIB:.0f} GiB the pool already uses.")

    database_limit = level.get("maxDatabaseCount")
    if database_limit and len(live["databases"]) > database_limit:
        problems.append(f"{name}: the pool holds {len(live['databases'])} databases but {sku_label} allows "
                        f"{database_limit}.")

    database_sizes = available(level.get("supportedPerDatabaseMaxSizes"))
    if database_sizes:
        largest = max(to_bytes(entry["maxValue"]) for entry in database_sizes)
        too_big = sorted(database["name"] for database in live["databases"]
                         if (database.get("maxSizeBytes") or 0) > largest)
        if too_big:
            problems.append(f"{name}: these databases have a maximum size above the {largest / GIB:g} GiB "
                            f"{sku_label} allows per database: {', '.join(too_big)}.")
    return problems


def run_az(arguments, operation):
    try:
        result = subprocess.run(
            ["az", *arguments, "--only-show-errors", "--output", "json"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=False,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        raise ValidationError(f"{operation}: Azure CLI could not complete the request.") from None
    if result.returncode:
        raise ValidationError(f"{operation} failed (Azure CLI exit {result.returncode}).")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ValidationError(f"{operation}: Azure CLI returned invalid JSON.") from None


def read_pools(parameters_file):
    try:
        result = subprocess.run(
            ["az", "bicep", "build-params", "--file", parameters_file, "--stdout", "--only-show-errors"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300, check=False,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        raise ValidationError("Compiling the Classic parameters did not complete.") from None
    if result.returncode:
        raise ValidationError(f"Compiling the Classic parameters failed (exit {result.returncode}).")
    try:
        parameters = json.loads(json.loads(result.stdout)["parametersJson"])["parameters"]
    except (ValueError, KeyError, TypeError):
        raise ValidationError("Compiled Classic parameters were not in the expected format.") from None
    return parameters.get("sqlPoolsParams", {}).get("value", [])


def read_live(pool, subscription, default_resource_group):
    resource_group = pool.get("resourceGroupName") or default_resource_group
    location = (f"--subscription", subscription, "--resource-group", resource_group, "--server", pool["serverName"])
    live = run_az(["sql", "elastic-pool", "show", *location, "--name", pool["name"]],
                  f"Reading elastic pool {pool['name']}")
    databases = run_az(["sql", "elastic-pool", "list-dbs", *location, "--name", pool["name"]],
                       f"Listing databases in {pool['name']}")
    metrics = run_az(["monitor", "metrics", "list", "--resource", live["id"], "--metric", "storage_used",
                      "--offset", "1h", "--interval", "PT5M", "--aggregation", "Maximum"],
                     f"Reading storage used by {pool['name']}")
    used = [point.get("maximum") or 0 for metric in metrics.get("value", [])
            for series in metric.get("timeseries", []) for point in series.get("data", [])]
    return {
        "location": live["location"],
        "sku": {key: live["sku"].get(key) for key in ("name", "tier", "capacity", "family")
                if live["sku"].get(key) is not None},
        "perDatabaseSettings": {key: live["perDatabaseSettings"].get(key) for key in ("minCapacity", "maxCapacity")},
        "storageUsedBytes": max(used, default=0),
        "databases": [{"name": database["name"], "maxSizeBytes": database.get("maxSizeBytes")}
                      for database in databases],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--parameters", required=True, help="Classic .bicepparam file to check")
    parser.add_argument("--subscription", required=True, help="Classic subscription ID")
    parser.add_argument("--resource-group", required=True,
                        help="Classic resource group, used for pools without resourceGroupName")
    arguments = parser.parse_args()

    try:
        pools = read_pools(arguments.parameters)
        if not pools:
            print("No sqlPoolsParams entries to check.")
            return 0
        capabilities = {}
        problems = []
        for pool in pools:
            live = read_live(pool, arguments.subscription, arguments.resource_group)
            if live["location"] not in capabilities:
                capabilities[live["location"]] = run_az(
                    ["rest", "--method", "get", "--url",
                     f"https://management.azure.com/subscriptions/{arguments.subscription}/providers/Microsoft.Sql/"
                     f"locations/{live['location']}/capabilities?include=supportedElasticPoolEditions"
                     f"&api-version={CAPABILITIES_API_VERSION}"],
                    f"Reading SQL capabilities for {live['location']}")
            pool_problems = validate_pool(pool, capabilities[live["location"]], live)
            problems.extend(pool_problems)
            if not pool_problems:
                print(f"{pool['name']}: OK")
    except ValidationError as error:
        print(f"##vso[task.logissue type=error]{error}")
        return 1

    for problem in problems:
        print(f"##vso[task.logissue type=error]{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
