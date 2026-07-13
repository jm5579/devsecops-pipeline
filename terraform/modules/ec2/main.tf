# terraform/modules/ec2/main.tf
#
# SECURITY DECISION SUMMARY: the application instance lives in a private
# subnet with no public IP and no open inbound SSH port. The only inbound
# rule permitted is the application port, and only from the load
# balancer/ingress security group - never 0.0.0.0/0. All administrative
# access is via AWS Systems Manager (see terraform/modules/iam), not SSH.

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  # SECURITY DECISION: always resolve the latest Amazon Linux 2023 AMI at
  # apply time rather than pinning a specific, aging AMI ID, so newly
  # launched instances pick up the latest OS security patches. The
  # running instance itself is still kept current via SSM Patch Manager
  # (see README > Future Improvements for automating that).
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "Security group for the secure-python-app EC2 instance"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-app-sg"
  }
}

# SECURITY DECISION: inbound is restricted to exactly one port, and only
# from the specified ingress security group (e.g. an ALB), never a raw
# CIDR block. There is no SSH ingress rule anywhere in this module.
resource "aws_security_group_rule" "app_ingress" {
  type                     = "ingress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app.id
  source_security_group_id = var.ingress_security_group_id
  description               = "Application traffic from the load balancer/ingress security group only"
}

# SECURITY DECISION: egress is scoped to HTTPS only (443) - sufficient
# for pulling images from ECR, calling SSM/CloudWatch endpoints, and
# reaching the NAT Gateway - rather than an unrestricted allow-all
# egress rule, which is a common CIS Benchmark / Trivy misconfiguration
# finding when left wide open.
resource "aws_security_group_rule" "app_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.app.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS egress for ECR pulls, SSM, and CloudWatch"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = var.iam_instance_profile_name

  # SECURITY DECISION: no `key_name` is set - there is intentionally no
  # SSH key pair associated with this instance. Combined with the
  # absence of an SSH ingress rule above, direct SSH access is not
  # merely discouraged, it is architecturally impossible; SSM Session
  # Manager / Run Command is the only administrative path.

  metadata_options {
    http_tokens                = "required" # SECURITY DECISION: enforce IMDSv2, closing the classic SSRF-to-credential-theft path (IMDSv1)
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    encrypted   = true # SECURITY DECISION: EBS root volume encrypted at rest
    volume_size = 20
    volume_type = "gp3"
  }

  # SECURITY DECISION: user_data only installs the systemd unit and
  # container runtime - it never contains AWS credentials, the Flask
  # secret key, or any other sensitive value. FLASK_SECRET_KEY is
  # delivered separately via an SSM Parameter Store SecureString that
  # the systemd unit reads at start time (see README > GitHub Actions
  # Secrets Configuration for the end-to-end secret flow).
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    app_port   = var.app_port
    aws_region = var.aws_region
  })

  tags = {
    Name = "secure-python-app" # matched by the SSM deploy target in the GitHub Actions workflow
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---- CloudTrail ----------------------------------------------------------
resource "aws_cloudtrail" "main" {
  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = var.cloudtrail_bucket_id
  include_global_service_events = true
  is_multi_region_trail         = true # SECURITY DECISION: captures API activity in every region, not just the one this app is deployed to
  enable_log_file_validation    = true # SECURITY DECISION: cryptographically detects any tampering with delivered log files

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = {
    Name = "${var.name_prefix}-trail"
  }
}
