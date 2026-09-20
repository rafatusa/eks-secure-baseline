output "cluster_name" {
  description = "EKS cluster name. Read by configure/verify/compliance stages via terraform output."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = aws_eks_cluster.main.version
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.main.arn
}

output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = <<-EOT
    CIDR block of the VPC.

    Consumed by the application NetworkPolicy. With ALB target-type=ip the
    load balancer sends traffic from its own ENIs inside the VPC, so the
    ingress allow rule is an ipBlock covering the VPC — NOT a podSelector.
  EOT
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs hosting the worker nodes."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet IDs used for the NAT gateway and load balancers."
  value       = aws_subnet.public[*].id
}

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.main.arn
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider backing IRSA."
  value       = aws_iam_openid_connect_provider.main.arn
}

output "compliance_scanner_role_arn" {
  description = "IRSA role ARN annotated onto the compliance-scanner service account."
  value       = aws_iam_role.compliance_scanner.arn
}

output "alb_controller_role_arn" {
  description = <<-EOT
    IRSA role ARN annotated onto the aws-load-balancer-controller service
    account. Read by the configure stage when installing the Helm chart.
  EOT
  value       = aws_iam_role.alb_controller.arn
}

output "ecr_repository_url" {
  description = <<-EOT
    Registry URL of the application image repository.

    The app pipeline reads this from terraform state directly rather than
    receiving it through a job output: the URL embeds the account ID and the
    project name, and GitHub silently DROPS any job output whose value
    contains a secret substring (PROJECT_NAME is a secret).
  EOT
  value       = aws_ecr_repository.app.repository_url
}

output "api_allowed_cidr" {
  description = "CIDR currently permitted to reach the Kubernetes API endpoint."
  value       = var.api_allowed_cidr
}

output "cluster_log_group" {
  description = "CloudWatch log group holding control plane audit and authenticator logs."
  value       = aws_cloudwatch_log_group.cluster.name
}
