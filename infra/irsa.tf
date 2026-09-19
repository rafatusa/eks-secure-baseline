locals {
  oidc_issuer_host = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# IRSA role for the compliance scanner. Scoped to one namespace and one
# service account so no other pod can assume it.
resource "aws_iam_role" "compliance_scanner" {
  name = "${var.project_name}-compliance-scanner"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.main.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer_host}:sub" = "system:serviceaccount:compliance:compliance-scanner"
        }
      }
    }]
  })

  tags = {
    Name = "${var.project_name}-compliance-scanner"
  }
}

# Read-only describe access: the scanner correlates in-cluster findings with
# the cluster's AWS-side configuration. No mutating actions are granted.
resource "aws_iam_role_policy" "compliance_scanner" {
  name = "${var.project_name}-compliance-scanner-policy"
  role = aws_iam_role.compliance_scanner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:DescribeNodegroup",
        "eks:ListNodegroups",
        "eks:DescribeAddon",
        "eks:ListAddons",
      ]
      Resource = [
        aws_eks_cluster.main.arn,
        "${aws_eks_cluster.main.arn}/*",
      ]
    }]
  })
}
