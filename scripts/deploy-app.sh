#!/usr/bin/env bash
#
# Render and apply the application manifests.
#
# Called INSIDE scripts/ci-api-access.sh, which has already granted this
# runner temporary API access and run `aws eks update-kubeconfig`. This
# script must therefore NOT call update-kubeconfig itself — doing so outside
# the access window is how a stage ends up talking to a stale context.
#
# USAGE
#   bash scripts/deploy-app.sh <image-ref> <app-version>
#
# TEMPLATING: the manifests carry IMAGE_PLACEHOLDER / VERSION_PLACEHOLDER /
# VPC_CIDR_PLACEHOLDER rather than being generated. Keeping them as real,
# lintable YAML means kubeconform validates them in the lint stage and Trivy
# scans them in the security stage — neither of which can inspect a manifest
# that only exists as a heredoc at deploy time.
#
# Substitution uses python rather than sed: an image ref contains '/' and
# ':', which turn a naive sed expression into a syntax error or a silent
# mis-substitution depending on the delimiter chosen.

set -euo pipefail

IMAGE_REF="${1:?usage: deploy-app.sh <image-ref> <app-version>}"
APP_VERSION="${2:?app version required}"

NAMESPACE="app"
DEPLOYMENT="baseline-app"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "${RENDER_DIR}"' EXIT

echo "==> Reading VPC CIDR from terraform state"
# Read from state rather than accepting it as a job input: the NetworkPolicy
# must match the real network, and a value threaded through a job output can
# be silently dropped by GitHub when it contains a secret substring.
VPC_CIDR="$(cd infra && terraform output -raw vpc_cidr)"

if ! printf '%s' "${VPC_CIDR}" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
  echo "ERROR: vpc_cidr from terraform output is not a CIDR: '${VPC_CIDR}'" >&2
  exit 1
fi
echo "    VPC CIDR: ${VPC_CIDR}"

echo "==> Rendering manifests"
cp k8s/app/*.yaml "${RENDER_DIR}/"

IMAGE_REF="${IMAGE_REF}" APP_VERSION="${APP_VERSION}" VPC_CIDR="${VPC_CIDR}" \
RENDER_DIR="${RENDER_DIR}" python3 - <<'PYTHON'
import os
import pathlib
import sys

render_dir = pathlib.Path(os.environ["RENDER_DIR"])
replacements = {
    "IMAGE_PLACEHOLDER": os.environ["IMAGE_REF"],
    "VERSION_PLACEHOLDER": os.environ["APP_VERSION"],
    "VPC_CIDR_PLACEHOLDER": os.environ["VPC_CIDR"],
}

substituted = {key: 0 for key in replacements}

for path in sorted(render_dir.glob("*.yaml")):
    text = path.read_text(encoding="utf-8")
    original = text
    for token, value in replacements.items():
        count = text.count(token)
        if count:
            substituted[token] += count
            text = text.replace(token, value)
    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"    rendered {path.name}")

# Fail loudly if a placeholder was never found. A renamed or removed token
# would otherwise deploy a manifest still containing the literal string,
# which Kubernetes accepts for an env value and rejects for an image ref
# with an error that names the placeholder rather than the cause.
missing = [token for token, count in substituted.items() if count == 0]
if missing:
    print(f"ERROR: placeholders never matched: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

# Belt and braces: no placeholder may survive into an applied manifest.
for path in sorted(render_dir.glob("*.yaml")):
    text = path.read_text(encoding="utf-8")
    for token in replacements:
        if token in text:
            print(f"ERROR: {token} still present in {path.name}", file=sys.stderr)
            sys.exit(1)
PYTHON

echo "==> Applying manifests"
# Namespace first: applying a Deployment into a namespace that does not exist
# yet fails, and server-side ordering within a single apply is not guaranteed.
kubectl apply -f "${RENDER_DIR}/namespace.yaml"
kubectl apply -f "${RENDER_DIR}/"

echo "==> Waiting for rollout"
# The startup probe allows up to 150s for the JVM to boot, and maxUnavailable
# is 0, so a rollout can legitimately take a couple of minutes. A timeout
# shorter than the startup budget reports failure on a deployment that was
# about to succeed.
if ! kubectl rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=360s; then
  echo "!! Rollout did not complete. Diagnostics follow." >&2
  echo "::group::Pods"
  kubectl get pods -n "${NAMESPACE}" -o wide || true
  echo "::endgroup::"
  echo "::group::Events"
  kubectl get events -n "${NAMESPACE}" --sort-by=.lastTimestamp || true
  echo "::endgroup::"
  echo "::group::Container logs"
  kubectl logs -n "${NAMESPACE}" "deployment/${DEPLOYMENT}" --all-containers --tail=120 || true
  echo "::endgroup::"
  exit 1
fi

echo "==> Rollout complete"
kubectl get pods -n "${NAMESPACE}" -o wide
