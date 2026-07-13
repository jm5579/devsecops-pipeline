# terraform/backend.tf
#
# SECURITY DECISION: remote state in a private, encrypted, versioned S3
# bucket (created once via terraform/bootstrap) with DynamoDB locking,
# instead of local state files. This means state - which can contain
# sensitive attribute values - is never on a laptop or a stateless CI
# runner's disk after the job ends, is encrypted at rest, and can't be
# corrupted by two concurrent applies.
#
# Backend configuration cannot use variables, so the actual bucket/table
# names are supplied at `terraform init` time via a backend config file
# that is itself gitignored (see backend.hcl.example below and
# README.md > "Complete Setup Instructions").
terraform {
  backend "s3" {
    key            = "secure-python-app/terraform.tfstate"
    encrypt        = true
    dynamodb_table = "" # supplied via -backend-config, see backend.hcl.example
    bucket         = "" # supplied via -backend-config, see backend.hcl.example
    region         = "" # supplied via -backend-config, see backend.hcl.example
  }
}
