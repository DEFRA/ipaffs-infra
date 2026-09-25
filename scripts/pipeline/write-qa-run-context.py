#!/usr/bin/env python3
"""Write allowlisted QA provenance without treating a selected resource as a trigger."""

import json
import os
import sys
from pathlib import Path


def value(name):
    result = os.environ.get(name, "").strip()
    # ADO leaves undefined macros unexpanded, notably on legacy/manual runs.
    return None if not result or result.startswith("$(") else result


def identifier(name):
    result = value(name)
    return int(result) if result and result.isdecimal() and int(result) > 0 else None


def context():
    reason = value("QA_BUILD_REASON")
    # Match the shell's space-only empty check and retain the exact grep expression.
    raw_filter = os.environ.get("QA_TEST_FILTER", "")
    test_filter = raw_filter if raw_filter.replace(" ", "") else None
    requested_suite = value("QA_TEST_SUITE")
    deployment = None
    if reason == "ResourceTrigger" and value("QA_TRIGGER_ALIAS") == "deployment":
        run_id = identifier("QA_DEPLOYMENT_RUN_ID")
        pipeline_id = identifier("QA_DEPLOYMENT_PIPELINE_ID")
        source_ref = value("QA_DEPLOYMENT_SOURCE_REF")
        source_commit = value("QA_DEPLOYMENT_SOURCE_COMMIT")
        if not all((run_id, pipeline_id, source_ref, source_commit)):
            raise ValueError("Deployment-triggered QA is missing upstream run metadata")
        deployment = {
            "runId": run_id,
            "pipelineId": pipeline_id,
            "sourceRef": source_ref,
            "sourceCommit": source_commit,
        }
    return {
        "schemaVersion": 1,
        "environment": value("QA_ENVIRONMENT"),
        "qaRunId": identifier("QA_RUN_ID"),
        "qaPipelineId": identifier("QA_PIPELINE_ID"),
        "buildReason": reason,
        "triggerKind": "deployment" if deployment else {
            "Manual": "manual", "Schedule": "scheduled"
        }.get(reason, "other"),
        "triggeringDeployment": deployment,
        # A trigger relationship does not prove which application version tests observed.
        "deployedVersionVerified": False,
        "requestedSuite": requested_suite,
        "effectiveSuite": "test" if test_filter else requested_suite,
        "testFilter": test_filter,
        # This is deliberately not presented as an immutable QA image identity.
        "requestedImageTag": value("QA_IMAGE_TAG"),
    }


if __name__ == "__main__":
    data = context()
    destination = Path(sys.argv[1])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, indent=2) + "\n")
