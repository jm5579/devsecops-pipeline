# terraform/modules/ec2/variables.tf

variable "name_prefix" {
  description = "Prefix applied to resource names in this module."
  type        = string
}

variable "aws_region" {
  description = "AWS region, passed into user_data for the SSM parameter fetch."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the security group belongs to."
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID the instance is launched into."
  type        = string
}

variable "ingress_security_group_id" {
  description = "Security group ID (e.g. an ALB's) permitted to reach the app port. Required - there is no CIDR-based ingress path."
  type        = string
}

variable "iam_instance_profile_name" {
  description = "IAM instance profile name from the iam module."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "app_port" {
  description = "Port the application listens on inside the container."
  type        = number
}

variable "cloudtrail_bucket_id" {
  description = "S3 bucket ID (with an appropriate CloudTrail bucket policy) that CloudTrail delivers logs to."
  type        = string
}
