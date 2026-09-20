#!/usr/bin/env bash
#
# Install / upgrade the AWS Load Balancer Controller.
#
# Invoked through scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and configured kubectl. Do not call
# `aws eks update-kubeconfig` here — the wrapper owns that.
#
# WHAT THE CONTROLLER DOES
# ------------------------
# It watches Ingress resources and provisions real AWS Application Load
# Balancers in response. It never carries application traffic itself: it only
# programs AWS. That distinction drives the NetworkPolicy design — with
# target-type=ip the ALB connects to pod IPs directly from its own ENIs, so
# there is no controller pod in the data path to select on.
#
# TWO DIFFERENT VERSION IDENTIFIERS — DO NOT CONFLATE THEM
# --------------------------------------------------------
#   CHART_VERSION  3.5.0     the Helm chart version (helm --version)
#   CHARTS_REPO_TAG v0.0.244 the aws/eks-charts GIT TAG holding that chart
#
# The eks-charts repository tags releases as v0.0.N, which has NOTHING to do
# with the chart version inside it. Building a raw.githubusercontent URL from
# the chart version produces a 404, and the CRD apply below then fails with a
# "no matches for kind" error later that points nowhere near the real cause.
#
# Both values were verified against the upstream repository before being
# committed (tag v0.0.244 contains Chart.yaml version 3.5.0, appVersion
# v3.5.0). This project has twice lost a deploy cycle to an identifier that
# was assumed rather than checked; pinned versions get verified, never
# guessed.

set -euo pipefail

CHART_VERSION="3.5.0"
CHARTS_REPO_TAG="v0.0.244"
NAMESPACE="kube-system"
RELEASE="aws-load-balancer-controller"
SERVICE_ACCOUNT="aws-load-balancer-controller"

CLUSTER_NAME="${1:?usage: install-alb-controller.sh <cluster-name> <region>}"
REGION="${2:?region required}"

echo "::add-mask::${CLUSTER_NAME}"

echo "==> Reading controller IAM role and VPC from terraform state"
ROLE_ARN="$(cd infra && terraform output -raw alb_controller_role_arn)"
VPC_ID="$(cd infra && terraform output -raw vpc_id)"

if [ -z "${ROLE_ARN}" ] || [ -z "${VPC_ID}" ]; then
  echo "ERROR: could not read alb_controller_role_arn / vpc_id from state" >&2
  exit 1
fi
# The role ARN contains the account id and the project name.
echo "::add-mask::${ROLE_ARN}"

echo "==> Installing CRDs (chart ${CHART_VERSION}, repo tag ${CHARTS_REPO_TAG})"
# Helm installs CRDs ONLY on first install and never updates them on upgrade.
# Applying them explicitly is the documented upgrade path; skipping it is why
# a controller upgrade can start rejecting TargetGroupBinding resources it
# previously accepted.
kubectl apply --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/aws/eks-charts/${CHARTS_REPO_TAG}/stable/aws-load-balancer-controller/crds/crds.yaml"

echo "==> Adding the eks-charts repository"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null

echo "==> Installing/upgrading ${RELEASE} (chart ${CHART_VERSION})"
# `upgrade --install` is idempotent: first run installs, subsequent runs
# reconcile. The configure stage runs on every deploy, so this must be safe
# to re-run against an existing healthy release.
#
# vpcId is set explicitly rather than left to metadata-service discovery:
# discovery works, but naming it removes a runtime dependency and makes the
# binding to THIS VPC visible in the release values.
helm upgrade --install "${RELEASE}" eks/aws-load-balancer-controller \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --set "clusterName=${CLUSTER_NAME}" \
  --set "region=${REGION}" \
  --set "vpcId=${VPC_ID}" \
  --set "serviceAccount.create=true" \
  --set "serviceAccount.name=${SERVICE_ACCOUNT}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ROLE_ARN}" \
  --set "replicaCount=2" \
  --wait \
  --timeout 10m

echo "==> Waiting for the controller deployment to be available"
kubectl rollout status "deployment/${RELEASE}" -n "${NAMESPACE}" --timeout=300s

echo "==> Verifying the service account is annotated for IRSA"
# Without this annotation the controller falls back to the node instance
# role, which does not carry the ELB permissions. The symptom is an Ingress
# that never gets an address, with AccessDenied buried in the controller log
# — so assert it here, where the message can be explicit.
ANNOTATED="$(kubectl get serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")"

if [ -z "${ANNOTATED}" ]; then
  echo "ERROR: service account ${SERVICE_ACCOUNT} has no IRSA role annotation." >&2
  echo "       The controller would authenticate as the node role and fail" >&2
  echo "       to provision any load balancer." >&2
  exit 1
fi
echo "    IRSA annotation present."

echo "==> Verifying the IngressClass exists"
# Without an 'alb' IngressClass the controller ignores every Ingress that
# names it — silently, with no event and no error.
if ! kubectl get ingressclass alb >/dev/null 2>&1; then
  echo "ERROR: IngressClass 'alb' was not created by the chart." >&2
  kubectl get ingressclass || true
  exit 1
fi
echo "    IngressClass 'alb' present."

echo "AWS Load Balancer Controller ready."
