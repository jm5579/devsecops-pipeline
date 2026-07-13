# terraform/modules/iam/main.tf
#
# SECURITY DECISION: every policy in this module is scoped to the
# specific resources this project creates via ARN interpolation and
# condition keys, except where AWS APIs do not support resource-level
# permissions.

data "aws_caller_identity" "current" {}

# ---- EC2 instance role ----------------------------------------------

resource "aws_iam_role" "ec2_instance_role" {
  name = "${var.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"

        # SECURITY DECISION: a source-account condition helps prevent a
        # confused-deputy scenario involving another AWS account.
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance_role.name
}

# SECURITY DECISION: AmazonSSMManagedInstanceCore enables Session Manager
# and Run Command access so the deployment workflow does not require SSH.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SECURITY DECISION: pull access to ECR is scoped to the project's
# repository. GetAuthorizationToken must use Resource="*" because AWS
# does not support resource-level permissions for that action.
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
        Resource = "*"
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

# SECURITY DECISION: access to the S3 artifact bucket is limited to the
# app-logs prefix.
resource "aws_iam_role_policy" "s3_artifact_access" {
  name = "${var.name_prefix}-s3-artifact-policy"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid      = "ListOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
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

        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]

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

# SECURITY DECISION: CloudWatch Logs permissions are scoped to the
# application's log-group prefix.
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${var.name_prefix}-cloudwatch-logs-policy"
  role = aws_iam_role.ec2_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "AppLogGroupOnly"
        Effect = "Allow"

        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]

        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${var.name_prefix}*:*"
      }
    ]
  })
}

# ---- GitHub Actions OIDC deploy role -------------------------------

# SECURITY DECISION: GitHub Actions authenticates through OIDC, so no
# long-lived AWS access keys are stored in GitHub.
data "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github_actions[0].arn
    : data.aws_iam_openid_connect_provider.github_actions[0].arn
  )
}

resource "aws_iam_role" "github_actions_deploy" {
  name = "${var.name_prefix}-gha-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Federated = local.github_oidc_provider_arn
        }

        Action = "sts:AssumeRoleWithWebIdentity"

        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }

          StringLike = {
            # SECURITY DECISION: only workflow jobs running through this
            # repository's production environment may assume the role.
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:environment:production"
          }
        }
      }
    ]
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
        Sid    = "SSMDeployCommandDocument"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]

        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid    = "SSMDeployCommandInstance"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]

        Resource = [
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
        Resource = "*"
      }
    ]
  })
}