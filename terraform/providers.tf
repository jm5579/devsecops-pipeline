# terraform/providers.tf
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    # SECURITY DECISION: consistent tagging on every resource this config
    # creates supports cost allocation, ownership tracing, and CloudTrail/
    # Config-based auditing - all commonly required in regulated financial
    # environments.
    tags = {
      Project     = "secure-python-app"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
