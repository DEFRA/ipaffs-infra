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

from infrastructure_plan_markdown import TYPE_LABELS, environment_markdown, change_details_markdown, is_no_effect_only, resource_label, type_label, property_label
from infrastructure_plan_comparison import analyze_comparison
from infrastructure_plan_identity import has_identity_resource_id, identity_metadata_reason, is_metadata_only


CHANGE_TYPES = ("Create", "Modify", "Delete", "NoChange", "Deploy", "Ignore", "Unsupported", "Unknown")
RELEASE_ENVIRONMENTS = ("TST", "PRE", "PRD")
PREVIEW_ENVIRONMENTS = ("DEV", *RELEASE_ENVIRONMENTS)
UNRESOLVED_TYPES = {"Deploy", "Ignore", "Unsupported", "Unknown"}
ERROR_CODES = {
    "INVALID_EXISTING_NETWORK_SECURITY_GROUP_NAMES",
    "AZURE_CLI_TOO_OLD", "AZURE_COMMAND_FAILED", "AZURE_RESPONSE_UNAVAILABLE",
    "COMMAND_NOT_ALLOWED", "INVALID_OUTPUT_DIRECTORY", "INVALID_SOURCE_IDENTITY",
    "INVALID_SUBSCRIPTION", "MISSING_INPUT", "PARAMETER_RESOLUTION_FAILED",
    "PREVIEW_STATE_MISMATCH", "PRIVATE_STATE_OVERLAPS_REPORT", "SOURCE_COMMIT_MISMATCH",
    "UNRESOLVED_RESOURCE_NAME", "UNRESOLVED_SUBNET", "WHAT_IF_INCOMPLETE", "PREVIEW_FAILED", "NOT_RUN",
}
WITHHELD = "[withheld]"
MISSING = "[not present]"
LIMITATIONS = [
    "This is an ARM what-if prediction against the live environment, not a saved executable plan or a guarantee of deployment success.",
    "Proposed deterministic resource IDs are derived from candidate parameters; existing identity inputs come from Library. Future generated principal IDs and outputs cannot be predicted.",
    "Hooks, peering pipeline execution, Azure DevOps output persistence, Entra/group memberships and scripted DNS changes are outside this ARM preview.",
    "Refresh the preview before applying each environment: resources and inputs can change after this report was generated.",
    "Values are withheld unless their configuration path is explicitly approved for publication. Raw Azure payloads and diagnostic messages are not published.",
]
_IDENTIFIER = re.compile(r"^[A-Za-z0-9/][A-Za-z0-9._/()@:+ -]{0,1023}$")
_PROPERTY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.\[\]-]{0,511}$")
_SECRET = re.compile(r"password|secret|credential|connectionstring|token|protectedsettings|privatekey|accesskey|accountkey|sas|parameters|outputs|appsettings", re.I)
_EXPRESSION = re.compile(r"^\s*\[.*\]\s*$", re.S)
_UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
_IDENTITY_TYPE = "microsoft.managedidentity/userassignedidentities"
_IDENTITY_GENERATED_PATHS = {"properties.clientid", "properties.principalid", "properties.tenantid"}
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
        "parameterSource": "candidate parameters with current Library identity inputs",
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


def _public_value(path, value, present=True, resource_type=""):
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
    if (resource_type.lower() == _IDENTITY_TYPE and path.lower() == "properties.isolationscope"
            and isinstance(value, str) and value in {"None", "Regional"}):
        return value
    if boolean and isinstance(value, bool):
        return value
    if (numeric or normal == "sku.capacity") and isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
        return value
    if enum and isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,79}", value):
        return value
    return WITHHELD


def _identity_omission(change, path, after_snapshot):
    """Accept absent delta values, or ARM nulls backed by a desired snapshot.

    Null is not itself proof of omission. In particular, an explicit null
    isolationScope in the desired resource must stay visible for review.
    """
    if isinstance(after_snapshot, dict) and "properties" in after_snapshot:
        properties = after_snapshot["properties"]
        if (not isinstance(properties, dict) or path.lower() == "properties"
                or any(str(key).lower() == path.rsplit(".", 1)[-1].lower() for key in properties)):
            return False
    if "after" not in change:
        return True
    if change["after"] is not None or not isinstance(after_snapshot, dict):
        return False
    if "properties" not in after_snapshot:
        return True
    return isinstance(after_snapshot["properties"], dict)


