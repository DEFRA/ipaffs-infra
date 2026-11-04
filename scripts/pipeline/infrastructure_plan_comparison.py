"""Conservative comparison of sanitised target plans with a post-apply DEV control.

The control is evidence of recurring predictions, never proof of a false positive.
Only this module's fixed projection may be published: source values, messages and
unrecognised fields are deliberately absent from its output.
"""

from collections import Counter
from datetime import datetime
import math
import re


COMPONENTS = {"resource-group", "network", "acr", "classic", "infra", "infra-to-classic", "privatelink"}
ACTIONS = {"Create", "Modify", "Delete", "NoChange", "Deploy", "Ignore", "Unsupported", "Unknown"}
FIELD_ACTIONS = {"Create", "Modify", "Delete", "Array", "NoEffect"}
COMPARED_PATHS = [
    "bicep", "pipelines/vars", "pipelines/infrastructure.yaml",
    "pipelines/stages/deploy-bicep-resource-group.yaml",
    "pipelines/stages/deploy-bicep-network.yaml",
    "pipelines/stages/deploy-bicep-acr.yaml",
    "pipelines/stages/deploy-bicep-classic.yaml",
    "pipelines/stages/deploy-bicep-infra.yaml",
    "pipelines/stages/deploy-bicep-infra-to-classic.yaml",
    "pipelines/stages/deploy-bicep-privatelink.yaml",
    "scripts/pipeline/infrastructure_parameters.py",
]
SOURCE_DEPLOYMENT_STAGES = [
    "DeployResourceGroup", "DeployNetwork", "DeployACR", "DeployClassic",
    "DeployInfrastructure", "DeployInfrastructureToClassic", "PrivateLink",
]
_SHA = re.compile(r"[a-fA-F0-9]{40}")
_UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._()@:+ -]{0,255}")
_PATH = re.compile(r"[A-Za-z_][A-Za-z0-9_.\[\]-]{0,511}")
_TYPE = re.compile(r"Microsoft\.[A-Za-z][A-Za-z0-9.]*(?:/[A-Za-z][A-Za-z0-9-]*)+", re.I)
_SENTINELS = {"[withheld]", "[not present]", "[unresolved expression]", "unavailable"}
_SECURITY = re.compile(r"securityrules|securityprofile|authorization|accesspolic|principal|tenantid|credential|password|secret|token|encryption|disablelocalauth|enable.?rbac|publicnetworkaccess|firewall|networkacl|privatenetwork|privateendpointnetworkpolic", re.I)
_CONFIGURATION = re.compile(r"version|(?:^|\.)sku(?:\.|$)|addressprefix|cidr|subnet|serviceendpoint|servicecidr|podcidr|jobagents|targetgroups|script|command|members|autopause|capacity|replicas|nodecount|mincount|maxcount|agentpoolprofiles|route", re.I)

# Exact resource-type and whole-property matches only. Array indexes must not be
# normalised: the same index can refer to a different named object in each env.
# These are deliberately limited to omitted provider defaults/generated fields.
# A match here is always labelled pattern-only unless all values can be compared.
_OMITTED_DEFAULTS = {
    "microsoft.managedidentity/userassignedidentities": {"properties", "properties.clientid", "properties.principalid", "properties.tenantid"},
    "microsoft.network/privateendpoints": {"properties.ipversiontype"},
    "microsoft.cache/redis": {"properties.updatechannel", "properties.zonalallocationpolicy"},
    "microsoft.search/searchservices": {"properties.endpoint"},
    "microsoft.operationalinsights/workspaces": {"properties.retentionindays"},
}


def _dict(value):
    return value if isinstance(value, dict) else {}


def _list(value):
    return value if isinstance(value, list) else []


