"""Render already-sanitized ARM projections for people reviewing a release.

This module does not classify changes or alter the assessment outcome. The short
summary shows every proposed resource action; the companion detail report keeps
the field-level evidence. Background inventory is retained in plan.json only.
"""

from collections import Counter, defaultdict
import html
import json
import re


TYPE_LABELS = {
    "microsoft.alertsmanagement/prometheusrulegroups": "Prometheus rule group",
    "microsoft.authorization/roleassignments": "Role assignment",
    "microsoft.cache/redis": "Redis cache",
    "microsoft.containerregistry/registries": "Container registry",
    "microsoft.containerservice/managedclusters": "AKS cluster",
    "microsoft.dashboard/grafana": "Grafana instance",
    "microsoft.databasewatcher/watchers": "Database watcher",
    "microsoft.documentdb/databaseaccounts": "Cosmos DB account",
    "microsoft.insights/actiongroups": "Alert action group",
    "microsoft.insights/components": "Application Insights",
    "microsoft.insights/datacollectionrules": "Monitoring data collection rule",
    "microsoft.insights/metricalerts": "Metric alert",
    "microsoft.keyvault/vaults": "Key vault",
    "microsoft.kusto/clusters": "Data Explorer cluster",
    "microsoft.kusto/clusters/databases": "Data Explorer database",
    "microsoft.kusto/clusters/databases/principalassignments": "Data Explorer principal assignment",
    "microsoft.managedidentity/userassignedidentities": "Managed identity",
    "microsoft.managedidentity/userassignedidentities/federatedidentitycredentials": "Federated identity credential",
    "microsoft.network/loadbalancers": "Load balancer",
    "microsoft.network/networksecuritygroups": "Network security group",
    "microsoft.network/networksecuritygroups/securityrules": "Network security rule",
    "microsoft.network/privateendpoints": "Private endpoint",
    "microsoft.network/privatelinkservices": "Private Link service",
    "microsoft.network/routetables": "Route table",
    "microsoft.network/virtualnetworks": "Virtual network",
    "microsoft.network/virtualnetworks/subnets": "Subnet",
    "microsoft.operationalinsights/workspaces": "Log Analytics workspace",
    "microsoft.resources/deployments": "Nested deployment",
    "microsoft.resources/resourcegroups": "Resource group",
    "microsoft.search/searchservices": "Search service",
    "microsoft.search/searchservices/sharedprivatelinkresources": "Search private-link resource",
    "microsoft.servicenetworking/trafficcontrollers": "Application Gateway for Containers",
    "microsoft.servicenetworking/trafficcontrollers/associations": "Gateway association",
    "microsoft.servicenetworking/trafficcontrollers/frontends": "Gateway frontend",
    "microsoft.sql/servers": "SQL server",
    "microsoft.sql/servers/administrators": "SQL administrator",
    "microsoft.sql/servers/databases": "SQL database",
    "microsoft.sql/servers/elasticpools": "SQL elastic pool",
    "microsoft.sql/servers/jobagents": "SQL job agent",
    "microsoft.sql/servers/jobagents/jobs/steps": "SQL job step",
    "microsoft.sql/servers/jobagents/targetgroups": "SQL job target group",
    "microsoft.storage/storageaccounts": "Storage account",
}

