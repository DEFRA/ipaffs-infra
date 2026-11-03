#!/usr/bin/env python3
"""Publish value-redacted ARM what-if reports; never persist the input payloads.

The JSON artifact is deliberately a projection, not a copy of Azure's result.
Only resource identifiers and explicitly allowed configuration values leave this
module. In particular, diagnostics, deployment parameters, outputs and arbitrary
before/after payloads must never be written to pipeline artifacts.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import html
import json
import math
from pathlib import Path
import re


CHANGE_TYPES = ("Create", "Modify", "Delete", "NoChange", "Deploy", "Ignore", "Unsupported", "Unknown")
RELEASE_ENVIRONMENTS = ("TST", "PRE", "PRD")
UNRESOLVED_TYPES = {"Deploy", "Ignore", "Unsupported", "Unknown"}
ERROR_CODES = {
    "AZURE_CLI_TOO_OLD", "AZURE_COMMAND_FAILED", "AZURE_RESPONSE_UNAVAILABLE",
    "COMMAND_NOT_ALLOWED", "INVALID_OUTPUT_DIRECTORY", "INVALID_SOURCE_IDENTITY",
    "INVALID_SUBSCRIPTION", "MISSING_INPUT", "PARAMETER_RESOLUTION_FAILED",
    "PREVIEW_STATE_MISMATCH", "PRIVATE_STATE_OVERLAPS_REPORT", "SOURCE_COMMIT_MISMATCH",
    "UNRESOLVED_RESOURCE_NAME", "UNRESOLVED_SUBNET", "UPSTREAM_IDENTITY_UNAVAILABLE",
    "UPSTREAM_IDENTITY_WILL_CHANGE", "WHAT_IF_INCOMPLETE", "PREVIEW_FAILED", "NOT_RUN",
}
WITHHELD = "[withheld]"
MISSING = "[not present]"
LIMITATIONS = [
    "This is an ARM what-if prediction against the live environment, not a saved executable plan or a guarantee of deployment success.",
    "Proposed deterministic resource IDs are derived from candidate parameters; existing identity inputs come from Library/live resources. Future generated principal IDs and outputs cannot be predicted.",
    "Hooks, peering pipeline execution, Azure DevOps output persistence, Entra/group memberships and scripted DNS changes are outside this ARM preview.",
    "Refresh the preview before applying each environment: resources and inputs can change after this report was generated.",
    "Values are withheld unless their configuration path is explicitly approved for publication. Raw Azure payloads and diagnostic messages are not published.",
]
_IDENTIFIER = re.compile(r"^[A-Za-z0-9/][A-Za-z0-9._/()@:+ -]{0,1023}$")
_PROPERTY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.\[\]-]{0,511}$")
_SECRET = re.compile(r"password|secret|credential|connectionstring|token|protectedsettings|privatekey|accesskey|accountkey|sas|parameters|outputs|appsettings", re.I)
_EXPRESSION = re.compile(r"^\s*\[.*\]\s*$", re.S)
_BOOLEAN_LEAVES = {
    "enabled", "httpsonly", "supportshttpstrafficonly", "allowblobpublicaccess",
    "allowsharedkeyaccess", "ishnsenabled", "issftpenabled", "enablerbacauthorization",
    "enablepurgeprotection", "enablesoftdelete", "enableddosprotection",
    "enablevmprotection", "enableautoScaling", "enableautoupgrade", "enableencryption",
    "enableprivatelink", "disablelocalaccount", "disablelocalauth",
}
_NUMBER_LEAVES = {
    "capacity", "count", "nodecount", "replicas", "mincount", "maxcount", "osdisksizegb",
    "maxsizebytes", "retentionindays", "backupretentiondays", "partitions", "replicacount",
}
_ENUM_LEAVES = {
    "publicnetworkaccess", "minimumtlsversion", "mintlsversion", "accesstier",
    "networkaccess", "defaultaction", "tlsversion", "osdisktype", "ostype", "vmsize",
}


def _identifier(value, fallback="unavailable"):
    return value if isinstance(value, str) and _IDENTIFIER.fullmatch(value) else fallback


def _metadata(source):
    source = source if isinstance(source, dict) else {}
    environment = source.get("environment", "UNKNOWN")
    commit = str(source.get("commit", ""))
    source_ref = source.get("sourceRef", "")
    generated = source.get("generatedAt", "")
    return {
        "environment": environment if isinstance(environment, str) and re.fullmatch(r"[A-Z][A-Z0-9_-]{0,19}", environment) else "UNKNOWN",
        "commit": commit if re.fullmatch(r"[a-fA-F0-9]{7,64}", commit) else "unavailable",
        "sourceRef": source_ref if isinstance(source_ref, str) and re.fullmatch(r"refs/[A-Za-z0-9/_ .-]{1,240}", source_ref) else "unavailable",
        "buildId": str(source.get("buildId", "")) if re.fullmatch(r"[0-9]{1,20}", str(source.get("buildId", ""))) else "unavailable",
        "generatedAt": generated if isinstance(generated, str) and re.fullmatch(r"[0-9TtZz:.+ -]{10,40}", generated) else datetime.now(timezone.utc).isoformat(),
        "parameterSource": "candidate parameters with current Library/live identity inputs",
    }


def _scope(source):
    if isinstance(source, str):
        return _identifier(source)
    if isinstance(source, dict):
        return {key: _identifier(source[key]) for key in ("kind", "subscriptionId", "resourceGroup", "location") if key in source}
    return "unavailable"


def _path(value):
    if not isinstance(value, str):
        return "[unrecognised property]"
    # Dictionary keys and array selector strings may themselves contain values.
    value = re.sub(r"\[['\"].*?['\"]\]", "[entry]", value)
    return value if _PROPERTY.fullmatch(value) else "[unrecognised property]"


def _join_path(parent, child):
    if not parent or child.startswith(parent + ".") or child.startswith(parent + "["):
        return child
    return parent + ("" if child.startswith("[") else ".") + child


def _unresolved(value):
    if isinstance(value, str):
        return bool(_EXPRESSION.fullmatch(value))
    if isinstance(value, list):
        return any(_unresolved(item) for item in value)
    if isinstance(value, dict):
        return any(_unresolved(item) for item in value.values())
    return False


def _public_value(path, value, present=True):
    if not present:
        return MISSING
    if _SECRET.search(path) or path == "[unrecognised property]":
        return WITHHELD
    normal = re.sub(r"\[\d+\]|\.\d+(?=\.|$)", "", path).lower()
    leaf = normal.rsplit(".", 1)[-1]
    sku = normal in {"sku.name", "sku.tier", "sku.size", "sku.family", "sku.capacity"}
    numeric = leaf in _NUMBER_LEAVES
    boolean = leaf in {name.lower() for name in _BOOLEAN_LEAVES}
    enum = leaf in _ENUM_LEAVES or normal in {"location", "kind"} or sku
    if _unresolved(value):
        return "[unresolved expression]"
    if boolean and isinstance(value, bool):
        return value
    if (numeric or normal == "sku.capacity") and isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return value
    if enum and isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,79}", value):
        return value
    return WITHHELD


def _fields(delta, parent=""):
    fields = []
    if not isinstance(delta, list):
        return fields
    for change in delta:
        if not isinstance(change, dict):
            continue
        raw_path = change.get("path", "")
        full_path = _join_path(parent, raw_path) if isinstance(raw_path, str) else ""
        children = change.get("children", change.get("childDelta"))
        if isinstance(children, list) and children:
            fields.extend(_fields(children, full_path))
            continue
        path = _path(full_path)
        change_type = change.get("propertyChangeType")
        fields.append({
            "path": path,
            "changeType": change_type if change_type in {"Create", "Delete", "Modify", "Array", "NoEffect"} else "Unknown",
            "before": _public_value(path, change.get("before"), "before" in change),
            "after": _public_value(path, change.get("after"), "after" in change),
            "unresolved": _unresolved(change.get("before")) or _unresolved(change.get("after")),
            "metadataOnly": path.lower() == "tags.createddate",
        })
    return fields


def _snapshot_fields(snapshot, change_type):
    """Show approved create/delete configuration without copying entire snapshots."""
    result = []

    def visit(value, path=""):
        if isinstance(value, dict):
            for key, child in value.items():
                if isinstance(key, str) and not _SECRET.search(key):
                    visit(child, _join_path(path, key))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, f"{path}[{index}]")
        else:
            public = _public_value(path, value)
            if public != WITHHELD:
                result.append({"path": _path(path), "changeType": change_type,
                               "before": MISSING if change_type == "Create" else public,
                               "after": public if change_type == "Create" else MISSING,
                               "unresolved": _unresolved(value), "metadataOnly": False})

    visit(snapshot)
    return result


def _resource_type(change, resource_id):
    for snapshot in (change.get("after"), change.get("before")):
        if isinstance(snapshot, dict):
            resource_type = snapshot.get("type")
            if isinstance(resource_type, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9.]+/[A-Za-z0-9./-]+", resource_type):
                return resource_type
    parts = resource_id.split("/")
    providers = [index for index, part in enumerate(parts) if part.lower() == "providers"]
    if providers and len(parts) > providers[-1] + 2:
        index = providers[-1]
        return "/".join([parts[index + 1], *parts[index + 2::2]])
    if "/resourcegroups/" in resource_id.lower():
        return "Microsoft.Resources/resourceGroups"
    return "unavailable"


def _resource(change, potential=False):
    resource_id = _identifier(change.get("resourceId"))
    resource_type = _resource_type(change, resource_id)
    change_type = change.get("changeType") if change.get("changeType") in CHANGE_TYPES else "Unknown"
    fields = _fields(change.get("delta"))
    if not fields and change_type in {"Create", "Delete"}:
        fields = _snapshot_fields(change.get("after" if change_type == "Create" else "before"), change_type)
    metadata_only = change_type == "Modify" and bool(fields) and all(field["metadataOnly"] for field in fields)
    category = "deployment-metadata" if resource_type.lower() == "microsoft.resources/deployments" else "resource"
    impacts = []
    if change_type != "NoChange" and not metadata_only:
        search = resource_type.lower() + " " + " ".join(field["path"].lower() for field in fields)
        if change_type == "Delete":
            impacts.append("deletion")
        if any(term in search for term in ("managedidentity", "microsoft.authorization", "accesspolicies", "principal", "identity", "permissions")):
            impacts.append("identity/permissions")
        if any(term in search for term in ("microsoft.network", "network", "firewall", "subnet", "publicaccess", "privateendpoint")):
            impacts.append("network")
        if any(term in search for term in ("microsoft.storage", "microsoft.sql", "microsoft.documentdb", "microsoft.cache")):
            impacts.append("storage/data")
    return {"resourceId": resource_id, "type": resource_type,
            "name": resource_id.rsplit("/", 1)[-1], "changeType": change_type,
            "category": category, "metadataOnly": metadata_only, "potential": potential,
            "potentialImpact": impacts, "fields": fields,
            "unresolved": potential or change_type in UNRESOLVED_TYPES or (change_type == "Modify" and not fields) or any(field["unresolved"] and not field["metadataOnly"] for field in fields)}


def _counts(resources):
    counts = Counter(resource["changeType"] for resource in resources)
    return {name: counts[name] for name in CHANGE_TYPES}


def _component(component):
    component = component if isinstance(component, dict) else {}
    status = component.get("status")
    status = status if status in {"complete", "failed", "blocked", "not-applicable"} else "failed"
    raw = component.get("result")
    raw = raw if isinstance(raw, dict) else {}
    body = raw.get("properties", raw)
    body = body if isinstance(body, dict) else {}
    diagnostics = body.get("diagnostics", raw.get("diagnostics", []))
    diagnostics = diagnostics if isinstance(diagnostics, list) else ([] if diagnostics is None else [diagnostics])
    azure_status = raw.get("status", body.get("status"))
    successful = isinstance(azure_status, str) and azure_status.lower() in {"succeeded", "success"}
    changes = body.get("changes")
    valid = isinstance(changes, list) and all(isinstance(item, dict) for item in changes)
    if status == "complete" and (not successful or not valid or raw.get("error") or body.get("error")):
        status = "failed"
    resources = [_resource(change) for change in changes] if valid else []
    potential_changes = body.get("potentialChanges", [])
    if isinstance(potential_changes, list):
        resources.extend(_resource(change, potential=True) for change in potential_changes if isinstance(change, dict))
    elif potential_changes:
        diagnostics.append({})
    unknowns = sum(resource["unresolved"] for resource in resources) + len(diagnostics)
    if status in {"failed", "blocked"}:
        unknowns += 1
    code = component.get("errorCode")
    # The runner supplies fixed codes, never Azure's free-form messages/codes.
    code = code if isinstance(code, str) and code in ERROR_CODES else None
    digest = component.get("inputDigest")
    return {"name": _identifier(component.get("name"), "component"),
            "label": _identifier(component.get("label"), _identifier(component.get("name"), "Component")),
            "status": status, "scope": _scope(component.get("scope")),
            "complete": status in {"complete", "not-applicable"} and unknowns == 0,
            "errorCode": code, "inputDigest": digest if isinstance(digest, str) and re.fullmatch(r"[a-fA-F0-9]{64}", digest) else None,
            "diagnosticCount": len(diagnostics), "unknowns": unknowns,
            "totals": _counts(resources), "resources": resources}


def _md(value):
    text = json.dumps(value) if isinstance(value, (bool, int, float)) else str(value)
    return html.escape(text, quote=False).replace("#", "&#35;").replace("|", "&#124;").replace("`", "&#96;").replace("[", "&#91;").replace("]", "&#93;").replace("\n", " ").replace("\r", " ")


def _count_table(report):
    labels = ("Create", "Modify", "Delete", "NoChange", "Deploy", "Ignore", "Unsupported", "Unknown")
    lines = ["| Component | Assessment | " + " | ".join(labels) + " | Unresolved |",
             "|---|---|" + "---:|" * (len(labels) + 1)]
    for component in report["components"]:
        state = "Complete" if component["complete"] else "INCOMPLETE"
        if component["status"] == "not-applicable":
            state = "Not applicable"
        lines.append("| " + " | ".join([_md(component["label"]), state, *(str(component["totals"][name]) for name in labels), str(component["unknowns"])]) + " |")
    return lines


def _resource_lines(resources, fields=True):
    lines = []
    for resource in resources:
        impacts = "; potential impact: " + ", ".join(resource["potentialImpact"]) if resource["potentialImpact"] else ""
        unresolved = "; NOT FULLY ASSESSED" if resource["unresolved"] else ""
        lines.extend([f"#### {_md(resource['changeType'])}: {_md(resource['name'])}", "",
                      f"`{_md(resource['type'])}`{impacts}{unresolved}", "",
                      f"Resource: `{_md(resource['resourceId'])}`", ""])
        if fields and resource["fields"]:
            lines.extend(["| Property | Current | Proposed |", "|---|---|---|"])
            # Property paths are already restricted to a safe character set;
            # entities inside code spans would display literally for array paths.
            lines.extend(f"| `{field['path']}` | {_md(field['before'])} | {_md(field['after'])} |" for field in resource["fields"])
            lines.append("")
        elif resource["changeType"] == "Modify":
            lines.extend(["Property-level details were not supplied by ARM. Values and raw payloads are withheld.", ""])
    return lines


def _environment_markdown(report):
    metadata = report["metadata"]
    lines = [f"# Infrastructure preview: {metadata['environment']}", "",
             f"**{'Complete ARM assessment' if report['complete'] else 'INCOMPLETE — review unresolved coverage'}**", "",
             f"Commit: `{_md(metadata['commit'])}` · Source: `{_md(metadata['sourceRef'])}` · Build: {_md(metadata['buildId'])}", "",
             f"Generated: {_md(metadata['generatedAt'])}", "",
             f"Inputs: {_md(metadata['parameterSource'])}.", "",
             "Changes compare this candidate commit with the current live environment. Counts include deployment metadata; resource details are grouped below.", ""]
    lines.extend(_count_table(report))
    lines.extend(["", "`Deploy`, `Ignore` and `Unsupported` are not a no-change result. Ignore can indicate a resource outside the template or an expansion limit; it is shown as unassessed coverage. Diagnostic messages are withheld.", ""])
    for component in report["components"]:
        lines.extend([f"## {_md(component['label'])}", ""])
        if component["inputDigest"]:
            lines.extend([f"Input fingerprint (SHA-256): `{component['inputDigest']}`", ""])
        if component["status"] in {"failed", "blocked"}:
            lines.extend([f"**{component['status'].upper()}**: this component was not fully assessed. Error category: {_md(component['errorCode'] or 'PREVIEW_INCOMPLETE')}.", ""])
        if component["status"] == "not-applicable":
            lines.extend(["Not applicable to this environment.", ""])
        if component["diagnosticCount"]:
            lines.extend([f"ARM returned {component['diagnosticCount']} diagnostic record(s). Coverage is incomplete; raw messages are withheld.", ""])
        resources = component["resources"]
        meaningful = [resource for resource in resources if resource["category"] == "resource" and not resource["metadataOnly"] and resource["changeType"] != "NoChange"]
        metadata_resources = [resource for resource in resources if resource["category"] == "deployment-metadata"]
        timestamp_resources = [resource for resource in resources if resource["category"] == "resource" and resource["metadataOnly"]]
        if meaningful:
            lines.extend(_resource_lines(meaningful))
        elif component["complete"] and component["status"] != "not-applicable":
            lines.extend(["No assessed resource changes other than the metadata listed below." if timestamp_resources or metadata_resources else "No resource changes predicted by ARM.", ""])
        unchanged = sum(resource["changeType"] == "NoChange" and resource["category"] == "resource" for resource in resources)
        if unchanged:
            lines.extend([f"Unchanged resources: {unchanged} (identifiers are retained in plan.json).", ""])
        if timestamp_resources:
            lines.extend(["### Known CreatedDate metadata changes", "", "These resources change only `tags.CreatedDate`; the changes are retained separately.", ""])
            lines.extend(_resource_lines(timestamp_resources))
        if metadata_resources:
            lines.extend(["### Nested-deployment metadata", "", "These entries are retained separately from their child resources. Unresolved entries remain unassessed coverage.", ""])
            lines.extend(_resource_lines(metadata_resources))
    lines.extend(["## Coverage and limitations", ""])
    lines.extend("- " + limitation for limitation in LIMITATIONS)
    lines.extend(["", "Potential-impact labels identify changes worth reviewing; they do not prove an outage, replacement or data loss.", ""])
    return "\n".join(lines)


def _write(output_dir, report, markdown):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "plan.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (output_dir / "summary.md").write_text(markdown, encoding="utf-8")


def write_environment_report(output_dir: Path, metadata: dict, components: list[dict]) -> dict:
    """Write sanitized summary.md/plan.json; return the same safe JSON projection."""
    safe_components = [_component(component) for component in components]
    resources = [resource for component in safe_components for resource in component["resources"]]
    complete = bool(safe_components) and all(component["complete"] for component in safe_components)
    report = {"schemaVersion": 1, "kind": "environment", "metadata": _metadata(metadata),
              "complete": complete, "outcome": "complete" if complete else "incomplete",
              "executionStatus": "succeeded" if safe_components and all(component["status"] in {"complete", "not-applicable"} for component in safe_components) else "failed",
              "totals": _counts(resources), "resourceTotals": _counts([resource for resource in resources if resource["category"] == "resource" and not resource["metadataOnly"]]),
              "metadataOnlyTotals": _counts([resource for resource in resources if resource["category"] == "resource" and resource["metadataOnly"]]),
              "deploymentMetadataTotals": _counts([resource for resource in resources if resource["category"] == "deployment-metadata"]),
              "unknowns": sum(component["unknowns"] for component in safe_components),
              "components": safe_components, "limitations": LIMITATIONS}
    _write(output_dir, report, _environment_markdown(report))
    return report


def combine_reports(input_paths: list[Path], output_dir: Path) -> dict:
    """Combine all release environments; missing/mixed/invalid inputs fail closed.

    Only this module's already-sanitized report projection is accepted. A second
    projection below prevents accidental raw fields being copied into artifacts.
    """
    reports = {}
    invalid = False
    for path in input_paths:
        try:
            source = json.loads(Path(path).read_text(encoding="utf-8"))
            if source.get("schemaVersion") != 1 or source.get("kind") != "environment":
                invalid = True
                continue
            environment = _metadata(source.get("metadata"))["environment"]
            if environment not in RELEASE_ENVIRONMENTS or environment in reports:
                invalid = True
                continue
            # Retain only the header fields needed below. Arbitrary component or
            # payload keys from an artifact never flow into the combined output.
            unknowns = source.get("unknowns")
            valid_unknowns = isinstance(unknowns, int) and not isinstance(unknowns, bool) and unknowns >= 0
            totals = source.get("resourceTotals")
            valid_totals = isinstance(totals, dict) and all(isinstance(totals.get(name), int) and not isinstance(totals[name], bool) and totals[name] >= 0 for name in CHANGE_TYPES)
            metadata_totals = source.get("metadataOnlyTotals")
            valid_metadata_totals = isinstance(metadata_totals, dict) and all(isinstance(metadata_totals.get(name), int) and not isinstance(metadata_totals[name], bool) and metadata_totals[name] >= 0 for name in CHANGE_TYPES)
            if not valid_unknowns or not valid_totals or not valid_metadata_totals:
                invalid = True
            reports[environment] = {
                "metadata": _metadata(source.get("metadata")),
                "complete": source.get("complete") is True and valid_unknowns and unknowns == 0 and valid_totals and valid_metadata_totals and source.get("executionStatus") == "succeeded",
                "executionStatus": source.get("executionStatus"),
                "resourceTotals": totals if valid_totals else {},
                "metadataOnlyTotals": metadata_totals if valid_metadata_totals else {},
                "unknowns": unknowns if valid_unknowns else 1,
            }
        except (OSError, ValueError, AttributeError, TypeError):
            invalid = True
    commits = {report.get("metadata", {}).get("commit") for report in reports.values()}
    same_commit = len(commits) == 1 and "unavailable" not in commits
    missing = [environment for environment in RELEASE_ENVIRONMENTS if environment not in reports]
    complete = not invalid and not missing and same_commit and all(report.get("complete") is True for report in reports.values())
    # Summary-level fields have fixed schemas; component/resource artifacts remain
    # in their environment directories and are never blindly copied here.
    environments = []
    for environment in RELEASE_ENVIRONMENTS:
        source = reports.get(environment)
        totals = source.get("resourceTotals", {}) if source else {}
        metadata_totals = source.get("metadataOnlyTotals", {}) if source else {}
        environments.append({"environment": environment, "complete": bool(source and source.get("complete") is True),
                             "executionStatus": source.get("executionStatus") if source and source.get("executionStatus") in {"succeeded", "failed"} else "missing",
                             "totals": {name: value if isinstance((value := totals.get(name)), int) and not isinstance(value, bool) and value >= 0 else 0 for name in CHANGE_TYPES},
                             "metadataOnlyTotals": {name: value if isinstance((value := metadata_totals.get(name)), int) and not isinstance(value, bool) and value >= 0 else 0 for name in CHANGE_TYPES},
                             "unknowns": source.get("unknowns") if source and isinstance(source.get("unknowns"), int) and source["unknowns"] >= 0 else 1})
    report = {"schemaVersion": 1, "kind": "combined", "complete": complete,
              "outcome": "complete" if complete else "incomplete", "commit": next(iter(commits)) if same_commit and re.fullmatch(r"[a-fA-F0-9]{7,64}", str(next(iter(commits)))) else "unavailable",
              "missingEnvironments": missing, "sameCommit": same_commit, "invalidInputs": invalid,
              "environments": environments, "limitations": LIMITATIONS}
    lines = ["# Infrastructure release preview", "", f"**{'Complete ARM assessment for TST, PRE and PRD' if complete else 'INCOMPLETE — do not treat this as a full release assessment'}**", "", f"Candidate commit: `{report['commit']}`", "",
             "| Environment | Assessment | Create | Modify | Delete | Unchanged | Metadata only | Unassessed |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for item in environments:
        totals = item["totals"]
        lines.append(f"| {item['environment']} | {'Complete' if item['complete'] else 'INCOMPLETE'} | {totals['Create']} | {totals['Modify']} | {totals['Delete']} | {totals['NoChange']} | {sum(item['metadataOnlyTotals'].values())} | {item['unknowns']} |")
    lines.extend(["", "Resource counts exclude nested-deployment wrappers and CreatedDate-only modifications; metadata-only changes are counted separately. Each environment artifact retains all component and resource details.", ""])
    if missing:
        lines.extend(["Missing environment reports: " + ", ".join(missing) + ".", ""])
    if not same_commit:
        lines.extend(["Environment reports do not establish one common candidate commit.", ""])
    if invalid:
        lines.extend(["Some report inputs were invalid or duplicated; the combined assessment is incomplete.", ""])
    lines.extend(["## Coverage and limitations", "", *("- " + limitation for limitation in LIMITATIONS), ""])
    _write(output_dir, report, "\n".join(lines))
    return report


def main():
    parser = argparse.ArgumentParser(description="Combine sanitized infrastructure environment reports.")
    parser.add_argument("--combine", required=True, type=Path, help="Artifact directory containing environment plan.json files")
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    output_path = args.output_dir.resolve() / "plan.json"
    inputs = [path for path in args.combine.rglob("plan.json") if path.resolve() != output_path]
    report = combine_reports(inputs, args.output_dir)
    print("Infrastructure release preview: " + report["outcome"])
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
