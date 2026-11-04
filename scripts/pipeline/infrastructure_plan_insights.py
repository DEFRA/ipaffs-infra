"""Exact evidence for Application Insights' REST creation-origin metadata.

The 2020-02-02 API defines Bluefield/rest as the component's creation origin.
Only those absent-to-default additions are background: workspace, access and
other configuration changes remain separate. Never persist raw ARM snapshots.
"""

import json
import re


INSIGHTS_TYPE = "microsoft.insights/components"
METADATA_REASON = "APPLICATION_INSIGHTS_CREATION_METADATA"
MISSING = "[not present]"
ORIGIN_FIELDS = {"properties.Flow_Type": "Bluefield", "properties.Request_Source": "rest"}
_ABSENT = object()
_UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._()@:+ -]{0,255}")


def has_insights_resource_id(value):
    parts = value.split("/") if isinstance(value, str) and len(value) <= 1024 else []
    return (len(parts) == 9 and parts[0] == "" and parts[1].lower() == "subscriptions"
            and bool(_UUID.fullmatch(parts[2])) and parts[3].lower() == "resourcegroups"
            and bool(_SEGMENT.fullmatch(parts[4])) and parts[5].lower() == "providers"
            and parts[6].lower() == "microsoft.insights" and parts[7].lower() == "components"
            and bool(_SEGMENT.fullmatch(parts[8])))


def _unambiguous_keys(value):
    return (isinstance(value, dict) and all(isinstance(key, str) for key in value)
            and len({key.lower() for key in value}) == len(value))


def _properties(change, side):
    snapshot = change.get(side)
    if not _unambiguous_keys(snapshot):
        return None
    if any(key.lower() == canonical.lower() and key != canonical
           for key in snapshot for canonical in ("type", "id", "name", "apiVersion", "properties")):
        return None
    kind = snapshot.get("type")
    if not isinstance(kind, str) or kind.lower() != INSIGHTS_TYPE:
        return None
    resource_id = change["resourceId"]
    if ("id" in snapshot and (not isinstance(snapshot["id"], str)
                             or snapshot["id"].lower() != resource_id.lower())):
        return None
    if ("name" in snapshot and (not isinstance(snapshot["name"], str)
                               or snapshot["name"].lower() != resource_id.rsplit("/", 1)[-1].lower())):
        return None
    if "apiVersion" in snapshot and snapshot["apiVersion"] != "2020-02-02":
        return None
    properties = snapshot.get("properties")
    return properties if _unambiguous_keys(properties) else None


def _deltas(delta, parent="", ancestors=()):
    """Return full raw paths plus their containers; reject ambiguous structures."""
    if not isinstance(delta, list):
        return None
    result = []
    for entry in delta:
        if not _unambiguous_keys(entry) or not isinstance(entry.get("path"), str):
            return None
        if any(key.lower() == canonical.lower() and key != canonical
               for key in entry for canonical in ("path", "propertyChangeType", "before", "after", "children", "childDelta")):
            return None
        path = entry["path"]
        if parent and path != parent and not path.startswith(parent + "."):
            path = parent + "." + path
        if not path or len(path) > 512 or ("children" in entry and "childDelta" in entry):
            return None
        result.append((path, entry, ancestors))
        children = entry.get("children", entry.get("childDelta"))
        if children is not None:
            nested = _deltas(children, path, (*ancestors, entry))
            if nested is None:
                return None
            result.extend(nested)
    return result


def _origin_proven(path, expected, old, new, deltas):
    leaf = path.rsplit(".", 1)[-1]
    if any(key.lower() == leaf.lower() for key in old):
        return False
    if new.get(leaf, _ABSENT) != expected or any(key.lower() == leaf.lower() and key != leaf for key in new):
        return False
    matching = [(raw, ancestors) for candidate, raw, ancestors in deltas if candidate.lower() == path.lower()]
    if len(matching) != 1:
        return False
    raw, ancestors = matching[0]
    canonical = [candidate for candidate, entry, _ in deltas if entry is raw]
    if canonical != [path] or raw.get("propertyChangeType") != "Create":
        return False
    # ARM emits null delta values for missing properties. The complete before
    # snapshot above, not null itself, proves the property was absent.
    if raw.get("before") is not None or raw.get("after", _ABSENT) != expected:
        return False
    if raw.get("children", raw.get("childDelta")) not in (None, []):
        return False
    if any("before" in ancestor or "after" in ancestor for ancestor in ancestors):
        return False
    # A second coarse bag, descendant or case-alias path could contradict the
    # leaf prediction even when the normalizer happens to flatten it away.
    for candidate, entry, _ in deltas:
        lower = candidate.lower()
        if entry is raw:
            continue
        if lower.startswith(path.lower() + "."):
            return False
        if path.lower().startswith(lower + "."):
            if (candidate != path[:len(candidate)] or "before" in entry or "after" in entry
                    or entry.get("propertyChangeType") not in (None, "Modify")):
                return False
    return True


