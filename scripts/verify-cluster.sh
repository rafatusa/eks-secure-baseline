#!/usr/bin/env bash
#
# Verify the deployed cluster is healthy AND that the hardening controls are
# actually enforced — not merely applied.
#
# Invoked through scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and configured kubectl.
#
# Usage: verify-cluster.sh <cluster-name> <region>

set -euo pipefail

CLUSTER="${1:?cluster name required}"
REGION="${2:?region required}"

echo "::add-mask::${CLUSTER}"

echo "::group::Cluster health"
kubectl get nodes -o wide
echo "::endgroup::"

echo "::group::Control plane readiness"
kubectl get --raw='/readyz?verbose'
echo "::endgroup::"

echo "::group::Hardening objects present"
kubectl get networkpolicy,resourcequota -A
echo "::endgroup::"

echo "::group::Pod Security Admission enforcement"
bash scripts/verify-pss.sh
echo "::endgroup::"

echo "::group::API endpoint restriction"
bash scripts/verify-api-restriction.sh "${CLUSTER}" "${REGION}"
echo "::endgroup::"

echo "All verification checks passed."
