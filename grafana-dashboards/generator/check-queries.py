#!/usr/bin/env python3
"""Runs every panel query of a generated dashboard through a live Grafana and
prints what comes back, so a dashboard can be checked before it is deployed.

Usage:
  python3 check-queries.py <dashboard.json> <namespace> [service]

Variables are filled in from the environment, defaulting to DEV:
  GRAFANA_URL, SUBSCRIPTION_ID, RESOURCE_GROUP, APP_INSIGHTS, PROM_DS_UID,
  SERVICE_BUS_PREFIX, CLASSIC_SUBSCRIPTION_ID, CLASSIC_RESOURCE_GROUP, CLASSIC_SERVICE_BUS

Needs `az login`. Exits non-zero if any query returns an error.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

AMG_APP_ID = "ce34e7e5-485f-4d76-964f-b3d2b16d1e4f"  # Azure Managed Grafana


def env(name, default):
    return os.environ.get(name, default)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    dashboard = json.load(open(sys.argv[1]))
    ns = sys.argv[2]
    service = sys.argv[3] if len(sys.argv) > 3 else ""
    grafana = env("GRAFANA_URL", "https://DEVIMPINFGA1401-ahc2fhdqfmc6b0fe.suk.grafana.azure.com")
    token = subprocess.run(["az", "account", "get-access-token", "--resource", AMG_APP_ID,
                            "--query", "accessToken", "-o", "tsv"],
                           check=True, capture_output=True, text=True).stdout.strip()

    values = {
        "$namespace": ns,
        "$service": service,
        "$subscription": env("SUBSCRIPTION_ID", "f27f4f47-2766-40c8-8450-f585675f76a2"),
        "$resourceGroup": env("RESOURCE_GROUP", "DEVIMPINFRG1401"),
        "$appInsights": env("APP_INSIGHTS", "DEVIMPINFIN1401"),
        "${datasource}": env("PROM_DS_UID", "bfq876mzxyfi8b"),
        "$serviceBus": env("SERVICE_BUS_PREFIX", "devimpinfsb1401-") + ns,
        "$classicSubscription": env("CLASSIC_SUBSCRIPTION_ID", "e716414f-1f8e-48f1-8f56-65f35cfdafb6"),
        "$classicResourceGroup": env("CLASSIC_RESOURCE_GROUP", "SNDIMPINFRGP009"),
        "$classicServiceBus": env("CLASSIC_SERVICE_BUS", "SNDIMPINFSBS002"),
        "$entity": "*",
        "$__interval": "5m",
        "$__rate_interval": "2m",
        "$__range": "6h",
    }

    def fill(target):
        text = json.dumps(target)
        # Longest first, so $service does not clobber $serviceBus.
        for name in sorted(values, key=len, reverse=True):
            text = text.replace(name, values[name])
        return json.loads(text)

    errors = 0
    for panel in dashboard["panels"]:
        if panel["type"] == "row":
            continue
        results = []
        for target in panel["targets"]:
            target = fill(target)
            body = {"from": "now-6h", "to": "now", "queries": [dict(target, intervalMs=300000, maxDataPoints=500)]}
            request = urllib.request.Request(grafana + "/api/ds/query", json.dumps(body).encode(),
                                             {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            try:
                response = json.load(urllib.request.urlopen(request, timeout=120))
            except urllib.error.HTTPError as e:
                response = json.loads(e.read() or b"{}")
            result = response.get("results", {}).get(target["refId"], {})
            if result.get("error"):
                errors += 1
                results.append("ERROR " + result["error"][:300])
                continue
            frames = result.get("frames", [])
            rows = sum(len(f["data"]["values"][0]) for f in frames if f.get("data", {}).get("values"))
            results.append(f"{len(frames)} frames, {rows} rows")
        print(f"{panel['title'][:45]:45} {' ; '.join(results)}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
