"""Exact, value-redacted evidence for harmless managed-identity omissions.

An opaque properties bag is never enough evidence. The raw report projection
first verifies and expands it; downstream consumers recheck these leaf facts
instead of trusting metadataOnly or an arbitrary artifact reason string.
"""

import re

IDENTITY_TYPE = "microsoft.managedidentity/userassignedidentities"
GENERATED_PATHS = {"properties.clientid", "properties.principalid", "properties.tenantid"}
MISSING = "[not present]"
WITHHELD = "[withheld]"
_UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}")
_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._()@:+ -]{0,255}")


def has_identity_resource_id(value):
    parts = value.split("/") if isinstance(value, str) and len(value) <= 2048 else []
    return (len(parts) == 9 and parts[0] == "" and parts[1].lower() == "subscriptions"
            and bool(_UUID.fullmatch(parts[2])) and parts[3].lower() == "resourcegroups"
            and bool(_SEGMENT.fullmatch(parts[4])) and parts[5].lower() == "providers"
            and parts[6].lower() == "microsoft.managedidentity"
            and parts[7].lower() == "userassignedidentities"
            and bool(_SEGMENT.fullmatch(parts[8])))


def identity_metadata_reason(resource_type, field):
    if (not isinstance(resource_type, str) or resource_type.lower() != IDENTITY_TYPE
            or not isinstance(field, dict) or field.get("changeType") != "Delete"
            or field.get("unresolved") is not False or field.get("after") != MISSING):
        return None
    path = field.get("path")
    if not isinstance(path, str):
        return None
    if path.lower() in GENERATED_PATHS and field.get("before") == WITHHELD:
        return "GENERATED_IDENTITY_PROPERTY"
    # None is the documented unrestricted default. Removing Regional remains a
    # real security change, as do explicit null, expressions and unknown values.
    if path.lower() == "properties.isolationscope" and field.get("before") == "None":
        return "UNCHANGED_IDENTITY_SCOPE_DEFAULT"
    return None


def is_metadata_field(resource_type, field):
    return (isinstance(field, dict)
            and (str(field.get("path", "")).lower() == "tags.createddate"
                 or identity_metadata_reason(resource_type, field) is not None))


def is_metadata_only(resource):
    if (not isinstance(resource, dict) or resource.get("changeType") != "Modify"
            or resource.get("potential") is True):
        return False
    fields = resource.get("fields")
    return (isinstance(fields, list) and bool(fields)
            and (not any(identity_metadata_reason(resource.get("type"), field) for field in fields)
                 or has_identity_resource_id(resource.get("resourceId")))
            and all(is_metadata_field(resource.get("type"), field) for field in fields))
