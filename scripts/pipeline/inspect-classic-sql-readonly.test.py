#!/usr/bin/env python3
"""Offline safety checks for the temporary read-only SQL investigation."""

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("sql_readonly", Path(__file__).with_name("inspect-classic-sql-readonly.py"))
READONLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READONLY)


class ClassicSqlReadonlyTests(unittest.TestCase):
    def test_known_call_projects_only_parameter_values_and_accepts_whitespace(self):
        command = """EXECUTE [dbo].[DBA_Sch_Weekly_Index_Maintenance]
          @FragLvl2 = 70, @ExclTablenames=N'[dbo].[notification_audit],dbo.audit_log', @FragLvl1=30; """
        result = READONLY.command_projection(command)
        self.assertEqual("recognised", result["status"])
        self.assertEqual({"FragLvl1": 30, "FragLvl2": 70,
                          "ExclTablenames": ["dbo.notification_audit", "dbo.audit_log"]}, result["parameters"])
        self.assertEqual([], result["omittedKnownParameters"])
        self.assertEqual(1, result["statementCount"])
        self.assertFalse(result["containsUnparsedContent"])
        self.assertEqual(64, len(result["sha256"]))
        self.assertNotIn("EXECUTE", json.dumps(result))

    def test_omitted_parameters_are_explicit_instead_of_inventing_defaults(self):
        result = READONLY.command_projection("EXEC dbo.DBA_Sch_Weekly_Index_Maintenance;")
        self.assertEqual("recognised", result["status"])
        self.assertEqual({}, result["parameters"])
        self.assertEqual(["ExclTablenames", "FragLvl1", "FragLvl2"], result["omittedKnownParameters"])

    def test_arbitrary_sql_duplicate_parameters_and_extra_statements_never_escape(self):
        prefix = "EXEC dbo.DBA_Sch_Weekly_Index_Maintenance "
        for command in (
                "EXEC dbo.private_secret_proc;", prefix + "@Unknown='private-secret-value';",
                prefix + "@ExclTablenames='dbo.audit'; PRINT 'private-secret-value';",
                prefix + "@ExclTablenames='dbo.audit'';private-secret-value';",
                prefix + "@FragLvl1=30,@FragLvl1=70;", prefix + "@FragLvl1=999;",
                prefix + "@ExclTablenames='private-secret-value';",
                prefix + "@ExclTablenames='dbo.audit',;", prefix + "/* private-secret-value */",
                "EXEC dbo.DBA_Sch_Weekly_Index_Maintenance_private_secret_proc;",
        ):
            with self.subTest(command=command):
                result = READONLY.command_projection(command)
                self.assertEqual({"status", "sha256", "statementCount", "containsUnparsedContent"}, set(result))
                self.assertEqual("unknown", result["status"])
                self.assertTrue(result["containsUnparsedContent"])
                self.assertIsNone(result["statementCount"])
                self.assertNotIn("private-secret", json.dumps(result))

    def test_members_are_reprojected_and_credentials_are_never_selected(self):
        result = READONLY.member_projection({
            "membershipType": "Include", "type": "SqlDatabase", "serverName": "preimpdbssqa001.database.windows.net",
            "databaseName": "PREIMPDBSDBA001", "refreshCredential": "private-secret-credential",
            "connectionString": "private-secret-connection",
        })
        self.assertEqual({"membershipType", "type", "serverName", "databaseName"}, set(result))
        self.assertNotIn("private-secret", json.dumps(result))
        for value in ({"membershipType": "unexpected"}, {"membershipType": "Include", "type": "Unexpected"},
                      {"membershipType": "Include", "type": "SqlDatabase", "serverName": "secret;token=private-secret"},
                      {"membershipType": "Include", "type": "SqlDatabase", "serverName": "valid", "databaseName": "secret\nvalue"}):
            self.assertIsNone(READONLY.member_projection(value))

    def test_schedule_is_selected_without_description_or_arbitrary_metadata(self):
        schedule = {"type": "Recurring", "enabled": True, "interval": "P1W",
                    "startTime": "1900-01-01T00:00:00Z", "endTime": "9999-12-31T11:59:59Z",
                    "description": "private-secret-value"}
        result = READONLY.schedule_projection(schedule)
        self.assertNotIn("private-secret", json.dumps(result))
        self.assertEqual("P1W", result["interval"])
        self.assertIsNone(READONLY.schedule_projection({**schedule, "startTime": "private-secret-value"}))
        for timestamp in ("2026-11-04T09:52:18.2173817Z", "2026-11-04T09:52:18.2173817+00:00"):
            result = READONLY.schedule_projection({**schedule, "startTime": timestamp})
            self.assertEqual(timestamp, result["startTime"])
        self.assertIsNone(READONLY.schedule_projection({**schedule, "startTime": "2026-11-04T09:52:18.2173817Z;private-secret"}))

    def test_bicep_version_records_only_a_numeric_version_without_installing(self):
        for stdout, expected in (("Bicep CLI version 0.36.1 (private-secret-metadata)\n", "0.36.1"),
                                 ("private-secret-metadata", "unavailable")):
            with mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0, stdout, "private-secret-error")) as command:
                result = READONLY.bicep_version()
            self.assertEqual(expected, result)
            self.assertEqual(["az", "bicep", "version"], command.call_args.args[0])
            self.assertNotIn("private-secret", result)

    def test_investigation_uses_only_three_fixed_gets_and_withholds_raw_error_payloads(self):
        calls = []
        def response(command, **kwargs):
            calls.append(command)
            self.assertTrue(kwargs["capture_output"])
            self.assertEqual(["az", "rest", "--method", "get", "--url"], command[:5])
            url = command[5]
            self.assertTrue(url.startswith("https://management.azure.com/subscriptions/81ca326e-6270-418a-b764-e02a4ca60457/"))
            self.assertTrue(url.endswith("?api-version=2023-08-01"))
            if "/targetGroups/" in url:
                properties = {"members": [{"membershipType": "Include", "type": "SqlDatabase",
                    "serverName": "preimpdbssqa001.database.windows.net", "databaseName": "sampledb", "secret": "private-secret"}]}
            elif "/steps/" in url:
                properties = {"action": {"type": "TSql", "source": "Inline", "value": "EXEC dbo.private_secret_proc;"}}
            else:
                return subprocess.CompletedProcess(command, 1, "private-secret-body", "private-secret-error")
            return subprocess.CompletedProcess(command, 0, json.dumps({"id": url[28:].split("?")[0], "properties": properties}), "")
        with mock.patch("subprocess.run", side_effect=response):
            result = READONLY.inspect("PRE")
        self.assertEqual(3, len(calls))
        self.assertEqual("complete", result["targetGroup"]["status"])
        self.assertEqual("unavailable", result["weeklyJob"]["status"])
        self.assertEqual("unknown", result["weeklyStep"]["command"]["status"])
        self.assertNotIn("private-secret", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
