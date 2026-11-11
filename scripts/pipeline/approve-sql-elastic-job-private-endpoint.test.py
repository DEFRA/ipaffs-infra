"""Exercise scoped Elastic Jobs approval without contacting Azure."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("approve-sql-elastic-job-private-endpoint.py")
SPEC = importlib.util.spec_from_file_location("approve_sql_elastic_job_private_endpoint", SCRIPT)
APPROVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPROVAL)

SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
OTHER_SUBSCRIPTION = "22222222-2222-2222-2222-222222222222"
SERVER = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/classic/providers/Microsoft.Sql/servers/classic-sql"
ENDPOINT = f"{SERVER}/jobAgents/classic-agent/privateEndpoints/classic-agent"
CONNECTIONS = f"{SERVER}/privateEndpointConnections"
CONNECTION = f"{CONNECTIONS}/connection.123"
MANAGED_NAME = "EJ_abcdef_classic-agent"
MANAGED_ENDPOINT = (
    f"/subscriptions/{OTHER_SUBSCRIPTION}/resourceGroups/managed/providers/Microsoft.Network"
    f"/privateEndpoints/{MANAGED_NAME}"
)


def endpoint(managed_id=MANAGED_NAME, target=SERVER):
    return {"id": ENDPOINT, "properties": {"targetServerAzureResourceId": target, "privateEndpointId": managed_id}}


def connection(status, *, connection_id=CONNECTION, managed_id=MANAGED_ENDPOINT, provisioning="Ready"):
    return {
        "id": connection_id,
        "properties": {
            "privateEndpoint": {"id": managed_id},
            "privateLinkServiceConnectionState": {"status": status},
            "provisioningState": provisioning,
        },
    }


def page(*connections, next_link=None):
    return {"value": list(connections), "nextLink": next_link}


class ApprovalTests(unittest.TestCase):
    def setUp(self):
        self.cli = self.enterContext(patch.object(APPROVAL.subprocess, "run"))
        self.enterContext(patch.object(APPROVAL.time, "sleep"))
        self.enterContext(patch.object(APPROVAL, "POLL_ATTEMPTS", 3))
        self.output = self.enterContext(redirect_stdout(io.StringIO()))

    def responses(self, *responses):
        self.cli.side_effect = [
            response if isinstance(response, subprocess.CompletedProcess)
            else subprocess.CompletedProcess([], 0, json.dumps(response), "")
            for response in responses
        ]

    def approvals(self):
        return [call.args[0] for call in self.cli.call_args_list
                if call.args[0][1:4] == ["rest", "--method", "put"]]

    def test_approves_only_exact_target_across_pages_and_verifies_status(self):
        absent = subprocess.CompletedProcess([], 1, "", 'ERROR: Not Found({"error":{"code":"ResourceNotFound"}})')
        next_link = f"https://management.azure.com{CONNECTIONS}?api-version=2025-01-01&$skipToken=one"
        unrelated = connection("Pending", connection_id=f"{CONNECTIONS}/unrelated",
                               managed_id=f"{MANAGED_ENDPOINT}-backup")
        self.responses(absent, endpoint(None), endpoint(), page(unrelated, next_link=next_link),
                       page(connection("Pending")), None, page(connection("Pending", provisioning="Approving")),
                       page(connection("Approved")))
        APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual(1, len(self.approvals()))
        command = self.approvals()[0]
        self.assertEqual(f"{CONNECTION}?api-version=2025-01-01", command[command.index("--url") + 1])
        self.assertEqual(SUBSCRIPTION, command[command.index("--subscription") + 1])
        self.assertEqual({"properties": {"privateLinkServiceConnectionState": {
            "status": "Approved", "description": "Approved by the IPAFFS Classic deployment",
        }}}, json.loads(command[command.index("--body") + 1]))
        self.assertIn(CONNECTION, self.output.getvalue())

    def test_already_approved_full_id_ignores_same_leaf_in_another_group(self):
        unrelated = connection("Pending", connection_id=f"{CONNECTIONS}/unrelated",
                               managed_id=MANAGED_ENDPOINT.replace("/managed/", "/other/"))
        self.responses(endpoint(MANAGED_ENDPOINT.upper(), target=SERVER.upper()),
                       page(unrelated, connection("Approved")))
        APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual([], self.approvals())

    def test_duplicate_leaf_is_ambiguous(self):
        duplicate = connection("Pending", connection_id=f"{CONNECTIONS}/duplicate",
                               managed_id=MANAGED_ENDPOINT.replace("/managed/", "/other/"))
        self.responses(endpoint(), page(connection("Approved"), duplicate))
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "More than one SQL connection"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual([], self.approvals())

    def test_wrong_scope_cannot_be_approved(self):
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "Classic subscription"):
            APPROVAL.approve(ENDPOINT, OTHER_SUBSCRIPTION)
        self.cli.assert_not_called()
        self.responses(endpoint(target=SERVER.replace("/classic-sql", "/other")))
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "different SQL server"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.responses(endpoint(), page(connection("Pending", connection_id=CONNECTION.replace("/classic-sql/", "/other/"))))
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "outside the target SQL server"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual([], self.approvals())

    def test_continuation_link_cannot_leave_target_collection(self):
        wrong_url = f"https://management.azure.com{CONNECTIONS.replace('/classic-sql/', '/other/')}?skip=1"
        self.responses(endpoint(), page(connection("Pending"), next_link=wrong_url))
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "continuation link outside the target server"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual([], self.approvals())

    def test_rejected_and_unexpected_provisioning_states_cannot_be_approved(self):
        for status, provisioning in (("Rejected", "Ready"), ("Pending", "Dropping")):
            with self.subTest(status=status, provisioning=provisioning):
                self.responses(endpoint(), page(connection(status, provisioning=provisioning)))
                with self.assertRaises(APPROVAL.ApprovalError):
                    APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual([], self.approvals())

    def test_concurrent_approval_is_accepted_for_the_same_connection(self):
        failed = subprocess.CompletedProcess([], 1, "", "not Pending")
        for current in (connection("Approved"), connection("Pending", provisioning="Approving")):
            with self.subTest(provisioning=current["properties"]["provisioningState"]):
                self.cli.reset_mock()
                self.responses(endpoint(), page(connection("Pending")), failed, page(current),
                               page(connection("Approved")))
                APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
                self.assertEqual(1, len(self.approvals()))

    def test_approval_error_remains_a_failure_when_the_connection_is_pending(self):
        failed = subprocess.CompletedProcess([], 17, "", "unexpected response body")
        self.responses(endpoint(), page(connection("Pending")), failed, page(connection("Pending")))
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "Approve SQL private endpoint connection failed .*17"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual(1, len(self.approvals()))

    def test_pending_after_approval_times_out_without_repeating_write(self):
        pending = page(connection("Pending"))
        self.responses(endpoint(), pending, None, pending, pending, pending)
        with self.assertRaisesRegex(APPROVAL.ApprovalError, "Timed out waiting.*Approved"):
            APPROVAL.approve(ENDPOINT, SUBSCRIPTION)
        self.assertEqual(1, len(self.approvals()))


if __name__ == "__main__":
    unittest.main()
