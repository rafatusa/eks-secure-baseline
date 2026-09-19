#!/usr/bin/env bash
#
# Run a command with TEMPORARY access to the EKS API server, then always
# restore the locked-down allowlist.
#
# WHY THIS EXISTS
# ---------------
# The cluster's public_access_cidrs is locked to a single administrative
# host (/32). GitHub-hosted runners have ephemeral public IPs drawn from
# large, frequently-changing ranges, so there is no static CIDR we could
# add without effectively reopening the endpoint. Permanently allowlisting
# GitHub's published ranges would admit every GitHub Actions runner on the
# platform, not just ours — a far weaker posture than it appears.
#
# So each kubectl-using job grants ITSELF a /32 for the duration of the job
# and removes it afterwards. Steady-state exposure stays at one host, and
# the widened window is bounded by the job runtime.
#
# WHY A WRAPPER RATHER THAN grant/revoke STEPS
# --------------------------------------------
# The platform's pipeline spec has no step-level `if:` key, so an
# always()-style revoke step cannot be expressed. A plain "grant ... then
# revoke" pair of steps would leak the runner IP onto the allowlist
# permanently whenever a middle step failed — a security regression
# introduced by the very mechanism meant to harden the endpoint.
#
# A `trap ... EXIT` inside ONE step is strictly stronger than always():
# it fires on success, on failure, on `set -e` abort, and on SIGTERM when
# the job is cancelled or times out.
#
# USAGE
#   bash scripts/ci-api-access.sh <cluster-name> <region> <base-cidr> -- <command...>
#
# The allowlist is always reset to exactly <base-cidr>, which makes this
# idempotent and self-healing: even if a previous run died in a way that
# skipped the trap, the next run's reset restores the intended state.
#
# NOTE ON EVENTUAL CONSISTENCY: an EKS vpc-config update only takes effect
# once the cluster leaves UPDATING status, so both operations wait for
# ACTIVE. Issuing kubectl against a not-yet-applied allowlist fails with an
# opaque I/O timeout that looks like a networking bug.

set -euo pipefail

CLUSTER="${1:?usage: ci-api-access.sh <cluster> <region> <base-cidr> -- <command...>}"
REGION="${2:?region required}"
BASE_CIDR="${3:?base cidr required}"
SEPARATOR="${4:?expected -- before the command}"
shift 4

if [ "${SEPARATOR}" != "--" ]; then
  echo "ERROR: expected '--' before the command, got '${SEPARATOR}'" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "ERROR: no command given after --" >&2
  exit 1
fi

# The cluster name derives from PROJECT_NAME, which is a secret.
echo "::add-mask::${CLUSTER}"

wait_for_active() {
  local attempt=0
  local status
  while [ "${attempt}" -lt 60 ]; do
    status="$(aws eks describe-cluster \
      --name "${CLUSTER}" \
      --region "${REGION}" \
      --query 'cluster.status' \
      --output text 2>/dev/null || echo "UNKNOWN")"
    if [ "${status}" = "ACTIVE" ]; then
      return 0
    fi
    echo "cluster status=${status}; waiting for ACTIVE (attempt $((attempt + 1))/60)"
    sleep 10
    attempt=$((attempt + 1))
  done
  echo "ERROR: cluster did not reach ACTIVE within 10 minutes" >&2
  return 1
}

apply_cidrs() {
  local cidrs="$1"
  wait_for_active
  aws eks update-cluster-config \
    --name "${CLUSTER}" \
    --region "${REGION}" \
    --resources-vpc-config "publicAccessCidrs=${cidrs},endpointPublicAccess=true,endpointPrivateAccess=true" \
    >/dev/null
  wait_for_active
}

revoke() {
  # Runs from the EXIT trap. Must never change the script's exit status:
  # the wrapped command's result is what the pipeline stage reports.
  local rc=$?
  echo "::group::Restoring API allowlist to the administrative host"
  if aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" >/dev/null 2>&1; then
    if apply_cidrs "${BASE_CIDR}"; then
      echo "Allowlist restored to ${BASE_CIDR} (administrative host only)."
    else
      # Loud, because a failed revoke leaves the endpoint wider than intended.
      echo "WARNING: failed to restore the API allowlist. The runner IP may" >&2
      echo "still be permitted. Re-run the pipeline, or reset manually with:" >&2
      echo "  aws eks update-cluster-config --name <cluster> --region ${REGION} \\" >&2
      echo "    --resources-vpc-config publicAccessCidrs=${BASE_CIDR},endpointPublicAccess=true,endpointPrivateAccess=true" >&2
    fi
  else
    echo "Cluster not found; nothing to revoke."
  fi
  echo "::endgroup::"
  exit "${rc}"
}

# Resolve the runner's own egress IP. Two independent providers so a single
# endpoint outage does not fail the deploy; -f so an HTTP error page is
# never mistaken for an address.
RUNNER_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null || true)"
RUNNER_IP="$(printf '%s' "${RUNNER_IP}" | tr -d '[:space:]')"

if [ -z "${RUNNER_IP}" ]; then
  RUNNER_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  RUNNER_IP="$(printf '%s' "${RUNNER_IP}" | tr -d '[:space:]')"
fi

if ! printf '%s' "${RUNNER_IP}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  echo "ERROR: could not determine runner public IP (got '${RUNNER_IP}')" >&2
  exit 1
fi

echo "Granting temporary API access to runner ${RUNNER_IP}/32 (base: ${BASE_CIDR})"

# Arm the trap BEFORE widening the allowlist, so an interrupt between the
# grant and the command still restores the locked-down state.
trap revoke EXIT INT TERM

apply_cidrs "${BASE_CIDR},${RUNNER_IP}/32"
echo "Temporary access granted; running wrapped command."

# Configure kubectl inside the access window so every caller gets a working
# kubeconfig without repeating this in each stage.
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER}"

"$@"
