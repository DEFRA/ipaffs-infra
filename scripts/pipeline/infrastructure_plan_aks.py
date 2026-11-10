"""Narrow AKS output omissions and separately projected operational warnings.

Only API 2025-10-01 response properties are eligible. Writable node counts,
pool power states, identities and security settings are deliberately absent.
Raw values and error details never leave this module's fixed projection.
"""

import re


AKS_TYPE = "microsoft.containerservice/managedclusters"
METADATA_REASON = "AKS_READ_ONLY_PROPERTY"
WITHHELD = "[withheld]"
MISSING = "[not present]"
_ABSENT = object()
_UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._()@:+ -]{0,255}")
_POOL_NAME = re.compile(r"[a-z][a-z0-9]{0,11}")
_POOL_FIELD = re.compile(
    r"properties\.agentPoolProfiles\.(0|[1-9][0-9]{0,3})\."
    r"(eTag|currentOrchestratorVersion|nodeImageVersion|provisioningState|status)")
_CLUSTER_FIELDS = {
    "properties.provisioningState", "properties.powerState", "properties.maxAgentPools",
    "properties.currentKubernetesVersion", "properties.fqdn", "properties.privateFQDN",
    "properties.azurePortalFQDN", "properties.resourceUID",
}
_UNHEALTHY_STATES = {"Failed", "Canceled"}


def has_aks_resource_id(value):
    parts = value.split("/") if isinstance(value, str) and len(value) <= 2048 else []
    return (len(parts) == 9 and parts[0] == "" and parts[1].lower() == "subscriptions"
            and bool(_UUID.fullmatch(parts[2])) and parts[3].lower() == "resourcegroups"
            and bool(_SEGMENT.fullmatch(parts[4])) and parts[5].lower() == "providers"
            and parts[6].lower() == "microsoft.containerservice"
            and parts[7].lower() == "managedclusters"
            and bool(_SEGMENT.fullmatch(parts[8])))


def _path_kind(path):
    if not isinstance(path, str):
        return None
    if path in _CLUSTER_FIELDS:
        return (None, path.rsplit(".", 1)[-1])
    match = _POOL_FIELD.fullmatch(path)
    return (int(match.group(1)), match.group(2)) if match else None


def _snapshot_properties(change, key):
    snapshot = change.get(key)
    if not isinstance(snapshot, dict):
        return None
    kind = snapshot.get("type")
    if kind is not None and (not isinstance(kind, str) or kind.lower() != AKS_TYPE):
        return None
    properties = snapshot.get("properties")
    return properties if isinstance(properties, dict) else None


def _named_pools(properties):
    pools = properties.get("agentPoolProfiles") if isinstance(properties, dict) else None
    if not isinstance(pools, list) or not pools or len(pools) > 1000:
        return None
    names = []
    for pool in pools:
        name = pool.get("name") if isinstance(pool, dict) else None
        if not isinstance(name, str) or not _POOL_NAME.fullmatch(name) or name in names:
            return None
        names.append(name)
    return pools


def _raw_deltas(delta, parent=""):
    if not isinstance(delta, list):
        return
    for item in delta:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            continue
        path = item["path"]
        path = (path if not parent or path == parent or path.startswith(parent + ".")
                else parent + "." + path)
        if len(path) > 512:
            continue
        yield path, item
        children = item.get("children", item.get("childDelta"))
        if isinstance(children, list):
            yield from _raw_deltas(children, path)


def _healthy_read_only_value(leaf, value, pool=False):
    if leaf == "provisioningState":
        return value == "Succeeded"
    if leaf == "powerState":
        return not pool and isinstance(value, dict) and value == {"code": "Running"}
    if leaf == "maxAgentPools":
        return isinstance(value, int) and not isinstance(value, bool) and value > 0
    if leaf == "status":
        return pool and isinstance(value, dict) and not value
    return isinstance(value, str) and bool(value.strip()) and not value.strip().startswith("[")


def _omission_proof(change, path, raw):
    kind = _path_kind(path)
    old = _snapshot_properties(change, "before")
    new = _snapshot_properties(change, "after")
    children = raw.get("children", raw.get("childDelta"))
    if (kind is None or old is None or new is None or "before" not in raw
            or raw.get("propertyChangeType") != "Delete"
            or ("after" in raw and raw["after"] is not None)
            or (children is not None and children != [])):
        return None
    index, leaf = kind
    pool_name = None
    if index is not None:
        old_pools, new_pools = _named_pools(old), _named_pools(new)
        if old_pools is None or new_pools is None or index >= len(old_pools):
            return None
        old = old_pools[index]
        pool_name = old["name"]
        matching = [pool for pool in new_pools if pool["name"] == pool_name]
        if len(matching) != 1:
            return None
        new = matching[0]
    old_value = old.get(leaf, _ABSENT)
    # A differently-cased key is not evidence of omission either.
    new_present = any(isinstance(key, str) and key.lower() == leaf.lower() for key in new)
    if (old_value is _ABSENT or new_present or type(old_value) is not type(raw["before"])
            or old_value != raw["before"] or not _healthy_read_only_value(leaf, old_value, index is not None)):
        return None
    return {"aksPoolName": pool_name} if pool_name is not None else {}


