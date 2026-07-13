# terraform/modules/iam/main.tf
#
# SECURITY DECISION: every policy in this module is scoped to the
# specific resources this project creates (via ARN interpolation and
# condition keys), never to "*" resources, and grants only the actions
# the instance role actually needs to function. This is the Terraform
# expression of least privilege requested in the project brief.

data "aws_caller_identity" "current" {}

# ---- EC2 instance role ----------------------------------------------
resource "aws_iam_role" "ec2_instance_role" {
  name = "${var.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # SECURITY DECISION: a source-account condition key prevents any
      # confused-deputy scenario where a different AWS account's EC2
      # service could somehow assume this role.
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance_role.name
}

# SECURITY DECISION: AmazonSSMManagedInstanceCore is the narrowest AWS
# managed policy that enables Session Manager / Run Command access,
# which is how the pipeline's `deploy` job reaches the instance instead
# of SSH (see .github/workflows/devsecops-pipeline.yml).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SECURITY DECISION: pull access to ECR is scoped with a condition key
# requiring the request to originate from this specific VPC, so even a
# compromised instance credential can't be replayed usefully from
# outside the expected network path.
resource "aws_iam_role_policy" "ecr_pull" {
  name = "${var.name_prefix}-ecr-pull-policy"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # SECURITY DECISION: GetAuthorizationToken is an account-level, non-resource-scoped API - AWS requires Resource "*" for it
      },
      {
        Sid    = "ECRPullOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
        Condition = {
          StringEquals = {
            "aws:SourceVpc" = var.vpc_id
          }
        }
      }
    ]
  })
}

# SECURITY DECISION: write access to the S3 artifact bucket is limited to
# a single, path-prefixed object pattern and requires SSE-KMS on every
# PutObject, enforced via condition keys - the role can never write
# outside its own prefix or upload an unencrypted object.
resource "aws_iam_role_policy" "s3_artifact_access" {
  name = "${var.name_prefix}-s3-artifact-policy"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListOwnPrefix"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.artifact_bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["app-logs/*"]
          }
        }
      },
      {
        Sid    = "ReadWriteOwnPrefix"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.artifact_bucket_name}/app-logs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      }
    ]
  })
}

# SECURITY DECISION: CloudWatch Logs permissions are scoped to a single,
# named log group prefix rather than "logs:*" on all resources.
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${var.name_prefix}-cloudwatch-logs-policy"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AppLogGroupOnly"
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${var.name_prefix}*:*"
    }]
  })
}

# ---- GitHub Actions OIDC deploy role -----------------------------------
# SECURITY DECISION: GitHub Actions authenticates to AWS via OIDC
# federation and assumes this role for the duration of a single workflow
# run - there is no long-lived AWS access key stored as a GitHub secret.
# The trust policy's condition keys restrict which repository AND which
# branch may assume the role, so a workflow run from a fork or a feature
# branch cannot deploy to production even if it somehow obtained a valid
# OIDC token.
data "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  count           = var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : data.aws_iam_openid_connect_provider.github_actions[0].arn
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "${var.name_prefix}-gha-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # SECURITY DECISION: only workflow runs triggered by a push to
          # main on this exact repository can assume this role.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${var.name_prefix}-gha-deploy-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
      },
      {
        Sid      = "SSMDeployCommand"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        ]
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Name" = "secure-python-app"
          }
        }
      },
      {
        Sid      = "SSMCommandStatus"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "*" # SECURITY DECISION: this read-only status API does not support resource-level scoping
      }
    ]
  })
}
