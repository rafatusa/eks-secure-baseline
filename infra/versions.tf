terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend configuration is supplied at init time via -backend-config flags
  # by the platform pipeline. It must stay EMPTY here: backend blocks cannot
  # use variables, and a hardcoded key would share state across branches.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "udap"
      Component = "eks-secure-baseline"
    }
  }
}
