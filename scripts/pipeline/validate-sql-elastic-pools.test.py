"""Exercise the Classic elastic pool checks without contacting Azure."""

import copy
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("validate-sql-elastic-pools.py")
SPEC = importlib.util.spec_from_file_location("validate_sql_elastic_pools", SCRIPT)
POOLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POOLS)

GIB = 1024 ** 3


def size(limit, unit="Gigabytes"):
    return {"limit": limit, "unit": unit}


def fixed_sizes(*gibs):
    return [{"minValue": size(gib), "maxValue": size(gib), "scaleSize": size(0), "status": "Available"}
            for gib in gibs]


def per_database(maximums, minimums=(0,), unit="DTU"):
    return [{"limit": float(maximum), "unit": unit, "status": "Available",
             "supportedPerDatabaseMinPerformanceLevels": [
                 {"limit": float(minimum), "unit": unit, "status": "Available"}
                 for minimum in minimums if minimum <= maximum]}
            for maximum in maximums]


MAINTENANCE = [{"name": "SQL_Default", "status": "Default", "zoneRedundant": True},
               {"name": "SQL_NorthEurope_DB_1", "status": "Available", "zoneRedundant": True}]

# Trimmed from the North Europe capabilities response (November 2026).
CAPABILITIES = {"name": "northeurope", "status": "Available", "supportedServerVersions": [{
    "name": "12.0", "status": "Default", "supportedElasticPoolEditions": [
        {"name": "Premium", "status": "Available", "supportedElasticPoolPerformanceLevels": [
            {"sku": {"name": "PremiumPool", "tier": "Premium", "capacity": 250}, "status": "Available",
             "maxDatabaseCount": 100, "zoneRedundant": True, "supportedLicenseTypes": [],
             "supportedMaintenanceConfigurations": MAINTENANCE,
             "supportedMaxSizes": fixed_sizes(50, 100, 150, 200, 250, 300, 400, 500, 750, 800, 1024),
             "supportedPerDatabaseMaxSizes": fixed_sizes(1024),
             "supportedPerDatabaseMaxPerformanceLevels": per_database((25, 50, 75, 125, 250), (0, 25, 50))},
            {"sku": {"name": "PremiumPool", "tier": "Premium", "capacity": 4000}, "status": "Disabled",
             "maxDatabaseCount": 100, "zoneRedundant": True, "supportedLicenseTypes": [],
             "supportedMaintenanceConfigurations": MAINTENANCE, "supportedMaxSizes": fixed_sizes(4096),
             "supportedPerDatabaseMaxSizes": fixed_sizes(4096),
             "supportedPerDatabaseMaxPerformanceLevels": per_database((4000,))},
        ]},
        {"name": "GeneralPurpose", "status": "Default", "supportedElasticPoolPerformanceLevels": [
            {"sku": {"name": "GP_Gen5", "tier": "GeneralPurpose", "family": "Gen5", "capacity": 2},
             "status": "Available", "maxDatabaseCount": 100, "zoneRedundant": True,
             "supportedLicenseTypes": [{"name": "LicenseIncluded", "status": "Default"},
                                       {"name": "BasePrice", "status": "Available"}],
             "supportedMaintenanceConfigurations": MAINTENANCE,
             "supportedMaxSizes": [{"minValue": size(32), "maxValue": size(512), "scaleSize": size(1),
                                    "status": "Available"}],
             "supportedPerDatabaseMaxSizes": [{"minValue": size(33792, "Megabytes"),
                                               "maxValue": size(524288, "Megabytes"),
                                               "scaleSize": size(1024, "Megabytes"), "status": "Available"}],
             "supportedPerDatabaseMaxPerformanceLevels": per_database((0.25, 0.5, 1, 2), (0, 0.25), "VCores")},
        ]},
        {"name": "Standard", "status": "Available", "supportedElasticPoolPerformanceLevels": [
            {"sku": {"name": "StandardPool", "tier": "Standard", "capacity": 50}, "status": "Available",
             "maxDatabaseCount": 100, "zoneRedundant": False, "supportedLicenseTypes": [],
             "supportedMaintenanceConfigurations": [{"name": "SQL_Default", "status": "Default",
                                                     "zoneRedundant": False}],
             "supportedMaxSizes": fixed_sizes(50, 100, 250, 500),
             "supportedPerDatabaseMaxSizes": fixed_sizes(500),
             "supportedPerDatabaseMaxPerformanceLevels": per_database((10, 20, 50))},
        ]},
    ]}]}

