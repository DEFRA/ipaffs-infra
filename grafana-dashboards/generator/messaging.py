#!/usr/bin/env python3
"""Generates IPAFFSMessagingIntegrations.json (proposal dashboard 3: Messaging & Integrations)."""
from lib import *  # noqa: F401,F403

# The classic namespace is shared by every namespace in an environment; the AKS
# one ("<env>impinfsb1401-<namespace>") belongs to the selected namespace.
CLASSIC = ("$classicSubscription", "$classicResourceGroup", "$classicServiceBus")
OWN = ("$subscription", "$resourceGroup", "$serviceBus")

WAIT_STEPS = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 100}, {"color": RED, "value": 1000}]
DLQ_STEPS = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 100}]
PCT_STEPS = [{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}]


def sb(metric, ns, agg, **kw):
    return azmetric(metric, *ns, agg, **kw)


# ── At a glance ──────────────────────────────────────────────────────────────
row("At a glance")
line(
    (4, stat("Waiting (shared Service Bus)", [sb("ActiveMessages", CLASSIC, "Maximum", by_entity=False)],
             thresholds=WAIT_STEPS, decimals=0,
             desc="Messages waiting to be consumed across the whole classic namespace, now.")),
    (4, stat("New dead letters in range", [sb("DeadletteredMessages", CLASSIC, "Maximum", by_entity=False)],
             thresholds=DLQ_STEPS, decimals=0, reduceOptions={"calcs": ["diff"], "fields": "", "values": False},
             desc="Change in the dead-letter count over the selected range, classic namespace. Negative means someone cleared a DLQ.")),
    (4, stat("Service Bus server errors", [sb("ServerErrors", CLASSIC, "Total", by_entity=False, alias="classic"),
                                           sb("ServerErrors", OWN, "Total", by_entity=False, alias="own", ref="B")],
             thresholds=DLQ_STEPS, decimals=0, reduceOptions={"calcs": ["sum"], "fields": "", "values": False},
             desc="Errors on the Service Bus side in range, classic plus this namespace's own.")),
    (4, stat("Partner call failures", [kql(PARTNERS + "| summarize v = 100.0 * countif(failed) / count()\n", "table")],
             unit="percent", decimals=2, thresholds=PCT_STEPS,
             desc="Failed outbound calls to external partners from this namespace. Blob 404s (existence checks) are not counted.")),
    (4, stat("Risk engine fallback", [kql(RISK_FALLBACK_PCT, "table")],
             unit="percent", decimals=1, thresholds=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 10}],
             desc="Share of risk assessments that fell back to the default because the risk engine call failed.")),
    (4, stat("Integration jobs failing", [kql(JOB_REQUESTS + "| summarize arg_max(timestamp, success) by name\n| summarize v = countif(success == false)\n", "table")],
             decimals=0, thresholds=[{"color": GREEN, "value": None}, {"color": RED, "value": 1}],
             desc="Scheduled jobs whose most recent run in range failed. See the jobs table below.")),
    h=4,
)

# ── Shared (classic) Service Bus ────────────────────────────────────────────
row("Service Bus: shared namespace $classicServiceBus")
line(
    (8, bargauge("Waiting messages by entity", [sb("ActiveMessages", CLASSIC, "Maximum", entity="$entity", top=15)],
                 thresholds=WAIT_STEPS, noValue="Nothing waiting",
                 desc="Now, largest first. A topic's figure is the sum over its subscriptions: Azure Monitor does not split by subscription.")),
    (8, bargauge("Dead-lettered by entity", [sb("DeadletteredMessages", CLASSIC, "Maximum", entity="$entity", top=15)],
                 thresholds=DLQ_STEPS, noValue="No dead letters")),
    (8, ts("Dead-lettered over time (top 8)", [sb("DeadletteredMessages", CLASSIC, "Maximum", entity="$entity", top=8)],
           unit="short", desc="A rising line is a consumer rejecting messages now; a flat one is old dead letters nobody has cleared.")),
    h=9,
)
line(
    (8, ts("Waiting over time (top 8)", [sb("ActiveMessages", CLASSIC, "Maximum", entity="$entity", top=8)],
           unit="short", desc="Rising while incoming is flat or zero means a stuck or missing consumer.")),
    (8, ts("Incoming by entity (top 8)", [sb("IncomingMessages", CLASSIC, "Total", entity="$entity", top=8)], unit="short")),
    (8, ts("Completed by entity (top 8)", [sb("CompleteMessage", CLASSIC, "Total", entity="$entity", top=8)], unit="short",
           desc="Messages consumers settled successfully.")),
)

