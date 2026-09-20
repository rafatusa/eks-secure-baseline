#!/usr/bin/env bash
#
# Build the application image, scan it, and push it to ECR.
#
# USAGE
#   bash scripts/build-push-image.sh <tag>
#
# The tag is the commit SHA. ECR has IMMUTABLE tags enabled, so a given SHA
# can only ever be pushed once — which is exactly the property that makes a
# deployed tag mean something. Re-running this workflow on an unchanged
# commit is therefore expected to find the image already present, and that is
# treated as success rather than an error.
#
# WHY THE ECR URL IS READ HERE RATHER THAN PASSED IN
# --------------------------------------------------
# The repository URL embeds the AWS account id and the project name, and
# PROJECT_NAME is a repository secret. GitHub silently DROPS a job output
# whose value contains a secret substring, so threading it between jobs
# yields an empty string and a confusing failure. Every job that needs it
# reads it from terraform state itself.

set -euo pipefail

TAG="${1:?usage: build-push-image.sh <tag>}"
REGION="${AWS_REGION:-us-east-1}"

echo "==> Reading the ECR repository URL from terraform state"
ECR_URL="$(cd infra && terraform output -raw ecr_repository_url)"

if [ -z "${ECR_URL}" ]; then
  echo "ERROR: ecr_repository_url is empty in terraform state." >&2
  echo "       Run the main deploy pipeline first so the repository exists." >&2
  exit 1
fi
echo "::add-mask::${ECR_URL}"

REGISTRY="${ECR_URL%%/*}"
echo "::add-mask::${REGISTRY}"

IMAGE_REF="${ECR_URL}:${TAG}"

echo "==> Authenticating to ECR"
# The password is piped straight into docker login and never written to disk
# or echoed. --password-stdin is the only form that avoids it appearing in
# the process list.
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "==> Checking whether ${TAG} already exists"
# Tag immutability means a re-push of the same SHA fails. That is a correct
# refusal, not a build error, so detect it up front and skip cleanly.
if aws ecr describe-images \
     --repository-name "$(basename "${ECR_URL}")" \
     --image-ids "imageTag=${TAG}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "    Image for ${TAG} is already in ECR; skipping build and push."
  echo "    (Tags are immutable — the existing image IS this commit.)"
  exit 0
fi

echo "==> Building the image"
docker build \
  --tag "${IMAGE_REF}" \
  --file app/Dockerfile \
  app/

echo "==> Scanning the built image for vulnerabilities"
# Scans the IMAGE, which is different from the Dockerfile scan in the
# security stage: this catches CVEs in the base image and in the resolved
# Java dependency tree, neither of which is visible in the Dockerfile.
#
# This gate is real. If it fails, the correct response is to rebuild on an
# updated base image or bump the vulnerable dependency — never to lower the
# severity threshold or add an ignore entry to make the pipeline green.
if ! command -v trivy >/dev/null 2>&1; then
  echo "    Installing Trivy"
  TRIVY_VERSION="0.74.0"
  curl -fsSL -o /tmp/trivy.deb \
    "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.deb"
  sudo dpkg -i /tmp/trivy.deb
fi

echo "::group::Image vulnerabilities — all severities (informational)"
trivy image --scanners vuln --exit-code 0 --severity LOW,MEDIUM,HIGH,CRITICAL "${IMAGE_REF}" || true
echo "::endgroup::"

echo "==> Gating on HIGH and CRITICAL vulnerabilities"
# --ignore-unfixed: a CVE with no available fix cannot be actioned by
# rebuilding, so failing on it would block every deploy until the upstream
# distribution publishes a patch, with no remediation available in between.
# Fixable HIGH/CRITICAL findings still fail the build.
trivy image \
  --scanners vuln \
  --severity HIGH,CRITICAL \
  --ignore-unfixed \
  --exit-code 1 \
  "${IMAGE_REF}"

echo "==> Pushing ${TAG} to ECR"
docker push "${IMAGE_REF}"

echo "==> Push complete."
