# terraform/variables.tf

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ca-central-1" # SECURITY DECISION: Canadian region for data residency requirements
}

variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, production)."
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b"]
}

variable "instance_type" {
  description = "EC2 instance type for the application host."
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    CIDR allowed to reach the instance over SSH. Left as a variable with
    no default (must be explicitly supplied) rather than a convenient
    but dangerous 0.0.0.0/0 default, forcing an intentional choice.
    In this architecture SSH is not actually opened at all (see
    terraform/modules/ec2) - this variable exists for teams that choose
    to enable a bastion path and must explicitly scope it.
  EOT
  type        = string
  default     = null
}

variable "app_port" {
  description = "Port the containerized Flask application listens on."
  type        = number
  default     = 8080
}

variable "artifact_bucket_name" {
  description = "Globally-unique name for the S3 bucket used for application artifacts/logs."
  type        = string
}

variable "alarm_notification_email" {
  description = "Email address to notify for CloudWatch/CloudTrail alarms."
  type        = string
  default     = null
}

variable "trusted_ingress_cidr" {
  description = <<-EOT
    CIDR block permitted to reach the application over HTTPS (e.g. your
    organization's VPN or an upstream ALB's subnet range). No default is
    provided - this must be explicitly and deliberately scoped by
    whoever deploys this configuration, never left as 0.0.0.0/0.
  EOT
  type        = string
}

variable "github_org" {
  description = "GitHub organization or username that owns this repository, used to scope the OIDC deploy role trust policy."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name, used to scope the OIDC deploy role trust policy."
  type        = string
}
