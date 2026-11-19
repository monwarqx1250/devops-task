# ---------------------------------------------------------------------------
# EC2 instance role: write to this log group and register with SSM (for CI
# deploys and shell access without SSH). Images come from GHCR, so no registry
# permissions are needed in AWS.
# No static access keys anywhere: credentials come from the instance profile.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "WriteAppLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "app-runtime"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

# Required for SSM Run Command (deploys) and Session Manager (no SSH needed).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}
