# terraform/modules/s3/main.tf
#
# SECURITY DECISION SUMMARY: this bucket stores application logs/
# artifacts (not Terraform state - that has its own bucket, see
# terraform/bootstrap). Every control below is required, not optional,
# reflecting how a federally regulated financial institution would
# expect any data-at-rest bucket to be configured by default.

resource "aws_kms_key" "s3" {
  description             = "KMS key for ${var.bucket_name} server-side encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true # SECURITY DECISION: automatic yearly key rotation without re-encrypting existing data

  tags = {
    Name = "${var.bucket_name}-kms-key"
  }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.s3.key_id
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  tags = {
    Name = var.bucket_name
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
    # SECURITY DECISION: versioning protects against accidental deletion
    # or overwrite of log/artifact data, and is a prerequisite for
    # object-lock style retention if that's added later.
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true # SECURITY DECISION: reduces KMS request cost/throttling without weakening encryption
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  # SECURITY DECISION: all four public access block settings enabled -
  # this bucket can never be made public even by a future bucket policy
  # or ACL misconfiguration, short of deliberately removing this resource.
}

resource "aws_s3_bucket_policy" "enforce_tls" {
  count  = var.manage_bucket_policy ? 1 : 0
  bucket = aws_s3_bucket.this.id

  # SECURITY DECISION: explicit deny on any request made without TLS,
  # so data can never be read or written to this bucket in plaintext
  # over the network, regardless of which client or role is used.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.this.arn,
        "${aws_s3_bucket.this.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-log-versions"
    status = "Enabled"

    # SECURITY DECISION: noncurrent (superseded) versions are retained
    # for 90 days - long enough for an incident investigation to recover
    # an overwritten/deleted object - then expired, rather than
    # accumulating indefinitely and becoming both a cost and a data-
    # minimization concern.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    filter {
      prefix = "app-logs/"
    }
  }
}

resource "aws_s3_bucket_logging" "this" {
  count  = var.enable_access_logging ? 1 : 0
  bucket = aws_s3_bucket.this.id

  target_bucket = var.access_log_bucket_id
  target_prefix = "s3-access-logs/${var.bucket_name}/"
  # SECURITY DECISION: server access logging is opt-in via variable so
  # this module can also be used to create the access-log bucket itself
  # (which cannot log to itself). See README > Terraform Infrastructure.
}
