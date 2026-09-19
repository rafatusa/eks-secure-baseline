#!/usr/bin/env python3
"""Build a human-readable compliance report from kube-bench and Trivy output.

Scope statement (deliberately reproduced in every report):
    This report covers the CIS Amazon EKS Benchmark, not a DISA STIG.
    DISA publishes STIGs for the Kubernetes platform and for RHEL/Ubuntu node
    operating systems. There is no DISA STIG for Amazon EKS, and the
    Kubernetes STIG assumes access to control-plane component flags that a
    managed EKS control plane does not expose to customers. Amazon Linux 2023
    additionally has no published DISA SCAP content. The controls below are
    therefore the customer-responsibility subset that can be genuinely
    evaluated on this platform.

PARSING NOTE — null vs missing (this cost a failed compliance stage)
--------------------------------------------------------------------
kube-bench emits `"tests": null` for controls it did not evaluate. On EKS
that is GUARANTEED, not exceptional: the eks-1.2.0 benchmark ships
controlplane.yaml and master.yaml sections whose components are managed by
AWS and cannot be assessed from inside the cluster, so they come back with a
null test list.

`dict.get("tests", [])` does NOT protect against this. The default is only
returned when the key is ABSENT; here the key is PRESENT with value None, so
`.get` returns None and iteration raises:

    TypeError: 'NoneType' object is not iterable

Every nested traversal below therefore uses `(x.get(key) or [])`, which
collapses both missing AND null to an empty list. The same applies to Trivy's
`Results` / `Misconfigurations`, which are null for resources that produced
no findings. Keep this idiom if you extend the parser.
"""

from __future__ import annotations

import argparse
import html
import json
import os
from collections import Counter
from datetime import datetime, timezone
from typing import Any

SCOPE_NOTE = (
    "This report covers the CIS Amazon EKS Benchmark, not a DISA STIG. "
    "DISA publishes STIGs for the Kubernetes platform and for RHEL/Ubuntu node "
    "operating systems; there is no DISA STIG for Amazon EKS, and the Kubernetes "
    "STIG assumes access to control-plane component flags that a managed EKS "
    "control plane does not expose. Amazon Linux 2023 has no published DISA SCAP "
    "content. The controls evaluated here are the customer-responsibility subset "
    "that can be genuinely assessed on this platform. Control-plane hardening is "
    "an AWS-inherited control."
)

STATUS_ORDER = ["FAIL", "WARN", "INFO", "PASS"]


def load_json(path: str | None) -> Any:
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: could not read {path}: {exc}")
        return None


def parse_kube_bench(data: Any) -> tuple[list[dict], Counter, list[str]]:
    """Flatten kube-bench JSON into a list of checks, status totals, and the
    names of controls that reported no assessable tests.

    Returns (checks, totals, unassessed_controls).
    """
    checks: list[dict] = []
    totals: Counter = Counter()
    unassessed: list[str] = []

    if not data:
        return checks, totals, unassessed

    # `or []` (not `.get(..., [])`): kube-bench uses null, not a missing key.
    for control in data.get("Controls") or []:
        benchmark = control.get("text") or control.get("id") or "unknown"

        groups = control.get("tests") or []
        if not groups:
            # Expected on EKS for control-plane / master sections: AWS manages
            # those components, so they are inherited rather than assessable.
            unassessed.append(str(benchmark))
            continue

        for group in groups:
            section = group.get("desc") or group.get("section") or ""
            for check in group.get("results") or []:
                state = (check.get("test_desc") or "").strip()
                status = (check.get("status") or "INFO").upper()
                totals[status] += 1
                checks.append(
                    {
                        "benchmark": benchmark,
                        "section": section,
                        "id": check.get("test_number") or "",
                        "description": state,
                        "status": status,
                        "remediation": (check.get("remediation") or "").strip(),
                    }
                )

    return checks, totals, unassessed


