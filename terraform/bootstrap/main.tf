# terraform/bootstrap/main.tf
#
# SECURITY DECISION / DESIGN NOTE:
# Terraform's S3 backend cannot bootstrap itself - the bucket and lock
# table that will hold remote state must already exist before any config
# can be configured to use them as a backend. This tiny, separate
# configuration is applied exactly once, with local state (there is
# nothing sensitive in it beyond resource IDs), to create that bucket and
# table. Every other module in this repository then uses the S3 backend
# defined in terraform/backend.tf, which points at the resources created
# here. This bootstrap config is intentionally never modified again.

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
}

variable "aws_region" {
  description = "AWS region for the state backend resources."
  type        = string
  default     = "ca-central-1" # SECURITY DECISION: Canadian region for data residency
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform remote state."
  type        = string
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # SECURITY DECISION: prevent `terraform destroy` from ever deleting the
  # bucket that holds the state for every other environment in this repo.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled" # SECURITY DECISION: recover from accidental state corruption/overwrite
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  # SECURITY DECISION: Terraform state frequently contains resource IDs,
  # ARNs, and sometimes sensitive attribute values - it must never be
  # publicly reachable under any circumstance.
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.state_bucket_name}-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # SECURITY DECISION: DynamoDB-based state locking prevents two
  # simultaneous `terraform apply` runs (e.g. two CI runs, or a CI run
  # racing a local apply) from corrupting shared infrastructure state.

  server_side_encryption {
    enabled = true
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.terraform_locks.name
}
