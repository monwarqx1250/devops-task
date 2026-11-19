locals {
  name = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}

# Default VPC is acceptable for this task (see README "Design decisions").
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Latest Amazon Linux 2023 AMI for the instance's architecture.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

locals {
  arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.arch}"
}
