# terraform/modules/s3/variables.tf

variable "bucket_name" {
  description = "Globally-unique S3 bucket name."
  type        = string
}

variable "access_log_bucket_id" {
  description = "Optional destination bucket ID for S3 server access logs."
  type        = string
  default     = null
}

variable "enable_access_logging" {
  description = "Whether to enable S3 server access logging for this bucket."
  type        = bool
  default     = false
}

variable "manage_bucket_policy" {
  description = "Whether this module should create its default TLS-enforcement bucket policy."
  type        = bool
  default     = true
}