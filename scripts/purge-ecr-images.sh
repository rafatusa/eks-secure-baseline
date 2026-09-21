#!/usr/bin/env bash
#
# Empty the application ECR repository BEFORE `terraform destroy`.
#
# WHY THIS EXISTS
# ---------------
# The destroy job failed with:
#
#   Error: ECR Repository (<project>-app) not empty, consider using
#   force_delete: ... StatusCode: 400, RepositoryNotEmptyException
#
# even though infra/ecr.tf sets `force_delete = true`. That is not a
# contradiction, and it is NOT fixed by editing ecr.tf:
#
#   * `force_delete` has NO representation in the ECR API. It is a
#     client-side-only attribute that exists solely inside terraform state,
#     and it is written there by an APPLY.
#   * `terraform destroy` deletes resources from the PRIOR STATE. It does
#     not re-evaluate configuration for a resource it is about to destroy.
#
# So a repository whose state object was written by an apply that ran BEFORE
# `force_delete = true` was added is deleted with force=false forever after,
# no matter what the .tf file says. The destroy plan in the failing run
# proves it: the aws_ecr_repository.app diff lists registry_id,
# repository_url, tags, encryption_configuration and
# image_scanning_configuration — and no force_delete at all.
#
# Re-running destroy would therefore fail identically every time, and it
# fails LATE: by then the VPC, EKS cluster and IAM roles are already gone,
# so the stack is left half-destroyed with a dirty state file.
#
# Emptying the repository first removes the dependency on that stale state
# attribute entirely: DeleteRepository succeeds with force=false when there
# is nothing left to delete. This is safe and idempotent — it is only ever
# run by the destroy workflow, whose entire purpose is to remove this
# infrastructure, and the images are rebuilt from source by the app-deploy
# pipeline.
#
# USAGE
#   bash scripts/purge-ecr-images.sh <repository-name> [region]
#
# Exits 0 when the repository is absent or already empty, so a resumed
# teardown is never blocked by this script.
set -euo pipefail

REPO="${1:?usage: purge-ecr-images.sh <repository-name> [region]}"
REGION="${2:-${AWS_REGION:-us-east-1}}"

# A previous destroy may already have removed the repository. That is a
# legitimate state for a resumed teardown, not an error: there is nothing to
# empty and terraform destroy must still be allowed to proceed.
if ! aws ecr describe-repositories \
  --repository-names "${REPO}" \
  --region "${REGION}" >/dev/null 2>&1; then
  echo "==> ECR repository is not present; nothing to purge."
  echo "    (Normal when resuming a teardown that already removed it.)"
  exit 0
fi

echo "==> Emptying ECR repository before terraform destroy"

# batch-delete-image accepts at most 100 image IDs per call, so page until
# the repository reports empty. Deleting by imageDigest (rather than by tag)
# removes tagged and untagged images alike, including the untagged layers
# left behind by overwritten or abandoned pushes.
while :; do
  IMAGE_IDS="$(aws ecr list-images \
    --repository-name "${REPO}" \
    --region "${REGION}" \
    --max-items 100 \
    --query 'imageIds[*].{imageDigest:imageDigest}' \
    --output json 2>/dev/null || echo '[]')"

  # Compare against the compact form so whitespace/formatting differences
  # between AWS CLI versions cannot make an empty list look non-empty.
  if [ -z "${IMAGE_IDS}" ] || [ "$(printf '%s' "${IMAGE_IDS}" | tr -d ' \n\r\t')" = "[]" ]; then
    echo "    Repository is empty."
    break
  fi

  COUNT="$(printf '%s' "${IMAGE_IDS}" | grep -c 'imageDigest' || true)"
  echo "    Deleting ${COUNT} image(s)..."

  # Do not let a partial failure abort the teardown: report and re-loop.
  # If nothing can be deleted the loop would spin, so break on failure and
  # let terraform surface the real error.
  if ! aws ecr batch-delete-image \
    --repository-name "${REPO}" \
    --region "${REGION}" \
    --image-ids "${IMAGE_IDS}" \
    --output text >/dev/null 2>&1; then
    echo "!! WARNING: batch-delete-image failed for ${REPO}." >&2
    echo "!! terraform destroy may fail with RepositoryNotEmptyException." >&2
    break
  fi
done

echo "==> ECR purge complete."
