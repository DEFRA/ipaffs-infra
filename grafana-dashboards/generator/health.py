#!/usr/bin/env python3
"""Generates IPAFFSServiceHealth.json (proposal dashboard 1: Service Health, layer 1)."""
from lib import *  # noqa: F401,F403

# User journeys, told apart by frontend and route. Order is the tile order.
JOURNEYS = [
    ("Create & submit CHED", "notification-frontend"),
    ("Clone CHED", "notification-frontend"),
    ("Search & dashboards", "notification-frontend"),
    ("Document upload", "upload-frontend"),
    ("Border checks & decision", "decision-frontend"),
    ("Control (OV)", "control-frontend"),
    ("FSA checks", "checks-frontend"),
    ("Border notifications", "bordernotification-frontend"),
    ("BCP admin", "bcpadmin-frontend"),
]
JOURNEY_TABLE = "datatable(Journey: string, Service: string, Order: int) [\n" + ",\n".join(
    f'    "{j}", "{s}", {i}' for i, (j, s) in enumerate(JOURNEYS)) + "\n]"

JOURNEY_REQUESTS = ai("requests", f'''| where cloud_RoleName endswith "-frontend"
| where name != "GET /admin/health-check" and name !startswith "GET /public/" and name !contains "/assets/"
| extend role = {ROLE}, path = tostring(split(name, " ")[1])
| extend Journey = case(
    role == "notification-frontend" and path contains "/cloning", "Clone CHED",
    role == "notification-frontend" and path matches regex @"^/protected/notifications/?$", "Search & dashboards",
    role == "decision-frontend" and path matches regex @"^/protected/bip-notifications/?$", "Search & dashboards",
    role == "control-frontend" and path matches regex @"^/protected/ov-notifications/?$", "Search & dashboards",
    role == "notification-frontend", "Create & submit CHED",
    role == "upload-frontend", "Document upload",
    role == "decision-frontend", "Border checks & decision",
    role == "control-frontend", "Control (OV)",
    role == "checks-frontend", "FSA checks",
    role == "bordernotification-frontend", "Border notifications",
    role == "bcpadmin-frontend", "BCP admin",
    "")
| where Journey != ""
| extend bad = toint(resultCode) >= 500
''')

# Every journey gets a row, so a journey with no traffic shows as such rather than vanishing.
JOURNEY_SUMMARY = (
    f"let j = {JOURNEY_REQUESTS.rstrip()}\n"
    "| summarize Requests = count(), Failed = countif(bad), p95 = percentile(duration, 95) by Journey;\n"
    f"{JOURNEY_TABLE}\n"
    "| join kind=leftouter j on Journey\n"
    "| extend ['Success %'] = iff(Requests > 0, 100.0 * (Requests - Failed) / Requests, real(null)), ['p95 ms'] = round(p95)\n"
    "| order by Order asc\n"
    "| project Journey, Service, Requests, ['Success %'], ['p95 ms']\n")

# Key transactions with an availability SLO over the calendar month: the share of
# attempts that did not get a 5xx. Budget left is how much of the allowed 0.5% is unused.
SLO_TARGET = 99.5
SLOS = [
    ("Submit CHED", "notification-frontend", r"^POST /protected/notifications/[^/]+/declaration$"),
    ("Record decision", "decision-frontend", r"^POST /protected/bip-notifications/[^/]+/review$"),
    ("Upload document", "upload-frontend", r"^POST /protected/upload/.+/attach$"),
]
SLO_QUERY = (
    "let target = " + str(SLO_TARGET / 100) + ";\n"
    "datatable(SLO: string, Service: string, Order: int) [\n" + ",\n".join(
        f'    "{n}", "{s}", {i}' for i, (n, s, _) in enumerate(SLOS)) + "\n]\n"
    "| join kind=leftouter (\n"
    "    requests\n"
    "    | where timestamp >= startofmonth(now())\n"
    '    | where cloud_RoleName endswith "-frontend"\n'
    '    ' + NS.strip() + "\n"
    "    | extend SLO = case(\n" + ",\n".join(
        f'        name matches regex @"{r}", "{n}"' for n, _, r in SLOS) + ',\n        "")\n'
    '    | where SLO != ""\n'
    "    | summarize Requests = count(), Failed = countif(toint(resultCode) >= 500) by SLO\n"
    ") on SLO\n"
    "| extend ['Budget left %'] = iff(Requests > 0, round(100.0 * (1 - (todouble(Failed) / Requests) / (1 - target)), 1), real(null)),\n"
    "    ['Success %'] = iff(Requests > 0, round(100.0 * (Requests - Failed) / Requests, 3), real(null))\n"
    "| order by Order asc\n"
    "| project SLO, Service, Requests, Failed, ['Success %'], ['Budget left %']\n")


def drilldown_link(field="Service"):
    return {"title": "Open ${__data.fields.%s} in Service Drill-down" % field,
            "url": "/d/ipaffs-service-drilldown?var-namespace=${namespace}&var-service=${__data.fields.%s}&${__url_time_range}" % field}


