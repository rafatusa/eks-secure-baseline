#!/usr/bin/env bash
#
# Delete Kubernetes-created AWS load balancers BEFORE terraform destroy.
#
# WHY THIS EXISTS
# ---------------
# Services of type LoadBalancer (and Ingress objects) cause the in-cluster
# controller to create AWS load balancers and security groups that terraform
# never records in state. `terraform destroy` therefore leaves them behind,
# where they:
#   * continue billing (~$16/month per ALB, plus Elastic IP charges), and
#   * hold ENIs in the VPC subnets, so DeleteVpc fails with
#     DependencyViolation and the whole teardown stalls.
#
# This was observed first-hand in this AWS account: two orphaned ALBs
# (k8s-argocd-*, k8s-appdev-*) plus three security groups survived a deleted
# EKS cluster and blocked VPC deletion, alongside 14 orphaned target groups
# spread across 11 long-deleted VPCs.
#
# Deleting the Services first lets the controller remove its own AWS
# resources cleanly, which is the only reliable ordering.
set -euo pipefail

WAIT_SECONDS=300
POLL_INTERVAL=10
REGION="${AWS_REGION:-us-east-1}"

# The cluster may already be gone (for example, resuming a partial teardown).
# That is not an error — there is simply nothing to clean up.
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "==> Cluster is not reachable; skipping in-cluster cleanup."
  echo "    (Normal when resuming a teardown that already removed the cluster.)"
  exit 0
fi

echo "==> Looking for LoadBalancer-type Services"
LB_SERVICES="$(kubectl get services --all-namespaces \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
  2>/dev/null || echo "")"

if [ -z "${LB_SERVICES}" ]; then
  echo "    None found."
else
  # Here-string instead of a pipe: a piped while-loop runs in a subshell,
  # which silently discards any state it sets.
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    namespace="${entry%%/*}"
    name="${entry##*/}"
    echo "    Deleting service ${namespace}/${name}"
    kubectl delete service "${name}" -n "${namespace}" \
      --ignore-not-found=true --timeout=120s || true
  done <<< "${LB_SERVICES}"
fi

echo "==> Looking for Ingress resources"
INGRESSES="$(kubectl get ingress --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
  2>/dev/null || echo "")"

if [ -z "${INGRESSES}" ]; then
  echo "    None found."
else
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    namespace="${entry%%/*}"
    name="${entry##*/}"
    echo "    Deleting ingress ${namespace}/${name}"
    kubectl delete ingress "${name}" -n "${namespace}" \
      --ignore-not-found=true --timeout=120s || true
  done <<< "${INGRESSES}"
fi

echo "==> Waiting up to ${WAIT_SECONDS}s for AWS load balancers to disappear"
# scripts/tf-output.sh rather than a bare `terraform output -raw vpc_id`:
# that command exits 0 and prints the placeholder `<vpc_id>` when the state
# has no outputs, so `|| echo ""` does not catch it. The placeholder would
# then be used as a VpcId filter below, matching nothing, and this loop
# would report "all load balancers are gone" without having checked
# anything — a false all-clear on the exact failure this script prevents.
VPC_ID="$(bash scripts/tf-output.sh vpc_id infra)"

if [ -z "${VPC_ID}" ]; then
  echo "    No vpc_id in terraform state; skipping the wait."
  exit 0
fi

elapsed=0
while [ "${elapsed}" -lt "${WAIT_SECONDS}" ]; do
  # ALB/NLB (elbv2) and classic ELB (elb) are separate APIs — check both.
  remaining="$(aws elbv2 describe-load-balancers \
    --region "${REGION}" \
    --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" \
    --output text 2>/dev/null || echo "0")"

  remaining_classic="$(aws elb describe-load-balancers \
    --region "${REGION}" \
    --query "length(LoadBalancerDescriptions[?VPCId=='${VPC_ID}'])" \
    --output text 2>/dev/null || echo "0")"

  if [ "${remaining}" = "0" ] && [ "${remaining_classic}" = "0" ]; then
    echo "    All load balancers in ${VPC_ID} are gone."
    exit 0
  fi

  echo "    ${remaining} ALB/NLB and ${remaining_classic} classic LB remaining; waiting..."
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

# Do not hard-fail: terraform destroy should still run and remove what it owns.
# A warning here tells the operator exactly what to check afterwards.
echo "!! WARNING: load balancers still present in ${VPC_ID} after ${WAIT_SECONDS}s." >&2
echo "!! terraform destroy may fail with DependencyViolation on the VPC." >&2
echo "!! If it does, delete the remaining load balancers and re-run destroy." >&2
