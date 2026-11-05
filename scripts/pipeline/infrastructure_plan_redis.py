"""Project Redis settings individually and retain only narrowly proven omissions.

The API's read-only connection limit and an unchanged Automatic zone policy are
background. Writable memory settings remain reviewable, including omissions.
Only approved numeric configuration values leave the raw ARM projection.
"""

import copy
import json
import re


REDIS_TYPE = "microsoft.cache/redis"
CONFIG = "properties.redisConfiguration"
ZONE = "properties.zonalAllocationPolicy"
MISSING = "[not present]"
WITHHELD = "[withheld]"
READ_ONLY = "REDIS_READ_ONLY_SETTING"
AUTOMATIC = "UNCHANGED_REDIS_AUTOMATIC_ZONE_POLICY"
OMISSION = "REDIS_WRITABLE_MEMORY_OMISSION"
EXPANSION = "EXPANDED_REDIS_CONFIGURATION"
MEMORY_KEYS = {"maxmemory-reserved", "maxmemory-delta", "maxfragmentationmemory-reserved"}
NUMERIC_KEYS = MEMORY_KEYS | {"maxclients"}
_ABSENT = object()
_NUMBER = re.compile(r"0|[1-9][0-9]{0,8}")
_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]{0,127}")
_UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._()@:+ -]{0,255}")


def has_redis_resource_id(value):
    parts = value.split("/") if isinstance(value, str) and len(value) <= 1024 else []
    return (len(parts) == 9 and parts[0] == "" and parts[1].lower() == "subscriptions"
            and bool(_UUID.fullmatch(parts[2])) and parts[3].lower() == "resourcegroups"
            and bool(_SEGMENT.fullmatch(parts[4])) and parts[5].lower() == "providers"
            and parts[6].lower() == "microsoft.cache" and parts[7].lower() == "redis"
            and bool(_SEGMENT.fullmatch(parts[8])))


def numeric_setting(value):
    return isinstance(value, str) and bool(_NUMBER.fullmatch(value))


def public_config_value(path, value):
    """Unknown keys never fall back to the global number/enum publication rules."""
    key = path[len(CONFIG) + 1:] if isinstance(path, str) and path.startswith(CONFIG + ".") else ""
    return value if key in NUMERIC_KEYS and numeric_setting(value) else WITHHELD


def property_label(path):
    labels = {
        "maxclients": "Redis connection limit (maxclients)",
        "maxmemory-reserved": "Redis memory reserve (maxmemory-reserved, MB)",
        "maxmemory-delta": "Redis memory delta reserve (maxmemory-delta, MB)",
        "maxfragmentationmemory-reserved": "Redis fragmentation reserve (maxfragmentationmemory-reserved, MB)",
    }
    if isinstance(path, str) and path.startswith(CONFIG + "."):
        key = path[len(CONFIG) + 1:]
        return labels.get(key, "Redis setting " + key)
    return "Redis zone allocation policy" if path == ZONE else None


def _keys(value, canonical=()):
    return (isinstance(value, dict) and all(isinstance(key, str) for key in value)
            and len({key.lower() for key in value}) == len(value)
            and not any(key.lower() == name.lower() and key != name for key in value for name in canonical))


def _equal(a, b):
    try:
        return json.dumps(a, sort_keys=True, allow_nan=False) == json.dumps(b, sort_keys=True, allow_nan=False)
    except (TypeError, ValueError):
        return False


def _context(change):
    if (not _keys(change, ("resourceId", "changeType", "before", "after", "delta"))
            or change.get("changeType") != "Modify" or not has_redis_resource_id(change.get("resourceId"))):
        return None
    snapshots = []
    for side in ("before", "after"):
        snapshot = change.get(side)
        if not _keys(snapshot, ("id", "name", "type", "apiVersion", "properties", "zones", "tags")):
            return None
        if not isinstance(snapshot.get("type"), str) or snapshot["type"].lower() != REDIS_TYPE:
            return None
        if "apiVersion" in snapshot and snapshot["apiVersion"] != "2024-11-01":
            return None
        if "id" in snapshot and (not isinstance(snapshot["id"], str) or snapshot["id"].lower() != change["resourceId"].lower()):
            return None
        if "name" in snapshot and snapshot["name"] != change["resourceId"].rsplit("/", 1)[-1]:
            return None
        if not _keys(snapshot.get("properties"), ("redisConfiguration", "zonalAllocationPolicy", "sku")):
            return None
        snapshots.append(snapshot)
    return snapshots