MESSAGING_LINK = {"title": "Open Messaging & Integrations",
                  "url": "/d/ipaffs-messaging-integrations?var-namespace=${namespace}&${__url_time_range}"}
PLATFORM_LINK = {"title": "Open Platform Overview", "url": "/d/ipaffs-aks-ops-v1?${__url_time_range}"}


def tiles(title, query, field, unit, steps, link, name_field, desc=None, decimals=None, no_value="No traffic"):
    """One coloured tile per table row, named after name_field and showing field.

    The query is cut down to the name, the service (for the link) and the one value,
    because Grafana matches field selectors against the display name, which here
    is the row's name rather than the column's.
    """
    keep = [name_field] + (["Service"] if "__data.fields.Service" in link["url"] else []) + [f"['{field}']"]
    p = stat(title, [kql(query + "| project " + ", ".join(keep) + "\n", "table")], unit=unit, thresholds=steps,
             decimals=decimals, desc=desc, colorMode="background", textMode="value_and_name", justifyMode="center",
             wideLayout=True, orientation="auto", text={"titleSize": 13, "valueSize": 26},
             reduceOptions={"calcs": ["lastNotNull"], "fields": "", "values": True})
    d = p["fieldConfig"]["defaults"]
    d["displayName"] = "${__data.fields.%s}" % name_field
    d["noValue"] = no_value
    d["links"] = [link]
    # Rows with no traffic come back null: grey, not the red of the lowest threshold.
    d["mappings"] = [{"type": "special", "options": {"match": "null", "result": {"text": no_value, "color": "#6e7079", "index": 0}}}]
    return p


def single(title, targets, link, steps, ds=AZ, **kw):
    p = stat(title, targets, ds=ds, thresholds=steps, colorMode="background", text={"titleSize": 13, "valueSize": 26}, **kw)
    p["fieldConfig"]["defaults"]["links"] = [link]
    return p


SUCCESS_STEPS = [{"color": RED, "value": None}, {"color": AMBER, "value": 98}, {"color": GREEN, "value": 99.5}]
LATENCY_STEPS = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1000}, {"color": RED, "value": 3000}]
BUDGET_STEPS = [{"color": RED, "value": None}, {"color": AMBER, "value": 25}, {"color": GREEN, "value": 50}]
ZERO_GOOD = [{"color": GREEN, "value": None}, {"color": RED, "value": 1}]
ZERO_GOOD_AMBER = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 100}]
FAIL_STEPS = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}]

WEBAPP = f'namespace="$namespace", container="webapp", pod=~"^.+{DEPLOYMENT_POD}"'

# ── User journeys ───────────────────────────────────────────────────────────
row("User journeys in $namespace")
grid(
    (0, 0, 16, 5, tiles("Success rate (no 5xx)", JOURNEY_SUMMARY, "Success %", "percent", SUCCESS_STEPS, drilldown_link(),
                        "Journey", decimals=2,
                        desc="Share of frontend requests in each journey that did not fail with a 5xx. Click a tile for the frontend's drill-down.")),
    (0, 5, 16, 5, tiles("Latency p95", JOURNEY_SUMMARY, "p95 ms", "ms", LATENCY_STEPS, drilldown_link(), "Journey",
                        desc="95th percentile response time of the frontend pages in each journey.")),
    (16, 0, 8, 10, tiles(f"Error budget left this month ({SLO_TARGET}% SLO)", SLO_QUERY, "Budget left %", "percent", BUDGET_STEPS,
                         drilldown_link(), "SLO", decimals=1, no_value="No attempts this month",
                         desc=f"Availability SLO of {SLO_TARGET}% per calendar month for the three key transactions: "
                              "submit CHED (declaration), record decision (review) and upload document (attach). "
                              "100% means no 5xx yet this month; 0% means the month's allowance is used up. Ignores the time picker.")),
)