def parse_trivy(data: Any) -> tuple[list[dict], Counter]:
    """Flatten Trivy Kubernetes JSON into findings plus severity totals."""
    findings: list[dict] = []
    totals: Counter = Counter()

    if not data:
        return findings, totals

    if isinstance(data, list):
        resources = data
    else:
        resources = data.get("Resources") or data.get("Misconfigurations") or []

    for resource in resources:
        if not isinstance(resource, dict):
            continue
        kind = resource.get("Kind") or ""
        name = resource.get("Name") or ""
        namespace = resource.get("Namespace") or ""
        for result in resource.get("Results") or []:
            for misconf in result.get("Misconfigurations") or []:
                severity = (misconf.get("Severity") or "UNKNOWN").upper()
                totals[severity] += 1
                findings.append(
                    {
                        "kind": kind,
                        "name": name,
                        "namespace": namespace,
                        "id": misconf.get("ID") or "",
                        "title": misconf.get("Title") or "",
                        "severity": severity,
                        "resolution": (misconf.get("Resolution") or "").strip(),
                    }
                )

    return findings, totals


def build_summary(
    bench_totals: Counter,
    trivy_totals: Counter,
    bench_checks: list[dict],
    unassessed: list[str],
) -> str:
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    total_checks = sum(bench_totals.values())
    passed = bench_totals.get("PASS", 0)
    failed = bench_totals.get("FAIL", 0)
    warned = bench_totals.get("WARN", 0)

    score = (passed / total_checks * 100) if total_checks else 0.0

    lines = [
        "=" * 72,
        "  COMPLIANCE REPORT - CIS Amazon EKS Benchmark",
        f"  Generated: {generated}",
        "=" * 72,
        "",
        "SCOPE",
        "-" * 72,
    ]

    # Wrap the scope note at 70 characters without pulling in textwrap.
    words = SCOPE_NOTE.split()
    line = ""
    for word in words:
        if len(line) + len(word) + 1 > 70:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}".strip()
    if line:
        lines.append(line)

    lines += [
        "",
        "KUBE-BENCH (CIS EKS)",
        "-" * 72,
        f"  Total checks : {total_checks}",
        f"  PASS         : {passed}",
        f"  FAIL         : {failed}",
        f"  WARN         : {warned}",
        f"  INFO         : {bench_totals.get('INFO', 0)}",
        f"  Pass rate    : {score:.1f}%",
        "",
    ]

    if unassessed:
        lines += [
            "NOT ASSESSABLE (AWS-inherited)",
            "-" * 72,
        ]
        for control in unassessed:
            lines.append(f"  - {control}")
        lines += [
            "  These sections are managed by AWS on EKS and cannot be",
            "  evaluated from inside the cluster. They are inherited",
            "  controls, not failures.",
            "",
        ]

    if failed:
        lines.append("FAILED CHECKS")
        lines.append("-" * 72)
        for check in bench_checks:
            if check["status"] == "FAIL":
                ident = check["id"] or "-"
                lines.append(f"  [{ident}] {check['description']}")
        lines.append("")

    if trivy_totals:
        lines += [
            "TRIVY (cluster misconfiguration)",
            "-" * 72,
            f"  CRITICAL     : {trivy_totals.get('CRITICAL', 0)}",
            f"  HIGH         : {trivy_totals.get('HIGH', 0)}",
            f"  MEDIUM       : {trivy_totals.get('MEDIUM', 0)}",
            f"  LOW          : {trivy_totals.get('LOW', 0)}",
            "",
        ]
    else:
        lines += [
            "TRIVY (cluster misconfiguration)",
            "-" * 72,
            "  No Trivy report available.",
            "",
        ]

    lines.append("=" * 72)
    return "\n".join(lines)


def status_colour(status: str) -> str:
    return {
        "PASS": "#1a7f37",
        "FAIL": "#cf222e",
        "WARN": "#9a6700",
        "INFO": "#57606a",
        "CRITICAL": "#cf222e",
        "HIGH": "#bc4c00",
        "MEDIUM": "#9a6700",
        "LOW": "#57606a",
    }.get(status.upper(), "#57606a")


