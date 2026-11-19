resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "${local.name}: HTTP in, HTTPS out"
  vpc_id      = data.aws_vpc.default.id
}

# Only the app port is exposed. No SSH: shell access and deploys go through SSM.
resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_http_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "HTTP to the app"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# Outbound HTTPS covers ECR, CloudWatch Logs, SSM and the dnf package mirrors.
# DNS and NTP use the VPC resolver / Amazon Time Sync, which security groups don't filter.
# Accepted: ECR/SSM/CloudWatch are public endpoints, so restricting egress further needs
# VPC interface endpoints (~$7/month each). Listed under "What I would improve".
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs and package mirrors"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region         = var.aws_region
    ecr_repository_url = aws_ecr_repository.app.repository_url
    log_group          = aws_cloudwatch_log_group.app.name
    environment        = var.environment
    log_level          = var.log_level
    image_tag          = var.image_tag
    deploy_script      = file("${path.module}/../scripts/deploy-app.sh")
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  monitoring = false # detailed monitoring costs extra; basic 5-minute metrics are enough here

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami] # don't replace the instance every time a new AMI is published
  }
}
