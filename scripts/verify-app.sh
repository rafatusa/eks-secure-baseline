#!/usr/bin/env bash
#
# Verify the application is genuinely reachable through the public ALB.
#
# Called INSIDE scripts/ci-api-access.sh (kubeconfig is already configured).
#
# WHY THE HOSTNAME IS READ HERE RATHER THAN PASSED IN
# ---------------------------------------------------
# The ALB DNS name embeds the project name, and PROJECT_NAME is a repository
# secret. GitHub SILENTLY DROPS any job output whose value contains a secret
# substring — the downstream job receives an empty string and the failure
# looks like a missing load balancer rather than a masking rule. Reading it
# from the cluster in the job that needs it sidesteps the whole problem.
#
# WHY IT POLLS TWICE, FOR DIFFERENT THINGS
# ----------------------------------------
# 1. The Ingress ADDRESS appears only once the controller has created the
#    ALB: roughly 30-90s, and it is empty until then.
# 2. The ALB then has to register targets and pass two consecutive health
#    checks before it stops returning 503: a further 1-3 minutes.
# A single curl immediately after deployment fails every time, so the
# distinction matters — an empty address and a 503 have different causes and
# different fixes.

set -euo pipefail

NAMESPACE="app"
INGRESS="baseline-app"

ADDRESS_TIMEOUT=300
ADDRESS_INTERVAL=10
HTTP_RETRIES=40
HTTP_INTERVAL=15

echo "==> Waiting for the Ingress to be assigned a load balancer address"
elapsed=0
ALB_HOST=""
while [ "${elapsed}" -lt "${ADDRESS_TIMEOUT}" ]; do
  ALB_HOST="$(kubectl get ingress "${INGRESS}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")"
  if [ -n "${ALB_HOST}" ]; then
    break
  fi
  echo "    no address yet (${elapsed}s/${ADDRESS_TIMEOUT}s)"
  sleep "${ADDRESS_INTERVAL}"
  elapsed=$((elapsed + ADDRESS_INTERVAL))
done

if [ -z "${ALB_HOST}" ]; then
  echo "!! ERROR: the Ingress never received a load balancer address." >&2
  echo "!! This almost always means the AWS Load Balancer Controller could" >&2
  echo "!! not provision the ALB. The controller logs carry the real reason;" >&2
  echo "!! an IAM AccessDenied there is the most common cause." >&2
  echo "::group::Ingress description"
  kubectl describe ingress "${INGRESS}" -n "${NAMESPACE}" || true
  echo "::endgroup::"
  echo "::group::Load balancer controller logs"
  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller \
    --tail=100 || true
  echo "::endgroup::"
  exit 1
fi

# The hostname embeds the project name, which is a secret.
echo "::add-mask::${ALB_HOST}"
echo "    Address assigned."

echo "==> Polling the public endpoint until the ALB reports targets healthy"
# --retry-all-errors covers connection refusals and resets while the target
# group is still registering, not just HTTP error codes.
if curl --fail --silent --show-error \
        --retry "${HTTP_RETRIES}" \
        --retry-delay "${HTTP_INTERVAL}" \
        --retry-all-errors \
        --max-time 20 \
        --output /tmp/landing.html \
        "http://${ALB_HOST}/"; then
  echo "    HTTP 200 from the load balancer."
else
  echo "!! ERROR: the application did not become reachable through the ALB." >&2
  echo "::group::Target health"
  kubectl describe ingress "${INGRESS}" -n "${NAMESPACE}" || true
  echo "::endgroup::"
  echo "::group::Pods"
  kubectl get pods -n "${NAMESPACE}" -o wide || true
  echo "::endgroup::"
  echo "::group::NetworkPolicies (a wrong ingress rule shape causes exactly this)"
  kubectl get networkpolicies -n "${NAMESPACE}" -o yaml || true
  echo "::endgroup::"
  exit 1
fi

echo "==> Checking the response is the landing page, not an error page"
# A 200 alone is not proof: an ALB fixed-response rule or a misrouted backend
# can return 200 with unrelated content. Assert on content the app actually
# serves.
if ! grep -q "Spring Boot on the secure baseline" /tmp/landing.html; then
  echo "!! ERROR: the endpoint returned 200 but not the expected landing page." >&2
  head -c 500 /tmp/landing.html >&2 || true
  exit 1
fi
echo "    Landing page content confirmed."

echo "==> Checking the health endpoint through the load balancer"
if ! curl --fail --silent --show-error --max-time 20 \
      "http://${ALB_HOST}/actuator/health" > /tmp/health.json; then
  echo "!! ERROR: /actuator/health is not reachable through the ALB." >&2
  exit 1
fi
grep -q '"status":"UP"' /tmp/health.json || {
  echo "!! ERROR: health endpoint did not report UP:" >&2
  cat /tmp/health.json >&2
  exit 1
}
echo "    Health endpoint reports UP."

echo "==> Confirming both replicas are serving"
READY="$(kubectl get deployment baseline-app -n "${NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
DESIRED="$(kubectl get deployment baseline-app -n "${NAMESPACE}" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")"
echo "    ${READY}/${DESIRED} replicas ready."
if [ "${READY}" != "${DESIRED}" ]; then
  echo "!! WARNING: not all replicas are ready." >&2
fi

# Written to the step summary so the URL is reachable from the run page.
# NOTE: this is intentionally NOT a job output — see the masking note above.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Application deployed"
    echo ""
    echo "The landing page is live behind the internet-facing ALB."
    echo ""
    echo "Retrieve the URL with:"
    echo ""
    echo '```'
    echo "kubectl get ingress ${INGRESS} -n ${NAMESPACE} \\"
    echo "  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
    echo '```'
    echo ""
    echo "(The hostname is masked in these logs because it embeds the project name.)"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "==> Application verified."
