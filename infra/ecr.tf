# ---------------------------------------------------------------------------
# ECR repository for the application image.
#
# The cluster's node group runs in PRIVATE subnets and reaches the registry
# through the NAT gateway. A private ECR repository keeps the image inside
# the account: pulls are authenticated by the node instance role, so the
# image is never anonymously reachable the way a public Docker Hub tag is.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name = "${var.project_name}-app"

  # Tag immutability is the control that makes a SHA tag MEAN something.
  # With mutable tags, the image behind a deployed tag can be replaced after
  # the fact, so the digest running in the cluster no longer corresponds to
  # the commit that was reviewed and scanned. The pipeline tags every build
  # with its commit SHA, which is unique per build, so immutability never
  # conflicts with a legitimate re-push.
  image_tag_mutability = "IMMUTABLE"

  # Scan every pushed image for OS and library CVEs. Findings are visible in
  # the ECR console and via the API; this does not gate the pipeline, which
  # scans with Trivy separately.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Reuse the cluster CMK rather than the AWS-managed aws/ecr key: image
  # layers are encrypted under a key whose policy and rotation this project
  # controls and audits.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.eks.arn
  }

  tags = {
    Name = "${var.project_name}-app"
  }
}

# ---------------------------------------------------------------------------
# Lifecycle policy: bound storage growth.
#
# Every pipeline run pushes a new SHA-tagged image. Without expiry the
# repository grows without limit and quietly becomes a line on the bill that
# nobody attributes to anything.
#
# Untagged images are deleted after 1 day: they are the layers left behind
# when a tag is overwritten or a push is abandoned, and nothing can ever
# reference them.
#
# Tagged images keep the 15 most recent, which preserves a genuine rollback
# window (the previous images are still pullable by digest) while capping
# storage.
# ---------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 15 most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 15
        }
        action = { type = "expire" }
      },
    ]
  })
}