_ACTIONS = {"Create", "Modify", "Delete"}
_WITHHELD = "[withheld]"
_MISSING = "[not present]"
_UNRESOLVED = "[unresolved expression]"
_GROUPS = {
    "agentpoolprofiles": "node pool settings", "autoscalerprofile": "cluster autoscaling",
    "addonprofiles": "cluster add-ons", "networkprofile": "cluster networking",
    "securityrules": "security rules", "subnets": "subnet settings",
    "virtualnetworkpeerings": "VNet peerings", "ipconfigurations": "IP configuration",
    "loadbalancerfrontendipconfigurations": "load balancer frontend",
    "members": "job targets", "datastore": "data store connections",
    "actions": "alert actions", "redisconfiguration": "Redis configuration",
    "encryption": "encryption settings", "encryptionwithcmk": "customer-managed encryption",
    "identityprofile": "identity settings", "aadprofile": "Azure AD settings",
    "apiserveraccessprofile": "API server access",
    "storageprofile": "cluster storage", "windowsprofile": "Windows settings",
    "servicemeshprofile": "service mesh settings", "metricsprofile": "cluster metrics",
    "serviceprincipalprofile": "service principal settings", "action": "job command",
    "workspaceresourceid": "Log Analytics workspace", "principalid": "principal identity",
    "issuer": "federation issuer", "retentionindays": "retention in days",
    "disablelocalauth": "local authentication setting", "kubernetesversion": "Kubernetes version",
    "perdatabasesettings": "per-database settings", "publicnetworkaccess": "public network access",
    "dataendpointenabled": "data endpoint setting", "ipversiontype": "IP version",
    "updatechannel": "update channel", "zonalallocationpolicy": "zone allocation policy",
    "creatorcanadmin": "creator administrator access", "grafanamajorversion": "Grafana major version",
    "maxsizebytes": "maximum size in bytes", "accessmode": "access mode",
}


def md(value):
    """Escape a projected value for Markdown, including Azure logging syntax."""
    text = json.dumps(value) if isinstance(value, (bool, int, float)) else str(value)
    text = re.sub(r"[\x00-\x1f\x7f]", " ", text)
    text = html.escape(text, quote=False)
    for char, replacement in (("\\", "&#92;"), ("#", "&#35;"), ("|", "&#124;"),
                              ("`", "&#96;"), ("[", "&#91;"), ("]", "&#93;"),
                              ("*", "&#42;"), ("_", "&#95;")):
        text = text.replace(char, replacement)
    return text


def type_label(azure_type):
    """Return a plain-text friendly label; callers escape it with md()."""
    value = str(azure_type or "unavailable")
    return TYPE_LABELS.get(value.lower(), value)


def resource_label(resource):
    """Return a short plain-text name with parent names for nested resources."""
    resource_id = str(resource.get("resourceId", ""))
    parts = resource_id.split("/")
    providers = [index for index, part in enumerate(parts) if part.lower() == "providers"]
    if providers:
        # Keep parent/child names from each provider segment, including the
        # target resource of an extension such as a scoped role assignment.
        names = []
        for index, provider in enumerate(providers):
            end = providers[index + 1] if index + 1 < len(providers) else len(parts)
            names.extend(parts[provider + 3:end:2])
        if str(resource.get("type", "")).lower() == "microsoft.authorization/roleassignments" and len(providers) == 1:
            groups = [index for index, part in enumerate(parts) if part.lower() == "resourcegroups"]
            if groups and len(parts) > groups[0] + 1:
                names.insert(0, parts[groups[0] + 1])
        if names and all(names):
            return " / ".join(names)
    return str(resource.get("name", "unavailable"))


def _resources(report):
    return [resource for component in report.get("components", [])
            for resource in component.get("resources", [])]


def _actionable(resource):
    return (resource.get("category") == "resource" and not resource.get("metadataOnly")
            and resource.get("changeType") in _ACTIONS)


def _runtime_fields(resource):
    return [field for field in resource.get("fields", [])
            if str(field.get("path", "")).lower() != "tags.createddate"]


def _words(value):
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", str(value))
    return value.replace("_", " ").replace("-", " ")


def _property_label(path):
    parts = [part for part in str(path).split(".") if part != "properties"]
    if not parts:
        return "resource properties"
    if parts[0] == "sku":
        return "SKU " + _words(" ".join(parts[1:]))
    first = re.sub(r"\[.*?\]", "", parts[0]).lower()
    return _GROUPS.get(first, _words(parts[0]))


def _unique(values):
    return list(dict.fromkeys(values))


def _brief(values, limit=3):
    values = _unique(values)
    return ", ".join(values[:limit]) + (f" and {len(values) - limit} other setting groups" if len(values) > limit else "")


