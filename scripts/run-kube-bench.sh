#!/usr/bin/env bash
#
# Run the kube-bench CIS EKS Benchmark scan and collect its JSON output.
#
# Exits non-zero only on operational failure (job could not run). Compliance
# FINDINGS do not fail this script — generate-report.sh decides what is
# acceptable, so that a single FAIL does not hide the rest of the report.
set -euo pipefail

NAMESPACE="kube-bench"
JOB_NAME="kube-bench"
MANIFEST="k8s/compliance/kube-bench-job.yaml"
REPORT_DIR="reports"
TIMEOUT_SECONDS=600

mkdir -p "${REPORT_DIR}"

echo "==> Removing any previous kube-bench job"
# Jobs are immutable: a re-apply over an existing job fails. Delete first.
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found=true --wait=true

echo "==> Launching kube-bench (CIS EKS Benchmark)"
kubectl apply -f "${MANIFEST}"

echo "==> Waiting up to ${TIMEOUT_SECONDS}s for the scan to finish"
if ! kubectl wait --for=condition=complete "job/${JOB_NAME}" \
  -n "${NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s"; then

  echo "!! kube-bench job did not complete within ${TIMEOUT_SECONDS}s" >&2
  echo "--- job description ---" >&2
  kubectl describe "job/${JOB_NAME}" -n "${NAMESPACE}" >&2 || true
  echo "--- pod logs (if any) ---" >&2
  kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=200 >&2 || true
  exit 1
fi

echo "==> Collecting results"
POD_NAME="$(kubectl get pods -n "${NAMESPACE}" \
  --selector=job-name="${JOB_NAME}" \
  -o jsonpath='{.items[0].metadata.name}')"

if [ -z "${POD_NAME}" ]; then
  echo "!! Could not locate the kube-bench pod" >&2
  exit 1
fi

kubectl logs "${POD_NAME}" -n "${NAMESPACE}" > "${REPORT_DIR}/kube-bench-raw.json"

# kube-bench writes a banner line before the JSON payload on some versions.
# Keep only from the first '{' so the file is parseable regardless.
if ! grep -q '^{' "${REPORT_DIR}/kube-bench-raw.json"; then
  echo "==> Stripping non-JSON preamble from kube-bench output"
  sed -n '/^{/,$p' "${REPORT_DIR}/kube-bench-raw.json" > "${REPORT_DIR}/kube-bench.json"
else
  cp "${REPORT_DIR}/kube-bench-raw.json" "${REPORT_DIR}/kube-bench.json"
fi

# Fail loudly if the output is not valid JSON — a silently corrupt report is
# worse than no report.
if ! python3 -c "import json,sys; json.load(open('${REPORT_DIR}/kube-bench.json'))" 2>/dev/null; then
  echo "!! kube-bench output is not valid JSON. Raw output follows:" >&2
  cat "${REPORT_DIR}/kube-bench-raw.json" >&2
  exit 1
fi

echo "==> kube-bench scan complete: ${REPORT_DIR}/kube-bench.json"
