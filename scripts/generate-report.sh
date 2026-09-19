#!/usr/bin/env bash
#
# Turn the raw kube-bench and Trivy JSON into a readable compliance report.
# Produces:
#   reports/compliance-report.html  - full report for humans
#   reports/summary.txt             - terminal summary printed in the CI log
set -euo pipefail

REPORT_DIR="reports"
mkdir -p "${REPORT_DIR}"

if [ ! -f "${REPORT_DIR}/kube-bench.json" ]; then
  echo "!! Missing ${REPORT_DIR}/kube-bench.json — run run-kube-bench.sh first" >&2
  exit 1
fi

echo "==> Generating compliance report"
python3 scripts/build_report.py \
  --kube-bench "${REPORT_DIR}/kube-bench.json" \
  --trivy "${REPORT_DIR}/trivy-cluster.json" \
  --html-out "${REPORT_DIR}/compliance-report.html" \
  --summary-out "${REPORT_DIR}/summary.txt" \
  --json-out "${REPORT_DIR}/compliance-summary.json"

echo "==> Report written to ${REPORT_DIR}/"
ls -la "${REPORT_DIR}/"
