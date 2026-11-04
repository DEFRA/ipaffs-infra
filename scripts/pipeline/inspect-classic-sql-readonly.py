#!/usr/bin/env python3
"""Temporary investigation: project selected Classic SQL metadata from GETs only.

Never publish ARM responses or arbitrary SQL. Unexpected commands produce only
an unknown marker and digest; expected maintenance calls have a strict grammar.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


SCOPES = {
    "PRE": ("81ca326e-6270-418a-b764-e02a4ca60457", "PREIMPINFRGP001", "PREIMPDBSSQA001", "PREIMPDBSJBA001"),
    "PRD": ("79ee8c9c-33d7-4074-9f4c-a13f07c62a33", "PRDIMPINFRGP001", "PRDIMPDBSSQA001", "PRDIMPDBSJBA001"),
}
IDENTIFIER = r"(?:[A-Za-z_][A-Za-z0-9_]{0,127}|\[[A-Za-z_][A-Za-z0-9_]{0,127}\])"
EXCLUSION = re.compile(rf"{IDENTIFIER}\.{IDENTIFIER}")
MEMBER_NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_. -]{0,127}")
HOST = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}")
PARAMETER = re.compile(r"\s*@(?P<name>ExclTablenames|FragLvl1|FragLvl2)\s*=\s*(?P<value>N?'(?:[^']|'')*'|[0-9]{1,3})\s*", re.I)
PROCEDURE = re.compile(r"\s*EXEC(?:UTE)?\s+(?:dbo|\[dbo\])\s*\.\s*(?:DBA_Sch_Weekly_Index_Maintenance|\[DBA_Sch_Weekly_Index_Maintenance\])(?=\s|;|$)", re.I)


def command_projection(command):
    """Recognise one known procedure call; never return arbitrary source text."""
    if not isinstance(command, str):
        return {"status": "unknown", "sha256": None, "statementCount": None, "containsUnparsedContent": True}
    output = {"status": "unknown", "sha256": hashlib.sha256(command.encode("utf-8", errors="replace")).hexdigest(),
              "statementCount": None, "containsUnparsedContent": True}
    match = PROCEDURE.match(command)
    if not match:
        return output
    remainder = command[match.end():].strip()
    if remainder.endswith(";"):
        remainder = remainder[:-1].rstrip()
    supplied = {}
    canonical_names = {"excltablenames": "ExclTablenames", "fraglvl1": "FragLvl1", "fraglvl2": "FragLvl2"}
    while remainder:
        match = PARAMETER.match(remainder)
        if not match:
            return output
        name, value = canonical_names[match["name"].lower()], match["value"]
        if name in supplied:
            return output
        if name == "ExclTablenames":
            if not re.fullmatch(r"N?'(?:[^']|'')*'", value, re.I):
                return output
            literal = value[1:] if value[:1].lower() == "n" else value
            excluded = [item.strip() for item in literal[1:-1].split(",")] if literal[1:-1].strip() else []
            if len(excluded) > 100 or any(not EXCLUSION.fullmatch(item) for item in excluded):
                return output
            supplied[name] = [item.replace("[", "").replace("]", "") for item in excluded]
        else:
            if not value.isdecimal() or not 0 <= int(value) <= 100:
                return output
            supplied[name] = int(value)
        remainder = remainder[match.end():]
        if remainder:
            if not remainder.startswith(",") or not remainder[1:].strip():
                return output
            remainder = remainder[1:]
    output.update(status="recognised", statementCount=1, containsUnparsedContent=False,
                  procedure="dbo.DBA_Sch_Weekly_Index_Maintenance", parameters=supplied,
                  omittedKnownParameters=[name for name in canonical_names.values() if name not in supplied])
    return output


def member_projection(value):
    if not isinstance(value, dict) or value.get("membershipType") not in {"Include", "Exclude"}:
        return None
    kind = value.get("type")
    if kind not in {"SqlDatabase", "SqlElasticPool", "SqlServer"}:
        return None
    server = value.get("serverName")
    if not isinstance(server, str) or not HOST.fullmatch(server):
        return None
    output = {"membershipType": value["membershipType"], "type": kind, "serverName": server}
    for key in ("databaseName", "elasticPoolName"):
        field = value.get(key)
        if field is not None:
            if not isinstance(field, str) or field != field.strip() or not MEMBER_NAME.fullmatch(field):
                return None
            output[key] = field
    if (kind == "SqlDatabase" and "databaseName" not in output
            or kind == "SqlElasticPool" and "elasticPoolName" not in output):
        return None
    return output


def schedule_projection(value):
    if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
        return None
    if value.get("type") not in {"Once", "Recurring"}:
        return None
    output = {"enabled": value["enabled"], "type": value["type"]}
    for key in ("startTime", "endTime"):
        field = value.get(key)
        if not isinstance(field, str) or len(field) > 50:
            return None
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})", field):
            return None
        try:
            # ARM uses seven fractional digits; Python 3.10 accepts at most six.
            normalised = re.sub(r"(\.[0-9]{6})[0-9](?=Z|[+-][0-9]{2}:[0-9]{2}$)", r"\1", field)
            instant = datetime.fromisoformat(normalised.replace("Z", "+00:00"))
            if instant.utcoffset() is None:
                return None
        except ValueError:
            return None
        output[key] = field
    interval = value.get("interval")
    if interval is not None:
        if not isinstance(interval, str) or not re.fullmatch(r"P[0-9YMWDTHS.]{1,30}", interval):
            return None
        output["interval"] = interval
    return output


def read_resource(resource_id):
    """Each resource lookup is a fixed-resource ARM GET, captured privately."""
    result = subprocess.run(
        ["az", "rest", "--method", "get", "--url",
         "https://management.azure.com" + resource_id + "?api-version=2023-08-01",
         "--only-show-errors", "--output", "json"],
        capture_output=True, text=True, timeout=90,
    )
    if result.returncode:
        raise ValueError("READ_FAILED")
    body = json.loads(result.stdout)
    if not isinstance(body, dict) or str(body.get("id", "")).lower() != resource_id.lower():
        raise ValueError("RESOURCE_ID_MISMATCH")
    return body.get("properties")


def bicep_version():
    """Capture only the numeric CLI version; never install or update tooling."""
    try:
        result = subprocess.run(["az", "bicep", "version"], capture_output=True, text=True, timeout=30)
        match = re.search(r"\bBicep CLI version ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(?=\s|$)", result.stdout)
        return match[1] if result.returncode == 0 and match else "unavailable"
    except Exception:
        return "unavailable"


def inspect(environment):
    subscription, group, server, agent = SCOPES[environment]
    base = f"/subscriptions/{subscription}/resourceGroups/{group}/providers/Microsoft.Sql/servers/{server}/jobAgents/{agent}"
    evidence = {"schemaVersion": 1, "environment": environment, "readOnly": True,
                "generatedAt": datetime.now(timezone.utc).isoformat(),
                "scope": {"subscriptionId": subscription, "resourceGroupName": group, "serverName": server, "jobAgentName": agent}}
    routes = {"targetGroup": "/targetGroups/index-maintenance",
              "weeklyJob": "/jobs/DBA_MAINT_INDEX_WEEKLY",
              "weeklyStep": "/jobs/DBA_MAINT_INDEX_WEEKLY/steps/JobStep"}
    for name, suffix in routes.items():
        try:
            properties = read_resource(base + suffix)
            if not isinstance(properties, dict):
                raise ValueError("PROPERTIES_NOT_RECOGNISED")
            if name == "targetGroup":
                members = properties.get("members")
                if not isinstance(members, list) or len(members) > 1000:
                    raise ValueError("MEMBERS_NOT_RECOGNISED")
                selected = [member_projection(member) for member in members]
                evidence[name] = {"status": "complete" if all(member is not None for member in selected) else "incomplete",
                                  "memberCount": len(members), "members": [member for member in selected if member is not None],
                                  "unrecognisedMemberCount": sum(member is None for member in selected)}
            elif name == "weeklyJob":
                schedule = schedule_projection(properties.get("schedule"))
                evidence[name] = {"status": "complete" if schedule is not None else "incomplete", "schedule": schedule}
            else:
                action = properties.get("action")
                if not isinstance(action, dict) or action.get("type") != "TSql" or action.get("source") != "Inline":
                    raise ValueError("ACTION_NOT_RECOGNISED")
                evidence[name] = {"status": "complete", "actionType": "TSql", "actionSource": "Inline",
                                  "command": command_projection(action.get("value"))}
        except Exception:
            # Azure error text, unexpected metadata, and raw SQL stay private.
            evidence[name] = {"status": "unavailable", "reasonCode": "READ_OR_PROJECTION_FAILED"}
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True, choices=SCOPES)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    evidence = inspect(args.environment)
    evidence["toolVersions"] = {"bicep": bicep_version()}
    commit, build_id = os.environ.get("BUILD_SOURCEVERSION", ""), os.environ.get("BUILD_BUILDID", "")
    if re.fullmatch(r"[a-fA-F0-9]{40}", commit):
        evidence["previewCommit"] = commit
    if re.fullmatch(r"[0-9]{1,20}", build_id):
        evidence["previewBuildId"] = build_id
    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / "classic-sql-readonly-evidence.json"
    destination.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"{args.environment}: sanitised read-only SQL evidence written.")
    return int(any(evidence[key]["status"] != "complete" for key in ("targetGroup", "weeklyJob", "weeklyStep")))


if __name__ == "__main__":
    raise SystemExit(main())