def _time(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00")) if isinstance(value, str) else None
        return parsed if parsed and parsed.utcoffset() is not None else None
    except ValueError:
        return None


def _sha(value):
    return isinstance(value, str) and bool(_SHA.fullmatch(value))


def _metadata(report):
    return _dict(_dict(report).get("metadata"))


def _member(value, allowed):
    return isinstance(value, str) and value in allowed


def _report_shape(report, environment):
    return (isinstance(report, dict) and report.get("schemaVersion") == 1
            and report.get("kind") == "environment"
            and _metadata(report).get("environment") == environment)


def _resource_ref(resource):
    """Reproject Azure identifiers; never forward arbitrary artifact strings."""
    rid = resource.get("resourceId")
    parts = rid.split("/") if isinstance(rid, str) and len(rid) <= 2048 else []
    valid = (len(parts) >= 5 and parts[0] == "" and parts[1].lower() == "subscriptions"
             and bool(_UUID.fullmatch(parts[2])) and parts[3].lower() == "resourcegroups"
             and bool(_SEGMENT.fullmatch(parts[4])))
    resource_type = "Microsoft.Resources/resourceGroups"
    if valid and len(parts) > 5:
        # Extension resources introduce another /providers/{namespace}/ segment.
        # Their type comes from the final provider, but retain the full parent
        # scope in resourceId so scoped role assignments remain distinguishable.
        cursor = 5
        while valid and cursor < len(parts):
            valid = (len(parts) >= cursor + 4 and parts[cursor].lower() == "providers"
                     and bool(_SEGMENT.fullmatch(parts[cursor + 1])))
            if not valid:
                break
            namespace = parts[cursor + 1]
            cursor += 2
            types = []
            while cursor < len(parts) and parts[cursor].lower() != "providers":
                valid = (cursor + 1 < len(parts) and bool(_SEGMENT.fullmatch(parts[cursor]))
                         and bool(_SEGMENT.fullmatch(parts[cursor + 1])))
                if not valid:
                    break
                types.append(parts[cursor])
                cursor += 2
            resource_type = "/".join([namespace, *types])
            valid = valid and bool(_TYPE.fullmatch(resource_type))
    if not valid:
        return {"resourceId": "unavailable", "type": "unavailable", "name": "unavailable"}
    claimed_type = resource.get("type")
    if not isinstance(claimed_type, str) or claimed_type.lower() != resource_type.lower():
        return {"resourceId": "unavailable", "type": "unavailable", "name": "unavailable"}
    return {"resourceId": rid, "type": resource_type, "name": parts[-1]}


def _path(field):
    value = field.get("path")
    return value if isinstance(value, str) and _PATH.fullmatch(value) else "[unrecognised property]"


def _safe_scalar(value):
    # This is used only for equality, never for publication. Placeholders, missing
    # values, expressions and arbitrary strings must not establish value matches.
    if isinstance(value, bool):
        return True
    if isinstance(value, int):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    return (isinstance(value, str) and value not in _SENTINELS
            and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,79}", value)))


def _value_match(dev_field, target_field):
    """Return matching-values/pattern-only or None; public differences veto."""
    all_public = True
    for side in ("before", "after"):
        dev_value, target_value = dev_field.get(side), target_field.get(side)
        dev_public, target_public = _safe_scalar(dev_value), _safe_scalar(target_value)
        if dev_public or target_public:
            if not dev_public or not target_public or type(dev_value) is not type(target_value) or dev_value != target_value:
                return None
        else:
            all_public = False
    return "matching-values" if all_public else "pattern-only"


def _effective_resources(report):
    for component in _list(_dict(report).get("components")):
        if isinstance(component, dict):
            for resource in _list(component.get("resources")):
                if isinstance(resource, dict):
                    yield component.get("name"), resource


def _baseline_status(dev_report, target_report, evidence):
    evidence = _dict(evidence)
    if not _report_shape(dev_report, "DEV"):
        return "DEV_REPORT_MISSING_OR_INVALID"
    if evidence.get("schemaVersion") != 1 or evidence.get("status") != "usable":
        return "BASELINE_EVIDENCE_UNAVAILABLE"
    if (evidence.get("sourceVerified") is not True or evidence.get("deploymentInputsUnchanged") is not True
            or evidence.get("sourceDeploymentVerified") is not True
            or evidence.get("sourceDeploymentStages") != SOURCE_DEPLOYMENT_STAGES
            or evidence.get("appliedPipelineId") != 9217 or isinstance(evidence.get("appliedPipelineId"), bool)
            or evidence.get("appliedBranch") != "refs/heads/main"
            or not isinstance(evidence.get("appliedBuildId"), int) or isinstance(evidence.get("appliedBuildId"), bool)
            or evidence["appliedBuildId"] <= 0 or not _sha(evidence.get("appliedCommit"))
            or evidence.get("comparedPaths") != COMPARED_PATHS):
        return "APPLIED_SOURCE_NOT_VERIFIED"
    dev_meta, target_meta = _metadata(dev_report), _metadata(target_report)
    preview_commit, preview_build = evidence.get("previewCommit"), evidence.get("previewBuildId")
    if (not _sha(preview_commit) or preview_commit != dev_meta.get("commit")
            or preview_commit != target_meta.get("commit")
            or not isinstance(preview_build, str) or not re.fullmatch(r"[0-9]{1,20}", preview_build)
            or preview_build != dev_meta.get("buildId") or preview_build != target_meta.get("buildId")):
        return "BASELINE_CANDIDATE_MISMATCH"
    applied, verified, generated, target_generated = (_time(evidence.get("appliedFinishTime")),
        _time(evidence.get("verifiedAt")), _time(dev_meta.get("generatedAt")), _time(target_meta.get("generatedAt")))
    # DEV report metadata is initialised immediately before provenance is checked.
    # Keep that ordering explicit and bounded; release jobs initialise later.
    if (not applied or not verified or not generated or not target_generated
            or not applied <= generated <= verified <= target_generated
            or (verified - generated).total_seconds() > 300):
        return "BASELINE_TIMING_INVALID"
    components = _list(dev_report.get("components"))
    if (dev_report.get("executionStatus") != "succeeded" or len(components) != len(COMPONENTS)
            or {component.get("name") for component in components
                if isinstance(component, dict) and isinstance(component.get("name"), str)} != COMPONENTS
            or any(not isinstance(component, dict) or component.get("status") != "complete"
                   or component.get("diagnosticCount") != 0 for component in components)):
        return "DEV_EXECUTION_INCOMPLETE"
    for _, resource in _effective_resources(dev_report):
        if (_member(resource.get("changeType"), {"Create", "Delete"})
                and _resource_ref(resource)["type"].lower() != "microsoft.resources/deployments"
                or resource.get("potential") is True):
            return "DEV_CONTROL_HAS_ACTIONS"
    return "VERIFIED_POST_APPLY_CONTROL"


def _is_security(resource_type, path):
    return (resource_type.lower() in {"microsoft.network/networksecuritygroups", "microsoft.network/networksecuritygroups/securityrules"}
            or resource_type.lower().startswith("microsoft.authorization/")
            or bool(_SECURITY.search(path)))


def _known_default(resource_type, path, action):
    return (action == "Delete" and path.lower() in _OMITTED_DEFAULTS.get(resource_type.lower(), set())
            and not re.search(r"\[|(?:^|\.)[0-9]+(?:\.|$)", path))


def _field_result(field, classification, reason, confidence="none"):
    action = field.get("changeType")
    return {"path": _path(field), "action": action if _member(action, FIELD_ACTIONS) else "Unknown",
            "classification": classification, "reasonCode": reason, "confidence": confidence}


def _metadata_field(field):
    return isinstance(field, dict) and _path(field).lower() == "tags.createddate"


def _background(resource):
    fields = _list(resource.get("fields"))
    if resource.get("potential") is True:
        return False
    return (_member(resource.get("changeType"), {"Ignore", "NoChange"})
            or _resource_ref(resource)["type"].lower() == "microsoft.resources/deployments"
            or resource.get("changeType") == "Modify" and bool(fields)
            and all(isinstance(field, dict) and (_metadata_field(field) or field.get("changeType") == "NoEffect") for field in fields))


def analyze_comparison(dev_report, target_report, baseline_evidence):
    """Label target observations using a verified control; never suppress changes.

    ``baseline_evidence`` must be independently verified by the pipeline before
    running DEV. Reports must belong to the same candidate commit and preview
    build, and every DEV component must execute without create/delete actions.
    Array properties and security/configuration edits are deliberately kept for
    review even when another environment reports the same textual delta.
    """
    target_report = _dict(target_report)
    environment = _metadata(target_report).get("environment")
    environment = environment if _member(environment, {"TST", "PRE", "PRD"}) else "UNKNOWN"
    reason = _baseline_status(dev_report, target_report, baseline_evidence)
    usable = reason == "VERIFIED_POST_APPLY_CONTROL" and _report_shape(target_report, environment) and environment != "UNKNOWN"
    if reason == "VERIFIED_POST_APPLY_CONTROL" and not usable:
        reason = "TARGET_REPORT_INVALID"
    elif usable and target_report.get("executionStatus") != "succeeded":
        usable, reason = False, "TARGET_EXECUTION_INCOMPLETE"
    index = {}
    if usable:
        for component, resource in _effective_resources(dev_report):
            ref = _resource_ref(resource)
            if (resource.get("changeType") != "Modify" or resource.get("potential") is True
                    or ref["type"] == "unavailable" or _background(resource)):
                continue
            for field in _list(resource.get("fields")):
                if (isinstance(field, dict) and field.get("unresolved") is not True
                        and _member(component, COMPONENTS) and _member(field.get("changeType"), FIELD_ACTIONS)):
                    key = (component, ref["type"].lower(), _path(field).lower(), field.get("changeType"))
                    index.setdefault(key, []).append(field)
    resources = []
    for component, resource in _effective_resources(target_report):
        ref = _resource_ref(resource)
        component = component if _member(component, COMPONENTS) else "unavailable"
        action = resource.get("changeType")
        action = action if _member(action, ACTIONS) else "Unknown"
        output = {"component": component, **ref, "action": action, "fields": []}
        if _background(resource):
            classification, resource_reason = "background", "NO_REVIEW_ACTION"
        elif resource.get("potential") is True or action in {"Unknown", "Unsupported", "Deploy"}:
            classification, resource_reason = "unresolved-coverage", "ACTION_NOT_ASSESSED"
        elif action in {"Create", "Delete"}:
            classification, resource_reason = "review-needed", "RESOURCE_CREATE_OR_DELETE"
        elif action != "Modify" or not _list(resource.get("fields")):
            classification, resource_reason = "unresolved-coverage", "FIELDS_NOT_ASSESSED"
        else:
            for field in _list(resource.get("fields")):
                field = _dict(field)
                path, field_action = _path(field), field.get("changeType")
                if _metadata_field(field) or field_action == "NoEffect":
                    result = _field_result(field, "background", "METADATA_OR_NO_EFFECT")
                elif field.get("unresolved") is True or path == "[unrecognised property]" or not _member(field_action, FIELD_ACTIONS):
                    result = _field_result(field, "unresolved-coverage", "FIELD_NOT_ASSESSED")
                elif component in {"classic", "infra-to-classic"}:
                    result = _field_result(field, "review-needed", "CLASSIC_SCOPE_DIFFERS")
                elif _known_default(ref["type"], path, field_action):
                    matches = index.get((component, ref["type"].lower(), path.lower(), field_action), []) if usable else []
                    confidence = next((value for match in matches if (value := _value_match(match, field))), None)
                    if confidence:
                        result = _field_result(field, "potential-noise", "RECURRING_PROVIDER_DEFAULT", confidence)
                    else:
                        result = _field_result(field, "review-needed", "NO_MATCHING_CONTROL_VALUE" if usable else "BASELINE_UNAVAILABLE")
                elif _is_security(ref["type"], path):
                    result = _field_result(field, "policy-security-review", "SECURITY_OR_POLICY_OWNERSHIP")
                elif _CONFIGURATION.search(path) or _CONFIGURATION.search(ref["type"]):
                    result = _field_result(field, "review-needed", "CONFIGURATION_REQUIRES_REVIEW")
                else:
                    result = _field_result(field, "review-needed", "NO_KNOWN_NOISE_PATTERN" if usable else "BASELINE_UNAVAILABLE")
                output["fields"].append(result)
            classes = {field["classification"] for field in output["fields"]} - {"background"}
            if "policy-security-review" in classes:
                classification, resource_reason = "policy-security-review", "SECURITY_OR_POLICY_OWNERSHIP"
            elif "review-needed" in classes:
                classification, resource_reason = "review-needed", "CONFIGURATION_REQUIRES_REVIEW"
            elif "unresolved-coverage" in classes or resource.get("unresolved") is True:
                classification, resource_reason = "unresolved-coverage", "FIELD_NOT_ASSESSED"
            elif classes == {"potential-noise"}:
                classification, resource_reason = "potential-noise", "RECURRING_PROVIDER_DEFAULT"
            else:
                classification, resource_reason = "background", "NO_REVIEW_ACTION"
        output.update({"classification": classification, "reasonCode": resource_reason})
        resources.append(output)
    resource_counts = Counter(resource["classification"] for resource in resources)
    field_counts = Counter(field["classification"] for resource in resources for field in resource["fields"])
    names = {"potential-noise": "potentialNoise", "review-needed": "review", "unresolved-coverage": "unresolved",
             "policy-security-review": "policySecurity", "background": "background"}
    counts = {name + "Resources": resource_counts[classification] for classification, name in names.items()}
    counts.update({name + "Fields": field_counts[classification] for classification, name in names.items()})
    return {"schemaVersion": 1, "kind": "dev-baseline-comparison", "environment": environment,
            "baseline": {"status": "usable" if usable else "unavailable", "reasonCode": reason},
            "counts": counts, "resources": resources}