def _deltas(delta, parent="", ancestors=()):
    if not isinstance(delta, list):
        return None
    result = []
    for entry in delta:
        if not _keys(entry, ("path", "propertyChangeType", "before", "after", "children", "childDelta")) or not isinstance(entry.get("path"), str):
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


def _unambiguous_leaf(path, raw, ancestors, deltas):
    if raw.get("children", raw.get("childDelta")) not in (None, []):
        return False
    matches = [(p, r) for p, r, _ in deltas if p.lower() == path.lower()]
    if matches != [(path, raw)]:
        return False
    for ancestor in ancestors:
        if "before" in ancestor or "after" in ancestor or ancestor.get("propertyChangeType") not in (None, "Modify"):
            return False
    for candidate, entry, _ in deltas:
        if entry is raw:
            continue
        if candidate.lower().startswith(path.lower() + "."):
            return False
        if path.lower().startswith(candidate.lower() + "."):
            if candidate != path[:len(candidate)] or "before" in entry or "after" in entry or entry.get("propertyChangeType") not in (None, "Modify"):
                return False
    return True


def _bag(value):
    return _keys(value) and all(_KEY.fullmatch(key) for key in value)


def _stable_sku(old, new):
    sku = old.get("sku")
    return (_keys(sku) and set(sku) == {"name", "family", "capacity"}
            and type(sku["capacity"]) is int
            and ((sku["name"] == "Standard" and sku["family"] == "C" and 0 <= sku["capacity"] <= 6)
                 or (sku["name"] == "Premium" and sku["family"] == "P" and 1 <= sku["capacity"] <= 4))
            and _equal(sku, new.get("sku")))


def _snapshot_value(properties, path):
    if path == ZONE:
        return properties.get("zonalAllocationPolicy", _ABSENT)
    bag = properties.get("redisConfiguration")
    return bag.get(path[len(CONFIG) + 1:], _ABSENT) if _bag(bag) and path.startswith(CONFIG + ".") else _ABSENT


def _publish_values(field, path, raw, old, new):
    for side, snapshot in (("before", old), ("after", new)):
        value = raw.get(side, _ABSENT)
        public = (value if path == ZONE and isinstance(value, str) and value in {"Automatic", "NoZones", "UserDefined"}
                  else public_config_value(path, value))
        if public != WITHHELD and _equal(value, _snapshot_value(snapshot, path)):
            field[side] = public


def _configuration_changes(raw, old, new):
    action = raw.get("propertyChangeType")
    if action == "Delete" and CONFIG.split(".")[-1] not in new and raw.get("after") is None:
        before, after = raw.get("before"), {}
        if not _bag(before) or not _equal(before, old.get("redisConfiguration", _ABSENT)):
            return None
    elif action == "Create" and "redisConfiguration" not in old and raw.get("before") is None:
        before, after = {}, raw.get("after")
        if not _bag(after) or not _equal(after, new.get("redisConfiguration", _ABSENT)):
            return None
    elif action == "Modify":
        before, after = raw.get("before"), raw.get("after")
        if (not _bag(before) or not _bag(after) or not _equal(before, old.get("redisConfiguration", _ABSENT))
                or not _equal(after, new.get("redisConfiguration", _ABSENT))):
            return None
    else:
        return None
    result = []
    for key in dict.fromkeys([*before, *after]):
        if key in before and key in after and _equal(before[key], after[key]):
            continue
        entry = {"path": CONFIG + "." + key,
                 "propertyChangeType": "Modify" if key in before and key in after else "Delete" if key in before else "Create"}
        if key in before:
            entry["before"] = before[key]
        if key in after:
            entry["after"] = after[key]
        result.append(entry)
    return result or None


