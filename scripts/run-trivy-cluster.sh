#!/usr/bin/env bash
#
# Trivy cluster scan: Kubernetes misconfiguration checks against the LIVE
# cluster, complementing kube-bench's node/CIS focus.
#
# kube-bench answers "is the node and cluster configured per CIS?".
# Trivy answers "are the workloads running on it configured safely?".
set -euo pipefail

REPORT_DIR="reports"
mkdir -p "${REPORT_DIR}"

echo "==> Annotating the compliance service account with its IRSA role"
# Read the role ARN from terraform state rather than hardcoding it: the ARN
# embeds the account id and project name.
ROLE_ARN="$(cd infra && terraform output -raw compliance_scanner_role_arn)"

if [ -n "${ROLE_ARN}" ]; then
  kubectl annotate serviceaccount compliance-scanner \
    -n compliance \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite
fi

# ---------------------------------------------------------------------------
# DO NOT PASS A POSITIONAL ARGUMENT HERE (this cost a failed compliance stage)
# ---------------------------------------------------------------------------
# An earlier revision ended this command with a bare `cluster`, intending it
# to mean "scan the whole cluster". It does not. In `trivy kubernetes` that
# positional is a KUBECONFIG CONTEXT NAME, so Trivy went looking for a
# context literally called "cluster" and died with:
#
#     FATAL  failed getting k8s cluster: context "cluster" does not exist
#
# `aws eks update-kubeconfig` names its context after the cluster ARN
# (arn:aws:eks:<region>:<account>:cluster/<name>), so that context never
# existed. With no positional, Trivy scans the kubeconfig's CURRENT context,
# which scripts/ci-api-access.sh has already selected. That is also why this
# script must NOT run `aws eks update-kubeconfig` itself — the access wrapper
# owns kubeconfig setup for the whole stage.
#
# Deliberately not hardcoding a context name: it would re-break the moment
# the cluster or region changes.
# ---------------------------------------------------------------------------
echo "==> Running Trivy Kubernetes misconfiguration scan (current context)"
kubectl config current-context

# --report all gives per-resource detail rather than a bare summary.
# Scoped to cluster-wide resources; this does NOT pull every image, which
# would take far longer than the stage timeout allows.
trivy kubernetes \
  --report all \
  --scanners misconfig,rbac \
  --severity HIGH,CRITICAL \
  --format json \
  --output "${REPORT_DIR}/trivy-cluster.json" \
  --timeout 15m || {
  echo "!! Trivy cluster scan failed" >&2
  exit 1
}

if [ ! -s "${REPORT_DIR}/trivy-cluster.json" ]; then
  echo "!! Trivy produced an empty report" >&2
  exit 1
fi

if ! python3 -c "import json,sys; json.load(open('${REPORT_DIR}/trivy-cluster.json'))" 2>/dev/null; then
  echo "!! Trivy output is not valid JSON" >&2
  exit 1
fi

echo "==> Trivy cluster scan complete: ${REPORT_DIR}/trivy-cluster.json"