def build_html(
    bench_checks: list[dict],
    bench_totals: Counter,
    trivy_findings: list[dict],
    trivy_totals: Counter,
    unassessed: list[str],
) -> str:
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    total_checks = sum(bench_totals.values())
    passed = bench_totals.get("PASS", 0)
    score = (passed / total_checks * 100) if total_checks else 0.0

    def esc(value: str) -> str:
        return html.escape(str(value or ""))

    rows = []
    ordered = sorted(
        bench_checks,
        key=lambda c: STATUS_ORDER.index(c["status"])
        if c["status"] in STATUS_ORDER
        else len(STATUS_ORDER),
    )
    for check in ordered:
        rows.append(
            "<tr>"
            f"<td class='mono'>{esc(check['id'])}</td>"
            f"<td>{esc(check['description'])}</td>"
            f"<td><span class='badge' style='background:{status_colour(check['status'])}'>"
            f"{esc(check['status'])}</span></td>"
            f"<td class='rem'>{esc(check['remediation'])}</td>"
            "</tr>"
        )

    trivy_rows = []
    for finding in sorted(
        trivy_findings, key=lambda f: 0 if f["severity"] == "CRITICAL" else 1
    ):
        location = f"{finding['kind']}/{finding['name']}"
        if finding["namespace"]:
            location = f"{finding['namespace']}/{location}"
        trivy_rows.append(
            "<tr>"
            f"<td class='mono'>{esc(finding['id'])}</td>"
            f"<td class='mono'>{esc(location)}</td>"
            f"<td>{esc(finding['title'])}</td>"
            f"<td><span class='badge' style='background:{status_colour(finding['severity'])}'>"
            f"{esc(finding['severity'])}</span></td>"
            "</tr>"
        )

    trivy_section = (
        "<p class='muted'>No Trivy findings at HIGH or CRITICAL severity.</p>"
        if not trivy_rows
        else (
            "<table><thead><tr><th>ID</th><th>Resource</th><th>Title</th>"
            "<th>Severity</th></tr></thead><tbody>"
            + "".join(trivy_rows)
            + "</tbody></table>"
        )
    )

    inherited_section = ""
    if unassessed:
        items = "".join(f"<li>{esc(c)}</li>" for c in unassessed)
        inherited_section = (
            "<h2>Not assessable (AWS-inherited)</h2>"
            "<p class='muted'>These benchmark sections cover components that AWS "
            "manages on EKS. They cannot be evaluated from inside the cluster and "
            "are inherited controls, not failures.</p>"
            f"<ul class='muted'>{items}</ul>"
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Compliance Report - CIS Amazon EKS Benchmark</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica,
          Arial, sans-serif; margin: 0; padding: 2rem; background: #f6f8fa;
          color: #1f2328; line-height: 1.5; }}
  .wrap {{ max-width: 1100px; margin: 0 auto; }}
  h1 {{ margin: 0 0 .25rem; font-size: 1.6rem; }}
  h2 {{ margin-top: 2.5rem; font-size: 1.2rem;
        border-bottom: 1px solid #d0d7de; padding-bottom: .4rem; }}
  .meta {{ color: #57606a; font-size: .9rem; margin-bottom: 1.5rem; }}
  .scope {{ background: #fff8c5; border: 1px solid #d4a72c;
            border-radius: 6px; padding: 1rem; font-size: .9rem;
            margin-bottom: 1.5rem; }}
  .cards {{ display: flex; gap: 1rem; flex-wrap: wrap; margin-bottom: 1rem; }}
  .card {{ background: #fff; border: 1px solid #d0d7de; border-radius: 6px;
           padding: 1rem 1.25rem; min-width: 120px; }}
  .card .n {{ font-size: 1.8rem; font-weight: 600; }}
  .card .l {{ color: #57606a; font-size: .8rem; text-transform: uppercase;
              letter-spacing: .04em; }}
  table {{ width: 100%; border-collapse: collapse; background: #fff;
           border: 1px solid #d0d7de; border-radius: 6px; overflow: hidden; }}
  th, td {{ text-align: left; padding: .6rem .8rem; font-size: .88rem;
            border-bottom: 1px solid #d0d7de; vertical-align: top; }}
  th {{ background: #f6f8fa; font-weight: 600; }}
  tr:last-child td {{ border-bottom: none; }}
  .mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
           font-size: .82rem; white-space: nowrap; }}
  .badge {{ color: #fff; padding: .12rem .5rem; border-radius: 10px;
            font-size: .75rem; font-weight: 600; }}
  .rem {{ color: #57606a; font-size: .82rem; }}
  .muted {{ color: #57606a; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>Compliance Report</h1>
  <div class="meta">CIS Amazon EKS Benchmark &middot; generated {generated}</div>

  <div class="scope"><strong>Scope.</strong> {html.escape(SCOPE_NOTE)}</div>

  <div class="cards">
    <div class="card"><div class="n">{total_checks}</div>
      <div class="l">Checks</div></div>
    <div class="card"><div class="n" style="color:#1a7f37">{passed}</div>
      <div class="l">Pass</div></div>
    <div class="card"><div class="n" style="color:#cf222e">
      {bench_totals.get('FAIL', 0)}</div><div class="l">Fail</div></div>
    <div class="card"><div class="n" style="color:#9a6700">
      {bench_totals.get('WARN', 0)}</div><div class="l">Warn</div></div>
    <div class="card"><div class="n">{score:.1f}%</div>
      <div class="l">Pass rate</div></div>
  </div>

  <h2>kube-bench results</h2>
  <table>
    <thead><tr><th>Control</th><th>Description</th><th>Status</th>
    <th>Remediation</th></tr></thead>
    <tbody>{''.join(rows) if rows else
      '<tr><td colspan="4">No kube-bench results.</td></tr>'}</tbody>
  </table>

  {inherited_section}

  <h2>Trivy cluster findings</h2>
  {trivy_section}
</div>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kube-bench", required=True)
    parser.add_argument("--trivy")
    parser.add_argument("--html-out", required=True)
    parser.add_argument("--summary-out", required=True)
    parser.add_argument("--json-out", required=True)
    args = parser.parse_args()

    bench_checks, bench_totals, unassessed = parse_kube_bench(
        load_json(args.kube_bench)
    )
    trivy_findings, trivy_totals = parse_trivy(load_json(args.trivy))

    # A report with zero evaluated controls is not a compliance report. This
    # is a genuine tooling failure (scanner produced no assessable output),
    # distinct from a report that contains FAIL findings — findings are the
    # report's CONTENT and must never fail the stage.
    if not bench_checks:
        print(
            "ERROR: kube-bench produced no assessable controls. "
            "Check the --benchmark value against the benchmarks the image "
            "ships, and review the kube-bench pod logs above."
        )
        return 1

    summary = build_summary(bench_totals, trivy_totals, bench_checks, unassessed)
    with open(args.summary_out, "w", encoding="utf-8") as handle:
        handle.write(summary + "\n")

    with open(args.html_out, "w", encoding="utf-8") as handle:
        handle.write(
            build_html(
                bench_checks,
                bench_totals,
                trivy_findings,
                trivy_totals,
                unassessed,
            )
        )

    machine_readable = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "scope": SCOPE_NOTE,
        "kube_bench": dict(bench_totals),
        "trivy": dict(trivy_totals),
        "unassessed_controls": unassessed,
        "failed_checks": [c for c in bench_checks if c["status"] == "FAIL"],
    }
    with open(args.json_out, "w", encoding="utf-8") as handle:
        json.dump(machine_readable, handle, indent=2)

    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
