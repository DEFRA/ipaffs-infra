#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


source = pathlib.Path(__file__).with_name("validate-access-contract.py")
spec = importlib.util.spec_from_file_location("access_contract", source)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class AccessContractTests(unittest.TestCase):
    def valid(self):
        return {
            "ACCESS_SQL_ADMINS_GROUP_ID": "11111111-1111-1111-1111-111111111111",
            "ACCESS_ACR_PULL_GROUP_ID": "22222222-2222-2222-2222-222222222222",
            "ACCESS_CERTIFICATE_READERS_GROUP_ID": "33333333-3333-3333-3333-333333333333",
            "ACCESS_SQL_ADMINS_GROUP_NAME": "AAG-Azure-Example-SQLAdmins",
        }

    def test_existing_contract_is_accepted(self):
        self.assertEqual([], contract.validate(self.valid()))

    def test_unexpanded_library_reference_is_rejected(self):
        values = self.valid()
        values["ACCESS_SQL_ADMINS_GROUP_ID"] = "$(sqlAdminGroupId)"
        self.assertEqual(1, len(contract.validate(values)))

    def test_missing_and_nil_ids_are_rejected(self):
        values = self.valid()
        values["ACCESS_ACR_PULL_GROUP_ID"] = ""
        values["ACCESS_CERTIFICATE_READERS_GROUP_ID"] = "00000000-0000-0000-0000-000000000000"
        self.assertEqual(2, len(contract.validate(values)))

    def test_missing_display_name_is_rejected(self):
        values = self.valid()
        values["ACCESS_SQL_ADMINS_GROUP_NAME"] = "$(sqlAdminGroupName)"
        self.assertEqual(1, len(contract.validate(values)))


if __name__ == "__main__":
    unittest.main()
