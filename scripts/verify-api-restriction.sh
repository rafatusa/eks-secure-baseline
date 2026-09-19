#!/usr/bin/env bash
#
# Verify the EKS API server's public access allowlist does not contain an
# open CIDR.
#
# WHY: the hardening claim of this project is "the API endpoint is reachable
# only from one administrative host". A claim nobody checks is a claim that
# quietly stops being true — for example if a future change reintroduces
# 0.0.0.0/0, or if a previous run's temporary CI grant was never revoked.
# This turns that claim into a gate.
#
# NOTE: this runs INSIDE the temporary-access window, so the runner's own
# /32 is expected to be present. It is tolerated (and reported) because the
# wrapper removes it on exit; only genuinely OPEN ranges fail the build.
#
# Usage: verify-api-restriction.sh <cluster-name> <region>

set -euo pipefail

CLUSTER="${1:?cluster name required}"
REGION="${2:?region required}"

echo "::add-mask::${CLUSTER}"

CIDRS="$(aws eks describe-cluster \
  --name "${CLUSTER}" \
  --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs[]' \
  --output text)"

PRIVATE="$(aws eks describe-cluster \
  --name "${CLUSTER}" \
  --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' \
  --output text)"

echo "Public access CIDRs : ${CIDRS}"
echo "Private access      : ${PRIVATE}"

FAILED=0

for cidr in ${CIDRS}; do
  case "${cidr}" in
    0.0.0.0/0|::/0)
      echo "FAIL: API server endpoint is open to ${cidr}" >&2
      FAILED=1
      ;;
  esac

  # Reject broad ranges too: a /8 is not meaningfully more restricted than
  # an open endpoint. Anything /24 or narrower is accepted.
  prefix="${cidr##*/}"
  if [ -n "${prefix}" ] && [ "${prefix}" -lt 24 ] 2>/dev/null; then
    echo "FAIL: API server allowlist entry ${cidr} is broader than /24" >&2
    FAILED=1
  fi
done

if [ "${PRIVATE}" != "True" ] && [ "${PRIVATE}" != "true" ]; then
  echo "FAIL: private endpoint access is disabled; in-cluster API traffic would traverse the internet" >&2
  FAILED=1
fi

if [ "${FAILED}" -ne 0 ]; then
  echo "API endpoint restriction check FAILED." >&2
  exit 1
fi

echo "PASS: API server endpoint is restricted to specific hosts and private access is enabled."