def _identity_property_changes(change, after_snapshot):
    """Split complete identity bags before redaction, preserving unknown keys.

    Coarse, withheld or malformed property bags are deliberately not expanded:
    they cannot establish that the omitted properties are generated fields.
    """
    action = change.get("propertyChangeType")
    before, after = change.get("before"), change.get("after")
    if action == "Delete" and isinstance(before, dict) and _identity_omission(change, "properties", after_snapshot):
        old, new = before, {}
    elif action == "Create" and isinstance(after, dict) and "before" not in change:
        old, new = {}, after
    elif action == "Modify" and isinstance(before, dict) and isinstance(after, dict):
        old, new = before, after
    else:
        return None
    keys = list(dict.fromkeys([*old, *new]))
    if (not keys or any(not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) for key in keys)
            or len({key.lower() for key in keys}) != len(keys)):
        return None
    result = []
    for key in keys:
        if (key.lower() in {"clientid", "principalid", "tenantid", "isolationscope"}
                and key in old and key in new and type(old[key]) is type(new[key])
                and old[key] == new[key]):
            continue
        leaf = {"path": key, "propertyChangeType": "Modify" if key in old and key in new else "Delete" if key in old else "Create"}
        if key in old:
            leaf["before"] = old[key]
        if key in new:
            leaf["after"] = new[key]
        result.append(leaf)
    return result or None


def _identity_metadata_reason(change, path, after_snapshot):
    if (change.get("propertyChangeType") != "Delete"
            or not _identity_omission(change, path, after_snapshot)):
        return None
    before = change.get("before")
    if path.lower() in _IDENTITY_GENERATED_PATHS and isinstance(before, str) and _UUID.fullmatch(before):
        return "GENERATED_IDENTITY_PROPERTY"
    if path.lower() == "properties.isolationscope" and before == "None":
        return "UNCHANGED_IDENTITY_SCOPE_DEFAULT"
    return None


def _fields(delta, parent="", resource_type="", resource_action="", potential=False, after_snapshot=None):
    fields = []
    if not isinstance(delta, list):
        return fields
    for change in delta:
        if not isinstance(change, dict):
            continue
        raw_path = change.get("path", "")
        full_path = _join_path(parent, raw_path) if isinstance(raw_path, str) else ""
        children = change.get("children", change.get("childDelta"))
        path = _path(full_path)
        identity = resource_type.lower() == _IDENTITY_TYPE
        child_fields = (_fields(children, full_path, resource_type, resource_action, potential, after_snapshot)
                        if isinstance(children, list) and children else [])
        if identity and path.lower() == "properties":
            expanded = _identity_property_changes(change, after_snapshot)
            malformed_children = ((children is not None and not isinstance(children, list))
                                  or (isinstance(children, list) and any(not isinstance(child, dict) for child in children)))
            if expanded is not None and not malformed_children:
                expanded_fields = _fields(expanded, full_path, resource_type, resource_action, potential, after_snapshot)
                # A child list must not erase a writable property present in the
                # complete coarse bag, nor introduce a hidden additional change.
                fields.extend(expanded_fields)
                fields.extend(child for child in child_fields if child not in expanded_fields)
                continue
            fields.extend(child_fields)
            if child_fields and "before" not in change and "after" not in change and not malformed_children:
                continue
        elif isinstance(children, list) and children:
            fields.extend(child_fields)
            continue
        change_type = change.get("propertyChangeType")
        reason = (_identity_metadata_reason(change, path, after_snapshot)
                  if identity and resource_action == "Modify" and not potential else None)
        field = {
            "path": path,
            "changeType": change_type if change_type in {"Create", "Delete", "Modify", "Array", "NoEffect"} else "Unknown",
            "before": _public_value(path, change.get("before"), "before" in change, resource_type),
            "after": MISSING if reason else _public_value(path, change.get("after"), "after" in change, resource_type),
            "unresolved": _unresolved(change.get("before")) or _unresolved(change.get("after")),
            "metadataOnly": bool(reason) or path.lower() == "tags.createddate",
        }
        if reason:
            field["metadataReason"] = reason
        if identity and path.lower() == "properties":
            field["unresolved"] = True
        if (identity and path.lower() in _IDENTITY_GENERATED_PATHS and change_type == "Delete"
                and not (isinstance(change.get("before"), str) and _UUID.fullmatch(change["before"]))):
            field["unresolved"] = True
        if (identity and change_type == "Delete"
                and path.lower() in _IDENTITY_GENERATED_PATHS | {"properties.isolationscope"}
                and not _identity_omission(change, path, after_snapshot)):
            field["unresolved"] = True
        fields.append(field)
    return fields


