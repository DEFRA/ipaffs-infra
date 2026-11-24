"""Identify the parent VNet peering list that ARM returns for separately managed children."""

import json
import re


_TYPE = "microsoft.network/virtualnetworks"
_PROPERTY = "virtualNetworkPeerings"
_PATH = "properties." + _PROPERTY
_REASON = "OMITTED_VNET_PEERING_COLLECTION"
_VNET_ID = re.compile(
    r"/subscriptions/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
    r"/resourceGroups/[\w.()-]+/providers/Microsoft\.Network/virtualNetworks/[\w.-]+", re.I)


def template_omits_vnet_peerings(template):
    """Prove omission on the network template's one same-scope vnetParams VNet.

    ARM what-if normalizes explicit null and [] to the same Delete as omission.
    Only recognize the compiled module binding we can trace to the network input.
    """
    pending = [(template, True)]
    found = False
    while pending:
        current, inherits_vnet = pending.pop()
        resources = current.get("resources") if isinstance(current, dict) else None
        if not isinstance(resources, (list, dict)):
            return False
        for resource in resources.values() if isinstance(resources, dict) else resources:
            if not isinstance(resource, dict) or "resources" in resource:
                return False
            kind = resource.get("type")
            if not isinstance(kind, str) or kind.startswith("["):
                return False
            props = resource.get("properties")
            same_scope = not any(key in resource for key in ("scope", "resourceGroup", "subscriptionId"))
            if kind.lower() == "microsoft.resources/deployments":
                if not isinstance(props, dict) or "templateLink" in props:
                    return False
                bindings = props.get("parameters")
                forwarded = isinstance(bindings, dict) and bindings.get("vnetParams") == {"value": "[parameters('vnetParams')]"}
                pending.append((props.get("template"), inherits_vnet and same_scope and forwarded))
            elif kind.lower() == "microsoft.network/virtualnetworks":
                if (found or not inherits_vnet or not same_scope or "copy" in resource
                        or resource.get("name") != "[parameters('vnetParams').name]" or not isinstance(props, dict)):
                    return False
                # A property loop materializes the key named by its 'name'.
                if any(key.lower() == "copy" and key != "copy" for key in props):
                    return False
                loops = props.get("copy", [])
                if not isinstance(loops, list) or not all(isinstance(loop, dict) for loop in loops):
                    return False
                keys = [*props, *(loop.get("name") for loop in loops)]
                if any(not isinstance(key, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key)
                       or key.lower() == "virtualnetworkpeerings" for key in keys):
                    return False
                found = True
    return found


def _other_vnet_configuration(snapshot):
    config = dict(snapshot)
    config["properties"] = {k: v for k, v in snapshot["properties"].items() if k != _PROPERTY}
    if isinstance(config.get("tags"), dict):
        config["tags"] = {k: v for k, v in config["tags"].items() if k != "CreatedDate"}
    return json.dumps(config, sort_keys=True)


def annotate_vnet_peering_omission(change, fields, template_vnet_id):
    # ARM also drops explicit [] and null from its proposed snapshot. The runner
    # only supplies this ID when the compiled template omits the collection.
    rid = change.get("resourceId")
    if (not isinstance(template_vnet_id, str) or not _VNET_ID.fullmatch(template_vnet_id)
            or not isinstance(rid, str) or rid.lower() != template_vnet_id.lower()
            or change.get("changeType") != "Modify"):
        return
    snapshots = (change.get("before"), change.get("after"))
    for snapshot in snapshots:
        if (not isinstance(snapshot, dict) or str(snapshot.get("type")).lower() != _TYPE
                or str(snapshot.get("id", rid)).lower() != rid.lower()
                or not isinstance(snapshot.get("properties"), dict)):
            return
    current, proposed = (snapshot["properties"] for snapshot in snapshots)
    peers = current.get(_PROPERTY)
    if (not isinstance(peers, list) or not peers
            or not all(isinstance(peer, dict) and isinstance(peer.get("name"), str) and peer["name"]
                       for peer in peers)
            or any(key.lower() == _PROPERTY.lower() for key in proposed)):
        return
    # Match the whole collection only. Indexed and nested changes stay visible.
    matches = [field for field in fields if field["path"].lower() == _PATH.lower()]
    if len(matches) != 1 or matches[0]["path"] != _PATH or matches[0]["unresolved"]:
        return
    # If this is the last reviewable field, an incomplete delta must not hide
    # a different VNet setting that changed between the full ARM snapshots.
    if (all(field is matches[0] or field["metadataOnly"] or field["changeType"] == "NoEffect" for field in fields)
            and _other_vnet_configuration(change["before"]) != _other_vnet_configuration(change["after"])):
        return
    for delta in change["delta"]:
        if (isinstance(delta, dict) and delta.get("path") == _PATH
                and delta.get("propertyChangeType") == "Delete" and delta.get("before") == peers
                and delta.get("after") is None and delta.get("children") in (None, [])
                and delta.get("childDelta") in (None, [])):
            matches[0].update(after="[not present]", metadataOnly=True, metadataReason=_REASON)


def vnet_peering_reason(resource_type, field, resource_id):
    if (isinstance(field, dict) and field.get("metadataReason") == _REASON
            and isinstance(resource_id, str) and _VNET_ID.fullmatch(resource_id)
            and isinstance(resource_type, str) and resource_type.lower() == _TYPE
            and field.get("path") == _PATH and field.get("changeType") == "Delete"
            and field.get("metadataOnly") is True and field.get("unresolved") is False
            and field.get("before") == "[withheld]" and field.get("after") == "[not present]"):
        return _REASON
    return None
