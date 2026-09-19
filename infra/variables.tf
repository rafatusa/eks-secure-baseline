variable "project_name" {
  description = "Branch-scoped project name used as the prefix for every cloud resource."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "k8s_version" {
  description = <<-EOT
    Kubernetes minor version for the EKS control plane and node group.
    Must be in AWS STANDARD support (1.33-1.36 as of 2026-07). Versions
    1.30-1.32 are extended support only and incur additional cost.
  EOT
  type        = string
  default     = "1.33"

  validation {
    condition     = contains(["1.33", "1.34", "1.35", "1.36"], var.k8s_version)
    error_message = "k8s_version must be a version in AWS standard support: 1.33, 1.34, 1.35 or 1.36."
  }
}

variable "api_allowed_cidr" {
  description = <<-EOT
    CIDR block permitted to reach the Kubernetes API server endpoint.
    Set this to your public IP as x.x.x.x/32 for a hardened posture.
    The default of 0.0.0.0/0 leaves the network path open (the API is still
    protected by AWS IAM authentication and Kubernetes RBAC) and WILL be
    reported as a finding by the CIS compliance scan.
  EOT
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.api_allowed_cidr, 0))
    error_message = "api_allowed_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.node_desired_size >= 2
    error_message = "node_desired_size must be at least 2 so the control plane can schedule across both availability zones."
  }
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "Size in GiB of the encrypted EBS root volume on each node."
  type        = number
  default     = 20
}

variable "billing_alarm_email" {
  description = <<-EOT
    Email address that receives the CloudWatch billing alarm notification.
    Set to an empty string or the literal "none" to skip creating the alarm
    and its SNS subscription. ("none" exists because CI secrets cannot hold
    an empty value.)
  EOT
  type        = string
  default     = ""

  validation {
    condition = (
      var.billing_alarm_email == "" ||
      lower(var.billing_alarm_email) == "none" ||
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.billing_alarm_email))
    )
    error_message = "billing_alarm_email must be a valid email address, an empty string, or \"none\"."
  }
}

variable "billing_alarm_threshold_usd" {
  description = "Estimated monthly charge in USD that triggers the billing alarm."
  type        = number
  default     = 200
}

variable "log_retention_days" {
  description = "Retention in days for the EKS control plane CloudWatch log group."
  type        = number
  default     = 30
}