def _change_summary(resource):
    action = resource.get("changeType")
    fields = _runtime_fields(resource)
    if action == "Create":
        locations = [field.get("after") for field in fields if field.get("path") == "location"]
        return "New resource proposed" + (f" in {locations[0]}" if locations and locations[0] not in (_WITHHELD, _UNRESOLVED, _MISSING) else "") + "."
    if action == "Delete":
        return "Resource deletion predicted by ARM."
    if not fields:
        return "ARM reports an update without property-level details."
    operations = defaultdict(list)
    comparisons = []
    for field in fields:
        operation = field.get("changeType", "Unknown")
        before, after = field.get("before"), field.get("after")
        label = _property_label(field.get("path", ""))
        public_before = before not in (_WITHHELD, _UNRESOLVED, _MISSING, None)
        public_after = after not in (_WITHHELD, _UNRESOLVED, _MISSING, None)
        if operation == "Modify" and public_before and public_after:
            comparisons.append(f"{label}: {json.dumps(before) if isinstance(before, bool) else before} → {json.dumps(after) if isinstance(after, bool) else after}")
        elif operation == "Create" and public_after:
            comparisons.append(f"Add property to proposed config: {label} = {json.dumps(after) if isinstance(after, bool) else after}")
        elif operation == "Delete" and public_before:
            operations[operation].append(f"{label} (current: {json.dumps(before) if isinstance(before, bool) else before})")
        else:
            operations[operation].append(label)
    summaries = []
    if comparisons:
        summaries.append(_brief(comparisons))
    phrases = {"Delete": "Remove property from proposed config", "Create": "Add property to proposed config",
               "Modify": "Change", "Array": "Change", "NoEffect": "Azure reports no effect for", "Unknown": "Unspecified property operation for"}
    for operation, labels in operations.items():
        suffix = " (values withheld)" if operation in {"Create", "Modify", "Array", "Unknown"} else ""
        summaries.append(f"{phrases.get(operation, phrases['Unknown'])}: {_brief(labels)}{suffix}")
    if any(field.get("unresolved") for field in fields):
        summaries.append("Some proposed values resolve only during deployment")
    return "; ".join(summaries) + "."


def _coverage_rows(report):
    rows = []
    for component in report.get("components", []):
        label = component.get("label", component.get("name", "Component"))
        groups = Counter()
        unresolved = defaultdict(list)
        for resource in component.get("resources", []):
            change_type = resource.get("changeType")
            kind = type_label(resource.get("type"))
            if change_type in {"Unsupported", "Deploy", "Unknown"}:
                groups[(change_type, kind)] += 1
            if resource.get("potential") and change_type != "Ignore":
                groups[("Potential", kind)] += 1
            if _actionable(resource):
                fields = _runtime_fields(resource)
                pending = [field for field in fields if field.get("unresolved")]
                if pending:
                    groups[("Deployment-time values", kind)] += 1
                    unresolved[kind].extend(_property_label(field.get("path", "")) for field in pending)
                elif change_type == "Modify" and not resource.get("fields"):
                    groups[("Missing property details", kind)] += 1
        reasons = {
            "Unsupported": "Azure did not preview these entries; inspect their Bicep configuration before promotion.",
            "Deploy": "Azure has not resolved its changes; inspect the proposed configuration before promotion.",
            "Unknown": "Azure supplied no recognised change classification; investigate before promotion.",
            "Potential": "Potential only; not a confirmed change. Check the dependency and refresh the preview.",
            "Missing property details": "ARM reported an update without its fields; inspect the Bicep configuration.",
        }
        for (reason, kind), count in groups.items():
            explanation = ("Unresolved " + _brief(unresolved[kind]) + "; verify resolved settings before promotion."
                           if reason == "Deployment-time values" else reasons[reason])
            rows.append((label, kind, count, reason + ": " + explanation))
        if component.get("status") in {"failed", "blocked"}:
            rows.append((label, "Component execution", 1,
                         f"{component['status']}: {component.get('errorCode') or 'PREVIEW_INCOMPLETE'}; fix the execution failure and rerun."))
        if component.get("diagnosticCount", 0):
            rows.append((label, "ARM diagnostics", component["diagnosticCount"],
                         "Azure returned diagnostics; investigate the incomplete component assessment."))
    return rows


