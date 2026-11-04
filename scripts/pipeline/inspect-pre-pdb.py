#!/usr/bin/env python3
"""Read PRE workload/PDB metadata; never publish pod specs or raw diagnostics."""

import argparse
import copy
import json
from pathlib import Path
import re
import subprocess


NAMESPACE = "pre"
CONTEXT = "PRE-PDB-READONLY"
KINDS = ("deployments", "poddisruptionbudgets", "pods", "jobs")
NAME = re.compile(r"[a-z0-9](?:[-a-z0-9.]{0,251}[a-z0-9])?")
CODE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,127}")
LABEL_VALUE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?|^$")
LABELS = {"service", "project", "app", "helm.sh/chart", "app.kubernetes.io/name",
          "app.kubernetes.io/instance", "app.kubernetes.io/component",
          "app.kubernetes.io/managed-by", "app.kubernetes.io/part-of",
          "batch.kubernetes.io/job-name", "job-name", "pod-template-hash"}


def name(value):
    return value if isinstance(value, str) and NAME.fullmatch(value) else "unavailable"


def code(value):
    return value if isinstance(value, str) and CODE.fullmatch(value) else "unavailable"


def number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def allowance(value):
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 100000:
        return value
    return value if isinstance(value, str) and re.fullmatch(r"[0-9]{1,6}%?", value) else None


def safe_labels(value):
    return {k: v for k, v in value.items()
            if k in LABELS and isinstance(v, str) and LABEL_VALUE.fullmatch(v)} if isinstance(value, dict) else {}


def matches(selector, labels):
    """Kubernetes policy/v1 selector semantics; unknown evidence is never False."""
    if selector is None:
        return False
    if not isinstance(selector, dict) or not isinstance(labels, dict):
        return None
    if set(selector) - {"matchLabels", "matchExpressions"}:
        return None
    exact, expressions = selector.get("matchLabels", {}), selector.get("matchExpressions", [])
    if not isinstance(exact, dict) or not isinstance(expressions, list):
        return None
    result = True
    for key, value in exact.items():
        if not isinstance(key, str) or not isinstance(value, str):
            return None
        result = result and key in labels and labels[key] == value
    for expression in expressions:
        if not isinstance(expression, dict) or set(expression) - {"key", "operator", "values"}:
            return None
        key, operation, values = expression.get("key"), expression.get("operator"), expression.get("values", [])
        if not isinstance(key, str) or not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            return None
        if operation in {"In", "NotIn"} and not values:
            return None
        if operation in {"Exists", "DoesNotExist"} and values:
            return None
        if operation == "In":
            valid = key in labels and labels[key] in values
        elif operation == "NotIn":
            valid = key not in labels or labels[key] not in values
        elif operation == "Exists":
            valid = key in labels
        elif operation == "DoesNotExist":
            valid = key not in labels
        else:
            return None
        result = result and valid
    return result


def selector(value):
    if value is None:
        return None
    if not isinstance(value, dict):
        return {"redacted": True}
    result = {"matchLabels": safe_labels(value.get("matchLabels", {})), "matchExpressions": []}
    redacted = set(result["matchLabels"]) != set(value.get("matchLabels", {})) if isinstance(value.get("matchLabels", {}), dict) else True
    expressions = value.get("matchExpressions", [])
    if not isinstance(expressions, list):
        return {"redacted": True}
    for entry in expressions:
        if (not isinstance(entry, dict) or entry.get("key") not in LABELS
                or entry.get("operator") not in {"In", "NotIn", "Exists", "DoesNotExist"}
                or not isinstance(entry.get("values", []), list)
                or not all(isinstance(v, str) and LABEL_VALUE.fullmatch(v) for v in entry.get("values", []))):
            redacted = True
            continue
        result["matchExpressions"].append({"key": entry["key"], "operator": entry["operator"], "values": entry.get("values", [])})
    result["redacted"] = redacted or bool(set(value) - {"matchLabels", "matchExpressions"})
    return result


