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

    This MUST be a single administrative host (x.x.x.x/32). The value is
    supplied at deploy time from the API_ALLOWED_CIDR secret; the default
    below is a documentation placeholder from RFC 5737 (TEST-NET-3) and is
    deliberately NOT a routable address, so a misconfigured deploy fails
    closed rather than exposing the API server to the internet.

    A public value such as 0.0.0.0/0 is rejected by the validation block:
    an internet-reachable API endpoint is a CRITICAL finding under both the
    CIS Amazon EKS Benchmark and Trivy's AWS-0041 check, and this project
    exists to be compliant, not to document its own exceptions.

    CI runners do NOT need a permanent entry here. The pipeline's kubectl
    stages add the runner's own public IP to the cluster's public access
    CIDR list for the duration of the job and remove it afterwards, so the
    steady-state allowlist stays exactly this one administrative host.
  EOT
  type        = string
  default     = "203.0.113.1/32"

  validation {
    condition     = can(cidrhost(var.api_allowed_cidr, 0))
    error_message = "api_allowed_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], var.api_allowed_cidr)
    error_message = "api_allowed_cidr must not be an open CIDR (0.0.0.0/0). Use a specific host, for example 203.0.113.10/32."
  }

  validation {
    condition     = tonumber(split("/", var.api_allowed_cidr)[1]) >= 24
    error_message = "api_allowed_cidr must be /24 or narrower so the API endpoint is not exposed to a broad network range."
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
