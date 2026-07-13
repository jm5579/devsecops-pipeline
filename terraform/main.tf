# terraform/main.tf
#
# This file wires the four modules together into the full architecture
# described in README.md > "Terraform Infrastructure": a VPC with public/
# private subnets, an EC2 instance in the private subnet, an S3 bucket
# for application artifacts, a separate S3 bucket for CloudTrail logs,
# and IAM roles scoped with least-privilege condition keys throughout.

data "aws_caller_identity" "current" {}

module "vpc" {
  source = "./modules/vpc"

  name_prefix          = "secure-python-app"
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
}

module "artifact_bucket" {
  source = "./modules/s3"

  bucket_name           = var.artifact_bucket_name
  access_log_bucket_id  = module.cloudtrail_bucket.bucket_id
  enable_access_logging = true
}

module "cloudtrail_bucket" {
  source = "./modules/s3"

  bucket_name          = "${var.artifact_bucket_name}-cloudtrail"
  manage_bucket_policy = false

  # SECURITY DECISION: no access_log_bucket_id is passed here - a bucket
  # cannot log to itself, and this bucket exists specifically to receive
  # CloudTrail's own audit trail, so a secondary access log would be
  # circular. It still inherits every other control from the s3 module
  # except the default bucket policy, because the root module supplies a
  # combined TLS + CloudTrail delivery policy.
}

# SECURITY DECISION: CloudTrail requires a bucket policy granting the
# CloudTrail service permission to check ACLs and deliver log objects.
# This is intentionally the ONLY principal/action added on top of the
# s3 module's default-deny public access posture.
resource "aws_s3_bucket_policy" "cloudtrail_delivery" {
  bucket = module.cloudtrail_bucket.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"

        Resource = [
          module.cloudtrail_bucket.bucket_arn,
          "${module.cloudtrail_bucket.bucket_arn}/*",
        ]

        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"

        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }

        Action   = "s3:GetBucketAcl"
        Resource = module.cloudtrail_bucket.bucket_arn

        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/secure-python-app-trail"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"

        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }

        Action = "s3:PutObject"

        Resource = "${module.cloudtrail_bucket.bucket_arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"

        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/secure-python-app-trail"
          }
        }
      },
    ]
  })
}

module "iam" {
  source = "./modules/iam"

  name_prefix          = "secure-python-app"
  aws_region           = var.aws_region
  vpc_id               = module.vpc.vpc_id
  artifact_bucket_name = module.artifact_bucket.bucket_id
  ecr_repository_name  = "secure-python-app"
  github_org           = var.github_org
  github_repo          = var.github_repo
}

# SECURITY DECISION: a dedicated security group represents the only
# permitted source of inbound application traffic (e.g. an internal ALB
# or a corporate VPN range for this portfolio-scale deployment - see
# README > Future Improvements for adding a public-facing ALB with WAF).
# The EC2 module's security group allows traffic from THIS security
# group only, never a raw public CIDR.
resource "aws_security_group" "ingress" {
  name        = "secure-python-app-ingress-sg"
  description = "Represents the trusted ingress path (ALB/VPN) permitted to reach the application"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.trusted_ingress_cidr]
    description = "HTTPS from the trusted ingress range only"
  }

  egress {
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
    description = "Forward to the application instance within the VPC only"
  }

  tags = {
    Name = "secure-python-app-ingress-sg"
  }
}

module "ec2" {
  source = "./modules/ec2"

  name_prefix               = "secure-python-app"
  aws_region                = var.aws_region
  vpc_id                    = module.vpc.vpc_id
  private_subnet_id         = module.vpc.private_subnet_ids[0]
  ingress_security_group_id = aws_security_group.ingress.id
  iam_instance_profile_name = module.iam.ec2_instance_profile_name
  instance_type             = var.instance_type
  app_port                  = var.app_port
  cloudtrail_bucket_id      = module.cloudtrail_bucket.bucket_id
}

# SECURITY DECISION: the Flask secret key lives only in SSM Parameter
# Store as an encrypted SecureString, populated once out-of-band (see
# README > Complete Setup Instructions) - Terraform declares the
# parameter exists but its value is deliberately never set from a
# Terraform variable, so it never appears in state or a plan diff.
resource "aws_ssm_parameter" "flask_secret_key" {
  name        = "/secure-python-app/flask-secret-key"
  type        = "SecureString"
  description = "Flask SECRET_KEY, populated out-of-band - see README > GitHub Actions Secrets Configuration"
  value       = "REPLACE_ME_OUT_OF_BAND" # SECURITY DECISION: placeholder only; overwritten manually/via a separate secure process, never via `terraform apply`

  lifecycle {
    ignore_changes = [value] # SECURITY DECISION: Terraform will never overwrite a manually-rotated secret value
  }
}