# ── Integrations ─────────────────────────────────────────────────────────────
CLASSIC = ("$classicSubscription", "$classicResourceGroup", "$classicServiceBus")
row("Integrations")
line(
    (5, single("Waiting on shared Service Bus", [azmetric("ActiveMessages", *CLASSIC, "Maximum", by_entity=False)], MESSAGING_LINK,
               [{"color": GREEN, "value": None}, {"color": AMBER, "value": 100}, {"color": RED, "value": 1000}], decimals=0,
               desc="Messages waiting across the classic namespace, which every namespace in the environment shares.")),
    (5, single("New dead letters", [azmetric("DeadletteredMessages", *CLASSIC, "Maximum", by_entity=False)], MESSAGING_LINK,
               ZERO_GOOD_AMBER, decimals=0, reduceOptions={"calcs": ["diff"], "fields": "", "values": False},
               desc="Change in dead-lettered messages over the selected range, shared namespace.")),
    (5, single("Risk engine fallback", [kql(RISK_FALLBACK_PCT, "table")], MESSAGING_LINK,
               [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 10}], unit="percent", decimals=1,
               desc="Risk assessments that got the default decision because the risk engine call failed.")),
    (5, single("Integration jobs failing", [kql(JOB_REQUESTS + "| summarize arg_max(timestamp, success) by name\n"
                                                "| summarize v = countif(success == false)\n", "table")], MESSAGING_LINK,
               ZERO_GOOD, decimals=0, desc="Scheduled jobs (reference data sync, MDM download, archiving) whose last run in range failed.")),
    (4, single("Service Bus errors", [azmetric("ServerErrors", *CLASSIC, "Total", by_entity=False)], MESSAGING_LINK,
               ZERO_GOOD_AMBER, decimals=0, reduceOptions={"calcs": ["sum"], "fields": "", "values": False})),
    h=4,
)
line(
    (24, tiles("Partner call failures", PARTNERS +
               "| summarize ['Fail %'] = round(100.0 * countif(failed) / count(), 2), Calls = count() by Partner = partner\n"
               "| order by Partner asc\n",
               "Fail %", "percent", FAIL_STEPS, MESSAGING_LINK, "Partner", decimals=1, no_value="No partner calls",
               desc="Failed outbound calls from this namespace to each external partner. Blob 404s are not counted.")),
    h=4,
)

# ── Platform ─────────────────────────────────────────────────────────────────
row("Platform")
line(
    (5, single("Nodes not ready", [promql('count(kube_node_info) - (sum(kube_node_status_condition{condition="Ready", status="true"}) or vector(0))', instant=True)],
               PLATFORM_LINK, ZERO_GOOD, ds=PROM, decimals=0, desc="Cluster nodes not in the Ready state.")),
    (5, single("Node pressure", [promql('sum(kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"}) or vector(0)', instant=True)],
               PLATFORM_LINK, ZERO_GOOD, ds=PROM, decimals=0, desc="Memory, disk or PID pressure conditions across nodes.")),
    (5, single("Deployments short of replicas", [promql(
        'count(max by (deployment) (kube_deployment_spec_replicas{namespace="$namespace"}) > '
        'max by (deployment) (kube_deployment_status_replicas_available{namespace="$namespace"})) or vector(0)', instant=True)],
        PLATFORM_LINK, ZERO_GOOD, ds=PROM, decimals=0, desc="Deployments in this namespace with fewer available pods than desired.")),
    (5, single("Container restarts", [promql(f'sum(increase(kube_pod_container_status_restarts_total{{{WEBAPP}}}[$__range])) or vector(0)', instant=True)],
               PLATFORM_LINK, [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}], ds=PROM, decimals=0,
               desc="Application container restarts in this namespace over the selected range.")),
    (4, single("OOMKilled", [promql(f'count(kube_pod_container_status_last_terminated_reason{{{WEBAPP}, reason="OOMKilled"}}) or vector(0)', instant=True)],
               PLATFORM_LINK, ZERO_GOOD, ds=PROM, decimals=0, desc="Running pods whose application container was last killed for running out of memory.")),
    h=4,
)

# ── Trend ────────────────────────────────────────────────────────────────────
row("Trend")
line(
    (12, ts("Journey error rate (5xx %)",
            [kql(JOURNEY_REQUESTS + "| summarize v = 100.0 * countif(bad) / count() by Journey, bin(timestamp, $__interval)\n| order by timestamp asc\n")],
            unit="percent", desc="Purple markers are pod starts (deploys and reschedules).",
            defaults={"custom": {"lineWidth": 1, "fillOpacity": 0, "showPoints": "never", "spanNulls": True}, "min": 0})),
    (12, ts("Journey traffic",
            [kql(JOURNEY_REQUESTS + "| summarize n = count() by Journey, bin(timestamp, $__interval)\n| order by timestamp asc\n")],
            unit="short", stack=True, desc="Frontend requests per bin, by journey.")),
)

emit(
    "ipaffs-service-health", "IPAFFS Service Health",
    "Is IPAFFS OK? User journeys, SLO error budgets, integrations and platform for one namespace. Every tile links to the layer 2 dashboard that explains it.",
    ["ipaffs", "layer-1"],
    BASE_VARIABLES + [
        NAMESPACE_VARIABLE,
        var_const("classicSubscription", "Classic subscription"),
        var_const("classicResourceGroup", "Classic resource group"),
        var_const("classicServiceBus", "Classic Service Bus namespace"),
    ],
    annotations=[
        {"name": "Pod starts (deploys)", "enable": True, "iconColor": "purple", "datasource": PROM,
         "expr": (f'max by (pod, image) (kube_pod_created{{namespace="$namespace"}} * on (namespace, pod) group_left (image) '
                  f'max by (namespace, pod, image) (kube_pod_container_info{{{WEBAPP}}})) * 1000'),
         "useValueForTime": True, "step": "1m", "titleFormat": "Pod started", "textFormat": "{{image}}"},
    ],
    refresh="5m",
)
