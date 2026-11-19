# Container stdout/stderr is shipped here by Docker's awslogs log driver.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}/app"
  retention_in_days = var.log_retention_days
}