PREMIUM_POOL = {
    "serverName": "prdimpdbssqa001", "name": "prdimpedpsqa001",
    "sku": {"name": "PremiumPool", "tier": "Premium", "capacity": 250},
    "perDatabaseSettings": {"minCapacity": 0, "maxCapacity": 250},
    "maxSizeGiB": 750, "zoneRedundant": True, "maintenanceConfigurationName": "SQL_Default", "tags": {},
}
GP_POOL = {
    **PREMIUM_POOL,
    "sku": {"name": "GP_Gen5", "tier": "GeneralPurpose", "family": "Gen5", "capacity": 2},
    "perDatabaseSettings": {"minCapacity": 0, "maxCapacity": 2},
    "maxSizeGiB": 100, "licenseType": "BasePrice",
}
LIVE = {
    "location": "northeurope",
    "sku": {"name": "PremiumPool", "tier": "Premium", "capacity": 250},
    "perDatabaseSettings": {"minCapacity": 0.0, "maxCapacity": 250.0},
    "storageUsedBytes": 20 * GIB,
    "databases": [{"name": "notification-microservice", "maxSizeBytes": 100 * GIB}],
}


def pool(base=PREMIUM_POOL, **changes):
    return {**copy.deepcopy(base), **changes}


def live(**changes):
    return {**copy.deepcopy(LIVE), **changes}


class ValidatePoolTest(unittest.TestCase):
    def check(self, candidate, current=None):
        return POOLS.validate_pool(candidate, CAPABILITIES, current or live())

    def assertProblem(self, text, problems):
        self.assertEqual(1, len(problems), problems)
        self.assertIn(text, problems[0])

    def test_current_premium_and_recommended_vcore_settings_pass(self):
        self.assertEqual([], self.check(pool()))
        self.assertEqual([], self.check(pool(GP_POOL)))

    def test_family_is_optional_when_matching_a_sku(self):
        candidate = pool(GP_POOL)
        del candidate["sku"]["family"]
        self.assertEqual([], self.check(candidate))

    def test_unknown_or_disabled_skus_are_rejected(self):
        self.assertProblem("SKU PremiumPool 300 is not offered in northeurope",
                           self.check(pool(sku={"name": "PremiumPool", "tier": "Premium", "capacity": 300})))
        self.assertProblem("SKU PremiumPool 4000 is not offered",
                           self.check(pool(sku={"name": "PremiumPool", "tier": "Premium", "capacity": 4000})))
        self.assertProblem("is not offered",
                           self.check(pool(sku={"name": "PremiumPool", "tier": "Standard", "capacity": 250})))

    def test_max_size_must_be_a_listed_size(self):
        self.assertProblem("maxSizeGiB 700 is not allowed for PremiumPool 250. Allowed: 50, 100",
                           self.check(pool(maxSizeGiB=700)))

    def test_vcore_max_size_uses_the_range(self):
        self.assertEqual([], self.check(pool(GP_POOL, maxSizeGiB=33)))
        self.assertProblem("Allowed: 32-512 (step 1) GiB", self.check(pool(GP_POOL, maxSizeGiB=600)))
        self.assertProblem("maxSizeGiB 31", self.check(pool(GP_POOL, maxSizeGiB=31)))

    def test_per_database_limits_must_be_an_offered_pair(self):
        self.assertProblem("per-database maxCapacity 100 is not allowed for PremiumPool 250. "
                           "Allowed: 25, 50, 75, 125, 250",
                           self.check(pool(perDatabaseSettings={"minCapacity": 0, "maxCapacity": 100})))
        self.assertProblem("per-database minCapacity 75 is not allowed with maxCapacity 250",
                           self.check(pool(perDatabaseSettings={"minCapacity": 75, "maxCapacity": 250})))
        self.assertProblem("per-database maxCapacity 4 is not allowed for GP_Gen5 2",
                           self.check(pool(GP_POOL, perDatabaseSettings={"minCapacity": 0, "maxCapacity": 4})))

    def test_licence_type_only_on_vcore_and_only_supported_values(self):
        self.assertProblem("licenseType BasePrice is not allowed for PremiumPool 250. Allowed: none",
                           self.check(pool(licenseType="BasePrice")))
        self.assertEqual([], self.check(pool(GP_POOL, licenseType="LicenseIncluded")))
        self.assertProblem("licenseType Free is not allowed for GP_Gen5 2. Allowed: LicenseIncluded, BasePrice",
                           self.check(pool(GP_POOL, licenseType="Free")))

    def test_zone_redundancy_and_maintenance_must_be_supported(self):
        standard = pool(sku={"name": "StandardPool", "tier": "Standard", "capacity": 50},
                        perDatabaseSettings={"minCapacity": 0, "maxCapacity": 50}, maxSizeGiB=100)
        self.assertEqual([], self.check(pool(standard, zoneRedundant=False)))
        problems = self.check(standard)
        self.assertTrue(any("zone redundancy is not supported for StandardPool 50" in p for p in problems), problems)
        self.assertProblem("maintenance configuration SQL_Elsewhere is not supported",
                           self.check(pool(maintenanceConfigurationName="SQL_Elsewhere")))

    def test_max_size_cannot_drop_below_used_storage(self):
        self.assertProblem("maxSizeGiB 500 is below the 660 GiB the pool already uses",
                           self.check(pool(maxSizeGiB=500), live(storageUsedBytes=660 * GIB)))

    def test_live_databases_must_fit_the_new_sku(self):
        databases = [{"name": f"db{index}", "maxSizeBytes": GIB} for index in range(101)]
        self.assertProblem("the pool holds 101 databases but PremiumPool 250 allows 100",
                           self.check(pool(), live(databases=databases)))
        large = [{"name": "notification-microservice", "maxSizeBytes": 750 * GIB}]
        self.assertProblem("maximum size above the 512 GiB GP_Gen5 2 allows per database: "
                           "notification-microservice",
                           self.check(pool(GP_POOL, maxSizeGiB=512), live(databases=large)))

    def test_keep_live_capacity_checks_the_live_sku_instead_of_the_parameters(self):
        candidate = pool(keepLiveCapacity=True, sku={"name": "Nonsense", "tier": "Premium", "capacity": 1},
                         perDatabaseSettings={"minCapacity": 0, "maxCapacity": 999})
        self.assertEqual([], self.check(candidate))
        problems = self.check(candidate, live(perDatabaseSettings={"minCapacity": 0, "maxCapacity": 100}))
        self.assertProblem("maxCapacity 100 (live, keepLiveCapacity)", problems)


