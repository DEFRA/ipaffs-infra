#!/usr/bin/env python3
"""Generates IPAFFSServiceDrilldown.json (proposal dashboard 2: Service Drill-down)."""
from lib import *  # noqa: F401,F403

# Every App Insights query starts from this: one service in one namespace. Role
# names are "<ns>.<service>" in feature namespaces and bare "<service>" in dev.
def ai(table, extra=""):
    return (
        f"{table}\n"
        "| where $__timeFilter(timestamp)\n"
        '| where cloud_RoleName in ("$service", "$namespace.$service")\n'
        '| where tostring(customDimensions["k8s.namespace.name"]) == "$namespace"\n'
        + extra
    )

# Requests, without health checks and static assets.
def req(extra=""):
    return ai("requests",
              '| where name != "GET /admin/health-check" and name !startswith "GET /public/"\n' + extra)

# Collapses CHED references, GUIDs and numeric ids so frontend routes group together.
OP = ('| extend op = replace_regex(replace_regex(replace_regex(name, @"[A-Z]+\\.GB\\.\\d{4}\\.\\d+[A-Z]?", "{ref}"),'
      ' @"[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}", "{guid}"), @"/\\d+(/|$)", @"/{n}\\1")\n')

# Deployment pods only: "<service>-<rs hash>-<suffix>", both drawn from Kubernetes'
# vowel-free alphabet, so job pods such as "<service>-migrations-xxxxx" are left out.
# Azure Managed Prometheus does not anchor regex matchers, hence ^ and $.
POD = 'namespace="$namespace", pod=~"^$service-[bcdfghjklmnpqrstvwxz2-9]{6,10}-[bcdfghjklmnpqrstvwxz2-9]{5}$"'

