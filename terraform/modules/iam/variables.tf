# terraform/modules/iam/variables.tf

variable "name_prefix" {
  description = "Prefix applied to all IAM resource names in this module."
  type        = string
}

variable "aws_region" {
  description = "AWS region, used to build resource ARNs for condition scoping."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID used to scope the ECR pull condition key."
  type        = string
}

variable "artifact_bucket_name" {
  description = "Name of the S3 artifact bucket the instance role may read/write under app-logs/*."
  type        = string
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository the instance and GitHub Actions may pull/push."
  type        = string
  default     = "secure-python-app"
}

variable "github_org" {
  description = "GitHub organization or username that owns the repository, used to scope the OIDC trust policy."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, used to scope the OIDC trust policy."
  type        = string
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Whether to create the GitHub Actions OIDC provider in this AWS
    account. An account can only have one OIDC provider per issuer URL,
    so set this to false (and rely on the data source instead) if a
    provider for token.actions.githubusercontent.com already exists.
  EOT
  type        = bool
  default     = true
}