def _snapshot_fields(snapshot, change_type, resource_type=""):
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
            public = _public_value(path, value, resource_type=resource_type)
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
    fields = _fields(change.get("delta"), resource_type=resource_type, resource_action=change_type,
                     potential=potential, after_snapshot=change.get("after"))
    if not fields and change_type in {"Create", "Delete"}:
        fields = _snapshot_fields(change.get("after" if change_type == "Create" else "before"), change_type, resource_type)
    if resource_type.lower() == _IDENTITY_TYPE and not has_identity_resource_id(resource_id):
        # Without a valid identity resource reference these otherwise harmless
        # leaves cannot establish which resource ARM assessed. Keep the gap in
        # both environment counts and the downstream comparison projection.
        for field in fields:
            if identity_metadata_reason(resource_type, field):
                field["unresolved"] = True
                field["metadataOnly"] = False
                field.pop("metadataReason", None)
    metadata_only = (change_type == "Modify" and not potential and bool(fields)
                     and all(field["metadataOnly"] for field in fields))
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
    _write(output_dir, report, environment_markdown(report))
    (Path(output_dir) / "change-details.md").write_text(change_details_markdown(report), encoding="utf-8")
    return report


def _review_breakdown(source):
    """Count fixed, friendly categories without copying artifact payload values."""
    changes = {}
    gaps = Counter()
    potential = Counter()
    unresolved = 0
    no_effect_only = 0
    components = source.get("components")
    for component in components if isinstance(components, list) else []:
        resources = component.get("resources") if isinstance(component, dict) else None
        for resource in resources if isinstance(resources, list) else []:
            if not isinstance(resource, dict) or resource.get("category") != "resource" or is_metadata_only(resource):
                continue
            if is_no_effect_only(resource):
                no_effect_only += 1
                continue
            resource_type = resource.get("type")
            label = TYPE_LABELS.get(resource_type.lower(), "Other Azure resources") if isinstance(resource_type, str) else "Other Azure resources"
            action = resource.get("changeType")
            if action in {"Create", "Modify", "Delete"}:
                if resource.get("potential") is True:
                    potential[action] += 1
                else:
                    changes.setdefault(label, Counter())[action] += 1
                fields = resource.get("fields")
                fields = fields if isinstance(fields, list) else []
                runtime_unknown = any(isinstance(field, dict) and field.get("unresolved") is True
                                      and str(field.get("path", "")).lower() != "tags.createddate" for field in fields)
                if resource.get("potential") is True or runtime_unknown or (action == "Modify" and resource.get("unresolved") is True and not fields):
                    unresolved += 1
            elif action in {"Unsupported", "Deploy", "Unknown"}:
                gaps[label] += 1
    return {"changes": {label: {action: counts[action] for action in ("Create", "Modify", "Delete")}
                        for label, counts in sorted(changes.items())},
            "unpreviewed": dict(sorted(gaps.items())), "unresolvedChanges": unresolved,
            "noEffectOnly": no_effect_only,
            "potential": {action: potential[action] for action in ("Create", "Modify", "Delete")}}


