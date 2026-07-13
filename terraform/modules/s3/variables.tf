# terraform/modules/s3/variables.tf

variable "bucket_name" {
  description = "Globally-unique S3 bucket name."
  type        = string
}

variable "access_log_bucket_id" {
  description = "Optional destination bucket ID for S3 server access logs. Leave null to disable (e.g. when this module creates the log bucket itself)."
  type        = string
  default     = null
}