def _omission(path, raw, old, new):
    if raw.get("propertyChangeType") != "Delete" or "before" not in raw or raw.get("after") is not None:
        return False
    if path.startswith(CONFIG + "."):
        key = path[len(CONFIG) + 1:]
        before = old.get("redisConfiguration")
        after = new.get("redisConfiguration", {})
        return (_bag(before) and _bag(after) and key in before
                and not any(k.lower() == key.lower() for k in after) and _equal(raw["before"], before[key]))
    return (path == ZONE and path.rsplit(".", 1)[-1] in old
            and not any(key.lower() == "zonalallocationpolicy" for key in new)
            and _equal(raw["before"], old["zonalAllocationPolicy"]))


def _same_other_configuration(snapshots, ignored):
    copies = copy.deepcopy(snapshots)
    for snapshot in copies:
        for key in ("id", "name", "type", "apiVersion"):
            snapshot.pop(key, None)
        if snapshot.get("zones", _ABSENT) is None:
            snapshot.pop("zones")
        if isinstance(snapshot.get("tags"), dict):
            snapshot["tags"].pop("CreatedDate", None)
            if not snapshot["tags"]:
                snapshot.pop("tags")
        properties = snapshot["properties"]
        for path in ignored:
            if path == ZONE:
                properties.pop("zonalAllocationPolicy", None)
            else:
                bag = properties.get("redisConfiguration")
                if isinstance(bag, dict):
                    bag.pop(path[len(CONFIG) + 1:], None)
        if properties.get("redisConfiguration") == {}:
            properties.pop("redisConfiguration")
    return _equal(*copies)


def project_redis_fields(change, fields, projector, potential=False):
    """Use the existing redactor on a complete leaf projection, then add proof."""
    if change.get("changeType") != "Modify":
        return fields
    claimed = any(isinstance(change.get(side), dict) and isinstance(change[side].get("type"), str)
                  and change[side]["type"].lower() == REDIS_TYPE for side in ("before", "after"))
    if not claimed and not has_redis_resource_id(change.get("resourceId")):
        return fields
    context, deltas = _context(change), _deltas(change.get("delta"))
    if context is None or deltas is None:
        # Coarse payloads may carry writable settings that the generic child
        # projection cannot assess. A malformed Redis record must not disappear
        # just because its surviving child happens to be date metadata.
        result = [dict(field) for field in fields]
        gap = next((field for field in result if field.get("path") == CONFIG), None)
        if gap is None:
            gap = projector([{"path": CONFIG, "propertyChangeType": "Unknown"}])[0]
            result.append(gap)
        gap.update(unresolved=True, metadataOnly=False)
        return result
    old, new = (snapshot["properties"] for snapshot in context)
    flat, proven, uncertain, expanded_actions = [], {}, set(), {}
    for path, raw, ancestors in deltas:
        # Transparent containers carry their leaves; value-carrying containers
        # are retained when they cannot be expanded with complete proof.
        children = raw.get("children", raw.get("childDelta"))
        if path == CONFIG:
            expanded = (_configuration_changes(raw, old, new)
                        if _unambiguous_leaf(path, raw, ancestors, deltas) else None)
            if expanded:
                flat.extend(expanded)
                proven.update({entry["path"]: entry for entry in expanded})
                expanded_actions.update({entry["path"]: raw["propertyChangeType"] for entry in expanded})
                continue
            uncertain.add(path)
        elif path == "properties" and any(isinstance(raw.get(side), dict)
                                           and any(key.lower() == "redisconfiguration" for key in raw[side] if isinstance(key, str))
                                           for side in ("before", "after")):
            # A value-carrying outer bag is retained as an assessment gap;
            # its sparse children do not establish the complete configuration.
            uncertain.add(path)
        elif children and "before" not in raw and "after" not in raw:
            continue
        entry = {key: value for key, value in raw.items() if key not in {"children", "childDelta"}}
        entry["path"] = path
        flat.append(entry)
        if _unambiguous_leaf(path, raw, ancestors, deltas):
            proven[path] = entry
    result = projector(flat)
    for field in result:
        path = field.get("path")
        if path in expanded_actions:
            field.update(configurationSource=EXPANSION, configurationOperation=expanded_actions[path])
        if path in uncertain:
            field["unresolved"] = True
        raw = proven.get(path)
        if raw is not None:
            _publish_values(field, path, raw, old, new)
        if potential or raw is None or field.get("unresolved") is not False or not _omission(path, raw, old, new):
            continue
        if path == CONFIG + ".maxclients" and numeric_setting(raw.get("before")) and raw["before"] != "0":
            field.update(before=raw["before"], after=MISSING, metadataOnly=True, metadataReason=READ_ONLY)
        elif path.startswith(CONFIG + ".") and path[len(CONFIG) + 1:] in MEMORY_KEYS and numeric_setting(raw.get("before")):
            field.update(before=raw["before"], after=MISSING, configurationOmission=OMISSION)
        elif (path == ZONE and raw["before"] == "Automatic"
              and _stable_sku(old, new)
              and all(snapshot.get("zones") is None for snapshot in context)
              and not any(p.lower() == "zones" or p.lower().startswith(("zones.", "zones[")) for p, _, _ in deltas)):
            field.update(before="Automatic", after=MISSING, metadataOnly=True, metadataReason=AUTOMATIC)
    ignored = {field["path"] for field in result if field.get("metadataReason") in {READ_ONLY, AUTOMATIC}}
    if (all(field.get("metadataOnly") is True or field.get("changeType") == "NoEffect" for field in result)
            and not _same_other_configuration(context, ignored)):
        if not ignored:
            gap = projector([{"path": CONFIG, "propertyChangeType": "Unknown"}])[0]
            gap.update(unresolved=True, metadataOnly=False)
            result.append(gap)
        for field in result:
            if field.get("metadataReason") in {READ_ONLY, AUTOMATIC}:
                field.update(metadataOnly=False, unresolved=True)
                field.pop("metadataReason", None)
    return result