# ── Namespace's own Service Bus ──────────────────────────────────────────────
row("Service Bus: this namespace's own $serviceBus")
line(
    (8, bargauge("Waiting messages by entity", [sb("ActiveMessages", OWN, "Maximum", entity="$entity", top=15)],
                 thresholds=WAIT_STEPS, noValue="Nothing waiting")),
    (8, bargauge("Dead-lettered by entity", [sb("DeadletteredMessages", OWN, "Maximum", entity="$entity", top=15)],
                 thresholds=DLQ_STEPS, noValue="No dead letters")),
    (8, ts("Incoming vs completed", [sb("IncomingMessages", OWN, "Total", by_entity=False, alias="incoming"),
                                     sb("CompleteMessage", OWN, "Total", by_entity=False, alias="completed", ref="B"),
                                     sb("ServerErrors", OWN, "Total", by_entity=False, alias="server errors", ref="C"),
                                     sb("ThrottledRequests", OWN, "Total", by_entity=False, alias="throttled", ref="D")],
           unit="short", overrides=[col("server errors", color={"mode": "fixed", "fixedColor": RED}),
                                    col("throttled", color={"mode": "fixed", "fixedColor": AMBER})])),
    h=9,
)

# ── Messaging from the apps' side ────────────────────────────────────────────
SB_DEPS = ai("dependencies", '| where type == "Microsoft.ServiceBus"\n'
             '| extend entity = tostring(split(target, "/")[0]), op = tostring(split(name, ".")[1])\n')
row("Messaging seen from the apps (App Insights, this namespace only)")
line(
    (14, table("Who sends and who consumes",
               [kql(SB_DEPS +
                    f'| summarize Sent = countif(op == "send"), ["Send failures"] = countif(op == "send" and success == false),\n'
                    f'    Completed = countif(op == "complete"), Senders = make_set_if({ROLE}, op == "send"),\n'
                    f'    Consumers = make_set_if({ROLE}, op in ("receiveMessages", "complete")) by Entity = entity\n'
                    '| extend Senders = strcat_array(Senders, ", "), Consumers = strcat_array(Consumers, ", ")\n'
                    "| order by Sent desc\n", "table")],
               sort="Sent", noValue="No Service Bus traffic from this namespace",
               desc="Unlike the metrics above, this is only this namespace's pods. An entity with senders and no consumers here is consumed elsewhere (Logic App, BTMS, another namespace) or not at all.",
               overrides=[col("Send failures", custom_cellOptions={"type": "color-text"},
                              thresholds={"mode": "absolute", "steps": DLQ_STEPS})])),
    (10, ts("Sent and completed",
            [kql(SB_DEPS + '| where op in ("send", "complete")\n'
                 '| summarize n = count() by series = strcat(entity, " ", op), bin(timestamp, $__interval)\n| order by timestamp asc\n')],
            unit="short")),
)

# ── External partners ────────────────────────────────────────────────────────
row("External partners (App Insights, this namespace only)")
line(
    (14, table("Calls by partner",
               [kql(PARTNERS +
                    "| summarize Calls = count(), ['Fail %'] = round(100.0 * countif(failed) / count(), 2), ['p95 ms'] = round(percentile(duration, 95)),\n"
                    f"    ['Last failure'] = maxif(timestamp, failed), Codes = strcat_array(make_set_if(resultCode, failed, 5), \", \"),\n"
                    f"    ['Called by'] = strcat_array(make_set({ROLE}, 5), \", \") by Partner = partner\n"
                    "| order by ['Fail %'] desc, Calls desc\n", "table")],
               noValue="No partner calls from this namespace",
               desc="Codes are the result codes of failed calls. 0 usually means a timeout or connection failure.",
               overrides=[col("Fail %", custom_cellOptions={"type": "color-background", "mode": "basic"},
                              thresholds={"mode": "absolute", "steps": PCT_STEPS}),
                          col("p95 ms", unit="ms")])),
    (10, ts("Failed calls by partner",
            [kql(PARTNERS + "| where failed\n| summarize n = count() by partner, bin(timestamp, $__interval)\n| order by timestamp asc\n")],
            unit="short", bars=True, stack=True, noValue="No failed partner calls")),
    h=9,
)
line(
    (12, ts("Partner latency p95",
            [kql(PARTNERS + "| summarize p95 = percentile(duration, 95) by partner, bin(timestamp, $__interval)\n| order by timestamp asc\n")],
            unit="ms", defaults={"custom": {"lineWidth": 1, "fillOpacity": 0, "showPoints": "never", "spanNulls": True,
                                            "scaleDistribution": {"type": "log", "log": 10}}},
            desc="Log scale: partners range from milliseconds (search) to minutes (RDS timeouts).")),
    (12, ts("Risk engine: answered vs fallback",
            [kql(ai("customMetrics", RISK +
                    '| summarize n = sum(valueSum) by series = iff(name endswith "fallback-count", "fallback", "answered"), bin(timestamp, $__interval)\n'
                    "| order by timestamp asc\n"))],
            unit="short", bars=True, stack=True, noValue="No risk assessments in range",
            desc="From riskassessment-service's own counters. Fallback means the CHED got the default risk decision.",
            overrides=[col("n fallback", color={"mode": "fixed", "fixedColor": RED}),
                       col("n answered", color={"mode": "fixed", "fixedColor": GREEN})])),
)

