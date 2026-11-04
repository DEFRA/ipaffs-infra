"""Recheck the narrowly evidenced background fields in sanitized reports."""

from infrastructure_plan_identity import (
    has_identity_resource_id, identity_metadata_reason,
    is_metadata_field as is_identity_metadata_field,
)
from infrastructure_plan_aks import aks_metadata_reason, has_aks_resource_id


def metadata_reason(resource_type, field):
    return identity_metadata_reason(resource_type, field) or aks_metadata_reason(resource_type, field)


def is_metadata_field(resource_type, field):
    return is_identity_metadata_field(resource_type, field) or bool(aks_metadata_reason(resource_type, field))


def is_metadata_only(resource):
    if (not isinstance(resource, dict) or resource.get("changeType") != "Modify"
            or resource.get("potential") is True):
        return False
    fields = resource.get("fields")
    if not isinstance(fields, list) or not fields:
        return False
    if (any(identity_metadata_reason(resource.get("type"), field) for field in fields)
            and not has_identity_resource_id(resource.get("resourceId"))):
        return False
    if (any(aks_metadata_reason(resource.get("type"), field) for field in fields)
            and not has_aks_resource_id(resource.get("resourceId"))):
        return False
    return all(is_metadata_field(resource.get("type"), field) for field in fields)