def _combined_markdown(report):
    environments = report["environments"]
    executed = (not report["invalidInputs"] and not report["missingEnvironments"] and report["sameCommit"]
                and all(item["executionStatus"] == "succeeded" for item in environments))
    status = ("All four environment previews ran successfully." if executed
              else "Some environment previews failed or are missing; this report is incomplete.")
    lines = ["# Infrastructure release preview", "", "**" + status + "**", "",
             "**Assessment: " + ("Complete" if report["complete"] else "INCOMPLETE — review the coverage gaps below") + "**", "",
             f"Candidate commit: `{report['commit']}`", "",
             "## What would change?", "",
             "| Environment | Create | Reported updates | Delete resources | Plans |",
             "|---|---:|---:|---:|---|"]
    for item in environments:
        totals = item["totals"]
        execution = {"succeeded": "Completed", "failed": "Failed", "missing": "Missing"}[item["executionStatus"]]
        values = [str(max(0, totals[action] - item["review"]["potential"].get(action, 0)
                             - (item["review"]["noEffectOnly"] if action == "Modify" else 0)))
                  if item["executionStatus"] != "missing" else "—" for action in ("Create", "Modify", "Delete")]
        lines.append(f"| {item['environment']} | {' | '.join(values)} | {execution} |")
    lines.extend(["", "These are Azure predictions against the live environment. An update can include provider defaults or properties omitted from the proposed configuration; it is not proof of an operational change. Counts exclude deployment wrappers, metadata-only updates and NoEffect-only updates, and can repeat a resource across component previews.", ""])
    lines.extend(_comparison_markdown(report["devComparison"]))
    types = sorted({label for item in environments for label in item["review"]["changes"]})
    if types:
        lines.extend(["## Reported actions by resource type", "",
                      "This table includes potential recurring noise alongside changes needing review. Equal counts can refer to different properties; use the classifications above to assess the changes.", "",
                      "| Resource | DEV | TST | PRE | PRD |", "|---|---|---|---|---|"])
        for label in types:
            cells = []
            for item in environments:
                counts = item["review"]["changes"].get(label, {})
                cells.append(", ".join(f"{counts[action]} {verb}" for action, verb in (("Create", "create"), ("Modify", "update"), ("Delete", "delete")) if counts.get(action)) or "—")
            lines.append("| " + _md(label) + " | " + " | ".join(cells) + " |")
        lines.append("")
    lines.extend(["## What still needs checking?", "", "| Environment | Azure cannot preview | Changed entries with unresolved values |", "|---|---|---:|"])
    for item in environments:
        review = item["review"]
        if item["executionStatus"] != "succeeded":
            lines.append(f"| {item['environment']} | Unavailable — preview {item['executionStatus']}; partial results require investigation | — |")
            continue
        gaps = "; ".join(f"{count} {_md(label)}" for label, count in review["unpreviewed"].items()) or "None reported"
        lines.append(f"| {item['environment']} | {gaps} | {review['unresolvedChanges']} |")
    potential = [f"{item['environment']}: {sum(item['review']['potential'].values())}" for item in environments
                 if any(item["review"]["potential"].values())]
    if potential:
        lines.extend(["", "**Potential predictions:** " + "; ".join(potential) + ". These are uncertain action entries, excluded from the create/update/delete totals above and labelled in the environment summaries."])
    lines.extend(["", "Unresolved values need checking against the intended configuration; Azure cannot determine them before deployment. Property-by-property evidence is in `change-details.md` in each `infrastructure-plan-ENV` artifact. `dev-comparison.json` records the comparison classifications without publishing source values.", "",
                  "## Background inventory", "",
                  "These are observations across component previews, not extra proposed changes. Individual inventory records are retained in `plan.json`.", "",
                  "| Environment | Ignored observations | Unchanged observations | Metadata-only updates | NoEffect-only updates |", "|---|---:|---:|---:|---:|"])
    for item in environments:
        counts = (["—", "—", "—", "—"] if item["executionStatus"] == "missing" else
                  [str(item["totals"]["Ignore"]), str(item["totals"]["NoChange"]),
                   str(sum(item["metadataOnlyTotals"].values())), str(item["review"]["noEffectOnly"])])
        lines.append(f"| {item['environment']} | {' | '.join(counts)} |")
    lines.extend(["", "Azure usually marks existing resources outside an individual template as Ignore, and can also do so when template expansion reaches a limit. They are not listed as individual review items; their presence still prevents a claim of complete coverage.", ""])
    lines.extend(["NoEffect-only updates contain only fields Azure marks as having no effect, plus possible CreatedDate metadata. They are excluded from the review list, while the environment JSON and change-details.md retain the original evidence.", ""])
    lines.extend(["Metadata-only updates can include CreatedDate, omitted generated managed-identity IDs and an omitted None regional-isolation default. Changes to Regional isolation, unknown properties and incomplete evidence remain reviewable. Original ARM operations and fixed metadata reasons remain in the environment artifacts.", ""])
    if report["missingEnvironments"]:
        lines.extend(["**Missing environment reports:** " + ", ".join(report["missingEnvironments"]) + ".", ""])
    if not report["sameCommit"]:
        lines.extend(["**Commit mismatch:** the reports do not establish one common candidate commit.", ""])
    if report["invalidInputs"]:
        lines.extend(["**Invalid reports:** some inputs were invalid or duplicated; do not rely on this comparison.", ""])
    lines.extend(["## Limits of this preview", "", *("- " + limitation for limitation in LIMITATIONS), ""])
    return "\n".join(lines)


