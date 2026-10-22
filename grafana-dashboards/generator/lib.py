"""Shared building blocks for the IPAFFS Grafana dashboard generators."""
import json
import sys

AZ = {"type": "grafana-azure-monitor-datasource", "uid": "azure-monitor-oob"}
PROM = {"type": "prometheus", "uid": "${datasource}"}
AI_RES = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/$appInsights"

panels = []
_id = 0
_y = 0


def _next_id():
    global _id
    _id += 1
    return _id


def row(title):
    global _y
    panels.append({"type": "row", "title": title, "id": _next_id(), "collapsed": False,
                   "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y}, "panels": []})
    _y += 1


def line(*specs, h=8):
    """Lays out panels left to right on one grid line; each spec is (width, panel)."""
    global _y
    x = 0
    for w, p in specs:
        p["id"] = _next_id()
        p["gridPos"] = {"h": h, "w": w, "x": x, "y": _y}
        panels.append(p)
        x += w
    assert x <= 24, x
    _y += h


def kql(query, fmt="time_series", ref="A"):
    return {"refId": ref, "datasource": AZ, "queryType": "Azure Log Analytics",
            "azureLogAnalytics": {"query": query, "resources": [AI_RES], "resultFormat": fmt,
                                  "dashboardTime": False}}


def promql(expr, legend="__auto", ref="A", instant=False):
    t = {"refId": ref, "datasource": PROM, "expr": expr, "legendFormat": legend, "range": not instant}
    if instant:
        t["instant"] = True
        t["format"] = "table"
    return t


def panel(kind, title, targets, unit=None, desc=None, ds=AZ, overrides=None, **opts):
    p = {"type": kind, "title": title, "datasource": ds, "targets": targets,
         "fieldConfig": {"defaults": {}, "overrides": overrides or []}, "options": {}}
    if unit:
        p["fieldConfig"]["defaults"]["unit"] = unit
    if desc:
        p["description"] = desc
    for k, v in opts.items():
        if k == "defaults":
            p["fieldConfig"]["defaults"].update(v)
        elif k == "noValue":
            p["fieldConfig"]["defaults"]["noValue"] = v
        else:
            p["options"][k] = v
    return p


def ts(title, targets, unit=None, desc=None, ds=AZ, stack=False, bars=False, overrides=None, **opts):
    custom = {"lineWidth": 1, "fillOpacity": 10, "showPoints": "never", "spanNulls": False}
    if stack:
        custom["stacking"] = {"mode": "normal", "group": "A"}
    if bars:
        custom.update({"drawStyle": "bars", "fillOpacity": 80})
    opts.setdefault("legend", {"displayMode": "list", "placement": "bottom", "showLegend": True})
    opts.setdefault("tooltip", {"mode": "multi", "sort": "desc"})
    defaults = {"custom": custom, **opts.pop("defaults", {})}
    return panel("timeseries", title, targets, unit, desc, ds, overrides, defaults=defaults, **opts)


def stat(title, targets, unit=None, desc=None, ds=AZ, thresholds=None, decimals=None, **opts):
    d = {"color": {"mode": "thresholds"}}
    d["thresholds"] = {"mode": "absolute", "steps": thresholds or [{"color": "text", "value": None}]}
    if decimals is not None:
        d["decimals"] = decimals
    opts.setdefault("reduceOptions", {"calcs": ["lastNotNull"], "fields": "", "values": False})
    opts.setdefault("colorMode", "value")
    opts.setdefault("graphMode", "none")
    opts.setdefault("textMode", "auto")
    return panel("stat", title, targets, unit, desc, ds, defaults=d, **opts)


def table(title, targets, desc=None, ds=AZ, overrides=None, sort=None, **opts):
    opts.setdefault("showHeader", True)
    opts.setdefault("cellHeight", "sm")
    if sort:
        opts["sortBy"] = [{"displayName": sort, "desc": True}]
    return panel("table", title, targets, None, desc, ds, overrides, defaults={"custom": {"align": "auto"}}, **opts)


def col(name, **props):
    return {"matcher": {"id": "byName", "options": name},
            "properties": [{"id": k.replace("_", "."), "value": v} for k, v in props.items()]}


GREEN, AMBER, RED = "green", "orange", "red"



def grid(*specs):
    """Places panels of mixed heights; each spec is (x, dy, w, h, panel) relative to the current line."""
    global _y
    bottom = 0
    for x, dy, w, h, p in specs:
        p["id"] = _next_id()
        p["gridPos"] = {"h": h, "w": w, "x": x, "y": _y + dy}
        panels.append(p)
        bottom = max(bottom, dy + h)
    _y += bottom


# ── App Insights scoped to the selected namespace ───────────────────────────
NS = '| where tostring(customDimensions["k8s.namespace.name"]) == "$namespace"\n'


def ai(table, extra=""):
    return f"{table}\n| where $__timeFilter(timestamp)\n" + NS + extra


ROLE = 'replace_regex(cloud_RoleName, @"^.*[.]", "")'

# Outbound calls grouped by partner. Gateway hosts differ per environment, so
# trade APIs are told apart by path. Service Bus, SQL, Redis and internal
# service-to-service calls are left out.
PARTNERS = ai("dependencies", '''| where type !in ("InProc", "SQL", "redis") and type !has "ServiceBus"
| extend partner = case(
    target contains "dynamics.com" or name contains "/trade-crm-adapter/", "Dynamics CRM",
    name contains "/trade-risk-assessment/" or name contains "/commodity-risk-categorisation-decider/", "Risk engine",
    name contains "/trade-notify/", "Notify (trade-notify)",
    name contains "/trade-delegated-authority/", "Delegated authority",
    name contains "/mdm/", "MDM",
    name contains "/graphql/", "Approved establishments (GraphQL)",
    name contains "/address-lookup", "Address lookup",
    name contains "/trade-imports-cloning/", "Trade imports cloning",
    target matches regex @"^ref(-[a-z]+)?[.]azure[.]defra[.]cloud", "Reference data (RDS)",
    target contains "search.windows.net", "Azure AI Search",
    type == "Azure blob", "Blob storage",
    target contains "antivirus", "Antivirus",
    target contains "login.microsoftonline.com" or target contains "b2clogin.com", "Entra ID / B2C",
    target contains "gateway", "Trade API gateway (other)",
    "")
| where partner != ""
| extend failed = success == false and not(type == "Azure blob" and resultCode == "404")
''')

JOB_REQUESTS = ai("requests",
                  '| where not(name matches regex "^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)( |$)") and name !contains "cache"\n')
RISK = '| where name in ("risk-assessment-risk-engine-fallback-count", "risk-assessment-risk-engine-success-count")\n'
RISK_FALLBACK_PCT = ai("customMetrics", RISK + '| summarize v = 100.0 * sumif(valueSum, name endswith "fallback-count") / sum(valueSum)\n')


# Pods created by a Deployment ("<name>-<rs hash>-<suffix>"); see POD in drilldown.py.
DEPLOYMENT_POD = '-[bcdfghjklmnpqrstvwxz2-9]{6,10}-[bcdfghjklmnpqrstvwxz2-9]{5}$'


def azmetric(metric, sub, rg, name, agg, alias="{{dimensionvalue}}", entity="*", top=10, ref="A", by_entity=True):
    """Azure Monitor Service Bus metric, optionally split by EntityName (queue or topic)."""
    dims = [{"dimension": "EntityName", "operator": "eq", "filters": [entity]}] if by_entity else []
    return {"refId": ref, "datasource": AZ, "queryType": "Azure Monitor", "subscription": sub,
            "azureMonitor": {"metricName": metric, "metricNamespace": "Microsoft.ServiceBus/namespaces",
                             "aggregation": agg, "timeGrain": "auto", "top": str(top), "alias": alias,
                             "dimensionFilters": dims, "allowedTimeGrainsMs": [],
                             "resources": [{"subscription": sub, "resourceGroup": rg, "resourceName": name,
                                            "metricNamespace": "Microsoft.ServiceBus/namespaces"}]}}


def bargauge(title, targets, unit=None, desc=None, ds=AZ, thresholds=None, calc="lastNotNull", **opts):
    d = {"color": {"mode": "thresholds"}, "min": 0,
         "thresholds": {"mode": "absolute", "steps": thresholds or [{"color": "green", "value": None}]}}
    opts.setdefault("reduceOptions", {"calcs": [calc], "fields": "", "values": False})
    opts.setdefault("orientation", "horizontal")
    opts.setdefault("displayMode", "basic")
    opts.setdefault("showUnfilled", True)
    opts.setdefault("valueMode", "color")
    opts.setdefault("namePlacement", "left")
    opts.setdefault("sizing", "manual")
    opts.setdefault("minVizHeight", 14)
    opts.setdefault("maxVizHeight", 18)
    return panel("bargauge", title, targets, unit, desc, ds, defaults=d, **opts)


def var_az(name, query_type, regex="", **q):
    return {"name": name, "type": "query", "hide": 2, "datasource": AZ, "refresh": 1, "regex": regex,
            "query": {"queryType": query_type, "refId": "A", "azureLogAnalytics": {"query": "", "resources": []}, **q},
            "definition": "", "includeAll": False, "multi": False, "options": [], "sort": 0}


def var_prom(name, query, hide=0, regex="", label=None, current=None, sort=1):
    v = {"name": name, "type": "query", "hide": hide, "datasource": PROM, "refresh": 2, "regex": regex,
         "query": {"qryType": 1, "query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
         "definition": query, "includeAll": False, "multi": False, "options": [], "sort": sort}
    if label:
        v["label"] = label
    if current:
        v["current"] = {"selected": True, "text": current, "value": current}
    return v


def var_const(name, label):
    """Filled in per environment by deploy-dashboards.sh from the ADO variable group."""
    return {"name": name, "type": "constant", "hide": 2, "label": label, "query": "", "skipUrlSync": True,
            "current": {"selected": True, "text": "", "value": ""}, "options": []}


# Prometheus datasource, then subscription -> resource group -> App Insights,
# resolved the same way as IPAFFS Application Overview.
BASE_VARIABLES = [
    {"name": "datasource", "type": "datasource", "query": "prometheus", "hide": 2, "refresh": 1, "regex": "",
     "current": {"selected": True, "text": "Prometheus", "value": "bfq876mzxyfi8b"}, "options": []},
    var_prom("subscription_id", "label_values(kube_pod_container_info, microsoft.subscriptionid)", hide=2, sort=0),
    var_az("subscription", "Azure Subscriptions", "/.*$subscription_id.*/"),
    var_az("resourceGroup", "Azure Resource Groups", "/.*IMPINFRG1401.*/i", subscription="$subscription"),
    var_az("appInsights", "Azure Resource Names", "", subscription="$subscription", resourceGroup="$resourceGroup",
           namespace="microsoft.insights/components"),
]

NAMESPACE_VARIABLE = var_prom("namespace", 'label_values(kube_pod_container_info{image=~".+/ipaffs/.+"}, namespace)',
                              label="Namespace", current="dev")

# Every IPAFFS dashboard, layer 1 first. Each dashboard links to all the others,
# carrying the namespace and time range across.
DASHBOARDS = [
    ("ipaffs-service-health", "Service Health"),
    ("ipaffs-service-drilldown", "Service Drill-down"),
    ("ipaffs-messaging-integrations", "Messaging & Integrations"),
    ("app-overview", "Application Overview"),
    ("ipaffs-aks-ops-v1", "Platform Overview"),
    ("dfsw5zhr4pjpce", "Service Overview"),
    ("ipaffs-qa-overview", "QA Overview"),
]


def links_except(uid):
    return [{"title": title, "type": "link", "url": f"/d/{u}?var-namespace=$namespace", "keepTime": True,
             "icon": "dashboard", "targetBlank": False}
            for u, title in DASHBOARDS if u != uid]

BUILTIN_ANNOTATION = {"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True,
                      "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"}


def emit(uid, title, description, tags, templating, annotations=(), refresh=""):
    json.dump({
        "id": None, "uid": uid, "title": title, "description": description, "tags": tags,
        "editable": True, "graphTooltip": 1, "refresh": refresh, "schemaVersion": 41,
        "time": {"from": "now-6h", "to": "now"}, "timepicker": {}, "timezone": "browser",
        "annotations": {"list": [BUILTIN_ANNOTATION, *annotations]},
        "templating": {"list": templating}, "links": links_except(uid), "panels": panels,
    }, sys.stdout, indent=2)
    print()
