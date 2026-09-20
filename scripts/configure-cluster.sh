#!/usr/bin/env bash
#
# Apply the hardening baseline to the cluster.
#
# Invoked through scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and configured kubectl. Do not call
# `aws eks update-kubeconfig` here — the wrapper owns that.
#
# USAGE
#   bash scripts/configure-cluster.sh <cluster-name> <region>

set -euo pipefail

CLUSTER_NAME="${1:?usage: configure-cluster.sh <cluster-name> <region>}"
REGION="${2:?region required}"

echo "::add-mask::${CLUSTER_NAME}"

echo "::group::Waiting for nodes to become Ready"
# The managed node group reports ACTIVE before kubelets have registered, so
# terraform finishing is not the same as the cluster being schedulable.
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get nodes -o wide
echo "::endgroup::"

echo "::group::Applying hardening baseline"
# Namespaces first: the quotas, network policies and RBAC below are all
# namespaced objects and a single `apply -f dir/` does not guarantee
# ordering within the directory.
kubectl apply -f k8s/hardening/namespace.yaml
kubectl apply -f k8s/hardening/
echo "::endgroup::"

echo "::group::Installing the AWS Load Balancer Controller"
# Platform capability, not application deployment.
#
# WHY IT LIVES IN configure AND NOT IN THE APP PIPELINE
# -----------------------------------------------------
# The controller is cluster infrastructure: it is the component that turns an
# Ingress resource into a real ALB. Installing it here means the app pipeline
# can deploy and roll back application versions without ever touching
# cluster-wide components or re-running terraform, which is the entire point
# of keeping the two pipelines separate.
#
# It is also idempotent (`helm upgrade --install`), so running it on every
# deploy reconciles drift rather than conflicting with an existing release.
bash scripts/install-alb-controller.sh "${CLUSTER_NAME}" "${REGION}"
echo "::endgroup::"

# ---------------------------------------------------------------------------
# k8s/compliance/ IS DELIBERATELY NOT APPLIED HERE
# ---------------------------------------------------------------------------
# It contains ONLY the kube-bench Job, which is a SCAN INVOCATION rather than
# part of the cluster's baseline configuration. scripts/run-kube-bench.sh
# owns its entire lifecycle — delete, apply, wait, collect results — and the
# compliance stage calls it on every run.
#
# An earlier revision applied it here as well. That made TWO callers own one
# object, and it broke the deploy: Kubernetes Jobs are IMMUTABLE, so once a
# Job exists, `kubectl apply` of a CHANGED spec.template is rejected with
#
#     The Job "kube-bench" is invalid: spec.template: Invalid value: ...
#
# The previous run's Job survives for ttlSecondsAfterFinished (1 hour), so
# any edit to the Job spec broke the very next deploy inside that window,
# while a deploy more than an hour later would have succeeded — an
# intermittent failure that depends on wall-clock timing between runs.
#
# run-kube-bench.sh deletes the Job before applying, which is the correct
# pattern for an immutable resource. Creating it here too added nothing:
# configure does not wait for it, read its results, or report on it.
#
# If a future change needs a non-Job resource under k8s/compliance/ (a
# ConfigMap of custom controls, say), apply THAT FILE explicitly here —
# do not re-add a blanket `kubectl apply -f k8s/compliance/`.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# k8s/app/ IS ALSO NOT APPLIED HERE — for a different reason.
# ---------------------------------------------------------------------------
# The application manifests carry IMAGE_PLACEHOLDER, which is substituted with
# a real ECR reference by scripts/deploy-app.sh. They are not applicable as
# committed, and the app-deploy pipeline owns them end to end. Applying them
# here would both fail and re-couple application releases to the baseline
# deploy that the separate pipeline exists to avoid.
# ---------------------------------------------------------------------------

echo "Cluster configuration complete (hardening baseline + load balancer controller)."