BASELINE_REASONS = {
    "DEPLOYMENT_INPUTS_CHANGED": "The candidate's deployment inputs differ from the last successful DEV apply. A matching successful DEV apply is needed before assessing recurring noise.",
    "VERIFIED_POST_APPLY_CONTROL": "Verified successful DEV apply; deployment source inputs match the candidate.",
    "DEV_REPORT_MISSING_OR_INVALID": "DEV report is missing or invalid.",
    "BASELINE_EVIDENCE_UNAVAILABLE": "Successful DEV apply evidence is missing or could not be verified.",
    "APPLIED_SOURCE_NOT_VERIFIED": "DEV apply provenance or deployment source inputs could not be verified.",
    "BASELINE_CANDIDATE_MISMATCH": "The DEV control does not belong to this candidate and preview run.",
    "BASELINE_TIMING_INVALID": "The DEV control's timing could not be verified.",
    "DEV_EXECUTION_INCOMPLETE": "DEV did not complete every component without execution errors or diagnostics.",
    "DEV_CONTROL_HAS_ACTIONS": "DEV still predicts resource creates, deletes or uncertain actions; it is not a usable post-apply control.",
    "TARGET_REPORT_INVALID": "Target report is missing or invalid.",
    "TARGET_EXECUTION_INCOMPLETE": "Target execution did not complete successfully.",
}

_COMPONENT_LABELS = {
    "resource-group": "Resource group", "network": "Network",
    "acr": "Container registry", "classic": "Classic services",
    "infra": "Infrastructure", "privatelink": "Private Link",
}


def _unresolved_rows(unresolved):
    """Group unidentified Unsupported observations without inventing identities.

    Counts are occurrences, not unique resources. Named observations stay
    individual, and the underlying JSON retains every original observation.
    """
    rows, groups = [], {}
    for environment, item in unresolved:
        component = _COMPONENT_LABELS.get(item["component"], "Unresolved component")
        unidentified = item["resourceId"] == "unavailable" and item["name"] == "unavailable"
        if unidentified:
            kind = type_label(item["type"]) if item["type"] != "unavailable" else "Resource type unresolved"
            label = kind + " — resource identity unresolved"
        else:
            label = type_label(item["type"]) + ": " + resource_label(item)
        key = (environment, item["component"], item["action"], item["type"])
        if unidentified and item["action"] == "Unsupported":
            if key in groups:
                rows[groups[key]][-1] += 1
                continue
            groups[key] = len(rows)
        rows.append([environment, component, item["action"], label, 1])
    return rows


