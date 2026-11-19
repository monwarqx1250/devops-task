bucket       = "REPLACE-with-your-state-bucket"
key          = "devops-task/production/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true # S3-native state locking (Terraform >= 1.10)
