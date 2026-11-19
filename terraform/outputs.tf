output "instance_id" {
  description = "EC2 instance ID (GitHub variable EC2_INSTANCE_ID)."
  value       = aws_instance.app.id
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_dns}"
}

output "github_actions_role_arn" {
  description = "Role assumed by GitHub Actions via OIDC (GitHub variable AWS_ROLE_ARN)."
  value       = aws_iam_role.github_deploy.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "ssm_shell" {
  description = "Open a shell on the instance without SSH."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}