def metadata(item):
    raw = item.get("metadata", {})
    result = {"name": name(raw.get("name")), "labels": safe_labels(raw.get("labels", {})),
              "generation": number(raw.get("generation")), "deleting": bool(raw.get("deletionTimestamp"))}
    release = raw.get("annotations", {}).get("meta.helm.sh/release-name")
    service = raw.get("labels", {}).get("service")
    if name(release) != "unavailable" and release in {raw.get("name"), str(service) + "-webapp", service}:
        result["helmRelease"] = release
    return result


def conditions(status):
    return [{"type": code(c.get("type")), "status": c.get("status") if c.get("status") in {"True", "False", "Unknown"} else "Unknown",
             "reason": code(c.get("reason"))} for c in status.get("conditions", []) if isinstance(c, dict)]


def owner(item):
    owners = [r for r in item.get("metadata", {}).get("ownerReferences", []) if r.get("controller") is True]
    return ({"kind": code(owners[0].get("kind")), "name": name(owners[0].get("name"))}
            if len(owners) == 1 else {"kind": "unavailable", "name": "unavailable"})


def pod(item):
    status = item.get("status", {})
    return {**metadata(item), "owner": owner(item), "node": name(item.get("spec", {}).get("nodeName")),
            "phase": status.get("phase") if status.get("phase") in {"Pending", "Running", "Succeeded", "Failed", "Unknown"} else "Unknown",
            "ready": any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", [])),
            "conditions": conditions(status), "containers": [
                {"name": name(c.get("name")), "ready": c.get("ready") is True, "restartCount": number(c.get("restartCount")),
                 "state": next((s for s in ("running", "waiting", "terminated") if s in c.get("state", {})), "unavailable"),
                 "reason": code(next((c["state"][s].get("reason") for s in ("waiting", "terminated") if s in c.get("state", {})), None)),
                 "exitCode": number(c.get("state", {}).get("terminated", {}).get("exitCode"))}
                for c in status.get("containerStatuses", []) if isinstance(c, dict)]}


def build_report(collections):
    raw_pods = collections["pods"]
    pods = [pod(item) for item in raw_pods]
    deployments = []
    for item in collections["deployments"]:
        spec, status = item.get("spec", {}), item.get("status", {})
        deployments.append({**metadata(item), "selector": selector(spec.get("selector")),
                            "desiredReplicas": number(spec.get("replicas")),
                            **{k: number(status.get(k)) for k in ("replicas", "readyReplicas", "availableReplicas", "updatedReplicas", "unavailableReplicas", "observedGeneration")},
                            "conditions": conditions(status)})
    jobs = [{**metadata(item), **{k: number(item.get("status", {}).get(k)) for k in ("active", "succeeded", "failed")},
             "conditions": conditions(item.get("status", {})), "ttlSecondsAfterFinished": number(item.get("spec", {}).get("ttlSecondsAfterFinished"))}
            for item in collections["jobs"]]
    budgets = []
    for item in collections["poddisruptionbudgets"]:
        spec, status = item.get("spec", {}), item.get("status", {})
        decisions = [matches(spec.get("selector"), raw.get("metadata", {}).get("labels", {})) for raw in raw_pods]
        selected = [p for p, selected in zip(pods, decisions) if selected is True]
        complete = all(selected is not None for selected in decisions)
        job_pods = [p for p in selected if p["owner"]["kind"] == "Job"]
        app_pods = [p for p in selected if p["owner"]["kind"] in {"ReplicaSet", "StatefulSet", "DaemonSet", "ReplicationController"}]
        proposed = copy.deepcopy(spec.get("selector"))
        if isinstance(proposed, dict) and isinstance(proposed.get("matchExpressions", []), list):
            proposed.setdefault("matchExpressions", []).extend([
                {"key": key, "operator": "DoesNotExist"} for key in ("batch.kubernetes.io/job-name", "job-name")])
        future_decisions = [matches(proposed, raw.get("metadata", {}).get("labels", {})) for raw in raw_pods]
        future_complete = complete and all(v is not None for v in future_decisions)
        future = [p for p, matched in zip(pods, future_decisions) if matched is True]
        future_apps = [p for p in future if p["owner"]["kind"] in {"ReplicaSet", "StatefulSet", "DaemonSet", "ReplicationController"}]
        counterfactual = {"complete": future_complete,
                          "selectedPodCount": len(future) if future_complete else None,
                          "selectedJobPodCount": sum(p["owner"]["kind"] == "Job" for p in future) if future_complete else None,
                          "selectedAppPodCount": len(future_apps) if future_complete else None,
                          "preservesApplicationSelection": {p["name"] for p in app_pods} == {p["name"] for p in future_apps} if future_complete else None}
        budgets.append({**metadata(item), "selector": selector(spec.get("selector")),
                        "maxUnavailable": allowance(spec.get("maxUnavailable")),
                        "minAvailable": allowance(spec.get("minAvailable")),
                        "unhealthyPodEvictionPolicy": spec.get("unhealthyPodEvictionPolicy") if spec.get("unhealthyPodEvictionPolicy") in {"AlwaysAllow", "IfHealthyBudget"} else None,
                        **{k: number(status.get(k)) for k in ("currentHealthy", "desiredHealthy", "expectedPods", "disruptionsAllowed", "observedGeneration")},
                        "conditions": conditions(status), "selectionComplete": complete,
                        "selectedPodCount": len(selected) if complete else None,
                        "selectedJobPodCount": len(job_pods) if complete else None,
                        "selectedCompletedJobPodCount": sum(p["phase"] in {"Succeeded", "Failed"} for p in job_pods) if complete else None,
                        "selectedAppPodCount": len(app_pods) if complete else None,
                        "selectedReadyAppPodCount": sum(p["ready"] for p in app_pods) if complete else None,
                        "counterfactualExcludingJobLabels": counterfactual,
                        "selectedPods": [{"name": p["name"], "owner": p["owner"], "phase": p["phase"], "ready": p["ready"]} for p in selected]})
    return {"schemaVersion": 1, "namespace": NAMESPACE, "readOnly": True, "complete": all(p["selectionComplete"] for p in budgets),
            "deployments": deployments, "podDisruptionBudgets": budgets, "pods": pods, "jobs": jobs}


