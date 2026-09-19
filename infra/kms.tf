data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Envelope encryption key for Kubernetes secrets stored in etcd.
# Without this, secrets are stored base64-encoded only — a CIS finding and a
# real exposure if etcd snapshots are ever accessible.
resource "aws_kms_key" "eks" {
  description             = "${var.project_name} EKS secret envelope encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEKSServiceUse"
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Name = "${var.project_name}-eks-kms"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.project_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ---------------------------------------------------------------------------
# Separate key for EBS root volumes on worker nodes.
#
# WHO ACTUALLY ENCRYPTS THE VOLUME (this cost a failed node group once)
# ---------------------------------------------------------------------------
# A managed node group launches its instances through an Auto Scaling group.
# When the launch template names a customer-managed CMK, the volume is
# encrypted by the AUTO SCALING SERVICE-LINKED ROLE acting as an IAM
# principal — NOT by the ec2.amazonaws.com service principal.
#
# A key policy that grants only Service = "ec2.amazonaws.com" therefore
# denies kms:CreateGrant to Auto Scaling, and EVERY instance is terminated
# at launch with:
#
#   Client.InvalidKMSKey.InvalidState: The KMS key provided is in an
#   incorrect state
#
# followed by "Instances failed to join the kubernetes cluster". The message
# is misleading: the key is ENABLED and perfectly healthy — the caller simply
# is not allowed to use it. The ASG retries ~10 times, then the node group
# goes CREATE_FAILED while the cluster itself stays ACTIVE.
#
# The fix is to authorise the real principals, never to drop `encrypted` or
# fall back to the AWS-managed aws/ebs key — encrypted node root volumes are
# a CIS control this project exists to satisfy.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "ebs" {
  description             = "${var.project_name} EKS node EBS volume encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Retained for EBS service-side operations (snapshot/volume handling
        # performed under the EC2 service principal).
        Sid       = "AllowEC2ServiceUse"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        # THE STATEMENT WHOSE ABSENCE FAILED THE NODE GROUP.
        # Auto Scaling encrypts the root volume on the ASG's behalf using
        # this service-linked role. Without it: InvalidKMSKey.InvalidState.
        Sid    = "AllowAutoScalingServiceLinkedRoleUse"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        # Grant creation is a separate action and must be scoped: the
        # GrantIsForAWSResource condition means this role can only create
        # grants for AWS services that encrypt/decrypt on its behalf, not
        # arbitrary principals.
        Sid    = "AllowAutoScalingServiceLinkedRoleGrants"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
        }
        Action   = ["kms:CreateGrant"]
        Resource = "*"
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
      {
        # The node instance role reads from its own encrypted root volume.
        Sid       = "AllowNodeRoleUse"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.node.arn }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid       = "AllowNodeRoleGrants"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.node.arn }
        Action    = ["kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })

  tags = {
    Name = "${var.project_name}-ebs-kms"
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.project_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}