# ── Jobs and retry events ───────────────────────────────────────────────────
row("Integration jobs and retry events")
line(
    (14, table("Scheduled jobs",
               [kql(JOB_REQUESTS +
                       f"| summarize Runs = count(), Failed = countif(success == false), ['p95 s'] = round(percentile(duration, 95) / 1000, 1),\n"
                       f"    ['Last run'] = max(timestamp), ['Last success'] = maxif(timestamp, success == true), Service = take_any({ROLE}) by Job = name\n"
                       '| extend Status = case(Failed == Runs, "failing", Failed > 0, "some failures", "ok")\n'
                       "| project Status, Job, Service, Runs, Failed, ['p95 s'], ['Last run'], ['Last success']\n"
                       "| order by Failed desc, Runs desc\n", "table")],
               noValue="No scheduled jobs ran in range",
               desc="Scheduled tasks reported as requests (reference data sync, MDM download, archiving). Cache-clearing tasks are left out.",
               overrides=[col("Status", custom_width=110, custom_cellOptions={"type": "color-text"},
                              mappings=[{"type": "value", "options": {
                                  "failing": {"color": RED, "index": 0},
                                  "some failures": {"color": AMBER, "index": 1},
                                  "ok": {"color": GREEN, "index": 2}}}])])),
    (10, ts("Retry and failure events",
            [kql("union\n"
                 " (customEvents\n | where $__timeFilter(timestamp)\n " + NS.strip() + "\n"
                 ' | where name matches regex "(?i)(retry|fail|error|poll|timeout|deadletter)"\n'
                 " | summarize n = count() by series = name, bin(timestamp, $__interval)),\n"
                 " (customMetrics\n | where $__timeFilter(timestamp)\n " + NS.strip() + "\n"
                 ' | where name == "Item_Retry_Count"\n'
                 " | summarize n = sum(valueSum) by series = name, bin(timestamp, $__interval))\n"
                 "| order by timestamp asc\n")],
            unit="short", bars=True, stack=True, noValue="No retry or failure events",
            desc="BIP, checks and decision retry events, *FailedEvent, SOAP search poll failures and Item_Retry_Count.")),
    h=9,
)

emit(
    "ipaffs-messaging-integrations", "IPAFFS Messaging & Integrations",
    "Is anything stuck between IPAFFS and its partners? Service Bus backlogs and dead letters, partner calls, integration jobs.",
    ["ipaffs", "layer-2"],
    BASE_VARIABLES + [
        NAMESPACE_VARIABLE,
        var_az("serviceBus", "Azure Resource Names", "/.*impinfsb1401-$namespace$/i", subscription="$subscription",
               resourceGroup="$resourceGroup", namespace="Microsoft.ServiceBus/namespaces"),
        var_const("classicSubscription", "Classic subscription"),
        var_const("classicResourceGroup", "Classic resource group"),
        var_const("classicServiceBus", "Classic Service Bus namespace"),
        {"name": "entity", "type": "textbox", "label": "Queue or topic (* for all)", "query": "*", "hide": 0,
         "current": {"selected": True, "text": "*", "value": "*"}, "options": [{"selected": True, "text": "*", "value": "*"}]},
    ],
)
