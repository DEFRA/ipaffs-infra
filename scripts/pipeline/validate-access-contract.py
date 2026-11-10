#!/usr/bin/env python3
"""Check the directory-group contract supplied by the operations access pipeline."""

import os
import sys
import uuid


GROUP_IDS = (
    "ACCESS_SQL_ADMINS_GROUP_ID",
    "ACCESS_ACR_PULL_GROUP_ID",
    "ACCESS_CERTIFICATE_READERS_GROUP_ID",
)


def validate(values):
    errors = []
    for name in GROUP_IDS:
        value = values.get(name, "").strip()
        try:
            parsed = uuid.UUID(value)
            if parsed.int == 0:
                raise ValueError("nil UUID")
        except ValueError:
            errors.append(f"{name} must contain an existing group object ID")
    group_name = values.get("ACCESS_SQL_ADMINS_GROUP_NAME", "").strip()
    if not group_name or "$(" in group_name:
        errors.append("ACCESS_SQL_ADMINS_GROUP_NAME must contain the existing SQL administrator group name")
    return errors


def main():
    errors = validate(os.environ)
    if errors:
        print("Operations access-group contract is incomplete:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        print(
            "Run ipaffs-operations pipelines/access-management.yaml with groupsOnly=true "
            "for this environment before provisioning infrastructure. Existing group IDs "
            "must remain in the Common/LowerEnvs/HigherEnvs/environment Library contract.",
            file=sys.stderr,
        )
        return 1
    print("Operations access-group contract is available; infrastructure can use the existing groups.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