def _other_configuration(snapshot, origin_paths):
    result = {key: value for key, value in snapshot.items() if key not in {"id", "name", "type", "apiVersion"}}
    result["properties"] = {key: value for key, value in snapshot["properties"].items()
                            if "properties." + key not in origin_paths}
    if isinstance(result.get("tags"), dict):
        tags = {key: value for key, value in result["tags"].items() if key != "CreatedDate"}
        if tags:
            result["tags"] = tags
        else:
            result.pop("tags")
    return result


def _same_configuration(before, after, origin_paths):
    # JSON equality preserves scalar types (unlike Python's False == 0) and
    # refuses non-JSON/NaN evidence. These private strings are never published.
    try:
        return json.dumps(_other_configuration(before, origin_paths), sort_keys=True, allow_nan=False) == json.dumps(
            _other_configuration(after, origin_paths), sort_keys=True, allow_nan=False)
    except (TypeError, ValueError):
        return False


def annotate_insights_origin(change, fields, potential=False):
    result = [dict(field) if isinstance(field, dict) else field for field in fields] if isinstance(fields, list) else []
    for field in result:
        if isinstance(field, dict) and field.get("path") in ORIGIN_FIELDS:
            field["metadataOnly"] = False
            field.pop("metadataReason", None)
    unannotated = [dict(field) if isinstance(field, dict) else field for field in result]
    if (not _unambiguous_keys(change) or potential or change.get("changeType") != "Modify"
            or not has_insights_resource_id(change.get("resourceId"))):
        return result
    if any(key.lower() == canonical.lower() and key != canonical
           for key in change for canonical in ("resourceId", "changeType", "before", "after", "delta")):
        return result
    old, new = _properties(change, "before"), _properties(change, "after")
    deltas = _deltas(change.get("delta"))
    if old is None or new is None or deltas is None:
        return result
    for field in result:
        if not isinstance(field, dict) or field.get("path") not in ORIGIN_FIELDS:
            continue
        path, expected = field["path"], ORIGIN_FIELDS[field["path"]]
        occurrences = [item for item in result if isinstance(item, dict)
                       and str(item.get("path", "")).lower() == path.lower()]
        if (len(occurrences) == 1 and field.get("changeType") == "Create"
                and field.get("unresolved") is False and _origin_proven(path, expected, old, new, deltas)):
            field.update(before=MISSING, after=expected, metadataOnly=True, metadataReason=METADATA_REASON)
    # A sparse/contradictory delta must not turn a real snapshot configuration
    # change into zero actions merely because its only reported leaves are
    # origins. Mixed resources retain their other review fields normally.
    proven_paths = {field["path"] for field in result if isinstance(field, dict)
                    and field.get("metadataReason") == METADATA_REASON}
    if (proven_paths and all(isinstance(field, dict) and (field.get("metadataOnly") is True
                                                  or field.get("changeType") == "NoEffect") for field in result)
            and not _same_configuration(change["before"], change["after"], proven_paths)):
        for index, field in enumerate(result):
            if field.get("metadataReason") == METADATA_REASON:
                result[index] = {**unannotated[index], "unresolved": True}
    return result


def insights_metadata_reason(resource_type, field, resource_id=None):
    """Recheck fixed published facts; a metadataOnly flag alone proves nothing."""
    if (not isinstance(resource_type, str) or resource_type.lower() != INSIGHTS_TYPE
            or not has_insights_resource_id(resource_id) or not isinstance(field, dict)
            or field.get("changeType") != "Create" or field.get("before") != MISSING
            or field.get("unresolved") is not False or field.get("metadataOnly") is not True
            or field.get("metadataReason") != METADATA_REASON):
        return None
    path = field.get("path")
    expected = ORIGIN_FIELDS.get(path) if isinstance(path, str) else None
    return METADATA_REASON if expected is not None and field.get("after") == expected else None
