#!/usr/bin/env bash
#
# Apply the hardening baseline and the compliance scanning resources.
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

echo "::group::Applying compliance scanning resources"
kubectl apply -f k8s/compliance/
echo "::endgroup::"

echo "Cluster configuration complete."