def environment_markdown(report):
    """Render a compact decision view without dumping background inventory."""
    metadata = report.get("metadata", {})
    resources = _resources(report)
    actions = [resource for resource in resources if _actionable(resource)]
    counts = Counter(resource["changeType"] for resource in actions if not resource.get("potential"))
    potential = sum(bool(resource.get("potential")) for resource in actions)
    execution = "succeeded" if report.get("executionStatus") == "succeeded" else "failed or incomplete"
    coverage = "complete" if report.get("complete") else "INCOMPLETE — review the coverage gaps below"
    lines = [f"# Infrastructure preview: {md(metadata.get('environment', 'UNKNOWN'))}", "",
             f"**Preview execution: {execution}. Assessment: {coverage}.**", "",
             f"Candidate: `{md(metadata.get('commit', 'unavailable'))}` · Build: {md(metadata.get('buildId', 'unavailable'))}", "",
             f"Preview started: {md(metadata.get('generatedAt', 'unavailable'))}.", "",
             ("ARM predicts " if execution == "succeeded" else "Partial results contain ")
             + f"**{counts['Create']} creates, {counts['Modify']} updates and {counts['Delete']} resource deletions**."
             + (f" There are also {potential} potential action entries, labelled below." if potential else ""), "",
             "Read the resource actions first, then the coverage gaps. An update is a prediction, not proof of a runtime change: provider defaults and omitted properties can create differences. A removed property is not a resource deletion.", "",
             "## Predicted changes", ""]
    if counts["Delete"]:
        lines.extend(["**Resource deletions are predicted. Review every Delete entry before promotion.**", ""])
    if not actions:
        lines.extend(["No Create, Modify or Delete resource entries were returned. This does not resolve any coverage gaps below.", ""])
    for component in report.get("components", []):
        selected = [resource for resource in component.get("resources", []) if _actionable(resource)]
        if not selected:
            continue
        lines.extend([f"### {md(component.get('label', component.get('name', 'Component')))}", "",
                      "| Action | Resource | What ARM reported |", "|---|---|---|"])
        for resource in selected:
            action = {"Create": "Create", "Modify": "Update", "Delete": "Delete"}[resource["changeType"]]
            if resource.get("potential"):
                action = "Potential " + action.lower()
            description = _change_summary(resource)
            if resource.get("potential"):
                description = "Potential only; not a confirmed change. " + description
            identity = f"{type_label(resource.get('type'))}: {resource_label(resource)}"
            lines.append(f"| {md(action)} | {md(identity)} | {md(description)} |")
        lines.append("")
    lines.extend(["## Coverage gaps", ""])
    gaps = _coverage_rows(report)
    if gaps:
        lines.extend(["These are limitations of the prediction, not additional confirmed resource changes. Groups may overlap.", "",
                      "| Component | Resource type | Entries | Why / next step |", "|---|---|---:|---|"])
        lines.extend("| " + " | ".join(md(value) for value in row) + " |" for row in gaps)
        lines.append("")
    else:
        lines.extend(["No unsupported types, unresolved runtime fields or component execution gaps were returned.", ""])
    lines.extend(["## Background inventory", "",
                  f"- Ignore: {sum(resource.get('changeType') == 'Ignore' for resource in resources)} occurrences across component previews. Ignore means Azure did not assess these entries in this component preview. They may be outside its template or beyond an expansion limit; this does not establish no change.",
                  f"- Unchanged: {sum(resource.get('changeType') == 'NoChange' and resource.get('category') == 'resource' for resource in resources)} occurrences. CreatedDate-only updates: {sum(bool(resource.get('metadataOnly')) for resource in resources)}. Nested-deployment entries: {sum(resource.get('category') == 'deployment-metadata' for resource in resources)}.",
                  "- These are occurrence counts, not distinct resources at risk. Individual inventory entries remain in plan.json.", "",
                  "Artifact files: `change-details.md` contains property-level evidence and identifiers; `plan.json` retains every sanitised entry. Values withheld by the report cannot be recovered from either artifact.", "",
                  "This live ARM prediction does not cover hooks, peering pipeline execution, Library output writes, Entra memberships or scripted DNS changes. Refresh it before promotion; it is not a saved executable plan or a guarantee of deployment success.", ""])
    return "\n".join(lines)