def _comparison_markdown(comparisons):
    """Render the comparator's fixed, value-free projection only."""
    lines = ["## Changes needing review", "",
             "DEV is the post-apply control. Only tightly matched provider defaults can be labelled potential recurring noise; repetition alone does not establish a false positive.", "",
             "| Target | Changes to review | Potential noise within updates | Unresolved observations | DEV comparison |",
             "|---|---:|---:|---:|---|"]
    for comparison in comparisons:
        counts = comparison["counts"]
        unresolved_count = sum(item["classification"] == "unresolved-coverage" or
                               any(field["classification"] == "unresolved-coverage" for field in item["fields"])
                               for item in comparison["resources"])
        status = "Available" if comparison["baseline"]["status"] == "usable" else "Unavailable"
        if comparison["executionStatus"] != "succeeded":
            lines.append(f"| {comparison['environment']} | — | — | — | Preview {comparison['executionStatus']} |")
        else:
            lines.append(f"| {comparison['environment']} | {counts['reviewResources'] + counts['policySecurityResources']} | {counts['potentialNoiseResources']} | {unresolved_count} | {status} |")
    lines.extend(["", "Potential noise remains included in the reported update totals above. Counts are observations across component previews, so the same resource can appear more than once.", ""])
    reasons = {item["baseline"]["reasonCode"] for item in comparisons}
    for reason in sorted(reasons):
        targets = ", ".join(item["environment"] for item in comparisons if item["baseline"]["reasonCode"] == reason)
        lines.extend([f"**{targets}:** {BASELINE_REASONS.get(reason, 'DEV comparison unavailable.')}" +
                      (" All target actions remain for review." if reason != "VERIFIED_POST_APPLY_CONTROL" else ""), ""])
    for comparison in comparisons:
        lines.extend([f"### {comparison['environment']}", ""])
        if comparison["executionStatus"] != "succeeded":
            lines.extend([f"Preview {comparison['executionStatus']}; no complete change list is available. Investigate execution before using any partial results.", ""])
            continue
        resources = [item for item in comparison["resources"] if item["classification"] in {"review-needed", "policy-security-review"}]
        if not resources:
            lines.extend(["No assessed actions in this review category. Check execution and coverage above before drawing conclusions.", ""])
            continue
        lines.extend(["| Action | Resource | Why review? | Relevant properties |", "|---|---|---|---|"])
        for item in resources:
            fields = [field for field in item["fields"] if field["classification"] not in {"background", "potential-noise"}]
            reason = ("Security or policy ownership" if item["classification"] == "policy-security-review" else
                      "Resource creation" if item["action"] == "Create" else
                      "Resource deletion" if item["action"] == "Delete" else
                      "Classic/SND control differs" if any(field["reasonCode"] == "CLASSIC_SCOPE_DIFFERS" for field in fields) else
                      "Configuration or unmatched prediction")
            operations = {"Modify": "Change", "Array": "Change", "Delete": "Remove property from config:", "Create": "Add property to config:"}
            properties = "; ".join(dict.fromkeys(f"{operations.get(field['action'], 'Unassessed')} {property_label(field['path'])}" for field in fields))
            property_groups = properties.split("; ")
            properties = "; ".join(property_groups[:3])
            if len(property_groups) > 3:
                properties += f"; +{len(property_groups) - 3} more in comparison JSON"
            action = "Update" if item['action'] == "Modify" else item['action']
            lines.append(f"| {action} | {_md(type_label(item['type']) + ': ' + resource_label(item))} | {reason} | {_md(properties) if properties else 'See environment details'} |")
        lines.append("")
    lines.extend(["## Potential recurring noise", "",
                  "These omitted provider defaults are also predicted by the verified DEV control. They may be false positives; this is not proof that an apply leaves the setting unchanged. Withheld values establish only a matching pattern, never matching actual values.", ""])
    patterns = Counter()
    for comparison in comparisons:
        for item in comparison["resources"]:
            for field in item["fields"]:
                if field["classification"] == "potential-noise":
                    patterns[(comparison["environment"], type_label(item["type"]), field["path"], field["confidence"])] += 1
    if patterns:
        lines.extend(["| Target | Resource type | Property | Observations | Evidence |", "|---|---|---|---:|---|"])
        for (env, label, path, confidence), count in sorted(patterns.items()):
            lines.append(f"| {env} | {_md(label)} | {_md(property_label(path))} | {count} | {'Matching public values' if confidence == 'matching-values' else 'Pattern only; values withheld'} |")
        lines.extend(["", "Mixed updates remain in the review list when another property needs review. Each matched resource is retained in `dev-comparison.json`.", ""])
    else:
        lines.extend(["None identified with a usable matching DEV control.", ""])
    unresolved = [(comparison["environment"], item) for comparison in comparisons
                  for item in comparison["resources"] if item["classification"] == "unresolved-coverage"
                  or any(field["classification"] == "unresolved-coverage" for field in item["fields"])]
    if unresolved:
        lines.extend(["## Unresolved predictions", "", "These are assessment gaps, including uncertain action entries, rather than confirmed changes or noise.", "",
                      "Unsupported entries with unresolved resource identities are grouped by target, component and resource type. Entries count observations, not unique resources. Named resources stay individual; every observation remains in the JSON artifacts.", "",
                      "| Target | Component | Action | Resource | Entries |", "|---|---|---|---|---:|"])
        for row in _unresolved_rows(unresolved):
            lines.append("| " + " | ".join(_md(value) for value in row) + " |")
        lines.append("")
    return lines