def annotate_aks_omissions(raw_change, fields, potential=False):
    result = [dict(field) if isinstance(field, dict) else field for field in fields] if isinstance(fields, list) else []
    if (not isinstance(raw_change, dict) or potential or raw_change.get("changeType") != "Modify"
            or not has_aks_resource_id(raw_change.get("resourceId"))):
        return result
    deltas = {}
    for path, raw in _raw_deltas(raw_change.get("delta")):
        deltas.setdefault(path, []).append(raw)
    for field in result:
        if not isinstance(field, dict) or _path_kind(field.get("path")) is None:
            continue
        field.pop("metadataReason", None)
        field.pop("aksPoolName", None)
        field["metadataOnly"] = False
        if field.get("changeType") != "Delete":
            continue
        candidates = deltas.get(field["path"], [])
        proof = (_omission_proof(raw_change, field["path"], candidates[0])
                 if len(candidates) == 1 and field.get("unresolved") is False else None)
        if proof is None:
            field["unresolved"] = True
            continue
        field.update(proof)
        field.update(before=WITHHELD, after=MISSING, unresolved=False,
                     metadataOnly=True, metadataReason=METADATA_REASON)
    return result


def aks_metadata_reason(resource_type, field):
    if (not isinstance(resource_type, str) or resource_type.lower() != AKS_TYPE
            or not isinstance(field, dict) or field.get("metadataReason") != METADATA_REASON
            or field.get("changeType") != "Delete" or field.get("before") != WITHHELD
            or field.get("after") != MISSING or field.get("unresolved") is not False):
        return None
    kind = _path_kind(field.get("path"))
    if kind is None:
        return None
    if kind[0] is not None:
        name = field.get("aksPoolName")
        if not isinstance(name, str) or not _POOL_NAME.fullmatch(name):
            return None
    elif "aksPoolName" in field:
        return None
    return METADATA_REASON


def aks_health_warnings(raw_change, potential=False):
    if not isinstance(raw_change, dict) or potential or not has_aks_resource_id(raw_change.get("resourceId")):
        return []
    properties = _snapshot_properties(raw_change, "before")
    if properties is None:
        return []
    warnings = []
    state = properties.get("provisioningState")
    if isinstance(state, str) and state in _UNHEALTHY_STATES:
        warnings.append({"code": "AKS_CLUSTER_PROVISIONING_FAILED"})
    pools = _named_pools(properties)
    for pool in pools or []:
        state = pool.get("provisioningState")
        if isinstance(state, str) and state in _UNHEALTHY_STATES:
            warnings.append({"code": "AKS_POOL_PROVISIONING_FAILED", "poolName": pool["name"]})
        else:
            status = pool.get("status")
            if (isinstance(status, dict)
                    and any(isinstance(key, str) and key.lower() in {"errordetail", "provisioningerror"}
                            and isinstance(value, dict) and bool(value)
                            for key, value in status.items())):
                warnings.append({"code": "AKS_POOL_REPORTED_ERROR", "poolName": pool["name"]})
    return warnings


def validated_aks_health_warnings(resource):
    if (not isinstance(resource, dict) or resource.get("potential") is True
            or not isinstance(resource.get("type"), str) or resource["type"].lower() != AKS_TYPE
            or not has_aks_resource_id(resource.get("resourceId"))):
        return []
    raw = resource.get("healthWarnings")
    if not isinstance(raw, list):
        return []
    warnings, seen = [], set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        code = item.get("code")
        if code == "AKS_CLUSTER_PROVISIONING_FAILED":
            warning = {"code": code}
        elif isinstance(code, str) and code in {"AKS_POOL_PROVISIONING_FAILED", "AKS_POOL_REPORTED_ERROR"}:
            name = item.get("poolName")
            if not isinstance(name, str) or not _POOL_NAME.fullmatch(name):
                continue
            warning = {"code": code, "poolName": name}
        else:
            continue
        key = (warning["code"], warning.get("poolName"))
        if key not in seen:
            warnings.append(warning)
            seen.add(key)
    return warnings
