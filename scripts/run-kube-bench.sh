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

# ---------------------------------------------------------------------------
# WAIT FOR *EITHER* TERMINAL CONDITION — NOT JUST 'complete'
# ---------------------------------------------------------------------------
# `kubectl wait --for=condition=complete` does NOT return when a Job FAILS:
# it blocks until the timeout expires. Combined with backoffLimit: 0 that
# turned a pod which died in ~2 seconds ("No targets configured for
# eks-1.5.0") into a 600-second stage hang that buried the real error at the
# bottom of a timeout message.
#
# Racing both conditions in the background and taking whichever resolves
# first means a failed scan is reported in seconds, with its pod logs, while
# a healthy scan still gets the full timeout budget to finish.
# ---------------------------------------------------------------------------
echo "==> Waiting up to ${TIMEOUT_SECONDS}s for the scan to reach a terminal state"

kubectl wait --for=condition=complete "job/${JOB_NAME}" \
  -n "${NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null 2>&1 &
COMPLETE_PID=$!

kubectl wait --for=condition=failed "job/${JOB_NAME}" \
  -n "${NAMESPACE}" --timeout="${TIMEOUT_SECONDS}s" >/dev/null 2>&1 &
FAILED_PID=$!

JOB_OUTCOME="timeout"
if wait -n "${COMPLETE_PID}" "${FAILED_PID}" 2>/dev/null; then
  # Whichever wait returned 0 won the race. Determine which condition it was
  # from the Job itself rather than inferring it from the pid.
  if [ "$(kubectl get "job/${JOB_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)" = "True" ]; then
    JOB_OUTCOME="complete"
  elif [ "$(kubectl get "job/${JOB_NAME}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = "True" ]; then
    JOB_OUTCOME="failed"
  fi
fi

# Stop the loser so it cannot linger for the rest of the timeout.
kill "${COMPLETE_PID}" "${FAILED_PID}" 2>/dev/null || true
wait "${COMPLETE_PID}" 2>/dev/null || true
wait "${FAILED_PID}" 2>/dev/null || true

if [ "${JOB_OUTCOME}" != "complete" ]; then
  if [ "${JOB_OUTCOME}" = "failed" ]; then
    echo "!! kube-bench job FAILED (this is a tooling failure, not a finding)" >&2
  else
    echo "!! kube-bench job did not reach a terminal state within ${TIMEOUT_SECONDS}s" >&2
  fi

  # The pod logs carry the actual reason (bad benchmark name, unreadable
  # host path, image pull failure). Print them FIRST — they are what a human
  # actually needs, and they were previously buried under the job dump.
  echo "--- pod logs ---" >&2
  kubectl logs "job/${JOB_NAME}" -n "${NAMESPACE}" --tail=200 >&2 2>/dev/null || \
    echo "(no pod logs available)" >&2

  echo "--- job description ---" >&2
  kubectl describe "job/${JOB_NAME}" -n "${NAMESPACE}" >&2 || true
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