def read(kind):
    if kind not in KINDS:
        raise RuntimeError("COMMAND_NOT_ALLOWED")
    result = subprocess.run(["kubectl", "--context", CONTEXT, "--namespace", NAMESPACE, "get", kind,
                             "--output", "json", "--request-timeout", "30s"], capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError("KUBERNETES_READ_FAILED")
    try:
        data = json.loads(result.stdout)
        items = data["items"]
        if not isinstance(items, list) or len(items) > 10000 or data.get("metadata", {}).get("continue"):
            raise ValueError()
        if any(not isinstance(i, dict) or i.get("metadata", {}).get("namespace") != NAMESPACE for i in items):
            raise ValueError()
        return items
    except (ValueError, KeyError, TypeError):
        raise RuntimeError("INVALID_OR_INCOMPLETE_KUBERNETES_RESPONSE") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    try:
        report = build_report({kind: read(kind) for kind in KINDS})
    except Exception:
        (args.output_dir / "diagnostic.json").write_text(json.dumps({"complete": False, "errorCode": "READ_ONLY_DIAGNOSTIC_FAILED"}) + "\n")
        print("Read-only diagnostic failed; raw command output withheld.")
        return 1
    (args.output_dir / "diagnostic.json").write_text(json.dumps(report, indent=2) + "\n")
    selected = sum(p["selectedJobPodCount"] for p in report["podDisruptionBudgets"]) if report["complete"] else "unavailable"
    summary = ["# PRE read-only PDB diagnostic", "", f"Deployments: {len(report['deployments'])}; PDBs: {len(report['podDisruptionBudgets'])}; Pods: {len(report['pods'])}; Jobs: {len(report['jobs'])}.",
               f"Selection assessment complete: {report['complete']}; selected Job-pod observations: {selected}.",
               "", "No workload, disruption budget, node or infrastructure changes were made. Resource specifications, environment variables and raw diagnostic messages are not published."]
    (args.output_dir / "summary.md").write_text("\n".join(summary) + "\n")
    print("Published sanitized read-only PRE workload/PDB metadata.")
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