def combine_reports(input_paths: list[Path], output_dir: Path) -> dict:
    """Combine all release environments; missing/mixed/invalid inputs fail closed.

    Only this module's already-sanitized report projection is accepted. A second
    projection below prevents accidental raw fields being copied into artifacts.
    """
    reports = {}
    source_reports = {}
    baseline_evidence = {}
    invalid = False
    for path in input_paths:
        try:
            source = json.loads(Path(path).read_text(encoding="utf-8"))
            if source.get("schemaVersion") != 1 or source.get("kind") != "environment":
                invalid = True
                continue
            environment = _metadata(source.get("metadata"))["environment"]
            if environment not in PREVIEW_ENVIRONMENTS or environment in reports:
                invalid = True
                continue
            # Retain headers and counts labelled only by fixed resource-type
            # aliases. Arbitrary artifact fields/values never flow into output.
            unknowns = source.get("unknowns")
            valid_unknowns = isinstance(unknowns, int) and not isinstance(unknowns, bool) and unknowns >= 0
            totals = source.get("resourceTotals")
            valid_totals = isinstance(totals, dict) and all(isinstance(totals.get(name), int) and not isinstance(totals[name], bool) and totals[name] >= 0 for name in CHANGE_TYPES)
            metadata_totals = source.get("metadataOnlyTotals")
            valid_metadata_totals = isinstance(metadata_totals, dict) and all(isinstance(metadata_totals.get(name), int) and not isinstance(metadata_totals[name], bool) and metadata_totals[name] >= 0 for name in CHANGE_TYPES)
            valid_completion = isinstance(source.get("complete"), bool)
            if not valid_unknowns or not valid_totals or not valid_metadata_totals or not valid_completion:
                invalid = True
            reports[environment] = {
                "metadata": _metadata(source.get("metadata")),
                "complete": source.get("complete") is True and valid_unknowns and unknowns == 0 and valid_totals and valid_metadata_totals and source.get("executionStatus") == "succeeded",
                "executionStatus": source.get("executionStatus"),
                "resourceTotals": totals if valid_totals else {},
                "metadataOnlyTotals": metadata_totals if valid_metadata_totals else {},
                "unknowns": unknowns if valid_unknowns else 1,
                "review": _review_breakdown(source),
            }
            source_reports[environment] = source
            if environment == "DEV":
                try:
                    baseline_evidence = json.loads(Path(path).with_name("baseline-evidence.json").read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    baseline_evidence = {}
        except (OSError, ValueError, AttributeError, TypeError):
            invalid = True
    commits = {report.get("metadata", {}).get("commit") for report in reports.values()}
    same_commit = len(commits) == 1 and "unavailable" not in commits
    missing = [environment for environment in PREVIEW_ENVIRONMENTS if environment not in reports]
    complete = not invalid and not missing and same_commit and all(report.get("complete") is True for report in reports.values())
    # Summary-level fields have fixed schemas; component/resource artifacts remain
    # in their environment directories and are never blindly copied here.
    environments = []
    for environment in PREVIEW_ENVIRONMENTS:
        source = reports.get(environment)
        totals = source.get("resourceTotals", {}) if source else {}
        metadata_totals = source.get("metadataOnlyTotals", {}) if source else {}
        environments.append({"environment": environment, "complete": bool(source and source.get("complete") is True),
                             "executionStatus": source.get("executionStatus") if source and source.get("executionStatus") in {"succeeded", "failed"} else "missing",
                             "totals": {name: value if isinstance((value := totals.get(name)), int) and not isinstance(value, bool) and value >= 0 else 0 for name in CHANGE_TYPES},
                             "metadataOnlyTotals": {name: value if isinstance((value := metadata_totals.get(name)), int) and not isinstance(value, bool) and value >= 0 else 0 for name in CHANGE_TYPES},
                             "unknowns": source.get("unknowns") if source and isinstance(source.get("unknowns"), int) and source["unknowns"] >= 0 else 1,
                             "review": source["review"] if source else {"changes": {}, "unpreviewed": {}, "unresolvedChanges": 0, "noEffectOnly": 0, "potential": {}}})
    comparisons = []
    for environment in RELEASE_ENVIRONMENTS:
        comparison = analyze_comparison(source_reports.get("DEV"), source_reports.get(environment),
                                        baseline_evidence if not invalid and same_commit else {})
        comparison["environment"] = environment
        source_execution = reports.get(environment, {}).get("executionStatus")
        comparison["executionStatus"] = source_execution if source_execution in {"succeeded", "failed"} else "missing"
        # Background inventories already exist in each environment's plan.json.
        comparison["resources"] = [item for item in comparison["resources"] if item["classification"] != "background"]
        comparisons.append(comparison)
    report = {"schemaVersion": 1, "kind": "combined", "complete": complete,
              "outcome": "complete" if complete else "incomplete", "commit": next(iter(commits)) if same_commit and re.fullmatch(r"[a-fA-F0-9]{7,64}", str(next(iter(commits)))) else "unavailable",
              "missingEnvironments": missing, "sameCommit": same_commit, "invalidInputs": invalid,
              "environments": environments, "devComparison": comparisons,
              "comparisonAvailable": all(item["baseline"]["status"] == "usable" for item in comparisons),
              "limitations": LIMITATIONS}
    _write(output_dir, report, _combined_markdown(report))
    (output_dir / "dev-comparison.json").write_text(json.dumps({"schemaVersion": 1, "comparisons": comparisons}, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description="Combine sanitized infrastructure environment reports.")
    parser.add_argument("--combine", required=True, type=Path, help="Artifact directory containing environment plan.json files")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--azure-pipelines", action="store_true",
                        help="Report incomplete coverage as a warning when every environment executed successfully")
    args = parser.parse_args()
    output_path = args.output_dir.resolve() / "plan.json"
    inputs = [path for path in args.combine.rglob("plan.json") if path.resolve() != output_path]
    report = combine_reports(inputs, args.output_dir)
    print("Infrastructure release preview: " + report["outcome"])
    execution_succeeded = (not report["invalidInputs"] and not report["missingEnvironments"]
                           and report["sameCommit"]
                           and all(environment["executionStatus"] == "succeeded"
                                   for environment in report["environments"]))
    if args.azure_pipelines and execution_succeeded and (not report["complete"] or not report["comparisonAvailable"]):
        # Keep the assessment incomplete in both artifacts. Only the pipeline's
        # execution status changes; missing/invalid/failed plans still fail.
        print("##vso[task.logissue type=warning;]All environment what-ifs executed successfully, "
              "but assessment coverage or the verified DEV comparison is incomplete. Review the promotion preview summary.")
        print("##vso[task.complete result=SucceededWithIssues;]Preview completed with assessment limitations")
        return 0
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
