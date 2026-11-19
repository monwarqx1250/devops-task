variable "project" {
  description = "Project name, used as a prefix for resource names."
  type        = string
  default     = "devops-task"
}

variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be \"staging\" or \"production\"."
  }
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is Free Tier eligible."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (Amazon Linux 2023 needs at least 8)."
  type        = number
  default     = 10
}

variable "allowed_http_cidrs" {
  description = "CIDR blocks allowed to reach the app on port 80."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "image_tag" {
  description = "Image tag started on first boot. Later deploys come from CI via SSM. Leave empty to boot without starting the app."
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Application log level."
  type        = string
  default     = "info"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for container logs."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs supports (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to assume the deploy role via OIDC."
  type        = string
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Only one may exist per AWS account, so set false in the second environment."
  type        = bool
  default     = true
}

variable "image_repository" {
  description = "Container image repository the instance pulls from (GitHub Container Registry)."
  type        = string
  default     = "ghcr.io/monwarqx1250/devops-task"
}
