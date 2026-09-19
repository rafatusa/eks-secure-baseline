#!/usr/bin/env bash
#
# Apply the hardening baseline to the cluster.
#
# Invoked through scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and configured kubectl. Do not call
# `aws eks update-kubeconfig` here — the wrapper owns that.

set -euo pipefail

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

echo "Cluster configuration complete (hardening baseline applied)."
