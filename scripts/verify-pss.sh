#!/usr/bin/env bash
#
# Assert that the hardening baseline is actually in force.
# A manifest that was applied is not the same as a policy that is enforced —
# this script checks the live cluster state and fails the verify stage if a
# control is missing.
set -euo pipefail

FAILURES=0

check() {
  local description="$1"
  local actual="$2"
  local expected="$3"

  if [ "${actual}" = "${expected}" ]; then
    printf '  PASS  %s\n' "${description}"
  else
    printf '  FAIL  %s (expected %q, got %q)\n' \
      "${description}" "${expected}" "${actual}"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "==> Verifying Pod Security Admission enforcement"

for ns in default compliance; do
  value="$(kubectl get namespace "${ns}" \
    -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' \
    2>/dev/null || echo "")"
  check "namespace/${ns} enforces 'restricted'" "${value}" "restricted"
done

echo "==> Verifying default-deny NetworkPolicies"

for ns in default compliance; do
  value="$(kubectl get networkpolicy default-deny-all -n "${ns}" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")"
  check "namespace/${ns} has default-deny-all" "${value}" "default-deny-all"
done

echo "==> Verifying no cluster-admin bindings to workload service accounts"

# A ServiceAccount bound to cluster-admin defeats every other control here.
# The filter is done with jsonpath + grep rather than an embedded Python
# heredoc: quoting a Python program inside a bash string is a reliable source
# of subtle escaping bugs.
CLUSTER_ADMIN_SUBJECTS="$(kubectl get clusterrolebindings -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{range .subjects[*]}{.kind}{"|"}{.namespace}{"|"}{.name}{"\n"}{end}{end}' 2>/dev/null || echo "")"

BAD_BINDINGS=""
while IFS= read -r line; do
  [ -z "${line}" ] && continue

  kind="${line%%|*}"
  rest="${line#*|}"
  namespace="${rest%%|*}"
  name="${rest#*|}"

  # Only ServiceAccounts matter here; user/group bindings are an operator
  # concern rather than a workload privilege-escalation path.
  [ "${kind}" != "ServiceAccount" ] && continue

  # The EKS control plane legitimately binds service accounts in kube-system.
  [ "${namespace}" = "kube-system" ] && continue

  BAD_BINDINGS="${BAD_BINDINGS}${namespace}/${name} "
done <<< "${CLUSTER_ADMIN_SUBJECTS}"

# Trim trailing whitespace so the comparison against "" is exact.
BAD_BINDINGS="${BAD_BINDINGS% }"

check "no workload ServiceAccount bound to cluster-admin" \
  "${BAD_BINDINGS}" ""

echo "==> Verifying ResourceQuota is present"

value="$(kubectl get resourcequota compliance-quota -n compliance \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")"
check "namespace/compliance has a ResourceQuota" \
  "${value}" "compliance-quota"

echo "==> Verifying nodes are not publicly addressable"

# Nodes live in private subnets, so no node should report an ExternalIP.
PUBLIC_IPS="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="ExternalIP")]}{.address}{" "}{end}{end}' \
  2>/dev/null || echo "")"
PUBLIC_IPS="$(echo "${PUBLIC_IPS}" | tr -s ' ' | sed 's/^ *//;s/ *$//')"

check "no node has an ExternalIP" "${PUBLIC_IPS}" ""

echo ""
if [ "${FAILURES}" -gt 0 ]; then
  echo "!! ${FAILURES} hardening check(s) failed" >&2
  exit 1
fi

echo "All hardening checks passed."
