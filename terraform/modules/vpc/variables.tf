# terraform/modules/vpc/variables.tf

variable "name_prefix" {
  description = "Prefix applied to all resource Name tags in this module."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
}
