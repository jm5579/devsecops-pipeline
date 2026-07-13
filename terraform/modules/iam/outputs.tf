# terraform/modules/iam/outputs.tf

output "ec2_instance_profile_name" {
  value = aws_iam_instance_profile.ec2_instance_profile.name
}

output "ec2_role_arn" {
  value = aws_iam_role.ec2_instance_role.arn
}

output "github_actions_deploy_role_arn" {
  description = "Supply this value as the AWS_DEPLOY_ROLE_ARN GitHub Actions secret."
  value       = aws_iam_role.github_actions_deploy.arn
}