class MainTest(unittest.TestCase):
    ARGUMENTS = ["validate", "--parameters", "params.bicepparam", "--subscription", "sub", "--resource-group", "rg"]

    def run_main(self):
        output = io.StringIO()
        with patch.object(sys, "argv", self.ARGUMENTS), redirect_stdout(output):
            code = POOLS.main()
        return code, output.getvalue()

    def test_no_pools_is_a_success_without_azure_calls(self):
        with patch.object(POOLS, "read_pools", return_value=[]), \
                patch.object(POOLS, "run_az", side_effect=AssertionError("no Azure calls")):
            code, output = self.run_main()
        self.assertEqual(0, code)
        self.assertIn("No sqlPoolsParams entries", output)

    def test_problems_are_logged_as_pipeline_errors_and_fail(self):
        pools = [pool(), pool(name="second", maxSizeGiB=700)]
        with patch.object(POOLS, "read_pools", return_value=pools), \
                patch.object(POOLS, "read_live", return_value=live()) as read_live, \
                patch.object(POOLS, "run_az", return_value=CAPABILITIES) as run_az:
            code, output = self.run_main()
        self.assertEqual(1, code)
        self.assertIn("prdimpedpsqa001: OK", output)
        self.assertIn("##vso[task.logissue type=error]second: maxSizeGiB 700", output)
        self.assertEqual(2, read_live.call_count)
        run_az.assert_called_once()
        self.assertIn("locations/northeurope/capabilities", " ".join(run_az.call_args.args[0]))

    def test_pools_in_other_resource_groups_are_read_there(self):
        calls = []

        def fake_az(arguments, operation):
            calls.append(arguments)
            if arguments[:3] == ["sql", "elastic-pool", "show"]:
                return {"id": "/pool", "location": "northeurope", "sku": LIVE["sku"],
                        "perDatabaseSettings": LIVE["perDatabaseSettings"]}
            if arguments[:3] == ["sql", "elastic-pool", "list-dbs"]:
                return []
            return {"value": [{"timeseries": [{"data": [{"maximum": 5.0}, {"maximum": None}]}]}]}

        with patch.object(POOLS, "run_az", side_effect=fake_az):
            result = POOLS.read_live(pool(resourceGroupName="OTHER"), "sub", "rg")
            POOLS.read_live(pool(), "sub", "rg")
        self.assertEqual(5, result["storageUsedBytes"])
        self.assertIn("OTHER", calls[0])
        self.assertIn("rg", calls[3])

    def test_azure_failures_stop_without_echoing_cli_output(self):
        failed = subprocess.CompletedProcess([], 1, "", "secret detail")
        with patch.object(POOLS, "read_pools", return_value=[pool()]), \
                patch.object(POOLS.subprocess, "run", return_value=failed):
            code, output = self.run_main()
        self.assertEqual(1, code)
        self.assertIn("Reading elastic pool prdimpedpsqa001 failed (Azure CLI exit 1)", output)
        self.assertNotIn("secret detail", output)


if __name__ == "__main__":
    unittest.main()