# ── At a glance ──────────────────────────────────────────────────────────────
row("At a glance")
line(
    (4, stat("Requests / min", [kql(req("| summarize v = count() / (($__timeTo() - $__timeFrom()) / 1m)\n"), "table")],
             decimals=1, desc="Average over the selected range. Health checks and static assets are excluded.")),
    (4, stat("Server errors (5xx)", [kql(req('| summarize v = 100.0 * countif(toint(resultCode) >= 500) / count()\n'), "table")],
             unit="percent", decimals=2,
             thresholds=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}])),
    (4, stat("Latency p95", [kql(req("| summarize v = percentile(duration, 95)\n"), "table")],
             unit="ms", thresholds=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1000}, {"color": RED, "value": 3000}])),
    (3, stat("Exceptions", [kql(ai("exceptions", "| summarize v = count()\n"), "table")],
             thresholds=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}])),
    (3, stat("Pods ready", [promql(f'sum(kube_pod_status_ready{{{POD}, condition="true"}}) or vector(0)', instant=True)],
             ds=PROM, desc="Pods passing their readiness probe now.",
             thresholds=[{"color": RED, "value": None}, {"color": GREEN, "value": 1}])),
    (3, stat("Restarts in range", [promql(f'sum(increase(kube_pod_container_status_restarts_total{{{POD}}}[$__range])) or vector(0)', instant=True)],
             ds=PROM, decimals=0, thresholds=[{"color": GREEN, "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 3}])),
    (3, stat("Version", [promql(f'count by (version) (label_replace(kube_pod_container_info{{{POD}, container="webapp"}}, "version", "$1", "image", ".*:(.+)"))',
                                "{{version}}", instant=True)],
             ds=PROM, textMode="name", colorMode="none", desc="Image tag of the running pods. More than one value means a rollout is in progress.",
             reduceOptions={"calcs": ["lastNotNull"], "fields": "", "values": True})),
    h=4,
)

# ── RED ──────────────────────────────────────────────────────────────────────
row("Requests: rate, errors, duration")
line(
    (12, ts("Request rate by operation (top 8)",
            [kql("let base = materialize(" + req(OP) + ");\n"
                 "let top = base | summarize total = count() by op | top 8 by total | project op;\n"
                 "base\n| where op in (top)\n| summarize n = count() by op, bin(timestamp, $__interval)\n| order by timestamp asc\n")],
            unit="short", desc="Calls per bin for the eight busiest operations.")),
    (12, ts("Errors: 4xx and 5xx",
            [kql(req("| extend cls = case(toint(resultCode) >= 500, \"5xx\", toint(resultCode) >= 400, \"4xx\", \"\")\n"
                     "| where cls != \"\"\n"
                     "| summarize n = count() by cls, bin(timestamp, $__interval)\n| order by timestamp asc\n"))],
            unit="short", stack=True, bars=True,
            desc="4xx is usually the caller's fault (validation, auth); 5xx is ours.",
            overrides=[col("n 5xx", color={"mode": "fixed", "fixedColor": RED}),
                       col("n 4xx", color={"mode": "fixed", "fixedColor": AMBER})])),
)
line(
    (12, ts("Latency p50 / p95 / p99",
            [kql(req("| summarize p50 = percentile(duration, 50), p95 = percentile(duration, 95), p99 = percentile(duration, 99) by bin(timestamp, $__interval)\n"
                     "| order by timestamp asc\n"))],
            unit="ms")),
    (12, table("Operations",
               [kql(req(OP + "| summarize Calls = count(), ['4xx %'] = round(100.0 * countif(toint(resultCode) between (400 .. 499)) / count(), 2),\n"
                             "    ['5xx %'] = round(100.0 * countif(toint(resultCode) >= 500) / count(), 2),\n"
                             "    ['p50 ms'] = round(percentile(duration, 50)), ['p95 ms'] = round(percentile(duration, 95)) by Operation = op\n"
                             "| order by Calls desc\n| take 50\n"), "table")],
               sort="Calls",
               overrides=[col("5xx %", custom_cellOptions={"type": "color-text"},
                              thresholds={"mode": "absolute", "steps": [{"color": "text", "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}]}),
                          col("p95 ms", unit="ms")])),
)

# ── Dependencies ─────────────────────────────────────────────────────────────
DEP = '| where type != "InProc"\n| extend dep = strcat(type, " · ", target)\n'
row("Dependencies: is the cause downstream?")
line(
    (12, table("Outbound calls by target",
               [kql(ai("dependencies", DEP +
                       "| summarize Calls = count(), ['Fail %'] = round(100.0 * countif(success == false) / count(), 2),\n"
                       "    ['p95 ms'] = round(percentile(duration, 95)), ['Max ms'] = round(max(duration)) by Type = type, Target = target\n"
                       "| order by Calls desc\n"), "table")],
               sort="Calls", desc="Everything this service calls: other microservices, SQL, Service Bus, blob storage, Entra ID.",
               overrides=[col("Fail %", custom_cellOptions={"type": "color-text"},
                              thresholds={"mode": "absolute", "steps": [{"color": "text", "value": None}, {"color": AMBER, "value": 1}, {"color": RED, "value": 5}]})])),
    (12, ts("Dependency p95 by target",
            [kql(ai("dependencies", DEP + "| summarize p95 = percentile(duration, 95) by dep, bin(timestamp, $__interval)\n| order by timestamp asc\n"))],
            unit="ms")),
)
line(
    (12, ts("Failed dependency calls by target",
            [kql(ai("dependencies", DEP + "| where success == false\n| summarize failed = count() by dep, bin(timestamp, $__interval)\n| order by timestamp asc\n"))],
            unit="short", bars=True, stack=True)),
    (12, table("Slowest dependency calls",
               [kql(ai("dependencies", DEP + "| top 20 by duration desc\n"
                       "| project Time = timestamp, Target = dep, Call = name, ['Duration ms'] = round(duration), OK = success, Result = resultCode, ['Operation id'] = operation_Id\n"), "table")],
               desc="Copy the operation id into App Insights transaction search to see the whole call chain.")),
)

# ── JVM ──────────────────────────────────────────────────────────────────────
def jvm(metric, agg="avg(value)"):
    return kql(ai("customMetrics", f'| where name == "{metric}"\n'
                  f"| summarize v = {agg} by cloud_RoleInstance, bin(timestamp, $__interval)\n| order by timestamp asc\n"))


row("JVM (Java services only)")
line(
    (5, ts("Heap used", [jvm("Heap Memory Used (MB)")], unit="decmbytes", noValue="Not a Java service")),
    (5, ts("Heap used % of max", [jvm("% Of Max Heap Memory Used")], unit="percent", noValue="Not a Java service",
           desc="Sustained growth after each GC suggests a leak.")),
    (5, ts("GC time", [jvm("GC Total Time", "sum(value)")], unit="ms", noValue="Not a Java service",
           desc="Milliseconds spent in garbage collection per bin, per pod.")),
    (4, ts("Threads", [jvm("Thread Count")], unit="short", noValue="Not a Java service")),
    (5, ts("DB connection pool",
           [kql(ai("customMetrics", '| where name in ("hikaricp_connections_active", "hikaricp_connections_pending", "hikaricp_connections_max")\n'
                   '| summarize v = max(valueMax) by series = replace_string(name, "hikaricp_connections_", ""), bin(timestamp, $__interval)\n'
                   "| order by timestamp asc\n"))],
           unit="short", noValue="No Hikari metrics from this service",
           desc="Active and pending connections against the pool maximum. Pending above zero means requests are waiting for a connection.",
           overrides=[col("v max", color={"mode": "fixed", "fixedColor": RED}, custom_lineStyle={"fill": "dash", "dash": [10, 10]}, custom_fillOpacity=0),
                      col("v pending", color={"mode": "fixed", "fixedColor": AMBER})])),
)

# ── Pods ─────────────────────────────────────────────────────────────────────
row("Pods")
line(
    (8, ts("CPU vs request / limit",
           [promql(f'sum by (pod) (rate(container_cpu_usage_seconds_total{{{POD}, container="webapp"}}[$__rate_interval]))', "{{pod}}"),
            promql(f'max(kube_pod_container_resource_requests{{{POD}, container="webapp", resource="cpu"}})', "request", "B"),
            promql(f'max(kube_pod_container_resource_limits{{{POD}, container="webapp", resource="cpu"}})', "limit", "C")],
           unit="cores", ds=PROM,
           overrides=[col("request", color={"mode": "fixed", "fixedColor": AMBER}, custom_lineStyle={"fill": "dash", "dash": [10, 10]}, custom_fillOpacity=0),
                      col("limit", color={"mode": "fixed", "fixedColor": RED}, custom_lineStyle={"fill": "dash", "dash": [10, 10]}, custom_fillOpacity=0)])),
    (8, ts("Memory vs request / limit",
           [promql(f'sum by (pod) (container_memory_working_set_bytes{{{POD}, container="webapp"}})', "{{pod}}"),
            promql(f'max(kube_pod_container_resource_requests{{{POD}, container="webapp", resource="memory"}})', "request", "B"),
            promql(f'max(kube_pod_container_resource_limits{{{POD}, container="webapp", resource="memory"}})', "limit", "C")],
           unit="bytes", ds=PROM, desc="Working set. Hitting the limit gets the pod OOMKilled.",
           overrides=[col("request", color={"mode": "fixed", "fixedColor": AMBER}, custom_lineStyle={"fill": "dash", "dash": [10, 10]}, custom_fillOpacity=0),
                      col("limit", color={"mode": "fixed", "fixedColor": RED}, custom_lineStyle={"fill": "dash", "dash": [10, 10]}, custom_fillOpacity=0)])),
    (8, ts("CPU throttling",
           [promql(f'sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{{POD}, container="webapp"}}[$__rate_interval]))', "{{pod}}")],
           unit="short", ds=PROM, noValue="No CPU limit, so no throttling",
           desc="Throttled CFS periods per second. Only non-zero when the container has a CPU limit.")),
)
line(
    (8, ts("Restarts",
           [promql(f'sum by (pod) (increase(kube_pod_container_status_restarts_total{{{POD}}}[$__rate_interval])) > 0', "{{pod}}")],
           unit="short", ds=PROM, bars=True, noValue="No restarts")),
    (8, table("Last termination reason",
              [promql(f'max by (pod, container, reason) (kube_pod_container_status_last_terminated_reason{{{POD}}})', instant=True)],
              ds=PROM, desc="Why each container last stopped (OOMKilled, Error, Completed).", noValue="No terminations recorded",
              overrides=[col("Time", custom_hidden=True), col("Value", custom_hidden=True)])),
    (8, ts("Replicas",
           [promql(f'sum(kube_deployment_spec_replicas{{namespace="$namespace", deployment="$service"}})', "desired"),
            promql(f'sum(kube_deployment_status_replicas_available{{namespace="$namespace", deployment="$service"}})', "available", "B"),
            promql(f'sum(kube_pod_status_ready{{{POD}, condition="true"}})', "ready", "C")],
           unit="short", ds=PROM, defaults={"decimals": 0})),
)

# ── Service-specific telemetry ──────────────────────────────────────────────
STANDARD_METRICS = ('| where name !startswith "jvm_" and name !startswith "http" and name !startswith "spring_" and name !startswith "tomcat_"\n'
                    '    and name !startswith "process_" and name !startswith "system_" and name !startswith "disk_" and name !startswith "logback_"\n'
                    '    and name !startswith "tasks_" and name !startswith "application_" and name !startswith "executor"\n'
                    '    and name !startswith "hikaricp_" and name !startswith "jdbc_" and name != "HeartbeatState"\n'
                    '    and name !in ("Total Started Thread Count", "Peak Thread Count", "Heap Memory Usage", "Non Heap Memory Usage", "Thread Count",\n'
                    '      "GC Total Time", "GC Total Count", "% Of Max Heap Memory Used", "Heap Memory Used (MB)", "Suspected Deadlocked Threads", "Loaded Class Count")\n')
row("Service-specific telemetry")
line(
    (12, table("Custom metrics (trackMetric, @Timed)",
               [kql(ai("customMetrics", STANDARD_METRICS +
                       "| summarize Samples = sum(valueCount), Avg = round(sum(valueSum) / sum(valueCount), 1), Max = round(max(valueMax), 1) by Metric = name\n"
                       "| order by Samples desc\n"), "table")],
               sort="Samples", noValue="This service sends no custom metrics",
               desc="Metrics the service code records itself. Most are durations in ms. JVM, HTTP and Spring metrics are left out.")),
    (12, ts("Custom events",
            [kql(ai("customEvents", "| summarize n = count() by name, bin(timestamp, $__interval)\n| order by timestamp asc\n"))],
            unit="short", bars=True, stack=True, noValue="No custom events in range",
            desc="Retry events, *FailedEvent, cache refreshes and MonitoringEvent.")),
)

# ── Exceptions ───────────────────────────────────────────────────────────────
row("Exceptions")
line(
    (10, ts("Exceptions by type",
            [kql(ai("exceptions", "| summarize n = count() by type, bin(timestamp, $__interval)\n| order by timestamp asc\n"))],
            unit="short", bars=True, stack=True, noValue="No exceptions")),
    (14, table("Top exceptions",
               [kql("exceptions\n"
                    "| where timestamp between (($__timeFrom() - 7d) .. $__timeTo())\n"
                    '| where cloud_RoleName in ("$service", "$namespace.$service")\n'
                    '| where tostring(customDimensions["k8s.namespace.name"]) == "$namespace"\n'
                    "| summarize Count = countif(timestamp >= $__timeFrom()), Before = countif(timestamp < $__timeFrom()),\n"
                    "    ['Last seen'] = max(timestamp), Message = take_any(outerMessage) by Type = type, ['Problem id'] = problemId\n"
                    "| where Count > 0\n"
                    '| extend New = iff(Before == 0, "new", "")\n'
                    "| project New, Count, Type, Message, ['Last seen'], ['Problem id']\n"
                    "| order by Count desc\n| take 25\n", "table")],
               sort="Count", noValue="No exceptions",
               desc="'new' means the problem id did not occur in the 7 days before the selected range: a likely regression.",
               overrides=[col("New", custom_width=60, custom_cellOptions={"type": "color-text"},
                              color={"mode": "fixed", "fixedColor": RED}),
                          col("Count", custom_width=80)])),
    h=9,
)


emit(
    "ipaffs-service-drilldown", "IPAFFS Service Drill-down",
    "One service in one namespace: requests, dependencies, JVM, pods, custom telemetry and exceptions.",
    ["ipaffs", "layer-2"],
    BASE_VARIABLES + [
        NAMESPACE_VARIABLE,
        var_prom("service", 'label_values(kube_deployment_spec_replicas{namespace="$namespace"}, deployment)', label="Service",
                 current="checks-service"),
    ],
    annotations=[
        {"name": "Pod starts (deploys)", "enable": True, "iconColor": "purple", "datasource": PROM,
         "expr": (f'max by (pod, image) (kube_pod_created{{{POD}}} * on (namespace, pod) group_left (image) '
                  f'max by (namespace, pod, image) (kube_pod_container_info{{{POD}, container="webapp"}})) * 1000'),
         "useValueForTime": True, "step": "1m", "titleFormat": "Pod started", "textFormat": "{{pod}} · {{image}}"},
    ],
)
