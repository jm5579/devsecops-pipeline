# terraform/outputs.tf

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "ec2_instance_id" {
  value = module.ec2.instance_id
}

output "ec2_private_ip" {
  value = module.ec2.private_ip
}

output "artifact_bucket_name" {
  value = module.artifact_bucket.bucket_id
}

output "github_actions_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN GitHub Actions secret."
  value       = module.iam.github_actions_deploy_role_arn
}
