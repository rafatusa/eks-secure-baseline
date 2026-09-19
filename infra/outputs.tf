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

output "api_allowed_cidr" {
  description = "CIDR currently permitted to reach the Kubernetes API endpoint."
  value       = var.api_allowed_cidr
}

output "cluster_log_group" {
  description = "CloudWatch log group holding control plane audit and authenticator logs."
  value       = aws_cloudwatch_log_group.cluster.name
}