def change_details_markdown(report):
    """Render actionable evidence and metadata without the Ignore inventory."""
    metadata = report.get("metadata", {})
    lines = [f"# Infrastructure change details: {md(metadata.get('environment', 'UNKNOWN'))}", "",
             f"Candidate: `{md(metadata.get('commit', 'unavailable'))}` · Source: `{md(metadata.get('sourceRef', 'unavailable'))}` · Build: {md(metadata.get('buildId', 'unavailable'))}", "",
             "ARM predictions can contain provider-default noise. Field removals describe the proposed configuration, not proof of a live reset. Potential-impact labels do not prove an outage, replacement or data loss. Ignore and ordinary NoChange inventory is retained only in plan.json.", ""]
    for component in report.get("components", []):
        lines.extend([f"## {md(component.get('label', component.get('name', 'Component')))}", "",
                      f"Execution: {md(component.get('status', 'unavailable'))}. Assessment: {'complete' if component.get('complete') else 'incomplete'}.", ""])
        if component.get("inputDigest"):
            lines.extend([f"Input fingerprint (SHA-256): `{md(component['inputDigest'])}`", ""])
        if component.get("errorCode"):
            lines.extend([f"Error category: {md(component['errorCode'])}.", ""])
        if component.get("diagnosticCount", 0):
            lines.extend([f"ARM diagnostics: {md(component['diagnosticCount'])}; raw messages are withheld.", ""])
        for resource in component.get("resources", []):
            if resource.get("changeType") == "Ignore" or (resource.get("changeType") == "NoChange" and not resource.get("potential")):
                continue
            action = resource.get("changeType", "Unknown")
            prefix = "Potential " if resource.get("potential") else ""
            metadata_note = " (metadata only)" if resource.get("metadataOnly") or resource.get("category") == "deployment-metadata" else ""
            lines.extend([f"### {md(prefix + action)}: {md(type_label(resource.get('type')))} — {md(resource_label(resource))}{metadata_note}", "",
                          f"Azure type: `{md(resource.get('type', 'unavailable'))}`", "",
                          f"Resource: {md(resource.get('resourceId', 'unavailable'))}", ""])
            if resource.get("potential"):
                lines.extend(["Potential only; not a confirmed change.", ""])
            if resource.get("potentialImpact"):
                lines.extend(["Potential impact: " + md(", ".join(resource["potentialImpact"])) + ".", ""])
            if resource.get("unresolved"):
                lines.extend(["Some aspects were not fully assessed; consult the summary coverage gaps.", ""])
            fields = resource.get("fields", [])
            if fields:
                lines.extend(["| Property | ARM operation | Current | Proposed |", "|---|---|---|---|"])
                for field in fields:
                    values = (field.get("path", "unavailable"), field.get("changeType", "Unknown"),
                              field.get("before", _MISSING), field.get("after", _MISSING))
                    lines.append("| " + " | ".join(md(value) for value in values) + " |")
                lines.append("")
            elif action == "Modify":
                lines.extend(["ARM did not supply property-level details for this update.", ""])
    lines.extend(["## Coverage and limitations", ""])
    lines.extend("- " + md(limitation) for limitation in report.get("limitations", []))
    return "\n".join(lines) + "\n"