def metadata_reason(resource_type, field, resource_id=None):
    if (not isinstance(resource_type, str) or resource_type.lower() != REDIS_TYPE or not has_redis_resource_id(resource_id)
            or not isinstance(field, dict) or field.get("metadataOnly") is not True or field.get("unresolved") is not False
            or field.get("changeType") != "Delete" or field.get("after") != MISSING):
        return None
    if (field.get("path") == CONFIG + ".maxclients" and field.get("metadataReason") == READ_ONLY
            and numeric_setting(field.get("before")) and field["before"] != "0"):
        return READ_ONLY
    if field.get("path") == ZONE and field.get("before") == "Automatic" and field.get("metadataReason") == AUTOMATIC:
        return AUTOMATIC
    return None


def omission_reason(resource_type, field, resource_id=None):
    if (not isinstance(resource_type, str) or resource_type.lower() != REDIS_TYPE or not has_redis_resource_id(resource_id)
            or not isinstance(field, dict) or field.get("metadataOnly") is not False or field.get("unresolved") is not False
            or field.get("changeType") != "Delete" or field.get("after") != MISSING
            or field.get("configurationOmission") != OMISSION):
        return None
    path = field.get("path", "")
    return OMISSION if path in {CONFIG + "." + key for key in MEMORY_KEYS} and numeric_setting(field.get("before")) else None


def comparison_setting(resource_type, field, resource_id=None):
    if omission_reason(resource_type, field, resource_id):
        return {"configurationOmission": OMISSION, "currentMemoryMB": field["before"]}
    return {}


def expansion_operation(resource_type, field, resource_id=None):
    if (not isinstance(resource_type, str) or resource_type.lower() != REDIS_TYPE or not has_redis_resource_id(resource_id)
            or not isinstance(field, dict) or field.get("configurationSource") != EXPANSION):
        return None
    path, operation, leaf = field.get("path"), field.get("configurationOperation"), field.get("changeType")
    if (not isinstance(path, str) or not path.startswith(CONFIG + ".")
            or not _KEY.fullmatch(path[len(CONFIG) + 1:])):
        return None
    return operation if (operation in {"Create", "Delete"} and leaf == operation
                         or operation == "Modify" and leaf in {"Create", "Modify", "Delete"}) else None


def comparison_omission(resource_type, field, resource_id=None):
    projected = {"path": field.get("path"), "changeType": field.get("action"), "before": field.get("currentMemoryMB"),
                 "after": MISSING, "configurationOmission": field.get("configurationOmission"), "metadataOnly": False,
                 "unresolved": False}
    return (field.get("classification") == "review-needed" and omission_reason(resource_type, projected, resource_id))
