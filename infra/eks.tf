resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Control plane log group. Created explicitly so retention is controlled;
# EKS would otherwise create it with never-expire retention.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.project_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-eks-logs"
  }
}

resource "aws_security_group" "cluster" {
  name        = "${var.project_name}-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-cluster-sg"
  }
}

# ACCEPTED RISK — Trivy AWS-0104 (unrestricted egress), documented exception.
#
# The EKS control plane's cross-account ENIs must reach worker node kubelets
# on ephemeral ports and regional AWS service endpoints (STS, ECR, CloudWatch
# Logs, EC2) whose prefix lists are not stable inputs to this security group.
# AWS's own EKS security group requirements specify outbound 0.0.0.0/0 for the
# cluster security group; narrowing it breaks node registration and add-on
# installation with errors that surface only after a full 15-minute apply.
#
# Compensating controls that make this acceptable:
#   - This SG is attached ONLY to the AWS-managed control plane ENIs. It is
#     not attached to any workload, so no application traffic transits it.
#   - No ingress rule exists on this SG: it is egress-only.
#   - Workload egress is governed separately by the default-deny
#     NetworkPolicies in k8s/hardening/network-policies.yaml.
#   - Nodes have no public IPs and sit in private subnets behind a NAT gateway.
#
# This is ignored at the single rule it applies to, NOT by filtering the
# CRITICAL severity or dropping --exit-code from the scanner, so every other
# finding in this repository still fails the pipeline.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "cluster_egress" {
  security_group_id = aws_security_group.cluster.id
  description       = "Allow control plane egress to nodes and AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_eks_cluster" "main" {
  name     = var.project_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.k8s_version

  vpc_config {
    subnet_ids = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)

    security_group_ids = [aws_security_group.cluster.id]

    # Private access keeps in-cluster traffic to the API off the internet.
    #
    # Public access is retained, but the network path is restricted to the
    # single administrative host in var.api_allowed_cidr (validated to reject
    # 0.0.0.0/0 and anything broader than /24). CI does not hold a standing
    # entry here: the pipeline's kubectl stages add the runner's own public
    # IP for the duration of the job and remove it in an always() step, so
    # the steady-state allowlist remains one host.
    #
    # The alternative — endpoint_public_access = false — is genuinely more
    # secure but requires a self-hosted runner or VPN inside the VPC for CI
    # to reach the API at all. That is a Tier-2 redesign, recorded in the
    # README as an optional enhancement rather than silently assumed.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.api_allowed_cidr]
  }

  # All five control plane log types. 'audit' and 'authenticator' are the two
  # that matter for compliance evidence; the rest aid debugging.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  access_config {
    # API authentication mode: IAM principals are granted access through
    # EKS access entries rather than the legacy aws-auth ConfigMap.
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # The CI stages mutate public_access_cidrs in-flight to admit the runner's
  # ephemeral IP, then restore it. Without this, the next terraform plan would
  # see the restored list as drift only if a cleanup step had failed — which
  # is exactly the condition we WANT terraform to report and correct, so the
  # attribute is deliberately NOT placed under lifecycle.ignore_changes.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = {
    Name = "${var.project_name}-eks"
  }
}

# OIDC provider enables IRSA — pods assume IAM roles without node-wide
# credentials, which is the least-privilege path for workload AWS access.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.project_name}-oidc"
  }
}

# Core add-ons, pinned by EKS to versions compatible with the cluster version.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}
